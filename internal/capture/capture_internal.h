// Shared ObjC helpers for the darwin capture modules.
// Public C API remains in capture_darwin.h (consumed by Go/cgo).

#ifndef CAPTURE_INTERNAL_H
#define CAPTURE_INTERNAL_H

#import "capture_darwin.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdlib.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

// UTF-8 strdup of an NSString; caller frees with free(). NULL if s is nil.
char *_Nullable CaptureCStrdup(NSString *_Nullable s);

void CaptureEnsureLock(void);
NSLock *CaptureLock(void);

NS_ASSUME_NONNULL_END

#endif
