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
	SourceID            string `json:"sourceId"`
	SourceKind          string `json:"sourceKind"`
	SystemAudio         bool   `json:"systemAudio"`
	Microphone          bool   `json:"microphone"`
	MicrophoneDeviceID  string `json:"microphoneDeviceId"`
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

// RecordingStatusEvent is emitted while a session is active (and when state changes).
type RecordingStatusEvent struct {
	Recording bool    `json:"recording"`
	Paused    bool    `json:"paused"`
	Elapsed   float64 `json:"elapsed"` // seconds of recorded content (excludes pause)
}

type RecorderService struct {
	mu sync.Mutex

	mediaDir    string
	currentPath string
	clips       []Clip
	sourcePath  string

	startedAt    time.Time
	pausedAt     time.Time
	pausedTotal  time.Duration
	isPaused     bool
	isRecording  bool
	statusStopCh chan struct{}

	onStatus func(RecordingStatusEvent)
}

func NewRecorderService() *RecorderService {
	dir := filepath.Join(os.TempDir(), "video-editor-wails")
	_ = os.MkdirAll(dir, 0o755)
	return &RecorderService{mediaDir: dir}
}

func (r *RecorderService) setStatusListener(fn func(RecordingStatusEvent)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.onStatus = fn
}

func (r *RecorderService) MediaDir() string {
	return r.mediaDir
}

func (r *RecorderService) HasScreenAccess() bool {
	return capture.HasScreenAccess()
}

func (r *RecorderService) RequestScreenAccess() bool {
	return capture.RequestAccess()
}

func (r *RecorderService) OpenScreenCaptureSettings() bool {
	return capture.OpenScreenCaptureSettings()
}

func (r *RecorderService) ListSources() ([]capture.Source, error) {
	return capture.ListSources()
}

func (r *RecorderService) ListMicrophones() ([]capture.MicDevice, error) {
	return capture.ListMicrophones()
}

func (r *RecorderService) RequestMicrophoneAccess() bool {
	return capture.RequestMicrophoneAccess()
}

func (r *RecorderService) GetSourceThumbnail(sourceID, sourceKind string) string {
	return capture.SourceThumbnail(sourceID, sourceKind)
}

func (r *RecorderService) IsRecording() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.isRecording
}

func (r *RecorderService) IsPaused() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.isPaused
}

func (r *RecorderService) GetStatus() RecordingStatusEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.statusLocked()
}

func (r *RecorderService) statusLocked() RecordingStatusEvent {
	return RecordingStatusEvent{
		Recording: r.isRecording,
		Paused:    r.isPaused,
		Elapsed:   r.elapsedLocked().Seconds(),
	}
}

func (r *RecorderService) elapsedLocked() time.Duration {
	if !r.isRecording || r.startedAt.IsZero() {
		return 0
	}
	end := time.Now()
	if r.isPaused && !r.pausedAt.IsZero() {
		end = r.pausedAt
	}
	d := end.Sub(r.startedAt) - r.pausedTotal
	if d < 0 {
		return 0
	}
	return d
}

func (r *RecorderService) emitStatusLocked() {
	ev := r.statusLocked()
	listener := r.onStatus
	app := application.Get()
	if app != nil {
		app.Event.Emit("recording:status", ev)
	}
	if listener != nil {
		// Avoid holding the mutex in tray UI updates.
		go listener(ev)
	}
}

func (r *RecorderService) startStatusLoop() {
	r.stopStatusLoopLocked()
	ch := make(chan struct{})
	r.statusStopCh = ch
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ch:
				return
			case <-ticker.C:
				r.mu.Lock()
				if !r.isRecording {
					r.mu.Unlock()
					return
				}
				r.emitStatusLocked()
				r.mu.Unlock()
			}
		}
	}()
}

func (r *RecorderService) stopStatusLoopLocked() {
	if r.statusStopCh != nil {
		close(r.statusStopCh)
		r.statusStopCh = nil
	}
}

func (r *RecorderService) StartRecording(opts RecordingOptions) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.isRecording || capture.IsRecording() {
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

	err := capture.Start(opts.SourceID, opts.SourceKind, out, opts.SystemAudio, opts.Microphone, opts.MicrophoneDeviceID, os.Getpid())
	if err != nil {
		app := application.Get()
		if app != nil {
			app.Event.Emit("recording:failed", RecordingFailedEvent{Message: err.Error()})
		}
		return err
	}

	r.currentPath = out
	r.isRecording = true
	r.isPaused = false
	r.startedAt = time.Now()
	r.pausedAt = time.Time{}
	r.pausedTotal = 0
	r.startStatusLoop()
	r.emitStatusLocked()
	return nil
}

func (r *RecorderService) PauseRecording() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.isRecording || r.isPaused {
		return fmt.Errorf("cannot pause")
	}
	if err := capture.Pause(); err != nil {
		return err
	}
	r.isPaused = true
	r.pausedAt = time.Now()
	r.emitStatusLocked()
	return nil
}

func (r *RecorderService) ResumeRecording() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.isRecording || !r.isPaused {
		return fmt.Errorf("cannot resume")
	}
	if err := capture.Resume(); err != nil {
		return err
	}
	if !r.pausedAt.IsZero() {
		r.pausedTotal += time.Since(r.pausedAt)
	}
	r.pausedAt = time.Time{}
	r.isPaused = false
	r.emitStatusLocked()
	return nil
}

func (r *RecorderService) StopRecording() (RecordingFinishedEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.stopStatusLoopLocked()

	path, err := capture.Stop()
	r.isRecording = false
	r.isPaused = false
	r.emitStatusLocked()
	if err != nil {
		app := application.Get()
		if app != nil {
			app.Event.Emit("recording:failed", RecordingFailedEvent{Message: err.Error()})
		}
		return RecordingFinishedEvent{}, err
	}

	duration := probeDuration(path)
	if duration <= 0 {
		duration = r.elapsedLocked().Seconds()
	}
	mediaURL := "/media/" + filepath.Base(path)
	r.sourcePath = path
	r.clips = []Clip{{
		ID:        fmt.Sprintf("clip-%d", time.Now().UnixNano()),
		Start:     0,
		End:       duration,
		SourceURL: mediaURL,
	}}
	r.startedAt = time.Time{}
	r.pausedAt = time.Time{}
	r.pausedTotal = 0

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
		Title:                "Export MP4",
		CanCreateDirectories: true,
		Filename:             "export.mp4",
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

func (r *RecorderService) ShowMainWindow() {
	app := application.Get()
	if app == nil {
		return
	}
	if win := app.Window.Current(); win != nil {
		win.Show().Focus()
		return
	}
	for _, win := range app.Window.GetAll() {
		win.Show().Focus()
		return
	}
}

// Relaunch quits this process and opens the same .app again.
// Needed after toggling Screen Recording — TCC is applied to new launches only.
func (r *RecorderService) Relaunch() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return
	}
	target := exe
	// Contents/MacOS/<bin> → ../../.. = Something.app
	if strings.Contains(exe, ".app/Contents/MacOS/") {
		target = filepath.Clean(filepath.Join(filepath.Dir(exe), "..", "..", ".."))
	}
	_ = exec.Command("open", "-n", target).Start()
	go func() {
		time.Sleep(250 * time.Millisecond)
		if app := application.Get(); app != nil {
			app.Quit()
		}
	}()
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

	for i, clip := range clips {
		part := filepath.Join(tmpDir, fmt.Sprintf("part-%d.mp4", i))
		args := []string{"-y", "-ss", fmt.Sprintf("%.3f", clip.Start), "-to", fmt.Sprintf("%.3f", clip.End), "-i", source, "-c", "copy", part}
		if err := exec.Command("ffmpeg", args...).Run(); err != nil {
			args = []string{"-y", "-ss", fmt.Sprintf("%.3f", clip.Start), "-to", fmt.Sprintf("%.3f", clip.End), "-i", source, "-c:v", "libx264", "-c:a", "aac", part}
			if err := exec.Command("ffmpeg", args...).Run(); err != nil {
				return fmt.Errorf("ffmpeg trim failed: %w", err)
			}
		}
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

func formatElapsed(seconds float64) string {
	if seconds < 0 {
		seconds = 0
	}
	total := int(seconds + 0.5)
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%d:%02d", m, s)
}
