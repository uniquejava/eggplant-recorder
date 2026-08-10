//go:build darwin

// Synthetic repro of muxing two incompatible PCM streams into one
// AVAssetWriterInput (what capture_recorder.m used to do for system audio + mic).
package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc -mmacosx-version-min=15.0
#cgo LDFLAGS: -framework Foundation -framework AVFoundation -framework CoreMedia -framework AudioToolbox -framework CoreAudio

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CMSampleBufferRef makePCM(double sampleRate, UInt32 channels, CMTime pts, double seconds) {
    UInt32 frames = (UInt32)(sampleRate * seconds);
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBitsPerChannel = 32;
    asbd.mChannelsPerFrame = channels;
    asbd.mBytesPerFrame = (asbd.mBitsPerChannel / 8) * asbd.mChannelsPerFrame;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    CMFormatDescriptionRef format = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format);

    size_t dataSize = (size_t)frames * asbd.mBytesPerFrame;
    void *data = calloc(1, dataSize);
    CMBlockBufferRef block = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, data, dataSize, NULL, NULL, 0, dataSize, kCMBlockBufferAssureMemoryNowFlag, &block);

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)sampleRate),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, format, frames, 1, &timing, 0, NULL, &sample);
    CFRelease(format);
    CFRelease(block);
    // block owns data via AssureMemoryNow + free when released? Actually we passed NULL for allocator
    // so we must not free data separately if block owns it — CMBlockBufferCreateWithMemoryBlock
    // with NULL blockAllocator means default allocator does not free custom memory.
    // Use custom deallocator via free:
    return sample;
}

// Returns 0 on success, 1 on writer failure. Prints diagnosis.
int MuxTwoAudioFormats(const char *path, int bothFormats) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

        NSError *err = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&err];
        if (err) {
            printf("writer create: %s\n", err.localizedDescription.UTF8String);
            return 2;
        }

        AudioChannelLayout stereo = {0};
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVEncoderBitRateKey: @192000,
            AVChannelLayoutKey: [NSData dataWithBytes:&stereo length:sizeof(stereo)],
        };
        AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
        audio.expectsMediaDataInRealTime = YES;
        [writer addInput:audio];
        [writer startWriting];
        [writer startSessionAtSourceTime:kCMTimeZero];

        // System-audio-like: stereo float32 @ 48k
        CMSampleBufferRef a = makePCM(48000, 2, CMTimeMake(0, 48000), 0.05);
        BOOL okA = [audio appendSampleBuffer:a];
        printf("append stereo48k=%d writerStatus=%ld err=%s\n",
               okA, (long)writer.status,
               writer.error.localizedDescription.UTF8String ?: "(nil)");
        CFRelease(a);

        if (bothFormats) {
            // Mic-like: mono float32 @ 48k into THE SAME input (current app bug)
            CMSampleBufferRef b = makePCM(48000, 1, CMTimeMake(2400, 48000), 0.05);
            BOOL okB = [audio appendSampleBuffer:b];
            printf("append mono48k=%d writerStatus=%ld err=%s\n",
                   okB, (long)writer.status,
                   writer.error.localizedDescription.UTF8String ?: "(nil)");
            CFRelease(b);
        } else {
            CMSampleBufferRef b = makePCM(48000, 2, CMTimeMake(2400, 48000), 0.05);
            BOOL okB = [audio appendSampleBuffer:b];
            printf("append stereo48k#2=%d writerStatus=%ld err=%s\n",
                   okB, (long)writer.status,
                   writer.error.localizedDescription.UTF8String ?: "(nil)");
            CFRelease(b);
        }

        [audio markAsFinished];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        printf("finish status=%ld err=%s\n",
               (long)writer.status,
               writer.error.localizedDescription.UTF8String ?: "(nil)");
        return writer.status == AVAssetWriterStatusCompleted ? 0 : 1;
    }
}
*/
import "C"
import (
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	dir, _ := os.MkdirTemp("", "mux-repro-*")
	same := filepath.Join(dir, "same-format.mp4")
	mixed := filepath.Join(dir, "mixed-format.mp4")

	fmt.Println("== same format (stereo then stereo) ==")
	rc1 := C.MuxTwoAudioFormats(C.CString(same), 0)
	fmt.Printf("exit=%d\n\n", int(rc1))

	fmt.Println("== mixed format (stereo then mono) — mimics sys+mic into one track ==")
	rc2 := C.MuxTwoAudioFormats(C.CString(mixed), 1)
	fmt.Printf("exit=%d\n", int(rc2))

	if rc1 == 0 && rc2 != 0 {
		fmt.Println("\nLOOP RED: mixed formats fail finalize (matches mic+system-audio bug)")
		os.Exit(1)
	}
	if rc1 == 0 && rc2 == 0 {
		fmt.Println("\nLOOP GREEN unexpectedly — hypothesis not confirmed by synthetic mux")
		os.Exit(0)
	}
	os.Exit(int(rc2))
}
