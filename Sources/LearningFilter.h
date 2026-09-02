// LearningFilter.h - "Learning Mode" whitelist filter for uYouEnhanced.
//
// Whitelist == the set of channels the signed-in YouTube account is currently
// subscribed to.  Everything that is not published by one of those channels is
// hidden from Home, Search, Shorts and the related/recommended shelves.
//
// The metadata extraction is modelled on Gonerino's element-renderer scanning
// (sources/Util.m), but the decision is inverted: Gonerino hides a blocked
// channel, this hides everything that is *not* subscribed.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The .xm files are compiled as Objective-C++ while LearningFilterCore.m is
// Objective-C, so every free function below has to be declared with C linkage —
// otherwise the C++ side looks for a mangled symbol the C side never defines.
#ifdef __cplusplus
#define LF_EXTERN extern "C"
#else
#define LF_EXTERN extern
#endif

#pragma mark - Defaults keys

// Learning Mode has no switches: filtering, the strict "never allow on a guess"
// rule, the subscription lock and the one-account limit are always on. A device
// restricted to learning is not one where the restriction can be toggled off.
// The only stored state is therefore the whitelist itself.
static NSString *const kLFStoredChannels = @"learningModeSubscribedChannels";
static NSString *const kLFLastSyncDate = @"learningModeLastSyncDate";
static NSString *const kLFBoundAccount = @"learningModeBoundAccount";

#pragma mark - Subscription store (the whitelist)

/// Persisted snapshot of "channels this account is subscribed to".
/// Entries are dictionaries: @{@"id": @"UC...", @"name": @"Channel name"}.
@interface LFSubscriptionStore : NSObject

+ (instancetype)sharedStore;

@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *channels;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly, nullable) NSDate *lastSyncDate;

/// YES once we hold a usable whitelist. While NO the filter stays inert so a
/// signed-out (or never-synced) app is not left with an empty home feed.
@property(nonatomic, readonly) BOOL ready;

- (BOOL)isSubscribedToChannelId:(nullable NSString *)channelId;
- (BOOL)isSubscribedToChannelName:(nullable NSString *)channelName;

/// Replaces the snapshot wholesale (used after a successful sync).
- (void)replaceWithChannels:(NSArray<NSDictionary<NSString *, NSString *> *> *)channels;
/// Adds channels without dropping known ones (used by passive harvesting).
- (void)mergeChannels:(NSArray<NSDictionary<NSString *, NSString *> *> *)channels;
- (void)reset;

@end

#pragma mark - Common filter layer

/// Single entry point used by every surface (spec §8).
LF_EXTERN BOOL LFIsSubscribedToChannel(NSString *_Nullable channelId);
/// The signed-in account's own channel, learned from `X-Goog-PageId`. It counts
/// as allowed even when the account does not subscribe to itself, so the "You"
/// tab does not hide the user from themselves.
LF_EXTERN BOOL LFIsOwnChannel(NSString *_Nullable channelId);
LF_EXTERN void LFSetOwnChannel(NSString *_Nullable channelId);
LF_EXTERN BOOL LFIsAllowedChannel(NSString *_Nullable channelId);

/// YES when the master switch is on *and* a whitelist is available.
LF_EXTERN BOOL LFFilteringActive(void);

typedef NS_ENUM(NSInteger, LFDecision) {
    LFDecisionAllow,   // resolved to a subscribed channel
    LFDecisionHide,    // resolved to a channel that is not subscribed
    LFDecisionUnknown, // nothing identifiable in this object
};

/// Applies the whitelist to an already extracted metadata dictionary.
LF_EXTERN LFDecision LFDecisionForInfo(NSDictionary *_Nullable info);
/// Convenience: resolves `LFDecisionUnknown` using kLFStrictUnknown.
LF_EXTERN BOOL LFShouldHideInfo(NSDictionary *_Nullable info);

#pragma mark - Metadata extraction

/// Exception-free, zero-argument, object-returning accessor. Used instead of
/// `-valueForKey:` so a missing selector never throws inside a hook.
LF_EXTERN id _Nullable LFSafeValueForKey(id _Nullable object, NSString *key);

/// YES when the payload contains one of the subscribe-button element ids.
LF_EXTERN BOOL LFDataLooksLikeSubscribeControl(NSData *_Nullable data);

// Keys produced by the extractors below.
static NSString *const LFInfoVideoIds = @"videoIds";     // NSSet<NSString *>
static NSString *const LFInfoChannelIds = @"channelIds"; // NSSet<NSString *>
static NSString *const LFInfoChannelName = @"channelName";
static NSString *const LFInfoIsShort = @"isShort";                     // NSNumber<BOOL>
static NSString *const LFInfoHasStrongChannelId = @"hasStrongChannel"; // NSNumber<BOOL>

/// Scans a serialised element payload for `UC…` channel ids and `videoId`s.
LF_EXTERN NSDictionary *_Nullable LFInfoFromData(NSData *_Nullable data);
/// Scans an arbitrary string (a protobuf text dump, a URL, …).
LF_EXTERN NSDictionary *_Nullable LFInfoFromString(NSString *_Nullable text);
/// Raw `UC…` channel ids found in a payload, used as a last-resort parser for
/// server-driven InnerTube responses.
LF_EXTERN NSSet<NSString *> *LFChannelIdsInData(NSData *_Nullable data);
/// Cached lookup for a `YTIElementRenderer`. Pass the already-materialised
/// payload when calling from inside a `-elementData` hook so the extraction
/// never re-enters that hook.
LF_EXTERN NSDictionary *_Nullable LFInfoForRenderer(id _Nullable renderer, NSData *_Nullable data);
LF_EXTERN NSDictionary *_Nullable LFInfoFromElementRenderer(id _Nullable renderer);
/// Cached lookup for an `ASDisplayNode` backing a feed cell.
LF_EXTERN NSDictionary *_Nullable LFInfoFromNode(id _Nullable node);

/// YES when the payload describes something the whitelist has an opinion about:
/// a video, or a channel named by a trustworthy id. Chips, headers and other
/// chrome carry neither and are never touched.
LF_EXTERN BOOL LFInfoCarriesContent(NSDictionary *_Nullable info);

#pragma mark - Subscription sync

/// Header stamped on the requests this tweak issues itself, so the networking
/// hooks can recognise and ignore them.
static NSString *const kLFOwnRequestHeader = @"X-uYE-LearningFilter";

@interface LFSubscriptionSync : NSObject

+ (instancetype)sharedSync;

/// Records the auth headers of an outgoing InnerTube request so we can issue
/// our own `browse` call with the same credentials.
- (void)captureRequest:(NSURLRequest *)request;
- (BOOL)hasCredentials;

@property(nonatomic, readonly, copy) NSString *statusDescription;
@property(nonatomic, readonly) BOOL syncing;

- (void)syncIfStale;
- (void)syncForcedWithCompletion:(void (^_Nullable)(BOOL success, NSUInteger count, NSString *message))completion;

@end

#pragma mark - Account guard

@interface LFAccountGuard : NSObject

+ (instancetype)sharedGuard;

/// Remembers the first account seen; used to reject a second one.
- (void)noteRequest:(NSURLRequest *)request;
/// YES when the request belongs to an account other than the bound one.
- (BOOL)shouldBlockRequest:(NSURLRequest *)request;
/// YES when a second account must not be added any more.
- (BOOL)accountSlotTaken;
- (void)resetBoundAccount;

/// Human-readable form of the bound identity, for the settings screen.
- (nullable NSString *)boundAccountIdentifier;

@end

#pragma mark - Subscribe/unsubscribe blocking

/// YES when the URL performs a subscription mutation that must be refused.
LF_EXTERN BOOL LFIsSubscriptionMutationURL(NSURL *_Nullable url);
/// YES when the string identifies a subscribe button element/view.
LF_EXTERN BOOL LFIdentifierIsSubscribeControl(NSString *_Nullable identifier);
/// YES when the string identifies an "add account" / account switcher control.
LF_EXTERN BOOL LFIdentifierIsAccountSwitchControl(NSString *_Nullable identifier);

#pragma mark - Settings

/// Appends the Learning Mode rows to the uYouEnhanced settings section.
LF_EXTERN void LFAppendSettingsItems(NSMutableArray *sectionItems, id settingsViewController);

NS_ASSUME_NONNULL_END
