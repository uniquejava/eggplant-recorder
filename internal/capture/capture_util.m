#import "capture_internal.h"

static NSLock *gCaptureLock = nil;

void CaptureEnsureLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCaptureLock = [[NSLock alloc] init];
    });
}

NSLock *CaptureLock(void) {
    CaptureEnsureLock();
    return gCaptureLock;
}

char *CaptureCStrdup(NSString *s) {
    if (!s) {
        return NULL;
    }
    const char *utf8 = [s UTF8String];
    if (!utf8) {
        return NULL;
    }
    return strdup(utf8);
}

void CaptureFreeResult(CaptureResultC result) {
    if (result.path) free(result.path);
    if (result.error) free(result.error);
}
