// LearningFilterCore.m - whitelist storage, the shared allow/deny decision and
// the channel-id extraction used by every hooked surface.

#import "LearningFilter.h"
#import "LearningFilterScan.h"
#import <objc/runtime.h>

#pragma mark - Small reflection helpers

/// Safe `-valueForKey:`-like accessor: only calls zero-argument selectors that
/// return an object, and never throws. Mirrors Gonerino's ValueForObjectKey().
static id LFValueForKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector])
            return nil;

        Method method = class_getInstanceMethod(object_getClass(object), selector);
        if (!method)
            return nil;

        const char *encoding = method_getTypeEncoding(method);
        if (!encoding || encoding[0] != '@')
            return nil;

        return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

id LFSafeValueForKey(id object, NSString *key) {
    return LFValueForKey(object, key);
}

static NSString *LFNormalizedName(NSString *name) {
    if (![name isKindOfClass:[NSString class]])
        return nil;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return nil;
    return trimmed.lowercaseString;
}

static BOOL LFIsChannelId(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length != 24)
        return NO;
    if (![value hasPrefix:@"UC"])
        return NO;
    static NSCharacterSet *disallowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        disallowed = [[NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    });
    return [value rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

#pragma mark - LFSubscriptionStore

// The store is a singleton, so its state lives at file scope rather than in
// properties: private, and it keeps this file buildable by the off-device tests
// in Tests/ (see Tests/run-tests.sh). All access goes through @synchronized on
// the shared instance.
static NSMutableArray<NSDictionary<NSString *, NSString *> *> *sStorage;
static NSMutableSet<NSString *> *sIdSet;
static NSMutableSet<NSString *> *sNameSet;

@implementation LFSubscriptionStore

+ (instancetype)sharedStore {
    static LFSubscriptionStore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        sStorage = [NSMutableArray array];
        sIdSet = [NSMutableSet set];
        sNameSet = [NSMutableSet set];
        [self loadFromDefaults];
    }
    return self;
}

- (void)loadFromDefaults {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kLFStoredChannels];
    if (![stored isKindOfClass:[NSArray class]])
        return;
    [self ingest:stored replacing:YES persist:NO];
}

- (void)ingest:(NSArray *)channels replacing:(BOOL)replacing persist:(BOOL)persist {
    @synchronized(self) {
        if (replacing) {
            [sStorage removeAllObjects];
            [sIdSet removeAllObjects];
            [sNameSet removeAllObjects];
        }

        for (id entry in channels) {
            if (![entry isKindOfClass:[NSDictionary class]])
                continue;
            NSString *channelId = [entry objectForKey:@"id"];
            NSString *name = [entry objectForKey:@"name"];
            if (![channelId isKindOfClass:[NSString class]] || !LFIsChannelId(channelId))
                continue;
            if (![name isKindOfClass:[NSString class]])
                name = @"";

            if ([sIdSet containsObject:channelId]) {
                if (name.length == 0)
                    continue;
                // Upgrade a previously name-less entry.
                NSUInteger index = [sStorage indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
                    return [[obj objectForKey:@"id"] isEqualToString:channelId];
                }];
                if (index != NSNotFound && [[[sStorage objectAtIndex:index] objectForKey:@"name"] length] == 0)
                    [sStorage replaceObjectAtIndex:index withObject:@{@"id": channelId, @"name": name}];
            } else {
                [sStorage addObject:@{@"id": channelId, @"name": name}];
                [sIdSet addObject:channelId];
            }

            NSString *normalized = LFNormalizedName(name);
            if (normalized)
                [sNameSet addObject:normalized];
        }

        if (persist) {
            [[NSUserDefaults standardUserDefaults] setObject:[sStorage copy] forKey:kLFStoredChannels];
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kLFLastSyncDate];
        }
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)channels {
    @synchronized(self) {
        return [sStorage copy];
    }
}

- (NSUInteger)count {
    @synchronized(self) {
        return sStorage.count;
    }
}

- (NSDate *)lastSyncDate {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kLFLastSyncDate];
    return [value isKindOfClass:[NSDate class]] ? value : nil;
}

- (BOOL)ready {
    return self.count > 0;
}

- (BOOL)isSubscribedToChannelId:(NSString *)channelId {
    if (![channelId isKindOfClass:[NSString class]] || channelId.length == 0)
        return NO;
    @synchronized(self) {
        return [sIdSet containsObject:channelId];
    }
}

- (BOOL)isSubscribedToChannelName:(NSString *)channelName {
    NSString *normalized = LFNormalizedName(channelName);
    if (!normalized)
        return NO;
    @synchronized(self) {
        return [sNameSet containsObject:normalized];
    }
}

- (void)replaceWithChannels:(NSArray<NSDictionary<NSString *, NSString *> *> *)channels {
    [self ingest:channels replacing:YES persist:YES];
}

- (void)mergeChannels:(NSArray<NSDictionary<NSString *, NSString *> *> *)channels {
    [self ingest:channels replacing:NO persist:YES];
}

- (void)reset {
    @synchronized(self) {
        [sStorage removeAllObjects];
        [sIdSet removeAllObjects];
        [sNameSet removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLFStoredChannels];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLFLastSyncDate];
    }
}

@end

#pragma mark - Decision layer

BOOL LFIsSubscribedToChannel(NSString *channelId) {
    return [[LFSubscriptionStore sharedStore] isSubscribedToChannelId:channelId];
}

BOOL LFIsAllowedChannel(NSString *channelId) {
    // The whole point of Learning Mode: allowed == subscribed (spec §4, §8).
    return LFIsSubscribedToChannel(channelId);
}

BOOL LFFilteringActive(void) {
    // The only thing that can hold the filter back: signed out or never synced,
    // where no whitelist exists so Whitelist Mode cannot be applied at all
    // (spec §9). Staying inert beats blanking the whole app.
    return [[LFSubscriptionStore sharedStore] ready];
}

LFDecision LFDecisionForInfo(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]])
        return LFDecisionUnknown;

    NSSet<NSString *> *channelIds = [info objectForKey:LFInfoChannelIds];
    if ([channelIds isKindOfClass:[NSSet class]] && channelIds.count > 0) {
        for (NSString *channelId in channelIds) {
            if (LFIsAllowedChannel(channelId))
                return LFDecisionAllow;
        }
        return LFDecisionHide;
    }

    NSString *channelName = [info objectForKey:LFInfoChannelName];
    if ([channelName isKindOfClass:[NSString class]] && channelName.length > 0)
        return [[LFSubscriptionStore sharedStore] isSubscribedToChannelName:channelName] ? LFDecisionAllow
                                                                                         : LFDecisionHide;

    return LFDecisionUnknown;
}

BOOL LFShouldHideInfo(NSDictionary *info) {
    switch (LFDecisionForInfo(info)) {
        case LFDecisionAllow:
            return NO;
        case LFDecisionHide:
        case LFDecisionUnknown:
            // Spec §14: never allow something through on a guess.
            return YES;
    }
    return YES;
}

#pragma mark - Payload scanning

// The scanning itself lives in LearningFilterScan.m (pure C) so it can be
// exercised by Tests/LearningFilterScanTests.c without a device. Everything
// below only converts its results into the Foundation types used above.

static NSUInteger const kLFMaxScannedBytes = 262144;

// An enum, not a `const size_t`: in C the latter is not a constant expression,
// so the stack buffers below would become variable-length arrays.
enum { kLFMaxIds = 64 };

static NSSet<NSString *> *LFChannelIdSetFromBytes(const uint8_t *bytes, size_t length) {
    LFScanChannelId found[kLFMaxIds];
    size_t strongCount = 0;
    size_t count = LFScanChannelIds(bytes, length, found, kLFMaxIds, &strongCount);
    if (count == 0)
        return [NSSet set];

    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (size_t index = 0; index < count; index++) {
        // When any protobuf-prefixed id is present the unprefixed ones are
        // discarded: those are the ones that can be base64 noise.
        if (strongCount > 0 && !found[index].strong)
            continue;
        NSString *identifier = [[NSString alloc] initWithBytes:found[index].value
                                                        length:LF_CHANNEL_ID_LENGTH
                                                      encoding:NSUTF8StringEncoding];
        if (identifier.length == LF_CHANNEL_ID_LENGTH)
            [identifiers addObject:identifier];
    }
    return [identifiers copy];
}

NSDictionary *LFInfoFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return nil;

    const uint8_t *bytes = data.bytes;
    size_t length = (size_t)MIN(data.length, kLFMaxScannedBytes);

    LFScanVideoId videos[kLFMaxIds];
    size_t videoCount = 0;
    int fromShortsPath = 0;
    videoCount = LFScanVideoIdsAfterPrefix(bytes, length, "https://i.ytimg.com/vi/", videos, videoCount, kLFMaxIds,
                                           NULL);
    videoCount = LFScanVideoIdsAfterPrefix(bytes, length, "https://i.ytimg.com/vi_webp/", videos, videoCount,
                                           kLFMaxIds, NULL);
    videoCount = LFScanVideoIdsAfterPrefix(bytes, length, "/shorts/", videos, videoCount, kLFMaxIds, &fromShortsPath);
    videoCount = LFScanVideoIdsAfterPrefix(bytes, length, "watch?v=", videos, videoCount, kLFMaxIds, NULL);

    NSMutableSet<NSString *> *videoIds = [NSMutableSet set];
    for (size_t index = 0; index < videoCount; index++) {
        NSString *videoId = [[NSString alloc] initWithBytes:videos[index].value
                                                     length:LF_VIDEO_ID_LENGTH
                                                   encoding:NSUTF8StringEncoding];
        if (videoId.length == LF_VIDEO_ID_LENGTH)
            [videoIds addObject:videoId];
    }

    BOOL isShort = fromShortsPath || LFScanLooksLikeShorts(bytes, length);
    NSSet<NSString *> *channelIds = LFChannelIdSetFromBytes(bytes, length);
    if (videoIds.count == 0 && channelIds.count == 0)
        return nil;

    return @{LFInfoVideoIds: [videoIds copy], LFInfoChannelIds: channelIds, LFInfoIsShort: @(isShort)};
}


NSSet<NSString *> *LFChannelIdsInData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return [NSSet set];
    return LFChannelIdSetFromBytes(data.bytes, (size_t)MIN(data.length, (NSUInteger)8388608));
}

NSDictionary *LFInfoFromString(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0)
        return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return LFInfoFromData(data);
}

static NSDictionary *LFMergeInfo(NSDictionary *lhs, NSDictionary *rhs) {
    if (!lhs)
        return rhs;
    if (!rhs)
        return lhs;

    NSMutableSet *videoIds = [NSMutableSet set];
    [videoIds unionSet:[lhs objectForKey:LFInfoVideoIds] ?: [NSSet set]];
    [videoIds unionSet:[rhs objectForKey:LFInfoVideoIds] ?: [NSSet set]];

    NSMutableSet *channelIds = [NSMutableSet set];
    [channelIds unionSet:[lhs objectForKey:LFInfoChannelIds] ?: [NSSet set]];
    [channelIds unionSet:[rhs objectForKey:LFInfoChannelIds] ?: [NSSet set]];

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    [merged setObject:[videoIds copy] forKey:LFInfoVideoIds];
    [merged setObject:[channelIds copy] forKey:LFInfoChannelIds];
    [merged setObject:@([[lhs objectForKey:LFInfoIsShort] boolValue] || [[rhs objectForKey:LFInfoIsShort] boolValue])
                forKey:LFInfoIsShort];
    NSString *name = [lhs objectForKey:LFInfoChannelName] ?: [rhs objectForKey:LFInfoChannelName];
    if (name)
        [merged setObject:name forKey:LFInfoChannelName];
    return [merged copy];
}

BOOL LFInfoIsSingleVideoLockup(NSDictionary *info) {
    NSSet *videoIds = [info objectForKey:LFInfoVideoIds];
    return [videoIds isKindOfClass:[NSSet class]] && videoIds.count == 1;
}

#pragma mark - Object extraction

static NSMapTable *LFInfoCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

// Element payloads are populated lazily, so the first scan of a node can come up
// short. Caching that permanently would hide the item for good once strict mode
// is on, so an incomplete answer is parked here and retried a few times instead.
static NSMapTable *LFPendingCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

static NSTimeInterval const kLFRetryInterval = 1.0;
static NSUInteger const kLFMaxScanAttempts = 5;

/// Sentinel for "scanned, definitively nothing here".
static NSDictionary *LFEmptyInfo(void) {
    static NSDictionary *empty;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ empty = @{}; });
    return empty;
}

/// An answer is only worth keeping once it identifies a channel; anything less
/// is a scan that may still improve on the next pass.
static BOOL LFInfoIsComplete(NSDictionary *info) {
    if (!info)
        return NO;
    return [[info objectForKey:LFInfoChannelIds] count] > 0 ||
           [[info objectForKey:LFInfoChannelName] length] > 0;
}

/// YES when a cached answer exists; `info` then holds it (possibly nil).
static BOOL LFLookupCachedInfo(id object, NSDictionary **info) {
    if (!object)
        return NO;

    @synchronized(LFInfoCache()) {
        NSDictionary *cached = [LFInfoCache() objectForKey:object];
        if (cached) {
            *info = cached.count > 0 ? cached : nil;
            return YES;
        }

        NSDictionary *pending = [LFPendingCache() objectForKey:object];
        if (!pending)
            return NO;

        NSDictionary *partial = [pending objectForKey:@"info"];
        NSUInteger attempts = [[pending objectForKey:@"attempts"] unsignedIntegerValue];
        NSTimeInterval recorded = [[pending objectForKey:@"time"] doubleValue];
        BOOL exhausted = attempts >= kLFMaxScanAttempts;
        if (exhausted || [NSDate timeIntervalSinceReferenceDate] - recorded < kLFRetryInterval) {
            *info = partial.count > 0 ? partial : nil;
            return YES;
        }
        return NO; // stale and retries left: scan again
    }
}

static void LFRecordInfo(id object, NSDictionary *info) {
    if (!object)
        return;

    @synchronized(LFInfoCache()) {
        if (LFInfoIsComplete(info)) {
            [LFInfoCache() setObject:info forKey:object];
            [LFPendingCache() removeObjectForKey:object];
            return;
        }

        NSDictionary *pending = [LFPendingCache() objectForKey:object];
        NSUInteger attempts = [[pending objectForKey:@"attempts"] unsignedIntegerValue] + 1;
        if (attempts >= kLFMaxScanAttempts) {
            // Give up rescanning; remember whatever the last pass produced.
            [LFInfoCache() setObject:info ?: LFEmptyInfo() forKey:object];
            [LFPendingCache() removeObjectForKey:object];
            return;
        }

        [LFPendingCache() setObject:@{
            @"info": info ?: LFEmptyInfo(),
            @"attempts": @(attempts),
            @"time": @([NSDate timeIntervalSinceReferenceDate])
        }
                             forKey:object];
    }
}

static NSString *LFChannelNameFromObject(id object) {
    for (NSString *key in @[@"ownerDisplayName", @"ownerName", @"channelName", @"channelTitle", @"authorName"]) {
        id value = LFValueForKey(object, key);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
            return value;
        if ([value respondsToSelector:@selector(string)]) {
            id text = LFValueForKey(value, @"string");
            if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0)
                return text;
        }
    }
    return nil;
}

/// Guards `-description` re-entrancy: the protobuf dump is only taken when the
/// cheap binary scan came up short. Re-entrancy is per-thread, and layout runs
/// on several, so this has to be thread-local rather than one shared flag.
static __thread BOOL LFDescribing = NO;

static NSDictionary *LFInfoFromRendererUncached(id renderer, NSData *payload) {
    NSDictionary *info = nil;

    NSData *data = payload;
    if (![data isKindOfClass:[NSData class]])
        data = LFValueForKey(renderer, @"elementData");
    if (![data isKindOfClass:[NSData class]])
        data = LFValueForKey(renderer, @"data");
    if ([data isKindOfClass:[NSData class]])
        info = LFInfoFromData(data);

    NSSet *channelIds = [info objectForKey:LFInfoChannelIds];
    BOOL needsDescription = (![channelIds isKindOfClass:[NSSet class]] || channelIds.count == 0) &&
                            [[info objectForKey:LFInfoVideoIds] count] > 0;
    if (needsDescription && !LFDescribing) {
        LFDescribing = YES;
        @try {
            info = LFMergeInfo(info, LFInfoFromString([renderer description]));
        } @catch (__unused NSException *exception) {
        }
        LFDescribing = NO;
    }

    NSString *name = LFChannelNameFromObject(renderer);
    if (name && info) {
        NSMutableDictionary *mutable = [info mutableCopy];
        [mutable setObject:name forKey:LFInfoChannelName];
        info = [mutable copy];
    }
    return info;
}

NSDictionary *LFInfoForRenderer(id renderer, NSData *data) {
    if (!renderer)
        return nil;

    NSDictionary *cached = nil;
    if (LFLookupCachedInfo(renderer, &cached))
        return cached;

    NSDictionary *info = nil;
    @try {
        info = LFInfoFromRendererUncached(renderer, data);
    } @catch (__unused NSException *exception) {
    }
    LFRecordInfo(renderer, info);
    return info;
}

NSDictionary *LFInfoFromElementRenderer(id renderer) {
    return LFInfoForRenderer(renderer, nil);
}

/// Walks the handful of relationships that lead from a feed cell's display node
/// to the element renderer that produced it (same route Gonerino uses).
static id LFElementRendererForNode(id node) {
    id parentResponder = LFValueForKey(node, @"parentResponder");
    id elementEntry = LFValueForKey(parentResponder, @"elementEntry");
    if (elementEntry)
        return elementEntry;

    for (NSString *key in @[@"elementRenderer", @"element", @"entry", @"asdPlayableEntry"]) {
        id candidate = LFValueForKey(node, key);
        if (candidate)
            return candidate;
    }

    id controller = LFValueForKey(node, @"controller");
    id entry = LFValueForKey(controller, @"elementEntry");
    if (entry)
        return entry;

    return nil;
}

NSDictionary *LFInfoFromNode(id node) {
    if (!node)
        return nil;

    NSDictionary *cached = nil;
    if (LFLookupCachedInfo(node, &cached))
        return cached;

    NSDictionary *info = nil;
    @try {
        info = LFInfoFromElementRenderer(LFElementRendererForNode(node));

        if (!info) {
            // Shorts nodes hang their metadata off the backing view's node.
            UIView *view = LFValueForKey(node, @"view");
            id viewNode = LFValueForKey(view, @"asyncdisplaykit_node");
            if (viewNode && viewNode != node)
                info = LFInfoFromElementRenderer(LFElementRendererForNode(viewNode));
        }

        NSString *name = LFChannelNameFromObject(node);
        if (name) {
            NSMutableDictionary *mutable = info ? [info mutableCopy] : [NSMutableDictionary dictionary];
            [mutable setObject:name forKey:LFInfoChannelName];
            info = [mutable copy];
        }
    } @catch (__unused NSException *exception) {
    }

    LFRecordInfo(node, info);
    return info;
}

#pragma mark - Subscription / account control identifiers

BOOL LFDataLooksLikeSubscribeControl(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return NO;
    return LFScanLooksLikeSubscribeControl(data.bytes, (size_t)MIN(data.length, kLFMaxScannedBytes)) ? YES : NO;
}

BOOL LFIsSubscriptionMutationURL(NSURL *url) {
    NSString *path = url.absoluteString;
    if (![path isKindOfClass:[NSString class]] || path.length == 0)
        return NO;
    return [path containsString:@"/youtubei/v1/subscription/subscribe"] ||
           [path containsString:@"/youtubei/v1/subscription/unsubscribe"];
}

static BOOL LFIdentifierMatchesAny(NSString *identifier, NSArray<NSString *> *needles) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0)
        return NO;
    NSString *normalized = identifier.lowercaseString;
    for (NSString *needle in needles) {
        if ([normalized containsString:needle])
            return YES;
    }
    return NO;
}

BOOL LFIdentifierIsSubscribeControl(NSString *identifier) {
    return LFIdentifierMatchesAny(identifier, @[
        @"subscribe_button", @"compact_subscribe", @"subscription_button", @"subscribe-button",
        @"channel_subscribe", @"shorts_subscribe"
    ]);
}

BOOL LFIdentifierIsAccountSwitchControl(NSString *identifier) {
    return LFIdentifierMatchesAny(identifier, @[
        @"add_account", @"add-account", @"account_switcher", @"account-switcher", @"channel_switcher",
        @"switch_account", @"add_channel", @"identity_switch"
    ]);
}
