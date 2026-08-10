#ifndef CAPTURE_DARWIN_H
#define CAPTURE_DARWIN_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *id;
    char *kind;   // "screen" | "window"
    char *name;
    int width;
    int height;
    char *thumbnail_png_b64; // may be NULL / empty
} CaptureSourceC;

typedef struct {
    CaptureSourceC *items;
    int count;
    char *error;
} CaptureSourceListC;

typedef struct {
    bool ok;
    char *path;
    char *error;
} CaptureResultC;

// Caller must free with CaptureFreeSources.
CaptureSourceListC CaptureListSources(void);
void CaptureFreeSources(CaptureSourceListC list);

// Returns 1 if screen recording permission appears granted.
int CaptureRequestAccess(void);

// Starts recording. exclude_pid: process id to exclude from capture (0 = none).
// Returns immediately; recording runs until CaptureStop.
CaptureResultC CaptureStart(
    const char *source_id,
    const char *source_kind,
    const char *output_path,
    bool system_audio,
    bool microphone,
    int exclude_pid
);

CaptureResultC CaptureStop(void);
int CaptureIsRecording(void);

void CaptureFreeResult(CaptureResultC result);

#ifdef __cplusplus
}
#endif

#endif
