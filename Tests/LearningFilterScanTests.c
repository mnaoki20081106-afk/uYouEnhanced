// Host tests for the Learning Mode payload scanner.
//
//   clang -std=c11 -I Sources Tests/LearningFilterScanTests.c Sources/LearningFilterScan.m -x c -o /tmp/lfscan
//   /tmp/lfscan
//
// The scanner decides which channel a feed item belongs to, so its boundary
// behaviour is what keeps the whitelist from either leaking or blanking a feed.

#include "LearningFilterScan.h"

#include <stdio.h>
#include <string.h>

static int gFailures = 0;
static int gChecks = 0;

static void check(int condition, const char *what) {
    gChecks++;
    if (!condition) {
        gFailures++;
        printf("FAIL: %s\n", what);
    }
}

static size_t channelIds(const char *payload, size_t length, LFScanChannelId *out, size_t *strong) {
    return LFScanChannelIds((const uint8_t *)payload, length, out, 8, strong);
}

#define REAL_ID "UCabcdefghijklmnopqrstuv"
#define OTHER_ID "UC0123456789_-ABCDEFGHIj"

static void testFind(void) {
    const uint8_t haystack[] = "abcabcdabce";
    size_t length = sizeof(haystack) - 1;

    check(LFScanFind(haystack, length, "abc", 3, 0) == 0, "find at start");
    check(LFScanFind(haystack, length, "abc", 3, 1) == 3, "find after start");
    check(LFScanFind(haystack, length, "abce", 4, 0) == 7, "find later match with repeated first byte");
    check(LFScanFind(haystack, length, "zzz", 3, 0) == LF_SCAN_NOT_FOUND, "missing needle");
    check(LFScanFind(haystack, length, "abcabcdabcex", 12, 0) == LF_SCAN_NOT_FOUND, "needle longer than haystack");
    check(LFScanFind(haystack, length, "e", 1, length - 1) == length - 1, "find last byte");
    check(LFScanFind(haystack, length, "a", 1, length) == LF_SCAN_NOT_FOUND, "from past the end");
    check(LFScanFind(haystack, length, "", 0, 0) == LF_SCAN_NOT_FOUND, "empty needle");
    check(LFScanFind(NULL, 0, "a", 1, 0) == LF_SCAN_NOT_FOUND, "null haystack");
}

static void testChannelIdBoundaries(void) {
    LFScanChannelId found[8];
    size_t strong = 0;

    // Protobuf: tag, length 24 (0x18), then the id.
    const char protobuf[] = "\x12\x18" REAL_ID "\x20\x01";
    check(channelIds(protobuf, sizeof(protobuf) - 1, found, &strong) == 1, "protobuf id found");
    check(strong == 1, "protobuf id is strong");
    check(strcmp(found[0].value, REAL_ID) == 0, "protobuf id value");

    // JSON: quoted, so bounded but without the length prefix.
    const char json[] = "{\"browseId\":\"" REAL_ID "\"}";
    check(channelIds(json, sizeof(json) - 1, found, &strong) == 1, "json id found");
    check(strong == 0, "json id is weak");

    // Sitting inside a longer token: an id character on either side rejects it.
    const char noise[] = "x" REAL_ID "y";
    check(channelIds(noise, sizeof(noise) - 1, found, &strong) == 0, "id surrounded by id bytes rejected");

    const char trailing[] = "\x18" REAL_ID "z";
    check(channelIds(trailing, sizeof(trailing) - 1, found, &strong) == 0, "id followed by id byte rejected");

    const char leading[] = "a" REAL_ID;
    check(channelIds(leading, sizeof(leading) - 1, found, &strong) == 0, "id preceded by id byte rejected");

    // At the very start and the very end of the buffer there is no neighbour.
    const char atStart[] = REAL_ID "\x20";
    check(channelIds(atStart, sizeof(atStart) - 1, found, &strong) == 1, "id at buffer start accepted");

    const char atEnd[] = "\x18" REAL_ID;
    check(channelIds(atEnd, sizeof(atEnd) - 1, found, &strong) == 1, "id at buffer end accepted");
    check(strong == 1, "id at buffer end keeps its prefix");

    // Too short to be an id.
    const char truncated[] = "\x18UCabcdefghijklmnopqrstu\x20";
    check(channelIds(truncated, sizeof(truncated) - 1, found, &strong) == 0, "23-character id rejected");

    // A non-id character inside the id.
    const char broken[] = "\x18UCabcdefg!ijklmnopqrstuv\x20";
    check(channelIds(broken, sizeof(broken) - 1, found, &strong) == 0, "id with punctuation rejected");

    // Duplicates collapse.
    const char twice[] = "\x18" REAL_ID "\x18" REAL_ID "\x20";
    check(channelIds(twice, sizeof(twice) - 1, found, &strong) == 1, "duplicate ids deduplicated");

    // Two different ids are both reported.
    const char pair[] = "\x18" REAL_ID "\x18" OTHER_ID "\x20";
    check(channelIds(pair, sizeof(pair) - 1, found, &strong) == 2, "two distinct ids reported");
    check(strong == 2, "both ids strong");

    // Nothing at all.
    const char none[] = "no identifiers in this payload";
    check(channelIds(none, sizeof(none) - 1, found, &strong) == 0, "payload without ids");
    check(strong == 0, "no strong ids reported");

    // Shorter than one id.
    check(channelIds("UC", 2, found, &strong) == 0, "payload shorter than an id");
}

static void testChannelIdCapacity(void) {
    char payload[1024];
    size_t offset = 0;
    for (int index = 0; index < 6; index++) {
        payload[offset++] = 0x18;
        memcpy(payload + offset, REAL_ID, LF_CHANNEL_ID_LENGTH);
        payload[offset + 2] = (char)('a' + index); // make each id distinct
        offset += LF_CHANNEL_ID_LENGTH;
        payload[offset++] = 0x20;
    }

    LFScanChannelId found[3];
    size_t strong = 0;
    size_t count = LFScanChannelIds((const uint8_t *)payload, offset, found, 3, &strong);
    check(count == 3, "channel id output is capped at capacity");
    check(strong == 3, "capped ids still counted as strong");
}

static void testVideoIds(void) {
    LFScanVideoId videos[8];
    size_t count = 0;
    int added = 0;

    const char thumbnail[] = "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg";
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)thumbnail, sizeof(thumbnail) - 1, "https://i.ytimg.com/vi/",
                                      videos, count, 8, &added);
    check(count == 1, "thumbnail video id found");
    check(added == 1, "thumbnail reports a hit");
    check(strcmp(videos[0].value, "dQw4w9WgXcQ") == 0, "thumbnail video id value");

    // The same id behind a different prefix must not be added twice.
    const char webp[] = "https://i.ytimg.com/vi_webp/dQw4w9WgXcQ/hq720.webp";
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)webp, sizeof(webp) - 1, "https://i.ytimg.com/vi_webp/", videos,
                                      count, 8, &added);
    check(count == 1, "duplicate video id not added twice");
    check(added == 1, "duplicate still reports a hit for the prefix");

    // A 12-character token is not a video id.
    const char tooLong[] = "https://i.ytimg.com/vi/dQw4w9WgXcQZ/hq720.jpg";
    count = 0;
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)tooLong, sizeof(tooLong) - 1, "https://i.ytimg.com/vi/", videos,
                                      count, 8, &added);
    check(count == 0, "over-long token rejected");
    check(added == 0, "over-long token reports no hit");

    // Shorts path drives the "this is a Short" flag.
    const char shorts[] = "yt://www.youtube.com/shorts/AbCdEfGhIjK?x=1";
    count = 0;
    added = 0;
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)shorts, sizeof(shorts) - 1, "/shorts/", videos, count, 8,
                                      &added);
    check(count == 1 && added == 1, "shorts path yields a video id");
    check(strcmp(videos[0].value, "AbCdEfGhIjK") == 0, "shorts video id value");

    // watch?v=
    const char watch[] = "https://www.youtube.com/watch?v=AbCdEfGhIjK&t=1";
    count = 0;
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)watch, sizeof(watch) - 1, "watch?v=", videos, count, 8, &added);
    check(count == 1, "watch url yields a video id");

    // Truncated payload: prefix present but the id is cut off.
    const char truncated[] = "https://i.ytimg.com/vi/dQw4";
    count = 0;
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)truncated, sizeof(truncated) - 1, "https://i.ytimg.com/vi/",
                                      videos, count, 8, &added);
    check(count == 0, "truncated id ignored");

    // Two different videos in one payload (a shelf, not a lockup).
    const char shelf[] = "https://i.ytimg.com/vi/dQw4w9WgXcQ/a.jpg https://i.ytimg.com/vi/AbCdEfGhIjK/b.jpg";
    count = 0;
    count = LFScanVideoIdsAfterPrefix((const uint8_t *)shelf, sizeof(shelf) - 1, "https://i.ytimg.com/vi/", videos,
                                      count, 8, &added);
    check(count == 2, "shelf payload reports both videos");
}

static void testMarkers(void) {
    const char subscribe[] = "eml.compact_subscribe_button";
    check(LFScanLooksLikeSubscribeControl((const uint8_t *)subscribe, sizeof(subscribe) - 1) == 1,
          "subscribe control detected");

    const char lockup[] = "eml.video_lockup with a thumbnail";
    check(LFScanLooksLikeSubscribeControl((const uint8_t *)lockup, sizeof(lockup) - 1) == 0,
          "plain lockup is not a subscribe control");

    const char shortsCell[] = "id.eml.shorts_video_cell";
    check(LFScanLooksLikeShorts((const uint8_t *)shortsCell, sizeof(shortsCell) - 1) == 1, "shorts cell detected");
    check(LFScanLooksLikeShorts((const uint8_t *)lockup, sizeof(lockup) - 1) == 0, "lockup is not shorts");
}

// A payload shaped like a real home-feed video cell: a thumbnail, the channel's
// browse endpoint, and a base64 continuation token that happens to contain a
// decoy "UC…" sequence.
static void testRealisticLockup(void) {
    const char payload[] =
        "\x0a\x10" "eml.video_lockup"
        "\x12\x2chttps://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg"
        "\x1a\x18" REAL_ID
        "\x22\x30" "4qmFsgIkEhhVQ" OTHER_ID "GgxlZ2xwYkdsdVpXRnk"; // base64-ish noise

    size_t length = sizeof(payload) - 1;

    LFScanVideoId videos[8];
    size_t videoCount = LFScanVideoIdsAfterPrefix((const uint8_t *)payload, length, "https://i.ytimg.com/vi/", videos,
                                                  0, 8, NULL);
    check(videoCount == 1, "realistic lockup reports exactly one video");

    LFScanChannelId found[8];
    size_t strong = 0;
    size_t count = LFScanChannelIds((const uint8_t *)payload, length, found, 8, &strong);
    check(count >= 1, "realistic lockup reports a channel");
    check(strong == 1, "exactly one strong channel id");

    // The strong-preferred set (what LFInfoFromData keeps) must be the real one.
    int sawReal = 0;
    int sawDecoy = 0;
    for (size_t index = 0; index < count; index++) {
        if (!found[index].strong)
            continue;
        if (strcmp(found[index].value, REAL_ID) == 0)
            sawReal = 1;
        if (strcmp(found[index].value, OTHER_ID) == 0)
            sawDecoy = 1;
    }
    check(sawReal == 1, "the browse endpoint id survives");
    check(sawDecoy == 0, "the base64 decoy is not treated as the channel");
}

int main(void) {
    testFind();
    testChannelIdBoundaries();
    testChannelIdCapacity();
    testVideoIds();
    testMarkers();
    testRealisticLockup();

    printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
