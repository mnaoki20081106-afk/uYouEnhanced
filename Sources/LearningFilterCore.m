// LearningFilterCore.m - whitelist storage, the shared allow/deny decision and
// the channel-id extraction used by every hooked surface.

#import "LearningFilter.h"
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

@interface LFSubscriptionStore ()
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *storage;
@property(nonatomic, strong) NSMutableSet<NSString *> *idSet;
@property(nonatomic, strong) NSMutableSet<NSString *> *nameSet;
@end

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
        _storage = [NSMutableArray array];
        _idSet = [NSMutableSet set];
        _nameSet = [NSMutableSet set];
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
            [self.storage removeAllObjects];
            [self.idSet removeAllObjects];
            [self.nameSet removeAllObjects];
        }

        for (id entry in channels) {
            if (![entry isKindOfClass:[NSDictionary class]])
                continue;
            NSString *channelId = entry[@"id"];
            NSString *name = entry[@"name"];
            if (![channelId isKindOfClass:[NSString class]] || !LFIsChannelId(channelId))
                continue;
            if (![name isKindOfClass:[NSString class]])
                name = @"";

            if ([self.idSet containsObject:channelId]) {
                if (name.length == 0)
                    continue;
                // Upgrade a previously name-less entry.
                NSUInteger index = [self.storage indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
                    return [obj[@"id"] isEqualToString:channelId];
                }];
                if (index != NSNotFound && [self.storage[index][@"name"] length] == 0)
                    self.storage[index] = @{@"id": channelId, @"name": name};
            } else {
                [self.storage addObject:@{@"id": channelId, @"name": name}];
                [self.idSet addObject:channelId];
            }

            NSString *normalized = LFNormalizedName(name);
            if (normalized)
                [self.nameSet addObject:normalized];
        }

        if (persist) {
            [[NSUserDefaults standardUserDefaults] setObject:[self.storage copy] forKey:kLFStoredChannels];
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kLFLastSyncDate];
        }
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)channels {
    @synchronized(self) {
        return [self.storage copy];
    }
}

- (NSUInteger)count {
    @synchronized(self) {
        return self.storage.count;
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
        return [self.idSet containsObject:channelId];
    }
}

- (BOOL)isSubscribedToChannelName:(NSString *)channelName {
    NSString *normalized = LFNormalizedName(channelName);
    if (!normalized)
        return NO;
    @synchronized(self) {
        return [self.nameSet containsObject:normalized];
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
        [self.storage removeAllObjects];
        [self.idSet removeAllObjects];
        [self.nameSet removeAllObjects];
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
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:kLFEnabled])
        return NO;
    // Signed out / never synced: no whitelist exists, so Whitelist Mode cannot
    // be applied at all (spec §9). Staying inert beats blanking the whole app.
    return [[LFSubscriptionStore sharedStore] ready];
}

LFDecision LFDecisionForInfo(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]])
        return LFDecisionUnknown;

    NSSet<NSString *> *channelIds = info[LFInfoChannelIds];
    if ([channelIds isKindOfClass:[NSSet class]] && channelIds.count > 0) {
        for (NSString *channelId in channelIds) {
            if (LFIsAllowedChannel(channelId))
                return LFDecisionAllow;
        }
        return LFDecisionHide;
    }

    NSString *channelName = info[LFInfoChannelName];
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
            return YES;
        case LFDecisionUnknown:
            break;
    }
    // Spec §14: never allow something through on a guess.
    return [[NSUserDefaults standardUserDefaults] boolForKey:kLFStrictUnknown];
}

#pragma mark - Byte scanning

static inline BOOL LFIsIdByte(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
           byte == '-' || byte == '_';
}

static NSUInteger LFFindBytes(const uint8_t *haystack, NSUInteger haystackLength, const char *needle,
                              NSUInteger needleLength, NSUInteger from) {
    if (needleLength == 0 || haystackLength < needleLength)
        return NSNotFound;
    for (NSUInteger index = from; index + needleLength <= haystackLength; index++) {
        if (memcmp(haystack + index, needle, needleLength) == 0)
            return index;
    }
    return NSNotFound;
}

/// Returns YES when at least one id was found behind `prefix`.
static BOOL LFCollectVideoIdsAfterPrefix(const uint8_t *bytes, NSUInteger length, const char *prefix,
                                         NSMutableSet<NSString *> *videoIds) {
    BOOL found = NO;
    NSUInteger prefixLength = strlen(prefix);
    NSUInteger cursor = 0;
    while (cursor + prefixLength + 11 <= length) {
        NSUInteger match = LFFindBytes(bytes, length, prefix, prefixLength, cursor);
        if (match == NSNotFound)
            return found;
        NSUInteger start = match + prefixLength;
        if (start + 11 > length)
            return found;

        BOOL valid = YES;
        for (NSUInteger offset = 0; offset < 11; offset++) {
            if (!LFIsIdByte(bytes[start + offset])) {
                valid = NO;
                break;
            }
        }
        if (valid && (start + 11 == length || !LFIsIdByte(bytes[start + 11]))) {
            NSString *videoId = [[NSString alloc] initWithBytes:bytes + start length:11 encoding:NSUTF8StringEncoding];
            if (videoId.length == 11) {
                [videoIds addObject:videoId];
                found = YES;
            }
        }
        cursor = match + prefixLength;
    }
    return found;
}

/// Collects `UC…` channel ids. A protobuf string field of length 24 is preceded
/// by the byte 0x18, which makes those matches far more trustworthy than an
/// accidental hit inside a base64 continuation token; when any such "strong"
/// match exists the weaker ones are discarded.
static NSSet<NSString *> *LFCollectChannelIds(const uint8_t *bytes, NSUInteger length) {
    NSMutableSet<NSString *> *strong = [NSMutableSet set];
    NSMutableSet<NSString *> *weak = [NSMutableSet set];

    for (NSUInteger index = 0; index + 24 <= length; index++) {
        if (bytes[index] != 'U' || bytes[index + 1] != 'C')
            continue;
        if (index > 0 && LFIsIdByte(bytes[index - 1]))
            continue;
        if (index + 24 < length && LFIsIdByte(bytes[index + 24]))
            continue;

        BOOL valid = YES;
        for (NSUInteger offset = 2; offset < 24; offset++) {
            if (!LFIsIdByte(bytes[index + offset])) {
                valid = NO;
                break;
            }
        }
        if (!valid)
            continue;

        NSString *channelId = [[NSString alloc] initWithBytes:bytes + index length:24 encoding:NSUTF8StringEncoding];
        if (channelId.length != 24)
            continue;
        if (index > 0 && bytes[index - 1] == 0x18)
            [strong addObject:channelId];
        else
            [weak addObject:channelId];
    }

    return strong.count > 0 ? [strong copy] : [weak copy];
}

NSDictionary *LFInfoFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return nil;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = MIN(data.length, (NSUInteger)262144);

    NSMutableSet<NSString *> *videoIds = [NSMutableSet set];
    LFCollectVideoIdsAfterPrefix(bytes, length, "https://i.ytimg.com/vi/", videoIds);
    LFCollectVideoIdsAfterPrefix(bytes, length, "https://i.ytimg.com/vi_webp/", videoIds);
    BOOL isShort = LFCollectVideoIdsAfterPrefix(bytes, length, "/shorts/", videoIds);
    LFCollectVideoIdsAfterPrefix(bytes, length, "watch?v=", videoIds);

    if (!isShort) {
        static const char *shortsMarkers[] = {"shorts_video_cell", "reel_item", "shorts_shelf"};
        for (NSUInteger index = 0; index < sizeof(shortsMarkers) / sizeof(shortsMarkers[0]); index++) {
            const char *marker = shortsMarkers[index];
            if (LFFindBytes(bytes, length, marker, strlen(marker), 0) != NSNotFound) {
                isShort = YES;
                break;
            }
        }
    }

    NSSet<NSString *> *channelIds = LFCollectChannelIds(bytes, length);
    if (videoIds.count == 0 && channelIds.count == 0)
        return nil;

    return @{LFInfoVideoIds: [videoIds copy], LFInfoChannelIds: channelIds, LFInfoIsShort: @(isShort)};
}

NSSet<NSString *> *LFChannelIdsInData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return [NSSet set];
    return LFCollectChannelIds(data.bytes, MIN(data.length, (NSUInteger)8388608));
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
    [videoIds unionSet:lhs[LFInfoVideoIds] ?: [NSSet set]];
    [videoIds unionSet:rhs[LFInfoVideoIds] ?: [NSSet set]];

    NSMutableSet *channelIds = [NSMutableSet set];
    [channelIds unionSet:lhs[LFInfoChannelIds] ?: [NSSet set]];
    [channelIds unionSet:rhs[LFInfoChannelIds] ?: [NSSet set]];

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    merged[LFInfoVideoIds] = [videoIds copy];
    merged[LFInfoChannelIds] = [channelIds copy];
    merged[LFInfoIsShort] = @([lhs[LFInfoIsShort] boolValue] || [rhs[LFInfoIsShort] boolValue]);
    NSString *name = lhs[LFInfoChannelName] ?: rhs[LFInfoChannelName];
    if (name)
        merged[LFInfoChannelName] = name;
    return [merged copy];
}

BOOL LFInfoIsSingleVideoLockup(NSDictionary *info) {
    NSSet *videoIds = info[LFInfoVideoIds];
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

// Sentinel stored for objects that carry nothing identifiable, so we do not
// rescan them on every layout pass.
static NSDictionary *LFEmptyInfo(void) {
    static NSDictionary *empty;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ empty = @{}; });
    return empty;
}

static NSDictionary *LFCachedInfo(id object) {
    if (!object)
        return nil;
    @synchronized(LFInfoCache()) {
        return [LFInfoCache() objectForKey:object];
    }
}

static void LFCacheInfo(id object, NSDictionary *info) {
    if (!object)
        return;
    @synchronized(LFInfoCache()) {
        [LFInfoCache() setObject:info ?: LFEmptyInfo() forKey:object];
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
/// cheap binary scan came up short.
static BOOL LFDescribing = NO;

static NSDictionary *LFInfoFromRendererUncached(id renderer, NSData *payload) {
    NSDictionary *info = nil;

    NSData *data = payload;
    if (![data isKindOfClass:[NSData class]])
        data = LFValueForKey(renderer, @"elementData");
    if (![data isKindOfClass:[NSData class]])
        data = LFValueForKey(renderer, @"data");
    if ([data isKindOfClass:[NSData class]])
        info = LFInfoFromData(data);

    NSSet *channelIds = info[LFInfoChannelIds];
    BOOL needsDescription = (![channelIds isKindOfClass:[NSSet class]] || channelIds.count == 0) &&
                            [info[LFInfoVideoIds] count] > 0;
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
        mutable[LFInfoChannelName] = name;
        info = [mutable copy];
    }
    return info;
}

NSDictionary *LFInfoForRenderer(id renderer, NSData *data) {
    if (!renderer)
        return nil;

    NSDictionary *cached = LFCachedInfo(renderer);
    if (cached)
        return cached.count > 0 ? cached : nil;

    NSDictionary *info = nil;
    @try {
        info = LFInfoFromRendererUncached(renderer, data);
    } @catch (__unused NSException *exception) {
    }
    LFCacheInfo(renderer, info);
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

    NSDictionary *cached = LFCachedInfo(node);
    if (cached)
        return cached.count > 0 ? cached : nil;

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
            mutable[LFInfoChannelName] = name;
            info = [mutable copy];
        }
    } @catch (__unused NSException *exception) {
    }

    LFCacheInfo(node, info);
    return info;
}

#pragma mark - Subscription / account control identifiers

BOOL LFDataLooksLikeSubscribeControl(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return NO;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = MIN(data.length, (NSUInteger)262144);
    static const char *needles[] = {"subscribe_button", "compact_subscribe", "subscription_button",
                                    "subscribe_button_view_model"};
    for (NSUInteger index = 0; index < sizeof(needles) / sizeof(needles[0]); index++) {
        const char *needle = needles[index];
        if (LFFindBytes(bytes, length, needle, strlen(needle), 0) != NSNotFound)
            return YES;
    }
    return NO;
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
