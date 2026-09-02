# Learning Mode — subscriptions-only whitelist

Learning Mode restricts YouTube to the channels the signed-in account is
*already* subscribed to. It is an additive feature: nothing in uYouEnhanced was
removed or rewritten, and with the master switch off the tweak is completely
inert (its `%ctor` returns before installing a single hook).

```
Whitelist == the account's current subscription list
Home / Search / Shorts / Related  →  subscribed channel ? show : hide
New subscriptions                 →  refused
Signed-in accounts                →  at most one
```

## 1. Investigation notes

### uYouEnhanced (target: YouTube 21.14.4, uYou 3.0.5)

| Question | Finding |
| --- | --- |
| Build layout | `Makefile` compiles `Sources/*.xm`, `Sources/*.x`, `Sources/*.m`, so new files drop in without Makefile changes. |
| Feed rendering | Every modern surface (Home, Search, Related, Shorts shelves) is rendered from ELM elements. `Sources/uYouPlus.xm:938` already hides Shorts cells by returning `[NSData data]` from `-[YTIElementRenderer elementData]` — proof that blanking an element removes the cell. |
| Section-level filtering | `Sources/AdBlocking.xm:199` filters `YTIItemSectionRenderer.contentsArray` / `YTIShelfRenderer` and reads `[elementRenderer description]` to classify an element. |
| Shorts player | `Sources/AdBlocking.xm:58` returns `nil` from `-[YTReelInfinitePlaybackDataSource makeContentModelForEntry:]` to drop an entry from the infinite Shorts feed. |
| Existing channel id access | None. Nothing in the tree reads `channelId`. |
| Existing subscription access | None. Only cosmetic switches (`kHideSubscriptions`, `kRedSubscribeButton`). |
| Account handling | Only `-[YTSettingsSectionItemManager updateAccountSwitcherSectionWithEntry:]` is stubbed out for `kDisableAccountSection`. No identity plumbing. |
| Settings UI | `Sources/uYouPlusSettings.xm` builds one `sectionItems` array inside `updateTweakSectionWithEntry:` and hands it to `setSectionItems:forCategory:…`. New rows are appended there. |

### Gonerino

| Question | Finding |
| --- | --- |
| Filter entry point | `%hook YTAsyncCollectionView` on `layoutSubviews` / `reloadData` / `didMoveToWindow` → debounced `FilterVisibleCells()` → hides `visibleCells` (`sources/Tweak.x:444`). |
| Metadata source | `Util videoInfoFromNode:` walks `node.parentResponder.elementEntry`, then scans the element renderer's `NSData` (`sources/Util.m:507`). |
| Video id | Byte scan for `https://i.ytimg.com/vi/` + 11 id characters. |
| Channel | **Display name only** — protobuf field 37, plus `ownerDisplayName`-style selectors and accessibility text heuristics. Gonerino never reads a `channelId`. |
| Search / Related / Shorts | Not special-cased; all four ride on the same `YTAsyncCollectionView` pass. |
| Decision | `blocked channel → hide`. Learning Mode needs the inverse, `subscribed channel → show`, which also means the "cannot identify it" case flips from *show* to *hide*. |

**What was reused:** the element-renderer byte-scanning approach, the
`parentResponder → elementEntry` route from a cell's display node to its
payload, the debounced visible-cell pass, and the per-object metadata cache.

**What had to change:** Gonerino matches on channel *names*, which are neither
unique nor stable. A whitelist that decides what the user is allowed to see
needs the `channelId`, so the scanner was rewritten around `UC…` ids (see §3).

## 2. Files

| File | Contents |
| --- | --- |
| `Sources/LearningFilter.h` | Defaults keys, store/sync/guard interfaces, the shared decision API. |
| `Sources/LearningFilterCore.m` | `LFSubscriptionStore` (the whitelist), `LFIsSubscribedToChannel()` / `LFIsAllowedChannel()` / `LFShouldHideInfo()`, and the channel-id/video-id scanner. |
| `Sources/LearningFilterSync.m` | InnerTube credential capture, subscription fetch, `LFAccountGuard`. |
| `Sources/LearningFilter.xm` | All hooks. |
| `Sources/LearningFilterSettings.xm` | The settings rows. |
| `Sources/uYouPlusSettings.xm` | One added call to `LFAppendSettingsItems()`. |
| `Sources/SettingsKeys.h` | New keys added to the export/import list. |
| `Tests/` | Off-device tests and their runner (§10). |

## 3. How a channel is identified

`LFInfoFromData()` scans an element payload for:

* **video ids** — 11 id characters after `https://i.ytimg.com/vi/`,
  `https://i.ytimg.com/vi_webp/`, `/shorts/` or `watch?v=`;
* **channel ids** — `UC` followed by 22 id characters, with non-id bytes on both
  sides.

Protobuf length-prefixes a 24-byte string with the byte `0x18`. Matches carrying
that prefix are treated as *strong*; when any strong match exists the weaker ones
(which can be accidental hits inside a base64 continuation token) are dropped.
Because a cell is allowed when **any** of its ids is subscribed, a stray false
positive can never hide a legitimate video.

Fallbacks, in order: the renderer's protobuf `description` dump (only when a
video id was found but no channel id — it is the expensive path), then the
`ownerDisplayName` / `channelName` selectors matched against the subscribed
channels' names.

The Shorts player takes a shortcut: `YTReelModel.playerResponseOverride
.videoDetails.channelId` is authoritative and is used directly.

Element payloads are populated lazily, so the first scan of a cell can come up
short. An answer that names no channel is therefore *not* cached: it is parked
for a second and rescanned, up to five times, before the tweak settles on it.
Without that, one early scan would hide a subscribed video permanently.

## 4. Where the filter is applied

| Surface | Hook |
| --- | --- |
| Home, Search, Related, recommendations, Shorts shelves | `-[YTIElementRenderer elementData]` returns empty data for a single-video lockup whose channel is not subscribed (a Shorts lockup follows the Shorts switch, everything else the feed switch). Elements carrying more than one video id (shelves, sections) are left alone — their items are separate elements and get filtered individually. |
| Anything that reaches layout anyway | `YTAsyncCollectionView` debounced visible-cell pass, ported from Gonerino. It only ever touches cells it hid itself. |
| Shorts infinite feed | `-[YTReelInfinitePlaybackDataSource makeContentModelForEntry:]` returns `nil`. |

Every one of them ends up in `LFShouldHideInfo()`, so there is exactly one place
where "allowed" is defined.

Non-video cells (chips, headers, shelf titles, comments, the Subscriptions tab's
own chrome) are never filtered: an item without a video id is skipped outright.

## 5. Where the whitelist comes from

The tweak has no credentials of its own, so it borrows the app's:

1. Two hooks watch outgoing requests and read (never modify) their headers,
   caching `Authorization`, `X-Goog-AuthUser`, `X-Goog-Visitor-Id`,
   `X-Goog-PageId`, the client name/version and the cookie header of any
   `…/youtubei/v1/…` call:
   * `NSMutableURLRequest` (`setValue:forHTTPHeaderField:`, `addValue:…`,
     `setAllHTTPHeaderFields:`, `setURL:`) — catches the request while it is
     being built, whichever stack ends up sending it;
   * `NSURLSession` **and** `__NSURLSessionLocal` — `NSURLSession` is a class
     cluster and the concrete subclass overrides the task factories, so hooking
     only the public class would see nothing.
   A cookie-authenticated request counts too: its headers are forwarded verbatim.
2. With those headers it POSTs `browse` for `browseId: FEchannels` ("All
   subscriptions"), following up to 20 continuations. The iOS client context is
   tried first, then WEB.
3. Channels the response explicitly marks `subscribed: true` win; only if the
   response carries no such marker does every channel it named get used. If the
   body cannot be decoded as JSON at all, the raw `UC…` scan is the last resort.
4. Results are persisted in `NSUserDefaults` under
   `learningModeSubscribedChannels` and refreshed at most every 6 hours (on
   `UIApplicationDidBecomeActive`), or on demand from the settings row. The
   first sync of a launch is kicked off as soon as usable credentials appear
   (throttled to once a minute) rather than waiting for the next foreground
   event, which happens before the app has made a signed-in request.

Requests the tweak issues itself carry `X-uYE-LearningFilter: 1` so the hooks
ignore them.

**Signed out / never synced (spec §9):** with an empty store `LFFilteringActive()`
returns `NO` and nothing is filtered. A signed-out app is a normal app rather
than an empty one, and the filter switches itself on as soon as a whitelist
exists.

## 6. Locking subscriptions

* `-[YTIElementRenderer elementData]` returns empty data for elements whose
  payload contains `subscribe_button` / `compact_subscribe` / `subscription_button`
  **and** no video id, so a video cell that merely mentions the word survives.
* `_ASDisplayView.didMoveToWindow` hides views whose accessibility identifier
  names a subscribe control.
* The definitive stop: requests to `/youtubei/v1/subscription/subscribe` and
  `/unsubscribe` are pointed at a dead local address, so no UI path — button,
  long-press menu, Shorts overlay or channel page — can mutate the list.

Unsubscribe is blocked as well, so the existing subscriptions cannot be
tampered with either.

## 7. One account

`LFAccountGuard` binds the first authenticated identity it sees. That identity
has two independent signals — `X-Goog-PageId` (the channel / brand account) and
`X-Goog-AuthUser` (the slot index) — and they are compared **component-wise**,
only when both sides carry the same signal. The app does not put both headers on
every request, and treating a missing one as "someone else" would lock a
perfectly legitimate single account out of its own app. Afterwards:

* authenticated InnerTube requests whose page id or auth-user *differs* from the
  bound one are refused, which is what makes a second account non-functional
  rather than merely hidden;
* views whose accessibility identifier names an add-account / account-switcher
  control are hidden;
* sign-out is never touched. Twenty consecutive unauthenticated `browse`/`player`
  calls are read as "signed out": the binding is released and the whitelist is
  cleared, so the next single account starts fresh. The settings row *Release the
  bound account* does the same on demand.

## 8. Settings

uYouEnhanced ▸ **🎓 Learning Mode (subscriptions only)**

| Row | Default |
| --- | --- |
| Enable Learning Mode | off (an existing install is never changed silently) |
| Sync subscriptions now | — shows the channel count and last sync time |
| View whitelisted channels | — read-only |
| Filter Home, Search and Related | on |
| Filter Shorts | on |
| Hide unidentifiable videos | on (spec §14) |
| Lock subscriptions | on |
| One account only | on |

## 9. Off-device tests

`Tests/run-tests.sh` runs everything that can be checked without a device or a
built tweak:

* **`Tests/LearningFilterScanTests.c`** exercises `Sources/LearningFilterScan.m`
  directly — id boundaries at the start and end of a buffer, ids embedded in
  base64, the protobuf length prefix that separates a trustworthy match from a
  chance one, over-long tokens, deduplication and the capacity limit.
* **`Tests/LearningFilterLogicTests.m`** builds `LearningFilterCore.m` against a
  host Foundation (the system one on macOS, GNUstep on Linux) and covers the
  store, the allow/deny decision, the signed-out gate, strict mode, the
  lazy-payload retry and the control identifiers.

Both suites were mutation-checked: deliberately breaking the boundary checks,
the strong-prefix rule, the allow/deny direction, the signed-out gate, strict
mode or the retry cache makes them fail.

The whole tree is also compile-checked against the real iOS SDK and the real
`Tweaks/YouTubeHeader`, after running each `.xm` through `logos.pl` — the same
front end theos uses. **Use `-Werror -Wvla -Wgnu-folding-constant`**: theos
builds with `-Werror`, and a `static const size_t` used as an array bound is a
warning on Apple clang (`-Wgnu-folding-constant`) but only surfaces as `-Wvla`
elsewhere — that exact difference let a CI-breaking VLA through once.

## 10. On-device test plan

With channels **A** and **B** subscribed and **C** not:

| Surface | A | B | C |
| --- | --- | --- | --- |
| Home / recommendations | shown | shown | hidden |
| Search results (search itself still works) | shown | shown | hidden |
| Shorts feed and Shorts shelves | shown | shown | hidden |
| Related / up-next | shown | shown | hidden |

Also verify:

1. **Search is not keyword-restricted** — searching a term still returns
   results; only non-subscribed uploaders disappear.
2. **Subscribe is refused** — the button is gone on the watch page, channel page
   and Shorts overlay; if one is reached anyway the request fails and the
   subscription count is unchanged after a restart.
3. **Existing subscriptions untouched** — the list on youtube.com is identical
   before and after a session.
4. **Second account refused** — Add account is hidden; switching accounts leaves
   the app on the bound account. Signing out works, and after *Release the bound
   account* a different account can sign in.
5. **Signed out** — no filtering, no empty feeds.
6. **Existing features intact** — ad blocking, SponsorBlock, PiP, playback speed,
   quality, downloads, theming and the Shorts/player options behave as before.
   Learning Mode adds hooks; it changes none of theirs.

## 11. Known limits

* The channel id is read out of a serialised element. If YouTube changes that
  encoding the scanner returns nothing, and with *Hide unidentifiable videos* on
  the feeds go empty rather than leaky — the safe direction, but it is the thing
  to check first after a YouTube update.
* `FEchannels` is a server-driven surface. If a future response stops carrying
  `subscribed: true`, the sync falls back to every channel the page names, which
  could include a recommendation shelf. The whitelist is visible in settings so
  this is verifiable.
* The account guard identifies an account by request headers, not by the app's
  own identity store, so an account added while the app is offline is only
  refused once it makes its first request.
