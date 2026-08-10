//go:build !darwin

package capture

import "errors"

type Source struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	Thumbnail string `json:"thumbnail"`
}

func ListSources() ([]Source, error) {
	return nil, errors.New("screen capture is only supported on macOS 15+")
}

func HasScreenAccess() bool            { return false }
func RequestAccess() bool              { return false }
func OpenScreenCaptureSettings() bool  { return false }

func SourceThumbnail(sourceID, sourceKind string) string { return "" }

func Start(sourceID, sourceKind, outputPath string, systemAudio, microphone bool, excludePID int) error {
	return errors.New("screen capture is only supported on macOS 15+")
}

func Stop() (string, error) {
	return "", errors.New("screen capture is only supported on macOS 15+")
}

func IsRecording() bool { return false }

func Pause() error  { return errors.New("screen capture is only supported on macOS 15+") }
func Resume() error { return errors.New("screen capture is only supported on macOS 15+") }
func IsPaused() bool { return false }
