// Host tests for the Learning Mode whitelist store and decision layer.
// See Tests/run-tests.sh for how these are built and run off-device.

#import "LearningFilter.h"

#import <Foundation/Foundation.h>

static int gFailures = 0;
static int gChecks = 0;

static void check(BOOL condition, NSString *what) {
    gChecks++;
    if (!condition) {
        gFailures++;
        printf("FAIL: %s\n", what.UTF8String);
    }
}

#define REAL_ID @"UCabcdefghijklmnopqrstuv"
#define OTHER_ID @"UC0123456789_-ABCDEFGHIj"
#define THIRD_ID @"UCzyxwvutsrqponmlkjihgfe"

static NSData *DataFromString(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

/// A payload shaped like a home-feed video lockup: element id, thumbnail URL and
/// the channel's browse endpoint behind a protobuf length byte.
static NSData *LockupPayload(NSString *channelId, NSString *videoId) {
    NSMutableData *data = [NSMutableData data];
    [data appendData:DataFromString(@"\n\x10" @"eml.video_lockup")];
    [data appendData:DataFromString([NSString stringWithFormat:@"\x12,https://i.ytimg.com/vi/%@/hq720.jpg", videoId])];
    uint8_t endpoint[] = {0x1a, 0x18};
    [data appendBytes:endpoint length:2];
    [data appendData:DataFromString(channelId)];
    uint8_t tail[] = {0x20, 0x01};
    [data appendBytes:tail length:2];
    return data;
}

static void resetDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[kLFStoredChannels, kLFLastSyncDate, kLFBoundAccount])
        [defaults removeObjectForKey:key];
    [[LFSubscriptionStore sharedStore] reset];
    LFSetOwnChannel(nil);
}

/// Stands in for a YTIElementRenderer whose payload is filled in lazily.
@interface LFFakeRenderer : NSObject {
@public
    int calls;
    NSData *payload;
}
- (NSData *)elementData;
@end

@implementation LFFakeRenderer
- (NSData *)elementData {
    calls++;
    return payload;
}
@end

#pragma mark - Tests

static void testPayloadExtraction(void) {
    NSDictionary *info = LFInfoFromData(LockupPayload(REAL_ID, @"dQw4w9WgXcQ"));
    check(info != nil, @"lockup payload yields info");
    check([[info objectForKey:LFInfoVideoIds] count] == 1, @"lockup has exactly one video id");
    check([[info objectForKey:LFInfoVideoIds] containsObject:@"dQw4w9WgXcQ"], @"lockup video id value");
    check([[info objectForKey:LFInfoChannelIds] count] == 1, @"lockup has exactly one channel id");
    check([[info objectForKey:LFInfoChannelIds] containsObject:REAL_ID], @"lockup channel id value");
    check(![[info objectForKey:LFInfoIsShort] boolValue], @"lockup is not a Short");
    check([[info objectForKey:LFInfoHasStrongChannelId] boolValue], @"lockup channel id is protobuf-prefixed");
    check(LFInfoCarriesContent(info), @"lockup carries content");

    // A shelf carries several videos, and all of their channels.
    NSMutableData *shelf = [[LockupPayload(REAL_ID, @"dQw4w9WgXcQ") mutableCopy] copy];
    NSMutableData *combined = [NSMutableData dataWithData:shelf];
    [combined appendData:LockupPayload(OTHER_ID, @"AbCdEfGhIjK")];
    NSDictionary *shelfInfo = LFInfoFromData(combined);
    check([[shelfInfo objectForKey:LFInfoVideoIds] count] == 2, @"shelf reports both videos");
    check([[shelfInfo objectForKey:LFInfoChannelIds] count] == 2, @"shelf reports both channels");
    check(LFInfoCarriesContent(shelfInfo), @"shelf carries content");

    // Shorts detection through the /shorts/ path.
    NSData *shorts = DataFromString(@"id.eml.shorts_video_cell yt://www.youtube.com/shorts/AbCdEfGhIjK");
    NSDictionary *shortsInfo = LFInfoFromData(shorts);
    check([[shortsInfo objectForKey:LFInfoIsShort] boolValue], @"shorts payload flagged as a Short");
    check([[shortsInfo objectForKey:LFInfoVideoIds] containsObject:@"AbCdEfGhIjK"], @"shorts video id value");

    // Nothing identifiable at all.
    check(LFInfoFromData(DataFromString(@"a header cell with no ids")) == nil, @"payload without ids yields nil");
    check(LFInfoFromData(nil) == nil, @"nil payload yields nil");
    check(LFInfoFromData([NSData data]) == nil, @"empty payload yields nil");

    // The base64 decoy must not displace the real channel.
    NSMutableData *withDecoy = [NSMutableData dataWithData:LockupPayload(REAL_ID, @"dQw4w9WgXcQ")];
    [withDecoy appendData:DataFromString([NSString stringWithFormat:@"\x22\x30" "4qmFsgIkEhhVQ%@GgxlZ2xw", OTHER_ID])];
    NSDictionary *decoyInfo = LFInfoFromData(withDecoy);
    check([[decoyInfo objectForKey:LFInfoChannelIds] count] == 1, @"decoy does not add a channel");
    check([[decoyInfo objectForKey:LFInfoChannelIds] containsObject:REAL_ID], @"real channel survives the decoy");
}

static void testStore(void) {
    resetDefaults();
    LFSubscriptionStore *store = [LFSubscriptionStore sharedStore];

    check(store.count == 0, @"store starts empty");
    check(!store.ready, @"empty store is not ready");
    check(!store.lastSyncDate, @"empty store has no sync date");

    [store replaceWithChannels:@[
        @{@"id": REAL_ID, @"name": @"Math Channel A"},
        @{@"id": OTHER_ID, @"name": @"Physics Channel B"},
        @{@"id": REAL_ID, @"name": @"Duplicate"},
        @{@"id": @"not-a-channel-id", @"name": @"Rejected"},          // too short
        @{@"id": @"XYabcdefghijklmnopqrstuv", @"name": @"Rejected"},  // right length, wrong prefix
        @{@"id": @"UCabcdefghij!lmnopqrstuv", @"name": @"Rejected"},  // illegal character
        @{@"id": @"", @"name": @"Rejected"},
        (NSDictionary *)@"not a dictionary" // deliberately the wrong type
    ]];

    check(store.count == 2, @"invalid and duplicate entries are dropped");
    check(![store isSubscribedToChannelId:@"XYabcdefghijklmnopqrstuv"], @"id without the UC prefix rejected");
    check(![store isSubscribedToChannelId:@"UCabcdefghij!lmnopqrstuv"], @"id with an illegal character rejected");
    check(store.ready, @"populated store is ready");
    check(store.lastSyncDate != nil, @"sync date recorded");
    check([store isSubscribedToChannelId:REAL_ID], @"subscribed id recognised");
    check([store isSubscribedToChannelId:OTHER_ID], @"second subscribed id recognised");
    check(![store isSubscribedToChannelId:THIRD_ID], @"unsubscribed id rejected");
    check(![store isSubscribedToChannelId:nil], @"nil id rejected");
    check(![store isSubscribedToChannelId:@""], @"empty id rejected");

    check([store isSubscribedToChannelName:@"Math Channel A"], @"subscribed name recognised");
    check([store isSubscribedToChannelName:@"  math channel a  "], @"name match ignores case and padding");
    check(![store isSubscribedToChannelName:@"Unknown Channel"], @"unsubscribed name rejected");
    check(![store isSubscribedToChannelName:nil], @"nil name rejected");

    // Merging adds without dropping, and fills in a missing name.
    [store mergeChannels:@[@{@"id": THIRD_ID, @"name": @""}]];
    check(store.count == 3, @"merge adds a channel");
    check([store isSubscribedToChannelId:THIRD_ID], @"merged id recognised");
    check(![store isSubscribedToChannelName:@""], @"empty name is not a match");

    [store mergeChannels:@[@{@"id": THIRD_ID, @"name": @"English Channel C"}]];
    check(store.count == 3, @"re-merging the same id does not duplicate it");
    check([store isSubscribedToChannelName:@"English Channel C"], @"missing name filled in by a later merge");

    // Replacing drops what is gone (an unsubscribe on the account).
    [store replaceWithChannels:@[@{@"id": REAL_ID, @"name": @"Math Channel A"}]];
    check(store.count == 1, @"replace drops removed channels");
    check(![store isSubscribedToChannelId:OTHER_ID], @"removed channel no longer subscribed");

    [store reset];
    check(store.count == 0, @"reset empties the store");
    check(!store.ready, @"reset store is not ready");
}

// Learning Mode cannot be switched off; the only thing that holds the filter
// back is having no whitelist to apply.
static void testFilteringGate(void) {
    resetDefaults();

    check(!LFFilteringActive(), @"filter inert while the whitelist is empty (signed out)");

    [[LFSubscriptionStore sharedStore] replaceWithChannels:@[@{@"id": REAL_ID, @"name": @"Math Channel A"}]];
    check(LFFilteringActive(), @"filter active once a whitelist exists");

    [[LFSubscriptionStore sharedStore] reset];
    check(!LFFilteringActive(), @"filter goes inert again when the whitelist is cleared");
}

static void testDecisions(void) {
    resetDefaults();
    [[LFSubscriptionStore sharedStore] replaceWithChannels:@[@{@"id": REAL_ID, @"name": @"Math Channel A"}]];

    check(LFIsSubscribedToChannel(REAL_ID), @"isSubscribedToChannel true for a subscribed id");
    check(!LFIsSubscribedToChannel(THIRD_ID), @"isSubscribedToChannel false for an unsubscribed id");
    check(LFIsAllowedChannel(REAL_ID) == LFIsSubscribedToChannel(REAL_ID), @"allowed == subscribed");

    // The account's own channel is allowed without being subscribed to itself.
    check(!LFIsAllowedChannel(THIRD_ID), @"an unrelated channel is not allowed");
    LFSetOwnChannel(THIRD_ID);
    check(LFIsOwnChannel(THIRD_ID), @"the bound page id is recognised as the user's own channel");
    check(LFIsAllowedChannel(THIRD_ID), @"the user's own channel is allowed");
    check(!LFIsSubscribedToChannel(THIRD_ID), @"…without being in the subscription list");
    LFSetOwnChannel(nil);
    check(!LFIsAllowedChannel(THIRD_ID), @"releasing the account drops that allowance");

    NSDictionary *allowed = LFInfoFromData(LockupPayload(REAL_ID, @"dQw4w9WgXcQ"));
    NSDictionary *denied = LFInfoFromData(LockupPayload(THIRD_ID, @"AbCdEfGhIjK"));

    check(LFDecisionForInfo(allowed) == LFDecisionAllow, @"subscribed channel is allowed");
    check(LFDecisionForInfo(denied) == LFDecisionHide, @"unsubscribed channel is hidden");
    check(!LFShouldHideInfo(allowed), @"allowed item is not hidden");
    check(LFShouldHideInfo(denied), @"denied item is hidden");

    // Any subscribed id in the set is enough, so a stray false positive from the
    // scanner can never hide a legitimate video.
    NSDictionary *mixed = @{LFInfoVideoIds: [NSSet setWithObject:@"dQw4w9WgXcQ"],
                            LFInfoChannelIds: [NSSet setWithObjects:THIRD_ID, REAL_ID, nil]};
    check(LFDecisionForInfo(mixed) == LFDecisionAllow, @"a subscribed id among several allows the item");

    // Name-only fallback.
    NSDictionary *byName = @{LFInfoVideoIds: [NSSet setWithObject:@"dQw4w9WgXcQ"],
                             LFInfoChannelIds: [NSSet set],
                             LFInfoChannelName: @"Math Channel A"};
    check(LFDecisionForInfo(byName) == LFDecisionAllow, @"channel name fallback allows a subscribed channel");
    NSDictionary *byWrongName = @{LFInfoVideoIds: [NSSet setWithObject:@"dQw4w9WgXcQ"],
                                  LFInfoChannelIds: [NSSet set],
                                  LFInfoChannelName: @"Some Other Channel"};
    check(LFDecisionForInfo(byWrongName) == LFDecisionHide, @"channel name fallback hides an unknown channel");

    // Unresolvable.
    NSDictionary *unknown = @{LFInfoVideoIds: [NSSet setWithObject:@"dQw4w9WgXcQ"], LFInfoChannelIds: [NSSet set]};
    check(LFDecisionForInfo(unknown) == LFDecisionUnknown, @"unresolvable item reports unknown");
    check(LFDecisionForInfo(nil) == LFDecisionUnknown, @"nil info reports unknown");

    check(LFShouldHideInfo(unknown), @"an unresolvable item is always hidden, never shown on a guess");
}

// A payload that is still being populated must not be cached as "no channel":
// with strict mode on that would hide the item permanently.
static void testLazyPayloadRetry(void) {
    resetDefaults();

    LFFakeRenderer *renderer = [[LFFakeRenderer alloc] init];
    // First pass: a thumbnail is there but the channel endpoint is not yet.
    renderer->payload = DataFromString(@"eml.video_lockup https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg");

    NSDictionary *first = LFInfoForRenderer(renderer, nil);
    check([[first objectForKey:LFInfoVideoIds] count] == 1, @"first pass sees the video");
    check([[first objectForKey:LFInfoChannelIds] count] == 0, @"first pass has no channel yet");
    check(renderer->calls == 1, @"first pass scans once");

    // Immediately afterwards the partial answer is reused rather than rescanned.
    LFInfoForRenderer(renderer, nil);
    check(renderer->calls == 1, @"repeat within the retry window does not rescan");

    // Once the window passes the payload is scanned again, and by then it is complete.
    renderer->payload = LockupPayload(REAL_ID, @"dQw4w9WgXcQ");
    [NSThread sleepForTimeInterval:1.1];

    NSDictionary *second = LFInfoForRenderer(renderer, nil);
    check(renderer->calls == 2, @"stale partial answer is rescanned");
    check([[second objectForKey:LFInfoChannelIds] containsObject:REAL_ID], @"rescan picks up the channel");

    // A complete answer is final.
    LFInfoForRenderer(renderer, nil);
    check(renderer->calls == 2, @"complete answer is not rescanned");
}

// "Explore other channels" and "from related searches" are single elements that
// carry several items — and sometimes channels with no video at all. Both used
// to slip past the filter.
static void testShelvesAndChannelCards(void) {
    resetDefaults();
    [[LFSubscriptionStore sharedStore] replaceWithChannels:@[@{@"id": REAL_ID, @"name": @"Math Channel A"}]];

    // A shelf where nothing is subscribed goes as a whole.
    NSMutableData *foreignShelf = [NSMutableData dataWithData:LockupPayload(OTHER_ID, @"dQw4w9WgXcQ")];
    [foreignShelf appendData:LockupPayload(THIRD_ID, @"AbCdEfGhIjK")];
    NSDictionary *foreignInfo = LFInfoFromData(foreignShelf);
    check([[foreignInfo objectForKey:LFInfoVideoIds] count] == 2, @"foreign shelf has two videos");
    check(LFDecisionForInfo(foreignInfo) == LFDecisionHide, @"a shelf with no subscribed channel is hidden");

    // One subscribed channel keeps the shelf; its items are judged on their own.
    NSMutableData *mixedShelf = [NSMutableData dataWithData:LockupPayload(REAL_ID, @"dQw4w9WgXcQ")];
    [mixedShelf appendData:LockupPayload(THIRD_ID, @"AbCdEfGhIjK")];
    check(LFDecisionForInfo(LFInfoFromData(mixedShelf)) == LFDecisionAllow,
          @"a shelf keeping one subscribed channel survives");

    // A channel card: a channel id and no video at all.
    NSMutableData *card = [NSMutableData data];
    [card appendData:DataFromString(@"\n\x12" @"eml.channel_lockup")];
    uint8_t endpoint[] = {0x1a, 0x18};
    [card appendBytes:endpoint length:2];
    [card appendData:DataFromString(THIRD_ID)];
    NSDictionary *cardInfo = LFInfoFromData(card);
    check([[cardInfo objectForKey:LFInfoVideoIds] count] == 0, @"channel card names no video");
    check(LFInfoCarriesContent(cardInfo), @"a channel card counts as content");
    check(LFDecisionForInfo(cardInfo) == LFDecisionHide, @"an unsubscribed channel card is hidden");

    NSMutableData *ownCard = [NSMutableData data];
    [ownCard appendData:DataFromString(@"\n\x12" @"eml.channel_lockup")];
    [ownCard appendBytes:endpoint length:2];
    [ownCard appendData:DataFromString(REAL_ID)];
    check(LFDecisionForInfo(LFInfoFromData(ownCard)) == LFDecisionAllow, @"a subscribed channel card stays");

    // Chrome: a channel id that is only a chance hit inside a base64 token has
    // no protobuf prefix, and must never be enough to hide something.
    NSData *chrome = DataFromString([NSString stringWithFormat:@"{\"token\":\"%@\"}", THIRD_ID]);
    NSDictionary *chromeInfo = LFInfoFromData(chrome);
    check(![[chromeInfo objectForKey:LFInfoHasStrongChannelId] boolValue], @"json id is not protobuf-prefixed");
    check(!LFInfoCarriesContent(chromeInfo), @"an unprefixed id alone is not content");
}

static void testControlIdentifiers(void) {
    check(LFIsSubscriptionMutationURL([NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/subscription/subscribe?key=x"]),
          @"subscribe endpoint recognised");
    check(LFIsSubscriptionMutationURL([NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/subscription/unsubscribe"]),
          @"unsubscribe endpoint recognised");
    check(!LFIsSubscriptionMutationURL([NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/browse"]),
          @"browse endpoint left alone");
    check(!LFIsSubscriptionMutationURL(nil), @"nil url is not a mutation");

    check(LFIdentifierIsSubscribeControl(@"eml.compact_subscribe_button"), @"subscribe identifier recognised");
    check(LFIdentifierIsSubscribeControl(@"id.channel_subscribe.button"), @"channel subscribe identifier recognised");
    check(!LFIdentifierIsSubscribeControl(@"eml.video_lockup"), @"video lockup is not a subscribe control");
    check(!LFIdentifierIsSubscribeControl(nil), @"nil identifier is not a subscribe control");

    check(LFIdentifierIsAccountSwitchControl(@"account_switcher.entry"), @"account switcher recognised");
    check(LFIdentifierIsAccountSwitchControl(@"ADD_ACCOUNT"), @"add account recognised regardless of case");
    check(!LFIdentifierIsAccountSwitchControl(@"eml.video_lockup"), @"video lockup is not an account control");

    check(LFDataLooksLikeSubscribeControl(DataFromString(@"eml.compact_subscribe_button")),
          @"subscribe payload recognised");
    check(!LFDataLooksLikeSubscribeControl(DataFromString(@"eml.video_lockup")),
          @"lockup payload is not a subscribe control");
}

static void testChannelIdsInJSON(void) {
    // The last-resort parser used when an InnerTube response cannot be decoded.
    NSString *json = [NSString stringWithFormat:@"{\"items\":[{\"browseId\":\"%@\"},{\"browseId\":\"%@\"}]}",
                                                REAL_ID, OTHER_ID];
    NSSet<NSString *> *identifiers = LFChannelIdsInData(DataFromString(json));
    check(identifiers.count == 2, @"both channel ids found in a JSON body");
    check([identifiers containsObject:REAL_ID] && [identifiers containsObject:OTHER_ID], @"json channel id values");
    check(LFChannelIdsInData(nil).count == 0, @"nil body yields no ids");
}

int main(void) {
    @autoreleasepool {
        testPayloadExtraction();
        testStore();
        testFilteringGate();
        testDecisions();
        testLazyPayloadRetry();
        testShelvesAndChannelCards();
        testControlIdentifiers();
        testChannelIdsInJSON();
        resetDefaults();
    }

    printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
