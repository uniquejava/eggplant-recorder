// ScreenCaptureKit recorder bridge for macOS 15+.
// Uses SCStream + AVAssetWriter to write H.264 MP4 with optional system audio / mic.

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

@interface VERecorder : NSObject <SCStreamDelegate, SCStreamOutput>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *videoInput;
@property(nonatomic, strong) AVAssetWriterInput *audioInput;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic, assign) BOOL writing;
@property(nonatomic, assign) BOOL paused;
@property(nonatomic, assign) BOOL sessionStarted;
@property(nonatomic, assign) BOOL hasLastInputPTS;
@property(nonatomic, assign) CMTime lastInputPTS;
@property(nonatomic, assign) CMTime outputPTS;
@property(nonatomic, strong) NSString *outputPath;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSError *lastError;
@end

@implementation VERecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.cyper.videoeditor.capture", DISPATCH_QUEUE_SERIAL);
        _lastInputPTS = kCMTimeInvalid;
        _outputPTS = kCMTimeZero;
    }
    return self;
}

- (BOOL)startWithFilter:(SCContentFilter *)filter
                  width:(size_t)width
                 height:(size_t)height
            systemAudio:(BOOL)systemAudio
             microphone:(BOOL)microphone
             outputPath:(NSString *)outputPath
                  error:(NSError **)outError {
    self.outputPath = outputPath;
    self.writing = NO;
    self.paused = NO;
    self.sessionStarted = NO;
    self.hasLastInputPTS = NO;
    self.lastInputPTS = kCMTimeInvalid;
    self.outputPTS = kCMTimeZero;
    self.lastError = nil;

    NSURL *url = [NSURL fileURLWithPath:outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError *err = nil;
    self.writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&err];
    if (err) {
        if (outError) *outError = err;
        return NO;
    }

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(width * height * 6),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    self.videoInput.expectsMediaDataInRealTime = YES;

    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
    };
    self.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput
                                                                                    sourcePixelBufferAttributes:attrs];
    if (![self.writer canAddInput:self.videoInput]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VERecorder" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video input"}];
        }
        return NO;
    }
    [self.writer addInput:self.videoInput];

    if (systemAudio || microphone) {
        AudioChannelLayout stereo = {0};
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVEncoderBitRateKey: @192000,
            AVChannelLayoutKey: [NSData dataWithBytes:&stereo length:sizeof(stereo)],
        };
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioInput.expectsMediaDataInRealTime = YES;
        if ([self.writer canAddInput:self.audioInput]) {
            [self.writer addInput:self.audioInput];
        } else {
            self.audioInput = nil;
        }
    }

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = width;
    config.height = height;
    config.minimumFrameInterval = CMTimeMake(1, 30);
    config.queueDepth = 8;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.showsCursor = YES;
    config.capturesAudio = systemAudio;
    if (@available(macOS 15.0, *)) {
        config.captureMicrophone = microphone;
    }
    if (systemAudio) {
        config.sampleRate = 48000;
        config.channelCount = 2;
    }

    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    NSError *addErr = nil;
    BOOL ok = [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:&addErr];
    if (!ok) {
        if (outError) *outError = addErr;
        return NO;
    }
    if (systemAudio) {
        [self.stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.queue error:nil];
    }
    if (@available(macOS 15.0, *)) {
        if (microphone) {
            [self.stream addStreamOutput:self type:SCStreamOutputTypeMicrophone sampleHandlerQueue:self.queue error:nil];
        }
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
        startErr = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (startErr) {
        if (outError) *outError = startErr;
        return NO;
    }

    self.writing = YES;
    return YES;
}

- (NSString *)stopAndFinish {
    self.writing = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self.stream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            self.lastError = error;
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    dispatch_sync(self.queue, ^{
        [self.videoInput markAsFinished];
        if (self.audioInput) {
            [self.audioInput markAsFinished];
        }
    });

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [self.writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    if (self.writer.status == AVAssetWriterStatusFailed) {
        self.lastError = self.writer.error;
        return nil;
    }
    return self.outputPath;
}

- (void)pause {
    self.paused = YES;
}

- (void)resume {
    self.paused = NO;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!self.writing || sampleBuffer == NULL) {
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // While paused, keep advancing the input clock but do not grow the output timeline.
    if (self.paused) {
        self.lastInputPTS = pts;
        self.hasLastInputPTS = YES;
        return;
    }

    if (!self.sessionStarted) {
        if (type != SCStreamOutputTypeScreen) {
            return;
        }
        [self.writer startWriting];
        [self.writer startSessionAtSourceTime:kCMTimeZero];
        self.sessionStarted = YES;
        self.outputPTS = kCMTimeZero;
        self.lastInputPTS = pts;
        self.hasLastInputPTS = YES;
    } else if (self.hasLastInputPTS) {
        CMTime delta = CMTimeSubtract(pts, self.lastInputPTS);
        if (CMTimeCompare(delta, kCMTimeZero) > 0) {
            self.outputPTS = CMTimeAdd(self.outputPTS, delta);
        }
        self.lastInputPTS = pts;
    } else {
        self.lastInputPTS = pts;
        self.hasLastInputPTS = YES;
    }

    CMTime relative = self.outputPTS;

    if (type == SCStreamOutputTypeScreen) {
        if (!self.videoInput.isReadyForMoreMediaData) {
            return;
        }
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            return;
        }
        [self.adaptor appendPixelBuffer:imageBuffer withPresentationTime:relative];
        return;
    }

    if ((type == SCStreamOutputTypeAudio || type == SCStreamOutputTypeMicrophone) && self.audioInput) {
        if (!self.audioInput.isReadyForMoreMediaData) {
            return;
        }
        CMSampleBufferRef timed = NULL;
        CMSampleTimingInfo timing;
        timing.duration = CMSampleBufferGetDuration(sampleBuffer);
        timing.presentationTimeStamp = relative;
        timing.decodeTimeStamp = kCMTimeInvalid;
        CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, 1, &timing, &timed);
        if (timed) {
            [self.audioInput appendSampleBuffer:timed];
            CFRelease(timed);
        }
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        self.lastError = error;
    }
}

@end

static VERecorder *gRecorder = nil;
static NSLock *gLock = nil;

static void ensureLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [[NSLock alloc] init];
    });
}

static char *cstrdup(NSString *s) {
    if (!s) {
        return NULL;
    }
    const char *utf8 = [s UTF8String];
    if (!utf8) {
        return NULL;
    }
    return strdup(utf8);
}

static NSString *pngBase64FromImage(NSImage *image) {
    if (!image) {
        return @"";
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
    if (!rep) {
        return @"";
    }
    // Downscale for UI thumbnails
    NSSize target = NSMakeSize(320, 180);
    NSImage *scaled = [[NSImage alloc] initWithSize:target];
    [scaled lockFocus];
    [image drawInRect:NSMakeRect(0, 0, target.width, target.height)
             fromRect:NSZeroRect
            operation:NSCompositingOperationCopy
             fraction:1.0];
    [scaled unlockFocus];
    rep = [[NSBitmapImageRep alloc] initWithData:[scaled TIFFRepresentation]];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) {
        return @"";
    }
    return [png base64EncodedStringWithOptions:0];
}

static NSImage *thumbnailForDisplay(SCDisplay *display) {
    if (@available(macOS 14.0, *)) {
        __block CGImageRef cgImage = NULL;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCScreenshotManager captureImageWithFilter:[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]]
                                      configuration:({
            SCStreamConfiguration *c = [[SCStreamConfiguration alloc] init];
            c.width = 320;
            c.height = 180;
            c.showsCursor = NO;
            c;
        })
                                  completionHandler:^(CGImageRef  _Nullable image, NSError * _Nullable error) {
            if (image) {
                cgImage = CGImageRetain(image);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        if (cgImage) {
            NSImage *img = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
            CGImageRelease(cgImage);
            return img;
        }
    }
    return nil;
}

static NSImage *thumbnailForWindow(SCWindow *window) {
    if (@available(macOS 14.0, *)) {
        __block CGImageRef shot = NULL;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
        SCStreamConfiguration *c = [[SCStreamConfiguration alloc] init];
        // Keep aspect roughly 16:10 for the picker cards.
        CGFloat w = MAX(window.frame.size.width, 1);
        CGFloat h = MAX(window.frame.size.height, 1);
        CGFloat scale = MIN(320.0 / w, 200.0 / h);
        c.width = (size_t)MAX(2, (size_t)(w * scale) & ~1);
        c.height = (size_t)MAX(2, (size_t)(h * scale) & ~1);
        c.showsCursor = NO;
        [SCScreenshotManager captureImageWithFilter:filter
                                      configuration:c
                                  completionHandler:^(CGImageRef  _Nullable image, NSError * _Nullable error) {
            if (image) {
                shot = CGImageRetain(image);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)));
        if (shot) {
            NSImage *img = [[NSImage alloc] initWithCGImage:shot size:NSZeroSize];
            CGImageRelease(shot);
            return img;
        }
    }
    return nil;
}

CaptureSourceListC CaptureListSources(void) {
    CaptureSourceListC out = {0};
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *err = nil;

    // Prefer the explicit API so we still get window titles when available.
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
        content = shareableContent;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (err || !content) {
        out.error = cstrdup(err.localizedDescription ?: @"Failed to list shareable content. Grant Screen Recording permission.");
        return out;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (SCDisplay *display in content.displays) {
        NSString *name = [NSString stringWithFormat:@"Screen %dx%d", (int)display.width, (int)display.height];
        // Display thumbs only — cheap enough and avoids blocking the window list.
        NSString *thumb = pngBase64FromImage(thumbnailForDisplay(display));
        [rows addObject:@{
            @"id": [NSString stringWithFormat:@"display:%u", (unsigned int)display.displayID],
            @"kind": @"screen",
            @"name": name,
            @"width": @(display.width),
            @"height": @(display.height),
            @"thumb": thumb ?: @"",
        }];
    }

    for (SCWindow *window in content.windows) {
        // Keep the old behaviour: show titled windows even when preview is empty/black.
        // Only skip obviously invalid tiny layers.
        CGFloat w = window.frame.size.width;
        CGFloat h = window.frame.size.height;
        if (w > 0 && h > 0 && (w < 32 || h < 32)) {
            continue;
        }
        NSString *title = window.title.length ? window.title : @"Window";
        NSString *app = window.owningApplication.applicationName ?: @"App";
        NSString *name = [NSString stringWithFormat:@"%@ — %@", app, title];
        [rows addObject:@{
            @"id": [NSString stringWithFormat:@"window:%u", (unsigned int)window.windowID],
            @"kind": @"window",
            @"name": name,
            @"width": @((int)MAX(w, 0)),
            @"height": @((int)MAX(h, 0)),
            // Window previews are loaded asynchronously via CaptureSourceThumbnail.
            @"thumb": @"",
        }];
    }

    out.count = (int)rows.count;
    out.items = (CaptureSourceC *)calloc((size_t)out.count, sizeof(CaptureSourceC));
    for (int i = 0; i < out.count; i++) {
        NSDictionary *row = rows[i];
        out.items[i].id = cstrdup(row[@"id"]);
        out.items[i].kind = cstrdup(row[@"kind"]);
        out.items[i].name = cstrdup(row[@"name"]);
        out.items[i].width = [row[@"width"] intValue];
        out.items[i].height = [row[@"height"] intValue];
        out.items[i].thumbnail_png_b64 = cstrdup(row[@"thumb"]);
    }
    return out;
}

char *CaptureSourceThumbnail(const char *source_id, const char *source_kind) {
    if (!source_id || !source_kind) {
        return strdup("");
    }
    NSString *sourceID = [NSString stringWithUTF8String:source_id];
    NSString *kind = [NSString stringWithUTF8String:source_kind];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
        content = shareableContent;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (!content) {
        return strdup("");
    }

    NSImage *image = nil;
    if ([kind isEqualToString:@"screen"]) {
        unsigned int displayID = 0;
        sscanf(source_id, "display:%u", &displayID);
        for (SCDisplay *d in content.displays) {
            if (d.displayID == displayID) {
                image = thumbnailForDisplay(d);
                break;
            }
        }
    } else {
        unsigned int windowID = 0;
        sscanf(source_id, "window:%u", &windowID);
        for (SCWindow *w in content.windows) {
            if (w.windowID == windowID) {
                image = thumbnailForWindow(w);
                break;
            }
        }
    }
    NSString *b64 = pngBase64FromImage(image);
    return cstrdup(b64 ?: @"");
}

void CaptureFreeSources(CaptureSourceListC list) {
    if (list.error) {
        free(list.error);
    }
    if (!list.items) {
        return;
    }
    for (int i = 0; i < list.count; i++) {
        free(list.items[i].id);
        free(list.items[i].kind);
        free(list.items[i].name);
        free(list.items[i].thumbnail_png_b64);
    }
    free(list.items);
}

int CaptureHasScreenAccess(void) {
    return CGPreflightScreenCaptureAccess() ? 1 : 0;
}

int CaptureRequestAccess(void) {
    // Preflight never shows UI. Only request when not yet granted —
    // CGRequestScreenCaptureAccess opens System Settings on macOS 15+
    // when permission is missing, so calling it every launch feels like a spam popup.
    if (CGPreflightScreenCaptureAccess()) {
        return 1;
    }
    return CGRequestScreenCaptureAccess() ? 1 : 0;
}

int CaptureOpenScreenCaptureSettings(void) {
    // Sequoia / Ventura Privacy & Security pane.
    NSArray<NSString *> *candidates = @[
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    ];
    for (NSString *s in candidates) {
        NSURL *url = [NSURL URLWithString:s];
        if (url && [[NSWorkspace sharedWorkspace] openURL:url]) {
            return 1;
        }
    }
    return 0;
}

CaptureResultC CaptureStart(
    const char *source_id,
    const char *source_kind,
    const char *output_path,
    bool system_audio,
    bool microphone,
    int exclude_pid
) {
    CaptureResultC result = {0};
    ensureLock();
    [gLock lock];
    if (gRecorder != nil && gRecorder.writing) {
        [gLock unlock];
        result.error = cstrdup(@"Already recording");
        return result;
    }
    [gLock unlock];

    NSString *sourceID = source_id ? [NSString stringWithUTF8String:source_id] : @"";
    NSString *kind = source_kind ? [NSString stringWithUTF8String:source_kind] : @"screen";
    NSString *outPath = output_path ? [NSString stringWithUTF8String:output_path] : @"";

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *err = nil;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
        content = shareableContent;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (err || !content) {
        result.error = cstrdup(err.localizedDescription ?: @"No screen recording permission");
        return result;
    }

    SCContentFilter *filter = nil;
    size_t width = 1280;
    size_t height = 720;

    if ([kind isEqualToString:@"screen"]) {
        unsigned int displayID = 0;
        sscanf(source_id, "display:%u", &displayID);
        SCDisplay *matched = nil;
        for (SCDisplay *d in content.displays) {
            if (d.displayID == displayID) {
                matched = d;
                break;
            }
        }
        if (!matched && content.displays.count > 0) {
            matched = content.displays.firstObject;
        }
        if (!matched) {
            result.error = cstrdup(@"Display not found");
            return result;
        }
        width = matched.width;
        height = matched.height;
        // Keep even dimensions for H.264.
        width -= width % 2;
        height -= height % 2;

        NSMutableArray<SCWindow *> *excluded = [NSMutableArray array];
        if (exclude_pid > 0) {
            for (SCWindow *w in content.windows) {
                if (w.owningApplication.processID == exclude_pid) {
                    [excluded addObject:w];
                }
            }
        }
        filter = [[SCContentFilter alloc] initWithDisplay:matched excludingWindows:excluded];
    } else {
        unsigned int windowID = 0;
        sscanf(source_id, "window:%u", &windowID);
        SCWindow *matched = nil;
        for (SCWindow *w in content.windows) {
            if (w.windowID == windowID) {
                matched = w;
                break;
            }
        }
        if (!matched) {
            result.error = cstrdup(@"Window not found");
            return result;
        }
        width = (size_t)matched.frame.size.width;
        height = (size_t)matched.frame.size.height;
        width -= width % 2;
        height -= height % 2;
        if (width < 2) width = 2;
        if (height < 2) height = 2;
        filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:matched];
    }

    VERecorder *recorder = [[VERecorder alloc] init];
    NSError *startErr = nil;
    BOOL ok = [recorder startWithFilter:filter
                                  width:width
                                 height:height
                            systemAudio:system_audio
                             microphone:microphone
                             outputPath:outPath
                                  error:&startErr];
    if (!ok) {
        result.error = cstrdup(startErr.localizedDescription ?: @"Failed to start capture");
        return result;
    }

    [gLock lock];
    gRecorder = recorder;
    [gLock unlock];

    result.ok = true;
    result.path = cstrdup(outPath);
    return result;
}

CaptureResultC CaptureStop(void) {
    CaptureResultC result = {0};
    ensureLock();
    [gLock lock];
    VERecorder *recorder = gRecorder;
    gRecorder = nil;
    [gLock unlock];

    if (!recorder) {
        result.error = cstrdup(@"Not recording");
        return result;
    }

    NSString *path = [recorder stopAndFinish];
    if (!path) {
        result.error = cstrdup(recorder.lastError.localizedDescription ?: @"Failed to finalize recording");
        return result;
    }
    result.ok = true;
    result.path = cstrdup(path);
    return result;
}

int CaptureIsRecording(void) {
    ensureLock();
    [gLock lock];
    int yes = (gRecorder != nil && gRecorder.writing) ? 1 : 0;
    [gLock unlock];
    return yes;
}

int CapturePause(void) {
    ensureLock();
    [gLock lock];
    VERecorder *recorder = gRecorder;
    [gLock unlock];
    if (!recorder || !recorder.writing) {
        return 0;
    }
    [recorder pause];
    return 1;
}

int CaptureResume(void) {
    ensureLock();
    [gLock lock];
    VERecorder *recorder = gRecorder;
    [gLock unlock];
    if (!recorder || !recorder.writing) {
        return 0;
    }
    [recorder resume];
    return 1;
}

int CaptureIsPaused(void) {
    ensureLock();
    [gLock lock];
    int yes = (gRecorder != nil && gRecorder.writing && gRecorder.paused) ? 1 : 0;
    [gLock unlock];
    return yes;
}

void CaptureFreeResult(CaptureResultC result) {
    if (result.path) free(result.path);
    if (result.error) free(result.error);
}
