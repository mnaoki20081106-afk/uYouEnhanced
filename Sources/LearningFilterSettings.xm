// LearningFilterSettings.xm - the Learning Mode rows inside the uYouEnhanced
// settings section. Called from uYouPlusSettings.xm so the existing section
// keeps ownership of its layout.

#import "LearningFilter.h"
#import "uYouPlusSettings.h"

/// Declared locally so this file compiles without pulling in the settings
/// view controller header just for one selector.
@protocol LFSettingsReloading <NSObject>
- (void)reloadData;
@end

static void LFShowToast(NSString *message) {
    Class managerClass = %c(GOOHUDManagerInternal);
    Class messageClass = %c(YTHUDMessage);
    if (!managerClass || !messageClass)
        return;
    [[managerClass sharedInstance] showMessageMainThread:[messageClass messageWithText:message]];
}

static NSString *LFStatusDescription(void) {
    LFSubscriptionStore *store = [LFSubscriptionStore sharedStore];
    NSDate *lastSync = store.lastSyncDate;

    NSString *when = @"never";
    if (lastSync) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        when = [formatter stringFromDate:lastSync];
    }

    if (store.count == 0)
        return [NSString stringWithFormat:@"No whitelist yet (last sync: %@). Filtering stays off until the "
                                          @"subscription list has been read. Tap to sync now.", when];

    return [NSString stringWithFormat:@"%lu subscribed channels · last sync: %@ · tap to sync now",
                                      (unsigned long)store.count, when];
}

/// Read-only dump of the whitelist, so the user can confirm what is allowed.
static void LFPresentWhitelist(id settingsViewController) {
    if (![settingsViewController isKindOfClass:[UIViewController class]])
        return;

    NSArray<NSDictionary<NSString *, NSString *> *> *channels = [LFSubscriptionStore sharedStore].channels;
    NSMutableString *text = [NSMutableString string];
    if (channels.count == 0)
        [text appendString:@"The whitelist is empty.\n\nSign in, open a video so YouTube makes an authenticated "
                           @"request, then use \"Sync subscriptions now\"."];

    NSArray *sorted = [channels sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSString *left = [lhs[@"name"] length] > 0 ? lhs[@"name"] : lhs[@"id"];
        NSString *right = [rhs[@"name"] length] > 0 ? rhs[@"name"] : rhs[@"id"];
        return [left localizedCaseInsensitiveCompare:right];
    }];
    for (NSDictionary *channel in sorted) {
        NSString *name = [channel[@"name"] length] > 0 ? channel[@"name"] : @"(name unknown)";
        [text appendFormat:@"%@\n%@\n\n", name, channel[@"id"]];
    }

    UIViewController *viewController = [[UIViewController alloc] init];
    viewController.title = @"Whitelisted channels";
    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.editable = NO;
    textView.text = text;
    textView.font = [UIFont systemFontOfSize:14];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [viewController.view addSubview:textView];
    viewController.view.backgroundColor = [UIColor systemBackgroundColor];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.topAnchor constant:44],
        [textView.leadingAnchor constraintEqualToAnchor:viewController.view.leadingAnchor constant:16],
        [textView.trailingAnchor constraintEqualToAnchor:viewController.view.trailingAnchor constant:-16],
        [textView.bottomAnchor constraintEqualToAnchor:viewController.view.bottomAnchor]
    ]];

    [(UIViewController *)settingsViewController presentViewController:viewController animated:YES completion:nil];
}

static YTSettingsSectionItem *LFSwitchItem(NSString *title, NSString *description, NSString *key) {
    return [%c(YTSettingsSectionItem) switchItemWithTitle:title
                                        titleDescription:description
                                 accessibilityIdentifier:nil
                                                switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:key]
                                             switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                                                 [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:key];
                                                 return YES;
                                             }
                                           settingItemId:0];
}

void LFAppendSettingsItems(NSMutableArray *sectionItems, id settingsViewController) {
    [sectionItems addObject:[%c(YTSettingsSectionItem)
                                itemWithTitle:@"\t"
                             titleDescription:@"🎓 LEARNING MODE (SUBSCRIPTIONS ONLY)"
                      accessibilityIdentifier:nil
                              detailTextBlock:nil
                                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) { return NO; }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                                switchItemWithTitle:@"Enable Learning Mode"
                                   titleDescription:@"Only videos from channels this account is already subscribed "
                                                    @"to are shown in Home, Search, Shorts and related videos. "
                                                    @"Restart YouTube after changing this."
                            accessibilityIdentifier:nil
                                           switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:kLFEnabled]
                                        switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                                            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kLFEnabled];
                                            LFShowToast(@"Restart YouTube to apply Learning Mode");
                                            return YES;
                                        }
                                      settingItemId:0]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                                itemWithTitle:@"Sync subscriptions now"
                             titleDescription:LFStatusDescription()
                      accessibilityIdentifier:nil
                              detailTextBlock:nil
                                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                      LFShowToast(@"Syncing subscriptions…");
                                      [[LFSubscriptionSync sharedSync]
                                          syncForcedWithCompletion:^(BOOL success, NSUInteger count, NSString *message) {
                                              LFShowToast(message ?: (success ? @"Synced" : @"Sync failed"));
                                              if ([settingsViewController respondsToSelector:@selector(reloadData)])
                                                  [(id<LFSettingsReloading>)settingsViewController reloadData];
                                          }];
                                      return YES;
                                  }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                                itemWithTitle:@"View whitelisted channels"
                             titleDescription:@"The channels currently treated as allowed. This list is the account's "
                                              @"own subscription list — it is not edited by hand."
                      accessibilityIdentifier:nil
                              detailTextBlock:nil
                                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                      LFPresentWhitelist(settingsViewController);
                                      return YES;
                                  }]];

    [sectionItems addObject:LFSwitchItem(@"Filter Home, Search and Related",
                                         @"Hides every video in the recommendation, search and related feeds that "
                                         @"does not come from a subscribed channel.",
                                         kLFFilterFeeds)];

    [sectionItems addObject:LFSwitchItem(@"Filter Shorts",
                                         @"Applies the same whitelist to the Shorts feed, Shorts shelves and Shorts "
                                         @"in search results.",
                                         kLFFilterShorts)];

    [sectionItems addObject:LFSwitchItem(@"Hide unidentifiable videos",
                                         @"When a video's channel cannot be determined, hide it instead of showing "
                                         @"it. Turn this off only for troubleshooting — it weakens the filter.",
                                         kLFStrictUnknown)];

    [sectionItems addObject:LFSwitchItem(@"Lock subscriptions",
                                         @"Hides subscribe buttons and refuses subscribe/unsubscribe requests, so "
                                         @"the whitelist cannot be extended from inside the app. Existing "
                                         @"subscriptions are left untouched.",
                                         kLFLockSubscriptions)];

    [sectionItems addObject:LFSwitchItem(@"One account only",
                                         @"After the first account signs in, additional accounts and account "
                                         @"switching are refused. Signing out stays possible.",
                                         kLFSingleAccount)];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                                itemWithTitle:@"Release the bound account"
                             titleDescription:@"Use this after signing out so a different single account can be used. "
                                              @"This also clears the stored whitelist."
                      accessibilityIdentifier:nil
                              detailTextBlock:nil
                                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                      [[LFAccountGuard sharedGuard] resetBoundAccount];
                                      LFShowToast(@"Bound account and whitelist cleared");
                                      if ([settingsViewController respondsToSelector:@selector(reloadData)])
                                          [(id<LFSettingsReloading>)settingsViewController reloadData];
                                      return YES;
                                  }]];
}
