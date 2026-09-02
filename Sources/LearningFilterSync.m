// LearningFilterSync.m - builds the whitelist from the account's real
// subscription list, and enforces the "one signed-in account" rule.
//
// The tweak has no credentials of its own, so it borrows them: every outgoing
// InnerTube request is inspected (read only) and its auth headers are cached.
// With those headers we can issue a `browse` call for FEchannels ("All
// subscriptions") and read back the channels the account is subscribed to.

#import "LearningFilter.h"

static NSString *const kLFInnerTubeBrowseURL = @"https://youtubei.googleapis.com/youtubei/v1/browse?prettyPrint=false";
static NSTimeInterval const kLFSyncInterval = 6 * 60 * 60; // 6 hours
static NSUInteger const kLFMaxContinuations = 20;

static NSArray<NSString *> *LFForwardedHeaderFields(void) {
    static NSArray *fields;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fields = @[
            @"Authorization", @"X-Goog-AuthUser", @"X-Goog-Visitor-Id", @"X-Goog-PageId",
            @"X-Goog-Api-Format-Version", @"X-Youtube-Client-Name", @"X-Youtube-Client-Version",
            @"X-Goog-Device-Auth", @"User-Agent", @"Accept-Language", @"Cookie"
        ];
    });
    return fields;
}

static NSString *LFHeader(NSURLRequest *request, NSString *field) {
    NSString *value = [request valueForHTTPHeaderField:field];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : nil;
}

static BOOL LFIsInnerTubeRequest(NSURLRequest *request) {
    NSString *url = request.URL.absoluteString;
    return [url isKindOfClass:[NSString class]] && [url containsString:@"/youtubei/v1/"];
}

static BOOL LFIsOwnRequest(NSURLRequest *request) {
    return LFHeader(request, kLFOwnRequestHeader) != nil;
}

#pragma mark - JSON helpers

static NSString *LFTitleString(id value) {
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0 ? value : nil;
    if (![value isKindOfClass:[NSDictionary class]])
        return nil;

    NSDictionary *dictionary = value;
    id simple = dictionary[@"simpleText"];
    if ([simple isKindOfClass:[NSString class]] && [(NSString *)simple length] > 0)
        return simple;

    id runs = dictionary[@"runs"];
    if ([runs isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id run in runs) {
            if ([run isKindOfClass:[NSDictionary class]] && [run[@"text"] isKindOfClass:[NSString class]])
                [text appendString:run[@"text"]];
        }
        if (text.length > 0)
            return [text copy];
    }
    return nil;
}

static BOOL LFLooksLikeChannelId(id value) {
    if (![value isKindOfClass:[NSString class]])
        return NO;
    NSString *text = value;
    if (text.length != 24 || ![text hasPrefix:@"UC"])
        return NO;
    static NSCharacterSet *disallowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        disallowed = [[NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    });
    return [text rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

/// YES when this renderer's own subtree says the account is subscribed. Used to
/// keep "channels you might like" shelves out of the whitelist.
static BOOL LFSubtreeSaysSubscribed(id json, NSUInteger depth) {
    if (depth > 6)
        return NO;

    if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json) {
            if (LFSubtreeSaysSubscribed(item, depth + 1))
                return YES;
        }
        return NO;
    }

    if (![json isKindOfClass:[NSDictionary class]])
        return NO;

    NSDictionary *dictionary = json;
    id subscribed = dictionary[@"subscribed"];
    if ([subscribed isKindOfClass:[NSNumber class]] && [subscribed boolValue])
        return YES;

    for (id value in dictionary.allValues) {
        if (LFSubtreeSaysSubscribed(value, depth + 1))
            return YES;
    }
    return NO;
}

/// Walks a decoded InnerTube response and records every channel it describes,
/// plus any continuation token so long subscription lists can be paged.
static void LFCollectChannels(id json, NSMutableDictionary<NSString *, NSString *> *channels,
                              NSMutableSet<NSString *> *subscribedIds,
                              NSMutableArray<NSString *> *continuations, NSUInteger depth) {
    if (depth > 40)
        return;

    if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json)
            LFCollectChannels(item, channels, subscribedIds, continuations, depth + 1);
        return;
    }

    if (![json isKindOfClass:[NSDictionary class]])
        return;

    NSDictionary *dictionary = json;

    NSString *channelId = nil;
    if (LFLooksLikeChannelId(dictionary[@"channelId"]))
        channelId = dictionary[@"channelId"];
    if (!channelId && [dictionary[@"navigationEndpoint"] isKindOfClass:[NSDictionary class]]) {
        id browse = dictionary[@"navigationEndpoint"][@"browseEndpoint"];
        if ([browse isKindOfClass:[NSDictionary class]] && LFLooksLikeChannelId(browse[@"browseId"]))
            channelId = browse[@"browseId"];
    }
    if (!channelId && [dictionary[@"browseEndpoint"] isKindOfClass:[NSDictionary class]] &&
        LFLooksLikeChannelId(dictionary[@"browseEndpoint"][@"browseId"]))
        channelId = dictionary[@"browseEndpoint"][@"browseId"];

    if (channelId) {
        NSString *name = LFTitleString(dictionary[@"title"]) ?: LFTitleString(dictionary[@"channelTitle"])
                                                            ?: LFTitleString(dictionary[@"displayName"])
                                                            ?: LFTitleString(dictionary[@"shortBylineText"]);
        NSString *existing = channels[channelId];
        if (!existing || (existing.length == 0 && name.length > 0))
            channels[channelId] = name ?: @"";
        if (LFSubtreeSaysSubscribed(dictionary, 0))
            [subscribedIds addObject:channelId];
    }

    id continuation = dictionary[@"continuationCommand"];
    if ([continuation isKindOfClass:[NSDictionary class]] && [continuation[@"token"] isKindOfClass:[NSString class]])
        [continuations addObject:continuation[@"token"]];

    for (id value in dictionary.allValues)
        LFCollectChannels(value, channels, subscribedIds, continuations, depth + 1);
}

#pragma mark - LFSubscriptionSync

@interface LFSubscriptionSync ()
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *capturedHeaders;
@property(nonatomic, copy) NSString *clientVersion;
@property(nonatomic, assign) BOOL syncing;
@property(nonatomic, copy) NSString *statusDescription;
@property(nonatomic, strong) NSURLSession *session;
@end

@implementation LFSubscriptionSync

+ (instancetype)sharedSync {
    static LFSubscriptionSync *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusDescription = @"Not synced yet";
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 20;
        configuration.HTTPShouldSetCookies = YES;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)captureRequest:(NSURLRequest *)request {
    if (![request isKindOfClass:[NSURLRequest class]] || LFIsOwnRequest(request) || !LFIsInnerTubeRequest(request))
        return;
    if (!LFHeader(request, @"Authorization"))
        return; // Only authenticated requests carry a usable identity.

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *field in LFForwardedHeaderFields()) {
        NSString *value = LFHeader(request, field);
        if (value)
            headers[field] = value;
    }
    if (headers.count == 0)
        return;

    @synchronized(self) {
        self.capturedHeaders = [headers copy];
        NSString *version = headers[@"X-Youtube-Client-Version"];
        if (version.length > 0)
            self.clientVersion = version;
    }
}

- (BOOL)hasCredentials {
    @synchronized(self) {
        return self.capturedHeaders.count > 0;
    }
}

- (void)syncIfStale {
    NSDate *last = [[LFSubscriptionStore sharedStore] lastSyncDate];
    if (last && [[NSDate date] timeIntervalSinceDate:last] < kLFSyncInterval &&
        [[LFSubscriptionStore sharedStore] ready])
        return;
    [self syncForcedWithCompletion:nil];
}

- (NSMutableURLRequest *)browseRequestWithBody:(NSDictionary *)body {
    NSDictionary *headers = nil;
    @synchronized(self) {
        headers = self.capturedHeaders;
    }
    if (headers.count == 0)
        return nil;

    NSError *error = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
    if (!payload)
        return nil;

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLFInnerTubeBrowseURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = payload;
    for (NSString *field in headers)
        [request setValue:headers[field] forHTTPHeaderField:field];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"1" forHTTPHeaderField:kLFOwnRequestHeader];
    return request;
}

- (NSDictionary *)contextForClient:(NSString *)clientName {
    NSString *version = self.clientVersion.length > 0 ? self.clientVersion : @"21.14.4";
    if ([clientName isEqualToString:@"WEB"])
        version = @"2.20240726.00.00";
    return @{
        @"client": @{
            @"clientName": clientName,
            @"clientVersion": version,
            @"hl": @"en",
            @"gl": @"US",
            @"platform": [clientName isEqualToString:@"WEB"] ? @"DESKTOP" : @"MOBILE"
        }
    };
}

/// Issues one browse call and hands back the decoded response.
- (void)performBrowseWithClient:(NSString *)clientName
                           body:(NSDictionary *)extraBody
                     completion:(void (^)(id json, NSData *raw, NSError *error))completion {
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:extraBody];
    body[@"context"] = [self contextForClient:clientName];

    NSMutableURLRequest *request = [self browseRequestWithBody:body];
    if (!request) {
        completion(nil, nil, [NSError errorWithDomain:@"LearningFilter"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"No InnerTube credentials captured yet"}]);
        return;
    }

    [[self.session dataTaskWithRequest:request
                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        if (error) {
                            completion(nil, nil, error);
                            return;
                        }
                        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                        completion(json, data, nil);
                    }] resume];
}

- (void)syncForcedWithCompletion:(void (^)(BOOL success, NSUInteger count, NSString *message))completion {
    @synchronized(self) {
        if (self.syncing) {
            if (completion)
                completion(NO, [[LFSubscriptionStore sharedStore] count], @"A sync is already running");
            return;
        }
        self.syncing = YES;
    }

    void (^finish)(BOOL, NSUInteger, NSString *) = ^(BOOL success, NSUInteger count, NSString *message) {
        @synchronized(self) {
            self.syncing = NO;
            self.statusDescription = message;
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(success, count, message); });
        }
    };

    if (![self hasCredentials]) {
        finish(NO, [[LFSubscriptionStore sharedStore] count],
               @"Waiting for YouTube to make a signed-in request — open a video, then try again");
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *collected = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *subscribedIds = [NSMutableSet set];
    [self browseSubscriptionsWithClients:@[@"IOS", @"WEB"]
                               clientIdx:0
                               collected:collected
                           subscribedIds:subscribedIds
                                  finish:finish];
}

/// Tries each client context in turn; the first one that yields channels wins.
- (void)browseSubscriptionsWithClients:(NSArray<NSString *> *)clients
                             clientIdx:(NSUInteger)clientIdx
                             collected:(NSMutableDictionary<NSString *, NSString *> *)collected
                         subscribedIds:(NSMutableSet<NSString *> *)subscribedIds
                                finish:(void (^)(BOOL, NSUInteger, NSString *))finish {
    if (clientIdx >= clients.count) {
        [self commitCollected:collected subscribedIds:subscribedIds finish:finish];
        return;
    }

    NSString *client = clients[clientIdx];
    [self browseWithClient:client
                      body:@{@"browseId": @"FEchannels"}
                 collected:collected
             subscribedIds:subscribedIds
             continuations:0
                completion:^{
                    if (collected.count > 0) {
                        [self commitCollected:collected subscribedIds:subscribedIds finish:finish];
                        return;
                    }
                    [self browseSubscriptionsWithClients:clients
                                               clientIdx:clientIdx + 1
                                               collected:collected
                                           subscribedIds:subscribedIds
                                                  finish:finish];
                }];
}

- (void)browseWithClient:(NSString *)client
                    body:(NSDictionary *)body
               collected:(NSMutableDictionary<NSString *, NSString *> *)collected
           subscribedIds:(NSMutableSet<NSString *> *)subscribedIds
           continuations:(NSUInteger)continuationCount
              completion:(void (^)(void))completion {
    [self performBrowseWithClient:client
                             body:body
                       completion:^(id json, NSData *raw, NSError *error) {
                           if (error || !json) {
                               // Server-driven responses are not always JSON we
                               // can decode; fall back to a raw id scan.
                               NSSet<NSString *> *ids = LFChannelIdsInData(raw);
                               for (NSString *channelId in ids) {
                                   if (!collected[channelId])
                                       collected[channelId] = @"";
                               }
                               completion();
                               return;
                           }

                           NSMutableArray<NSString *> *tokens = [NSMutableArray array];
                           LFCollectChannels(json, collected, subscribedIds, tokens, 0);

                           if (tokens.count > 0 && continuationCount < kLFMaxContinuations) {
                               [self browseWithClient:client
                                                 body:@{@"continuation": tokens.firstObject}
                                            collected:collected
                                        subscribedIds:subscribedIds
                                        continuations:continuationCount + 1
                                           completion:completion];
                               return;
                           }
                           completion();
                       }];
}

- (void)commitCollected:(NSMutableDictionary<NSString *, NSString *> *)collected
          subscribedIds:(NSMutableSet<NSString *> *)subscribedIds
                 finish:(void (^)(BOOL, NSUInteger, NSString *))finish {
    // Prefer the entries the response explicitly marks as subscribed; that keeps
    // "channels you might like" shelves out of the whitelist. Only when the
    // response carries no such marker do we fall back to every channel it named.
    NSArray<NSString *> *identifiers = subscribedIds.count > 0 ? subscribedIds.allObjects : collected.allKeys;

    // The signed-in user's own channel shows up in some responses; keeping it is
    // harmless (their own uploads stay visible) so no filtering is applied here.
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *channels = [NSMutableArray array];
    for (NSString *channelId in identifiers)
        [channels addObject:@{@"id": channelId, @"name": collected[channelId] ?: @""}];

    if (channels.count == 0) {
        finish(NO, [[LFSubscriptionStore sharedStore] count],
               @"Sync returned no channels — the whitelist was left untouched");
        return;
    }

    [[LFSubscriptionStore sharedStore] replaceWithChannels:channels];
    finish(YES, channels.count,
           [NSString stringWithFormat:@"Synced %lu subscribed channels", (unsigned long)channels.count]);
}

@end

#pragma mark - LFAccountGuard

@interface LFAccountGuard ()
@property(nonatomic, copy) NSString *boundAccountIdentifier;
@property(nonatomic, assign) NSUInteger signedOutStreak;
@end

@implementation LFAccountGuard

+ (instancetype)sharedGuard {
    static LFAccountGuard *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        id stored = [[NSUserDefaults standardUserDefaults] stringForKey:kLFBoundAccount];
        if ([stored isKindOfClass:[NSString class]])
            _boundAccountIdentifier = stored;
    }
    return self;
}

/// Stable-ish identity for the account behind a request. `X-Goog-PageId` names
/// the channel/brand account; `X-Goog-AuthUser` is the slot index and is the
/// fallback when no page id is present.
static NSString *LFIdentityForRequest(NSURLRequest *request) {
    NSString *pageId = LFHeader(request, @"X-Goog-PageId");
    if (pageId.length > 0)
        return [@"page:" stringByAppendingString:pageId];
    NSString *authUser = LFHeader(request, @"X-Goog-AuthUser");
    if (authUser.length > 0)
        return [@"authuser:" stringByAppendingString:authUser];
    return nil;
}

- (void)noteRequest:(NSURLRequest *)request {
    if (![request isKindOfClass:[NSURLRequest class]] || LFIsOwnRequest(request) || !LFIsInnerTubeRequest(request))
        return;

    if (!LFHeader(request, @"Authorization")) {
        NSString *url = request.URL.absoluteString;
        // Only genuine content calls count towards "the user signed out".
        if ([url containsString:@"/youtubei/v1/browse"] || [url containsString:@"/youtubei/v1/player"]) {
            @synchronized(self) {
                if (self.boundAccountIdentifier && ++self.signedOutStreak >= 5)
                    [self resetBoundAccount];
            }
        }
        return;
    }

    @synchronized(self) {
        self.signedOutStreak = 0;
        if (self.boundAccountIdentifier)
            return;
        NSString *identity = LFIdentityForRequest(request);
        if (identity.length == 0)
            return;
        self.boundAccountIdentifier = identity;
        [[NSUserDefaults standardUserDefaults] setObject:identity forKey:kLFBoundAccount];
    }
}

- (BOOL)shouldBlockRequest:(NSURLRequest *)request {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kLFSingleAccount])
        return NO;
    if (![request isKindOfClass:[NSURLRequest class]] || LFIsOwnRequest(request) || !LFIsInnerTubeRequest(request))
        return NO;
    if (!LFHeader(request, @"Authorization"))
        return NO;

    NSString *identity = LFIdentityForRequest(request);
    if (identity.length == 0)
        return NO;

    @synchronized(self) {
        return self.boundAccountIdentifier.length > 0 && ![self.boundAccountIdentifier isEqualToString:identity];
    }
}

- (BOOL)accountSlotTaken {
    @synchronized(self) {
        return self.boundAccountIdentifier.length > 0;
    }
}

- (void)resetBoundAccount {
    @synchronized(self) {
        self.boundAccountIdentifier = nil;
        self.signedOutStreak = 0;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLFBoundAccount];
    }
    // The whitelist belonged to that account; without it Whitelist Mode has no
    // input and must go inert rather than hide everything (spec §9).
    [[LFSubscriptionStore sharedStore] reset];
}

@end
