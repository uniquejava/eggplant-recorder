#import "capture_internal.h"

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
