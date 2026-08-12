#import "capture_internal.h"

@interface VERecorder : NSObject <SCStreamDelegate, SCStreamOutput>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *videoInput;
@property(nonatomic, strong) AVAssetWriterInput *systemAudioInput;
@property(nonatomic, strong) AVAssetWriterInput *micAudioInput;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic, assign) BOOL writing;
@property(nonatomic, assign) BOOL paused;
@property(nonatomic, assign) BOOL sessionStarted;
@property(nonatomic, assign) BOOL hasHostPTS;
@property(nonatomic, assign) BOOL pauseBeganValid;
@property(nonatomic, assign) BOOL resumePending;
@property(nonatomic, assign) CMTime sessionAnchor;
@property(nonatomic, assign) CMTime pausedAccumulated;
@property(nonatomic, assign) CMTime pauseBeganAt;
@property(nonatomic, assign) CMTime lastHostPTS;
@property(nonatomic, assign) CMTime lastVideoPTS;
@property(nonatomic, assign) CMTime lastSysAudioPTS;
@property(nonatomic, assign) CMTime lastMicPTS;
@property(nonatomic, strong) NSString *outputPath;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSError *lastError;
@end

@implementation VERecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("click.yinsb.eggplantrecorder.capture", DISPATCH_QUEUE_SERIAL);
        _sessionAnchor = kCMTimeInvalid;
        _pausedAccumulated = kCMTimeZero;
        _pauseBeganAt = kCMTimeInvalid;
        _lastHostPTS = kCMTimeInvalid;
        _lastVideoPTS = kCMTimeInvalid;
        _lastSysAudioPTS = kCMTimeInvalid;
        _lastMicPTS = kCMTimeInvalid;
    }
    return self;
}

- (AVAssetWriterInput *)makeAACAudioInput {
    AudioChannelLayout stereo = {0};
    stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @2,
        AVEncoderBitRateKey: @192000,
        AVChannelLayoutKey: [NSData dataWithBytes:&stereo length:sizeof(stereo)],
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    input.expectsMediaDataInRealTime = YES;
    return input;
}

- (BOOL)ensureMicrophonePermission:(NSError **)outError {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        return YES;
    }
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VERecorder"
                                            code:3
                                        userInfo:@{NSLocalizedDescriptionKey:
                @"Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."}];
        }
        return NO;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
        granted = ok;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!granted && outError) {
        *outError = [NSError errorWithDomain:@"VERecorder"
                                        code:3
                                    userInfo:@{NSLocalizedDescriptionKey:
            @"Microphone permission is required to record microphone audio."}];
    }
    return granted;
}

- (NSError *)friendlyStartError:(NSError *)err {
    if (!err) {
        return nil;
    }
    // SCStreamErrorFailedToStartMicrophoneCapture == -3820
    if (err.code == -3820) {
        return [NSError errorWithDomain:err.domain
                                   code:err.code
                               userInfo:@{NSLocalizedDescriptionKey:
            @"Failed to start microphone capture. Pick another input device, or grant Microphone permission in System Settings."}];
    }
    return err;
}

- (BOOL)startWithFilter:(SCContentFilter *)filter
                  width:(size_t)width
                 height:(size_t)height
            systemAudio:(BOOL)systemAudio
             microphone:(BOOL)microphone
     microphoneDeviceID:(NSString *)microphoneDeviceID
             outputPath:(NSString *)outputPath
                  error:(NSError **)outError {
    self.outputPath = outputPath;
    self.writing = NO;
    self.paused = NO;
    self.sessionStarted = NO;
    self.hasHostPTS = NO;
    self.pauseBeganValid = NO;
    self.resumePending = NO;
    self.sessionAnchor = kCMTimeInvalid;
    self.pausedAccumulated = kCMTimeZero;
    self.pauseBeganAt = kCMTimeInvalid;
    self.lastHostPTS = kCMTimeInvalid;
    self.lastVideoPTS = kCMTimeInvalid;
    self.lastSysAudioPTS = kCMTimeInvalid;
    self.lastMicPTS = kCMTimeInvalid;
    self.lastError = nil;
    self.systemAudioInput = nil;
    self.micAudioInput = nil;

    if (microphone) {
        NSError *micErr = nil;
        if (![self ensureMicrophonePermission:&micErr]) {
            if (outError) *outError = micErr;
            return NO;
        }
    }

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

    // System audio and microphone must be separate tracks — dumping both into one
    // AVAssetWriterInput corrupts/finishes the writer when formats or clocks differ.
    if (systemAudio) {
        self.systemAudioInput = [self makeAACAudioInput];
        if ([self.writer canAddInput:self.systemAudioInput]) {
            [self.writer addInput:self.systemAudioInput];
        } else {
            self.systemAudioInput = nil;
        }
    }
    if (microphone) {
        self.micAudioInput = [self makeAACAudioInput];
        if ([self.writer canAddInput:self.micAudioInput]) {
            [self.writer addInput:self.micAudioInput];
        } else {
            self.micAudioInput = nil;
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
    if (systemAudio || microphone) {
        config.sampleRate = 48000;
        config.channelCount = 2;
    }
    if (@available(macOS 15.0, *)) {
        config.captureMicrophone = microphone;
        if (microphone && microphoneDeviceID.length > 0) {
            config.microphoneCaptureDeviceID = microphoneDeviceID;
        }
    }

    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    NSError *addErr = nil;
    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:&addErr]) {
        if (outError) *outError = addErr;
        return NO;
    }
    if (systemAudio) {
        addErr = nil;
        if (![self.stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.queue error:&addErr]) {
            if (outError) *outError = addErr ?: [NSError errorWithDomain:@"VERecorder" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Failed to add system audio output"}];
            return NO;
        }
    }
    if (@available(macOS 15.0, *)) {
        if (microphone) {
            addErr = nil;
            if (![self.stream addStreamOutput:self type:SCStreamOutputTypeMicrophone sampleHandlerQueue:self.queue error:&addErr]) {
                if (outError) *outError = addErr ?: [NSError errorWithDomain:@"VERecorder" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to add microphone output"}];
                return NO;
            }
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
        if (outError) *outError = [self friendlyStartError:startErr];
        return NO;
    }

    self.writing = YES;
    return YES;
}

- (CMTime)relativePTSForHost:(CMTime)pts {
    CMTime relative = CMTimeSubtract(pts, self.sessionAnchor);
    if (CMTimeCompare(self.pausedAccumulated, kCMTimeZero) > 0) {
        relative = CMTimeSubtract(relative, self.pausedAccumulated);
    }
    if (CMTimeCompare(relative, kCMTimeZero) < 0) {
        relative = kCMTimeZero;
    }
    return relative;
}

- (CMTime)monotonicPTS:(CMTime)candidate previous:(CMTime)previous {
    if (!CMTIME_IS_VALID(previous)) {
        return candidate;
    }
    if (CMTimeCompare(candidate, previous) <= 0) {
        return CMTimeAdd(previous, CMTimeMake(1, 600));
    }
    return candidate;
}

- (BOOL)appendAudio:(CMSampleBufferRef)sampleBuffer
              toInput:(AVAssetWriterInput *)input
                  pts:(CMTime)pts
             lastPTS:(CMTime *)lastPTS {
    if (!input || !input.isReadyForMoreMediaData) {
        return NO;
    }
    CMTime outPTS = [self monotonicPTS:pts previous:*lastPTS];
    CMSampleBufferRef timed = NULL;
    CMSampleTimingInfo timing;
    timing.duration = CMSampleBufferGetDuration(sampleBuffer);
    timing.presentationTimeStamp = outPTS;
    timing.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, 1, &timing, &timed);
    if (!timed) {
        return NO;
    }
    BOOL ok = [input appendSampleBuffer:timed];
    CFRelease(timed);
    if (ok) {
        *lastPTS = outPTS;
    }
    return ok;
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
        if (self.systemAudioInput) {
            [self.systemAudioInput markAsFinished];
        }
        if (self.micAudioInput) {
            [self.micAudioInput markAsFinished];
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
    if (self.hasHostPTS) {
        self.pauseBeganAt = self.lastHostPTS;
        self.pauseBeganValid = YES;
    }
}

- (void)resume {
    self.paused = NO;
    if (self.pauseBeganValid) {
        self.resumePending = YES;
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!self.writing || sampleBuffer == NULL) {
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    self.lastHostPTS = pts;
    self.hasHostPTS = YES;

    if (self.resumePending && self.pauseBeganValid) {
        CMTime pausedFor = CMTimeSubtract(pts, self.pauseBeganAt);
        if (CMTimeCompare(pausedFor, kCMTimeZero) > 0) {
            self.pausedAccumulated = CMTimeAdd(self.pausedAccumulated, pausedFor);
        }
        self.pauseBeganValid = NO;
        self.resumePending = NO;
    }

    if (self.paused) {
        return;
    }

    if (!self.sessionStarted) {
        if (type != SCStreamOutputTypeScreen) {
            return;
        }
        [self.writer startWriting];
        [self.writer startSessionAtSourceTime:kCMTimeZero];
        self.sessionStarted = YES;
        self.sessionAnchor = pts;
    }

    CMTime relative = [self relativePTSForHost:pts];

    if (type == SCStreamOutputTypeScreen) {
        if (!self.videoInput.isReadyForMoreMediaData) {
            return;
        }
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            return;
        }
        CMTime videoPTS = [self monotonicPTS:relative previous:self.lastVideoPTS];
        if ([self.adaptor appendPixelBuffer:imageBuffer withPresentationTime:videoPTS]) {
            self.lastVideoPTS = videoPTS;
        }
        return;
    }

    if (type == SCStreamOutputTypeAudio) {
        CMTime sysLast = self.lastSysAudioPTS;
        [self appendAudio:sampleBuffer toInput:self.systemAudioInput pts:relative lastPTS:&sysLast];
        self.lastSysAudioPTS = sysLast;
        return;
    }

    if (@available(macOS 15.0, *)) {
        if (type == SCStreamOutputTypeMicrophone) {
            CMTime micLast = self.lastMicPTS;
            [self appendAudio:sampleBuffer toInput:self.micAudioInput pts:relative lastPTS:&micLast];
            self.lastMicPTS = micLast;
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

CaptureResultC CaptureStart(
    const char *source_id,
    const char *source_kind,
    const char *output_path,
    bool system_audio,
    bool microphone,
    const char *microphone_device_id,
    int exclude_pid
) {
    CaptureResultC result = {0};
    CaptureEnsureLock();
    [CaptureLock() lock];
    if (gRecorder != nil && gRecorder.writing) {
        [CaptureLock() unlock];
        result.error = CaptureCStrdup(@"Already recording");
        return result;
    }
    [CaptureLock() unlock];

    NSString *kind = source_kind ? [NSString stringWithUTF8String:source_kind] : @"screen";
    NSString *outPath = output_path ? [NSString stringWithUTF8String:output_path] : @"";
    NSString *micDeviceID = (microphone_device_id && microphone_device_id[0] != '\0')
        ? [NSString stringWithUTF8String:microphone_device_id]
        : @"";

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
        result.error = CaptureCStrdup(err.localizedDescription ?: @"No screen recording permission");
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
            result.error = CaptureCStrdup(@"Display not found");
            return result;
        }
        width = matched.width;
        height = matched.height;
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
            result.error = CaptureCStrdup(@"Window not found");
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
                     microphoneDeviceID:micDeviceID
                             outputPath:outPath
                                  error:&startErr];
    if (!ok) {
        result.error = CaptureCStrdup(startErr.localizedDescription ?: @"Failed to start capture");
        return result;
    }

    [CaptureLock() lock];
    gRecorder = recorder;
    [CaptureLock() unlock];

    result.ok = true;
    result.path = CaptureCStrdup(outPath);
    return result;
}

CaptureResultC CaptureStop(void) {
    CaptureResultC result = {0};
    CaptureEnsureLock();
    [CaptureLock() lock];
    VERecorder *recorder = gRecorder;
    gRecorder = nil;
    [CaptureLock() unlock];

    if (!recorder) {
        result.error = CaptureCStrdup(@"Not recording");
        return result;
    }

    NSString *path = [recorder stopAndFinish];
    if (!path) {
        result.error = CaptureCStrdup(recorder.lastError.localizedDescription ?: @"Failed to finalize recording");
        return result;
    }
    result.ok = true;
    result.path = CaptureCStrdup(path);
    return result;
}

int CaptureIsRecording(void) {
    CaptureEnsureLock();
    [CaptureLock() lock];
    int yes = (gRecorder != nil && gRecorder.writing) ? 1 : 0;
    [CaptureLock() unlock];
    return yes;
}

int CapturePause(void) {
    CaptureEnsureLock();
    [CaptureLock() lock];
    VERecorder *recorder = gRecorder;
    [CaptureLock() unlock];
    if (!recorder || !recorder.writing) {
        return 0;
    }
    [recorder pause];
    return 1;
}

int CaptureResume(void) {
    CaptureEnsureLock();
    [CaptureLock() lock];
    VERecorder *recorder = gRecorder;
    [CaptureLock() unlock];
    if (!recorder || !recorder.writing) {
        return 0;
    }
    [recorder resume];
    return 1;
}

int CaptureIsPaused(void) {
    CaptureEnsureLock();
    [CaptureLock() lock];
    int yes = (gRecorder != nil && gRecorder.writing && gRecorder.paused) ? 1 : 0;
    [CaptureLock() unlock];
    return yes;
}
