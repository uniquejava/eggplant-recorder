package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/cyper/video-editor-wails/internal/capture"
	"github.com/wailsapp/wails/v3/pkg/application"
)

type RecordingOptions struct {
	SourceID    string `json:"sourceId"`
	SourceKind  string `json:"sourceKind"`
	SystemAudio bool   `json:"systemAudio"`
	Microphone  bool   `json:"microphone"`
}

type Clip struct {
	ID        string  `json:"id"`
	Start     float64 `json:"start"`
	End       float64 `json:"end"`
	SourceURL string  `json:"sourceUrl"`
}

type RecordingFinishedEvent struct {
	Path     string  `json:"path"`
	MediaURL string  `json:"mediaUrl"`
	Duration float64 `json:"duration"`
}

type RecordingFailedEvent struct {
	Message string `json:"message"`
}

type RecorderService struct {
	mu          sync.Mutex
	mediaDir    string
	currentPath string
	clips       []Clip
	sourcePath  string
}

func NewRecorderService() *RecorderService {
	dir := filepath.Join(os.TempDir(), "video-editor-wails")
	_ = os.MkdirAll(dir, 0o755)
	return &RecorderService{mediaDir: dir}
}

func (r *RecorderService) MediaDir() string {
	return r.mediaDir
}

func (r *RecorderService) RequestScreenAccess() bool {
	return capture.RequestAccess()
}

func (r *RecorderService) ListSources() ([]capture.Source, error) {
	return capture.ListSources()
}

func (r *RecorderService) IsRecording() bool {
	return capture.IsRecording()
}

func (r *RecorderService) StartRecording(opts RecordingOptions) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if capture.IsRecording() {
		return fmt.Errorf("already recording")
	}
	if opts.SourceID == "" {
		return fmt.Errorf("no source selected")
	}
	if opts.SourceKind == "" {
		opts.SourceKind = "screen"
	}

	filename := fmt.Sprintf("rec-%d.mp4", time.Now().UnixNano())
	out := filepath.Join(r.mediaDir, filename)

	err := capture.Start(opts.SourceID, opts.SourceKind, out, opts.SystemAudio, opts.Microphone, os.Getpid())
	if err != nil {
		app := application.Get()
		if app != nil {
			app.Event.Emit("recording:failed", RecordingFailedEvent{Message: err.Error()})
		}
		return err
	}

	r.currentPath = out
	return nil
}

func (r *RecorderService) StopRecording() (RecordingFinishedEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	path, err := capture.Stop()
	if err != nil {
		app := application.Get()
		if app != nil {
			app.Event.Emit("recording:failed", RecordingFailedEvent{Message: err.Error()})
		}
		return RecordingFinishedEvent{}, err
	}

	duration := probeDuration(path)
	mediaURL := "/media/" + filepath.Base(path)
	r.sourcePath = path
	r.clips = []Clip{{
		ID:        fmt.Sprintf("clip-%d", time.Now().UnixNano()),
		Start:     0,
		End:       duration,
		SourceURL: mediaURL,
	}}

	ev := RecordingFinishedEvent{
		Path:     path,
		MediaURL: mediaURL,
		Duration: duration,
	}
	app := application.Get()
	if app != nil {
		app.Event.Emit("recording:finished", ev)
	}
	return ev, nil
}

func (r *RecorderService) GetClips() []Clip {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Clip, len(r.clips))
	copy(out, r.clips)
	return out
}

func (r *RecorderService) SetClips(clips []Clip) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.clips = clips
}

func (r *RecorderService) ExportVideo() (string, error) {
	r.mu.Lock()
	source := r.sourcePath
	clips := make([]Clip, len(r.clips))
	copy(clips, r.clips)
	r.mu.Unlock()

	if source == "" || len(clips) == 0 {
		return "", fmt.Errorf("nothing to export")
	}

	app := application.Get()
	if app == nil {
		return "", fmt.Errorf("application not ready")
	}

	dialog := app.Dialog.SaveFileWithOptions(&application.SaveFileDialogOptions{
		Title:            "Export MP4",
		CanCreateDirectories: true,
		Filename:         "export.mp4",
		Filters: []application.FileFilter{
			{DisplayName: "MP4 Video", Pattern: "*.mp4"},
		},
	})
	dest, err := dialog.PromptForSingleSelection()
	if err != nil {
		return "", err
	}
	if dest == "" {
		return "", nil
	}
	if !strings.HasSuffix(strings.ToLower(dest), ".mp4") {
		dest += ".mp4"
	}

	if err := exportClips(source, clips, dest); err != nil {
		return "", err
	}
	return dest, nil
}

func probeDuration(path string) float64 {
	cmd := exec.Command("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path)
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	var d float64
	_, _ = fmt.Sscanf(strings.TrimSpace(string(out)), "%f", &d)
	return d
}

func exportClips(source string, clips []Clip, dest string) error {
	if len(clips) == 1 && clips[0].Start <= 0.001 {
		// If end covers full file (or unknown), just copy.
		dur := probeDuration(source)
		if clips[0].End >= dur-0.05 || clips[0].End <= 0 {
			return copyFile(source, dest)
		}
	}

	tmpDir, err := os.MkdirTemp(filepath.Dir(dest), "ve-export-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	listPath := filepath.Join(tmpDir, "list.txt")
	var listBuilder strings.Builder
	parts := make([]string, 0, len(clips))

	for i, clip := range clips {
		part := filepath.Join(tmpDir, fmt.Sprintf("part-%d.mp4", i))
		args := []string{"-y", "-ss", fmt.Sprintf("%.3f", clip.Start), "-to", fmt.Sprintf("%.3f", clip.End), "-i", source, "-c", "copy", part}
		if err := exec.Command("ffmpeg", args...).Run(); err != nil {
			// fallback re-encode
			args = []string{"-y", "-ss", fmt.Sprintf("%.3f", clip.Start), "-to", fmt.Sprintf("%.3f", clip.End), "-i", source, "-c:v", "libx264", "-c:a", "aac", part}
			if err := exec.Command("ffmpeg", args...).Run(); err != nil {
				return fmt.Errorf("ffmpeg trim failed: %w", err)
			}
		}
		parts = append(parts, part)
		listBuilder.WriteString(fmt.Sprintf("file '%s'\n", part))
	}

	if err := os.WriteFile(listPath, []byte(listBuilder.String()), 0o644); err != nil {
		return err
	}
	cmd := exec.Command("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", dest)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg concat failed: %w", err)
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o644)
}

func mediaMiddleware(mediaDir string) application.Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if strings.HasPrefix(req.URL.Path, "/media/") {
				name := filepath.Base(strings.TrimPrefix(req.URL.Path, "/media/"))
				path := filepath.Join(mediaDir, name)
				http.ServeFile(w, req, path)
				return
			}
			next.ServeHTTP(w, req)
		})
	}
}
