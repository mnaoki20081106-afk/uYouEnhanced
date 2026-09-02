// LearningFilter.xm - the hooks that apply the subscription whitelist.
//
// Two layers cooperate:
//   A. `YTIElementRenderer -elementData` blanks a video lockup before it is ever
//      laid out. This covers Home, Search, Related and the Shorts shelves,
//      because every one of those surfaces is rendered from ELM elements.
//   B. `YTAsyncCollectionView` hides any visible cell that slipped past layer A
//      (the approach Gonerino uses), plus the Shorts infinite feed is filtered
//      at its data source.
//
// Everything routes through LFShouldHideInfo(), so there is a single decision
// point shared by all surfaces (spec §8).

#import "LearningFilter.h"
#import <objc/runtime.h>

#pragma mark - Interfaces (kept local so this file has no header dependencies)

@interface YTAsyncCollectionView : UICollectionView
@property(nonatomic, assign) BOOL lfFiltering;
@property(nonatomic, assign) BOOL lfFilterScheduled;
@property(nonatomic, assign) NSTimeInterval lfLastFilterTime;
- (void)lfScheduleFiltering;
@end

@interface _ASCollectionViewCell : UICollectionViewCell
- (id)node;
@end

@interface _ASDisplayView : UIView
@end

@interface YTIElementRenderer : NSObject
- (NSData *)elementData;
@end

@interface YTReelInfinitePlaybackDataSource : NSObject
- (id)makeContentModelForEntry:(id)entry;
@end

#pragma mark - Shared decision helper

/// Applies the whitelist to a feed item. Anything that is not recognisable as a
/// video is left untouched so headers, chips and shelves keep working.
static BOOL LFShouldHideVideoInfo(NSDictionary *info) {
    if (!LFFilteringActive())
        return NO;
    if ([info[LFInfoVideoIds] count] == 0)
        return NO;
    return LFShouldHideInfo(info);
}

static BOOL LFFeedFilteringEnabled(void) {
    return LFFilteringActive() && [[NSUserDefaults standardUserDefaults] boolForKey:kLFFilterFeeds];
}

static BOOL LFShortsFilteringEnabled(void) {
    return LFFilteringActive() && [[NSUserDefaults standardUserDefaults] boolForKey:kLFFilterShorts];
}

static BOOL LFSubscriptionsLocked(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kLFLockSubscriptions];
}

#pragma mark - Layer A: element level

%group LFElementFiltering

%hook YTIElementRenderer

- (NSData *)elementData {
    NSData *data = %orig;
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return data;

    if (LFSubscriptionsLocked() && LFDataLooksLikeSubscribeControl(data)) {
        NSDictionary *info = LFInfoForRenderer(self, data);
        // A subscribe control is its own element; a video lockup that merely
        // mentions one must not be blanked.
        if ([info[LFInfoVideoIds] count] == 0)
            return [NSData data];
    }

    if (!LFFeedFilteringEnabled() && !LFShortsFilteringEnabled())
        return data;

    NSDictionary *info = LFInfoForRenderer(self, data);
    if (!LFInfoIsSingleVideoLockup(info))
        return data;

    // A Shorts lockup follows the Shorts switch, everything else the feed switch.
    BOOL enabled = [info[LFInfoIsShort] boolValue] ? LFShortsFilteringEnabled() : LFFeedFilteringEnabled();
    if (enabled && LFShouldHideVideoInfo(info))
        return [NSData data];

    return data;
}

%end

%end // LFElementFiltering

#pragma mark - Layer B: cell level

static void LFFilterVisibleCells(YTAsyncCollectionView *collectionView);

static BOOL LFCollectionViewIsScrolling(UICollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static void *LFHiddenCellKey = &LFHiddenCellKey;

static void LFFilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView || collectionView.lfFiltering || LFCollectionViewIsScrolling(collectionView))
        return;

    collectionView.lfFiltering = YES;
    collectionView.lfLastFilterTime = CFAbsoluteTimeGetCurrent();
    @try {
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            id node = nil;
            if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")] &&
                [cell respondsToSelector:@selector(node)])
                node = [(_ASCollectionViewCell *)cell node];
            if (!node)
                node = LFSafeValueForKey(cell, @"node");
            if (!node)
                continue;

            NSDictionary *info = LFInfoFromNode(node);
            BOOL hide = LFShouldHideVideoInfo(info);
            BOOL wasHidden = objc_getAssociatedObject(cell, LFHiddenCellKey) != nil;
            if (!hide && !wasHidden)
                continue; // never touch cells this tweak does not own

            objc_setAssociatedObject(cell, LFHiddenCellKey, hide ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = hide;
            cell.alpha = hide ? 0.0 : 1.0;
            cell.userInteractionEnabled = !hide;
            cell.accessibilityElementsHidden = hide;
        }
    } @catch (__unused NSException *exception) {
    }
    collectionView.lfFiltering = NO;
}

%group LFCellFiltering

%hook YTAsyncCollectionView

%property(nonatomic, assign) BOOL lfFiltering;
%property(nonatomic, assign) BOOL lfFilterScheduled;
%property(nonatomic, assign) NSTimeInterval lfLastFilterTime;

%new
- (void)lfScheduleFiltering {
    if (!LFFeedFilteringEnabled())
        return;
    if (self.lfFilterScheduled || LFCollectionViewIsScrolling(self))
        return;
    if (CFAbsoluteTimeGetCurrent() - self.lfLastFilterTime < 0.35)
        return;

    self.lfFilterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        strongSelf.lfFilterScheduled = NO;
        if (!LFFeedFilteringEnabled())
            return;
        LFFilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    %orig;
    [self lfScheduleFiltering];
}

- (void)reloadData {
    %orig;
    [self lfScheduleFiltering];
}

- (void)didMoveToWindow {
    %orig;
    if (self.window)
        [self lfScheduleFiltering];
}

%end

%end // LFCellFiltering

#pragma mark - Shorts

%group LFShortsFiltering

%hook YTReelInfinitePlaybackDataSource

- (id)makeContentModelForEntry:(id)entry {
    id model = %orig;
    if (!model || !LFShortsFilteringEnabled())
        return model;

    // The reel's own player response carries the authoritative channel id.
    id playerResponse = LFSafeValueForKey(model, @"playerResponseOverride");
    id videoDetails = LFSafeValueForKey(playerResponse, @"videoDetails");
    NSString *channelId = LFSafeValueForKey(videoDetails, @"channelId");
    if ([channelId isKindOfClass:[NSString class]] && channelId.length > 0)
        return LFIsAllowedChannel(channelId) ? model : nil;

    NSDictionary *info = LFInfoFromNode(entry) ?: LFInfoFromElementRenderer(entry);
    if ([info[LFInfoChannelIds] count] > 0 || [info[LFInfoChannelName] length] > 0)
        return LFShouldHideInfo(info) ? nil : model;

    // Nothing identifiable: fall back to the strict-mode preference (spec §14).
    return [[NSUserDefaults standardUserDefaults] boolForKey:kLFStrictUnknown] ? nil : model;
}

%end

%end // LFShortsFiltering

#pragma mark - Subscribe / account controls in the view hierarchy

%group LFControlHiding

%hook _ASDisplayView

- (void)didMoveToWindow {
    %orig;
    NSString *identifier = self.accessibilityIdentifier;
    if (LFSubscriptionsLocked() && LFIdentifierIsSubscribeControl(identifier)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        return;
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kLFSingleAccount] &&
        [[LFAccountGuard sharedGuard] accountSlotTaken] && LFIdentifierIsAccountSwitchControl(identifier)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
    }
}

%end

%end // LFControlHiding

#pragma mark - Networking

/// Points a request at a dead local address so the task fails immediately
/// instead of reaching YouTube. Returning nil from these factory methods would
/// crash callers that assume a task.
static NSURLRequest *LFNeuteredRequest(NSURLRequest *request) {
    NSMutableURLRequest *blocked = [request mutableCopy];
    blocked.URL = [NSURL URLWithString:@"https://127.0.0.1:1/uye-learning-filter-blocked"];
    blocked.HTTPBody = nil;
    return blocked;
}

static NSURLRequest *LFInspectRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]])
        return request;

    [[LFSubscriptionSync sharedSync] captureRequest:request];
    [[LFAccountGuard sharedGuard] noteRequest:request];

    if (LFSubscriptionsLocked() && LFIsSubscriptionMutationURL(request.URL))
        return LFNeuteredRequest(request);

    if ([[LFAccountGuard sharedGuard] shouldBlockRequest:request])
        return LFNeuteredRequest(request);

    return request;
}

%group LFNetworking

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(LFInspectRequest(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return %orig(LFInspectRequest(request), completionHandler);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    return %orig(LFInspectRequest(request), bodyData);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return %orig(LFInspectRequest(request), bodyData, completionHandler);
}

%end

%end // LFNetworking

#pragma mark - Startup

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // First launch: pick the defaults the spec asks for. Feed/Shorts filtering
    // and the strict unknown-channel rule are on, but the master switch stays
    // off so an existing install is never changed behind the user's back.
    if (![defaults objectForKey:kLFStrictUnknown])
        [defaults setBool:YES forKey:kLFStrictUnknown];
    if (![defaults objectForKey:kLFFilterFeeds])
        [defaults setBool:YES forKey:kLFFilterFeeds];
    if (![defaults objectForKey:kLFFilterShorts])
        [defaults setBool:YES forKey:kLFFilterShorts];
    if (![defaults objectForKey:kLFLockSubscriptions])
        [defaults setBool:YES forKey:kLFLockSubscriptions];
    if (![defaults objectForKey:kLFSingleAccount])
        [defaults setBool:YES forKey:kLFSingleAccount];

    BOOL enabled = [defaults boolForKey:kLFEnabled];
    if (!enabled)
        return;

    %init(LFElementFiltering);
    %init(LFCellFiltering);
    %init(LFShortsFiltering);
    %init(LFControlHiding);
    %init(LFNetworking);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
                                                      [[LFSubscriptionSync sharedSync] syncIfStale];
                                                  }];
}
