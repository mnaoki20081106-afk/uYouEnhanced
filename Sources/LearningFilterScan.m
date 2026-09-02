// LearningFilterScan.m - pure C payload scanning for Learning Mode.
// Deliberately contains no Objective-C so Tests/LearningFilterScanTests.c can
// compile and run it on any host. See LearningFilterScan.h.

#include "LearningFilterScan.h"

#include <string.h>

int LFScanIsIdByte(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
           byte == '-' || byte == '_';
}

// memchr on the first byte, then memcmp for the rest. A byte-by-byte loop is far
// too slow here: this runs on every element payload the app lays out.
size_t LFScanFind(const uint8_t *haystack, size_t haystackLength, const char *needle, size_t needleLength,
                  size_t from) {
    if (!haystack || !needle || needleLength == 0 || haystackLength < needleLength)
        return LF_SCAN_NOT_FOUND;
    if (from > haystackLength - needleLength)
        return LF_SCAN_NOT_FOUND;

    const uint8_t *cursor = haystack + from;
    size_t remaining = haystackLength - from;
    while (remaining >= needleLength) {
        const uint8_t *hit = memchr(cursor, needle[0], remaining - needleLength + 1);
        if (!hit)
            return LF_SCAN_NOT_FOUND;
        if (memcmp(hit, needle, needleLength) == 0)
            return (size_t)(hit - haystack);
        remaining -= (size_t)(hit - cursor) + 1;
        cursor = hit + 1;
    }
    return LF_SCAN_NOT_FOUND;
}

static int LFScanContainsChannelId(const LFScanChannelId *ids, size_t count, const char *value) {
    for (size_t index = 0; index < count; index++) {
        if (memcmp(ids[index].value, value, LF_CHANNEL_ID_LENGTH) == 0)
            return 1;
    }
    return 0;
}

size_t LFScanChannelIds(const uint8_t *bytes, size_t length, LFScanChannelId *out, size_t capacity,
                        size_t *strongCount) {
    size_t count = 0;
    size_t strong = 0;
    if (strongCount)
        *strongCount = 0;
    if (!bytes || !out || capacity == 0 || length < LF_CHANNEL_ID_LENGTH)
        return 0;

    size_t index = 0;
    while (index + LF_CHANNEL_ID_LENGTH <= length) {
        // Only 'U' can start a channel id, so skip straight to the next one.
        const uint8_t *hit = memchr(bytes + index, 'U', length - (LF_CHANNEL_ID_LENGTH - 1) - index);
        if (!hit)
            break;
        index = (size_t)(hit - bytes);

        if (bytes[index + 1] != 'C')
            goto next;
        // A real id is bounded: an id character on either side means we are
        // looking at the middle of a longer token (a base64 blob, typically).
        if (index > 0 && LFScanIsIdByte(bytes[index - 1]))
            goto next;
        if (index + LF_CHANNEL_ID_LENGTH < length && LFScanIsIdByte(bytes[index + LF_CHANNEL_ID_LENGTH]))
            goto next;

        for (size_t offset = 2; offset < LF_CHANNEL_ID_LENGTH; offset++) {
            if (!LFScanIsIdByte(bytes[index + offset]))
                goto next;
        }

        if (!LFScanContainsChannelId(out, count, (const char *)(bytes + index))) {
            if (count == capacity)
                break;
            memcpy(out[count].value, bytes + index, LF_CHANNEL_ID_LENGTH);
            out[count].value[LF_CHANNEL_ID_LENGTH] = '\0';
            // Protobuf length-prefixes a 24-byte string with 0x18, which makes
            // such a match far more trustworthy than a chance hit in base64.
            out[count].strong = (index > 0 && bytes[index - 1] == 0x18) ? 1 : 0;
            if (out[count].strong)
                strong++;
            count++;
        }

    next:
        index++;
    }

    if (strongCount)
        *strongCount = strong;
    return count;
}

static int LFScanContainsVideoId(const LFScanVideoId *ids, size_t count, const char *value) {
    for (size_t index = 0; index < count; index++) {
        if (memcmp(ids[index].value, value, LF_VIDEO_ID_LENGTH) == 0)
            return 1;
    }
    return 0;
}

size_t LFScanVideoIdsAfterPrefix(const uint8_t *bytes, size_t length, const char *prefix, LFScanVideoId *out,
                                 size_t count, size_t capacity, int *added) {
    if (added)
        *added = 0;
    if (!bytes || !prefix || !out)
        return count;

    size_t prefixLength = strlen(prefix);
    size_t cursor = 0;
    while (cursor + prefixLength + LF_VIDEO_ID_LENGTH <= length) {
        size_t match = LFScanFind(bytes, length, prefix, prefixLength, cursor);
        if (match == LF_SCAN_NOT_FOUND)
            break;

        size_t start = match + prefixLength;
        if (start + LF_VIDEO_ID_LENGTH > length)
            break;

        int valid = 1;
        for (size_t offset = 0; offset < LF_VIDEO_ID_LENGTH; offset++) {
            if (!LFScanIsIdByte(bytes[start + offset])) {
                valid = 0;
                break;
            }
        }
        // A 12th id character means the token is longer than a video id.
        if (valid && start + LF_VIDEO_ID_LENGTH < length && LFScanIsIdByte(bytes[start + LF_VIDEO_ID_LENGTH]))
            valid = 0;

        if (valid && !LFScanContainsVideoId(out, count, (const char *)(bytes + start))) {
            if (count == capacity)
                break;
            memcpy(out[count].value, bytes + start, LF_VIDEO_ID_LENGTH);
            out[count].value[LF_VIDEO_ID_LENGTH] = '\0';
            count++;
            if (added)
                *added = 1;
        } else if (valid && added) {
            *added = 1;
        }

        cursor = match + prefixLength;
    }
    return count;
}

static int LFScanContainsAny(const uint8_t *bytes, size_t length, const char *const *needles, size_t needleCount) {
    for (size_t index = 0; index < needleCount; index++) {
        if (LFScanFind(bytes, length, needles[index], strlen(needles[index]), 0) != LF_SCAN_NOT_FOUND)
            return 1;
    }
    return 0;
}

int LFScanLooksLikeSubscribeControl(const uint8_t *bytes, size_t length) {
    static const char *const needles[] = {"subscribe_button", "compact_subscribe", "subscription_button"};
    return LFScanContainsAny(bytes, length, needles, sizeof(needles) / sizeof(needles[0]));
}

int LFScanLooksLikeShorts(const uint8_t *bytes, size_t length) {
    static const char *const needles[] = {"shorts_video_cell", "reel_item", "shorts_shelf"};
    return LFScanContainsAny(bytes, length, needles, sizeof(needles) / sizeof(needles[0]));
}
