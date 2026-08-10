#import "capture_internal.h"

int CaptureRequestMicrophoneAccess(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        return 1;
    }
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        return 0;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
        granted = ok;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return granted ? 1 : 0;
}

CaptureMicListC CaptureListMicrophones(void) {
    CaptureMicListC out = {0};
    // Listing works without mic permission; names may be limited until authorized.
    AVCaptureDevice *defaultDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    NSString *defaultID = defaultDev.uniqueID ?: @"";

    NSMutableArray<AVCaptureDevice *> *devices = [NSMutableArray array];
    if (@available(macOS 14.0, *)) {
        NSArray<AVCaptureDeviceType> *types = @[
            AVCaptureDeviceTypeMicrophone,
            AVCaptureDeviceTypeExternal,
        ];
        AVCaptureDeviceDiscoverySession *session =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                   mediaType:AVMediaTypeAudio
                                                                    position:AVCaptureDevicePositionUnspecified];
        if (session.devices.count) {
            [devices addObjectsFromArray:session.devices];
        }
    }
    if (devices.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray *legacy = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
        if (legacy.count) {
            [devices addObjectsFromArray:legacy];
        }
    }

    NSMutableArray<AVCaptureDevice *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (AVCaptureDevice *d in devices) {
        if (!d.uniqueID.length || [seen containsObject:d.uniqueID]) {
            continue;
        }
        [seen addObject:d.uniqueID];
        [unique addObject:d];
    }
    if (defaultDev && defaultDev.uniqueID.length && ![seen containsObject:defaultDev.uniqueID]) {
        [unique insertObject:defaultDev atIndex:0];
    }

    out.count = (int)unique.count;
    if (out.count == 0) {
        return out;
    }
    out.items = (CaptureMicDeviceC *)calloc((size_t)out.count, sizeof(CaptureMicDeviceC));
    for (int i = 0; i < out.count; i++) {
        AVCaptureDevice *d = unique[i];
        out.items[i].id = CaptureCStrdup(d.uniqueID);
        out.items[i].name = CaptureCStrdup(d.localizedName.length ? d.localizedName : d.uniqueID);
        out.items[i].is_default = [d.uniqueID isEqualToString:defaultID] ? 1 : 0;
    }
    return out;
}

void CaptureFreeMics(CaptureMicListC list) {
    if (list.error) {
        free(list.error);
    }
    if (!list.items) {
        return;
    }
    for (int i = 0; i < list.count; i++) {
        free(list.items[i].id);
        free(list.items[i].name);
    }
    free(list.items);
}
