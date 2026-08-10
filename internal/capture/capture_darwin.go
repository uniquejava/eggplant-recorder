//go:build darwin

package capture

/*
#cgo CFLAGS: -x objective-c -fobjc-arc -mmacosx-version-min=15.0
#cgo LDFLAGS: -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit -framework AppKit -framework CoreGraphics

#include <stdlib.h>
#include "capture_darwin.h"
*/
import "C"

import (
	"errors"
	"unsafe"
)

type Source struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	Thumbnail string `json:"thumbnail"` // raw base64 PNG without data-uri prefix
}

type MicDevice struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Default bool   `json:"default"`
}

func ListSources() ([]Source, error) {
	list := C.CaptureListSources()
	defer C.CaptureFreeSources(list)

	if list.error != nil {
		return nil, errors.New(C.GoString(list.error))
	}

	count := int(list.count)
	out := make([]Source, 0, count)
	if count == 0 || list.items == nil {
		return out, nil
	}

	items := unsafe.Slice(list.items, count)
	for _, item := range items {
		out = append(out, Source{
			ID:        C.GoString(item.id),
			Kind:      C.GoString(item.kind),
			Name:      C.GoString(item.name),
			Width:     int(item.width),
			Height:    int(item.height),
			Thumbnail: C.GoString(item.thumbnail_png_b64),
		})
	}
	return out, nil
}

func ListMicrophones() ([]MicDevice, error) {
	list := C.CaptureListMicrophones()
	defer C.CaptureFreeMics(list)
	if list.error != nil {
		return nil, errors.New(C.GoString(list.error))
	}
	count := int(list.count)
	out := make([]MicDevice, 0, count)
	if count == 0 || list.items == nil {
		return out, nil
	}
	items := unsafe.Slice(list.items, count)
	for _, item := range items {
		out = append(out, MicDevice{
			ID:      C.GoString(item.id),
			Name:    C.GoString(item.name),
			Default: item.is_default != 0,
		})
	}
	return out, nil
}

func HasScreenAccess() bool {
	return C.CaptureHasScreenAccess() == 1
}

func RequestAccess() bool {
	return C.CaptureRequestAccess() == 1
}

func RequestMicrophoneAccess() bool {
	return C.CaptureRequestMicrophoneAccess() == 1
}

func OpenScreenCaptureSettings() bool {
	return C.CaptureOpenScreenCaptureSettings() == 1
}

func SourceThumbnail(sourceID, sourceKind string) string {
	cid := C.CString(sourceID)
	ckind := C.CString(sourceKind)
	defer C.free(unsafe.Pointer(cid))
	defer C.free(unsafe.Pointer(ckind))
	cthumb := C.CaptureSourceThumbnail(cid, ckind)
	if cthumb == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(cthumb))
	return C.GoString(cthumb)
}

func Start(sourceID, sourceKind, outputPath string, systemAudio, microphone bool, microphoneDeviceID string, excludePID int) error {
	cid := C.CString(sourceID)
	ckind := C.CString(sourceKind)
	cpath := C.CString(outputPath)
	cmic := C.CString(microphoneDeviceID)
	defer C.free(unsafe.Pointer(cid))
	defer C.free(unsafe.Pointer(ckind))
	defer C.free(unsafe.Pointer(cpath))
	defer C.free(unsafe.Pointer(cmic))

	res := C.CaptureStart(cid, ckind, cpath, C.bool(systemAudio), C.bool(microphone), cmic, C.int(excludePID))
	defer C.CaptureFreeResult(res)
	if !bool(res.ok) {
		if res.error != nil {
			return errors.New(C.GoString(res.error))
		}
		return errors.New("failed to start recording")
	}
	return nil
}

func Stop() (string, error) {
	res := C.CaptureStop()
	defer C.CaptureFreeResult(res)
	if !bool(res.ok) {
		if res.error != nil {
			return "", errors.New(C.GoString(res.error))
		}
		return "", errors.New("failed to stop recording")
	}
	return C.GoString(res.path), nil
}

func IsRecording() bool {
	return C.CaptureIsRecording() == 1
}

func Pause() error {
	if C.CapturePause() != 1 {
		return errors.New("not recording")
	}
	return nil
}

func Resume() error {
	if C.CaptureResume() != 1 {
		return errors.New("not recording")
	}
	return nil
}

func IsPaused() bool {
	return C.CaptureIsPaused() == 1
}
