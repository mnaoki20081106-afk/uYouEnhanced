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

@interface __NSURLSessionLocal : NSURLSession
@end

#pragma mark - Shared decision helper

/// The single decision both layers use. Anything not recognisable as a video is
/// left untouched, so headers, chips and shelf titles keep working.
static BOOL LFShouldHideFeedItem(NSDictionary *info) {
    if (!LFFilteringActive())
        return NO;
    if ([[info objectForKey:LFInfoVideoIds] count] == 0)
        return NO;
    return LFShouldHideInfo(info);
}

#pragma mark - Layer A: element level

%group LFElementFiltering

%hook YTIElementRenderer

- (NSData *)elementData {
    NSData *data = %orig;
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return data;

    if (LFDataLooksLikeSubscribeControl(data)) {
        NSDictionary *info = LFInfoForRenderer(self, data);
        // A subscribe control is its own element; a video lockup that merely
        // mentions one must not be blanked.
        if ([[info objectForKey:LFInfoVideoIds] count] == 0)
            return [NSData data];
    }

    if (!LFFilteringActive())
        return data;

    // Only a single-video lockup is blanked wholesale; a shelf carries several
    // videos and its items are separate elements that get filtered on their own.
    NSDictionary *info = LFInfoForRenderer(self, data);
    if (!LFInfoIsSingleVideoLockup(info))
        return data;

    return LFShouldHideFeedItem(info) ? [NSData data] : data;
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
            BOOL hide = LFShouldHideFeedItem(info);
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
    if (!LFFilteringActive())
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
        if (!LFFilteringActive())
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
    if (!model || !LFFilteringActive())
        return model;

    // The reel's own player response carries the authoritative channel id.
    id playerResponse = LFSafeValueForKey(model, @"playerResponseOverride");
    id videoDetails = LFSafeValueForKey(playerResponse, @"videoDetails");
    NSString *channelId = LFSafeValueForKey(videoDetails, @"channelId");
    if ([channelId isKindOfClass:[NSString class]] && channelId.length > 0)
        return LFIsAllowedChannel(channelId) ? model : nil;

    NSDictionary *info = LFInfoFromNode(entry) ?: LFInfoFromElementRenderer(entry);
    if ([[info objectForKey:LFInfoChannelIds] count] > 0 || [[info objectForKey:LFInfoChannelName] length] > 0)
        return LFShouldHideInfo(info) ? nil : model;

    // Nothing identifiable: never let it through on a guess (spec §14).
    return nil;
}

%end

%end // LFShortsFiltering

#pragma mark - Subscribe / account controls in the view hierarchy

%group LFControlHiding

%hook _ASDisplayView

- (void)didMoveToWindow {
    %orig;
    NSString *identifier = self.accessibilityIdentifier;
    if (LFIdentifierIsSubscribeControl(identifier)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        return;
    }
    if ([[LFAccountGuard sharedGuard] accountSlotTaken] && LFIdentifierIsAccountSwitchControl(identifier)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
    }
}

%end

%end // LFControlHiding

#pragma mark - Networking

// Two independent nets. The NSURLSession hooks catch anything that goes through
// the standard task factories; the NSMutableURLRequest hooks catch the request
// while it is still being built, which also covers request objects handed to a
// networking stack we do not hook. Both only read headers — the single
// exception is repointing a forbidden request at a dead address.

static NSURL *LFBlockedURL(void) {
    static NSURL *url;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ url = [NSURL URLWithString:@"https://127.0.0.1:1/uye-learning-filter-blocked"]; });
    return url;
}

static void LFHandleOutgoingRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]])
        return;
    [[LFSubscriptionSync sharedSync] captureRequest:request];
    [[LFAccountGuard sharedGuard] noteRequest:request];
}

static BOOL LFRequestMustBeBlocked(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]])
        return NO;
    if (LFIsSubscriptionMutationURL(request.URL))
        return YES;
    return [[LFAccountGuard sharedGuard] shouldBlockRequest:request];
}

/// Points a request at a dead local address so the task fails immediately
/// instead of reaching YouTube. Returning nil from the task factories would
/// crash callers that assume a task.
static NSURLRequest *LFInspectRequest(NSURLRequest *request) {
    LFHandleOutgoingRequest(request);
    if (!LFRequestMustBeBlocked(request))
        return request;

    NSMutableURLRequest *blocked = [request mutableCopy];
    blocked.URL = LFBlockedURL();
    blocked.HTTPBody = nil;
    return blocked;
}

/// Same check, applied to a request that is still being assembled. `field` is
/// the header just written, or nil when the URL changed.
static void LFInspectMutableRequest(NSMutableURLRequest *request, NSString *field) {
    // Only the headers that carry an identity are worth looking at; anything
    // else would mean walking the URL on every single header write.
    if (field.length > 0 && [field caseInsensitiveCompare:@"Authorization"] != NSOrderedSame &&
        [field caseInsensitiveCompare:@"Cookie"] != NSOrderedSame)
        return;

    LFHandleOutgoingRequest(request);
    if (!LFRequestMustBeBlocked(request))
        return;

    NSURL *blocked = LFBlockedURL();
    if (![request.URL isEqual:blocked])
        request.URL = blocked; // re-enters this function once, then settles
}

%group LFNetworking

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig;
    LFInspectMutableRequest(self, field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig;
    LFInspectMutableRequest(self, field);
}

- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)fields {
    %orig;
    LFInspectMutableRequest(self, nil);
}

- (void)setURL:(NSURL *)URL {
    %orig;
    LFInspectMutableRequest(self, nil);
}

%end

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

// NSURLSession is a class cluster: +sessionWithConfiguration: hands back
// __NSURLSessionLocal, which overrides the task factories. Hooking only the
// public class would miss every request. Hooking a class that does not exist is
// a no-op, so this is safe on any iOS version.
%hook __NSURLSessionLocal

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
    // Learning Mode is not optional, so the hooks always go in. Whether they do
    // anything is decided by LFFilteringActive(), which needs a whitelist.
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
