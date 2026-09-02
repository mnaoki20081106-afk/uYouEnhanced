// LearningFilterScan.h - pure C payload scanning for Learning Mode.
//
// Kept free of Objective-C so it can be compiled and exercised by the host test
// in Tests/LearningFilterScanTests.c without an iOS device. LearningFilterCore.m
// wraps these in the Foundation types the rest of the tweak uses.

#ifndef LEARNING_FILTER_SCAN_H
#define LEARNING_FILTER_SCAN_H

#include <stddef.h>
#include <stdint.h>

#define LF_SCAN_NOT_FOUND ((size_t)-1)
#define LF_CHANNEL_ID_LENGTH 24
#define LF_VIDEO_ID_LENGTH 11

#ifdef __cplusplus
extern "C" {
#endif

/// YES for the characters YouTube ids are made of ([A-Za-z0-9_-]).
int LFScanIsIdByte(uint8_t byte);

/// First occurrence of `needle` at or after `from`, or LF_SCAN_NOT_FOUND.
size_t LFScanFind(const uint8_t *haystack, size_t haystackLength, const char *needle, size_t needleLength,
                  size_t from);

/// One `UC…` channel id found in a payload.
typedef struct {
    char value[LF_CHANNEL_ID_LENGTH + 1]; // NUL terminated
    int strong;                           // preceded by the protobuf length byte 0x18
} LFScanChannelId;

/// Collects channel ids into `out` (deduplicated, capped at `capacity`).
/// Returns the number written. `strongCount`, when non-NULL, receives how many
/// of those carried the protobuf length prefix.
size_t LFScanChannelIds(const uint8_t *bytes, size_t length, LFScanChannelId *out, size_t capacity,
                        size_t *strongCount);

/// One 11-character video id.
typedef struct {
    char value[LF_VIDEO_ID_LENGTH + 1];
} LFScanVideoId;

/// Collects the ids that follow `prefix` (e.g. "https://i.ytimg.com/vi/") into
/// `out`, skipping ones already present. Returns the new total count; `added`,
/// when non-NULL, is set to 1 if this prefix contributed at least one id.
size_t LFScanVideoIdsAfterPrefix(const uint8_t *bytes, size_t length, const char *prefix, LFScanVideoId *out,
                                 size_t count, size_t capacity, int *added);

/// YES when the payload carries one of the subscribe-control element ids.
int LFScanLooksLikeSubscribeControl(const uint8_t *bytes, size_t length);

/// YES when the payload carries one of the Shorts element markers.
int LFScanLooksLikeShorts(const uint8_t *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif
