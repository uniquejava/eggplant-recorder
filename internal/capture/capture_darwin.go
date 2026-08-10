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

func RequestAccess() bool {
	return C.CaptureRequestAccess() == 1
}

func Start(sourceID, sourceKind, outputPath string, systemAudio, microphone bool, excludePID int) error {
	cid := C.CString(sourceID)
	ckind := C.CString(sourceKind)
	cpath := C.CString(outputPath)
	defer C.free(unsafe.Pointer(cid))
	defer C.free(unsafe.Pointer(ckind))
	defer C.free(unsafe.Pointer(cpath))

	res := C.CaptureStart(cid, ckind, cpath, C.bool(systemAudio), C.bool(microphone), C.int(excludePID))
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
