#import "capture_internal.h"

static NSString *pngBase64FromImage(NSImage *image) {
    if (!image) {
        return @"";
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
    if (!rep) {
        return @"";
    }
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

// Drop IME candidates, system HUD overlays, off-screen helpers, and other
// non-recordable chrome that ScreenCaptureKit still enumerates.
static BOOL shouldListWindow(SCWindow *window) {
    if (!window || !window.owningApplication) {
        return NO;
    }
    if (!window.isOnScreen) {
        return NO;
    }
    if (window.windowLayer != 0) {
        return NO;
    }

    CGFloat w = window.frame.size.width;
    CGFloat h = window.frame.size.height;
    if (w < 80 || h < 80) {
        return NO;
    }

    pid_t selfPid = [[NSProcessInfo processInfo] processIdentifier];
    if (window.owningApplication.processID == selfPid) {
        return NO;
    }

    NSString *bundleID = window.owningApplication.bundleIdentifier ?: @"";
    NSString *appName = window.owningApplication.applicationName ?: @"";
    NSString *bundleLower = bundleID.lowercaseString;
    NSString *appLower = appName.lowercaseString;

    static NSArray<NSString *> *denyExact = nil;
    static NSArray<NSString *> *denyPrefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        denyExact = @[
            @"com.apple.dock",
            @"com.apple.controlcenter",
            @"com.apple.notificationcenterui",
            @"com.apple.screencaptureui",
            @"com.apple.Screenshot",
            @"com.apple.Spotlight",
            @"com.apple.loginwindow",
            @"com.apple.WindowManager",
            @"com.apple.SystemUIServer",
            @"com.apple.TextInputMenuAgent",
            @"com.apple.TextInputUI.xpc.CursorUIViewService",
            @"com.apple.AccessibilityVisualsAgent",
            @"com.apple.PIPAgent",
            @"com.apple.UserNotificationCenter",
            @"com.apple.chronod",
            @"com.apple.wallpaper.agent",
        ];
        denyPrefixes = @[
            @"com.apple.TextInputUI",
            @"com.apple.inputmethod.",
            @"com.apple.PressAndHold",
            @"com.apple.CoreGlyphs",
            @"com.sogou.",
            @"com.baidu.inputmethod",
            @"com.iflytek.",
            @"com.tencent.inputmethod",
            @"com.google.inputmethod",
            @"com.apple.Hilink",
        ];
    });

    for (NSString *exact in denyExact) {
        if ([bundleID isEqualToString:exact]) {
            return NO;
        }
    }
    for (NSString *prefix in denyPrefixes) {
        if ([bundleID hasPrefix:prefix]) {
            return NO;
        }
    }
    if ([bundleLower containsString:@"inputmethod"] ||
        [bundleLower containsString:@"textinput"] ||
        [bundleLower containsString:@".ime"] ||
        [appLower containsString:@"input method"] ||
        [appName containsString:@"输入法"] ||
        [appName containsString:@"搜狗"] ||
        [appName containsString:@"百度输入"] ||
        [appName containsString:@"讯飞"]) {
        return NO;
    }

    if (window.title.length == 0 && (w < 200 || h < 200)) {
        return NO;
    }

    return YES;
}

CaptureSourceListC CaptureListSources(void) {
    CaptureSourceListC out = {0};
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *err = nil;

    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
        content = shareableContent;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (err || !content) {
        out.error = CaptureCStrdup(err.localizedDescription ?: @"Failed to list shareable content. Grant Screen Recording permission.");
        return out;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (SCDisplay *display in content.displays) {
        NSString *name = [NSString stringWithFormat:@"Screen %dx%d", (int)display.width, (int)display.height];
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
        if (!shouldListWindow(window)) {
            continue;
        }
        CGFloat w = window.frame.size.width;
        CGFloat h = window.frame.size.height;
        NSString *title = window.title.length ? window.title : @"Window";
        NSString *app = window.owningApplication.applicationName ?: @"App";
        NSString *name = [NSString stringWithFormat:@"%@ — %@", app, title];
        [rows addObject:@{
            @"id": [NSString stringWithFormat:@"window:%u", (unsigned int)window.windowID],
            @"kind": @"window",
            @"name": name,
            @"width": @((int)MAX(w, 0)),
            @"height": @((int)MAX(h, 0)),
            @"thumb": @"",
        }];
    }

    out.count = (int)rows.count;
    out.items = (CaptureSourceC *)calloc((size_t)out.count, sizeof(CaptureSourceC));
    for (int i = 0; i < out.count; i++) {
        NSDictionary *row = rows[i];
        out.items[i].id = CaptureCStrdup(row[@"id"]);
        out.items[i].kind = CaptureCStrdup(row[@"kind"]);
        out.items[i].name = CaptureCStrdup(row[@"name"]);
        out.items[i].width = [row[@"width"] intValue];
        out.items[i].height = [row[@"height"] intValue];
        out.items[i].thumbnail_png_b64 = CaptureCStrdup(row[@"thumb"]);
    }
    return out;
}

char *CaptureSourceThumbnail(const char *source_id, const char *source_kind) {
    if (!source_id || !source_kind) {
        return strdup("");
    }
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
    return CaptureCStrdup(b64 ?: @"");
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
