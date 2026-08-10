package main

import (
	_ "embed"
	"fmt"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed build/tray/tray-idleTemplate.png
var trayIdleIcon []byte

//go:embed build/tray/tray-recordingTemplate.png
var trayRecordingIcon []byte

//go:embed build/tray/tray-pausedTemplate.png
var trayPausedIcon []byte

type TrayController struct {
	app      *application.App
	recorder *RecorderService
	tray     *application.SystemTray
	window   *application.WebviewWindow

	statusItem *application.MenuItem
	pauseItem  *application.MenuItem
	stopItem   *application.MenuItem
}

func setupTray(app *application.App, recorder *RecorderService, window *application.WebviewWindow) *TrayController {
	tc := &TrayController{
		app:      app,
		recorder: recorder,
		window:   window,
	}

	tray := app.SystemTray.New()
	tray.SetTemplateIcon(trayIdleIcon)
	tray.SetLabel("Idle")
	tray.SetTooltip("Video Editor Wails")
	tc.tray = tray

	tc.rebuildMenu(RecordingStatusEvent{})
	recorder.setStatusListener(tc.onStatus)

	tray.OnClick(func() {
		if window != nil {
			window.Show().Focus()
		}
	})

	return tc
}

func (t *TrayController) onStatus(ev RecordingStatusEvent) {
	if t == nil || t.tray == nil {
		return
	}
	application.InvokeSync(func() {
		t.applyStatus(ev)
	})
}

func (t *TrayController) applyStatus(ev RecordingStatusEvent) {
	switch {
	case !ev.Recording:
		t.tray.SetTemplateIcon(trayIdleIcon)
		t.tray.SetLabel("Idle")
		t.tray.SetTooltip("Video Editor Wails")
	case ev.Paused:
		t.tray.SetTemplateIcon(trayPausedIcon)
		label := fmt.Sprintf("⏸ %s", formatElapsed(ev.Elapsed))
		t.tray.SetLabel(label)
		t.tray.SetTooltip("Paused · " + label)
	default:
		t.tray.SetTemplateIcon(trayRecordingIcon)
		label := fmt.Sprintf("● %s", formatElapsed(ev.Elapsed))
		t.tray.SetLabel(label)
		t.tray.SetTooltip("Recording · " + label)
	}
	t.rebuildMenu(ev)
}

func (t *TrayController) rebuildMenu(ev RecordingStatusEvent) {
	menu := t.app.NewMenu()

	statusText := "Idle"
	switch {
	case ev.Recording && ev.Paused:
		statusText = "Paused · " + formatElapsed(ev.Elapsed)
	case ev.Recording:
		statusText = "Recording · " + formatElapsed(ev.Elapsed)
	}
	t.statusItem = menu.Add(statusText)
	t.statusItem.SetEnabled(false)

	menu.AddSeparator()

	if ev.Recording {
		if ev.Paused {
			t.pauseItem = menu.Add("Resume")
			t.pauseItem.OnClick(func(ctx *application.Context) {
				_ = t.recorder.ResumeRecording()
			})
		} else {
			t.pauseItem = menu.Add("Pause")
			t.pauseItem.OnClick(func(ctx *application.Context) {
				_ = t.recorder.PauseRecording()
			})
		}

		t.stopItem = menu.Add("Stop")
		t.stopItem.OnClick(func(ctx *application.Context) {
			_, _ = t.recorder.StopRecording()
			if t.window != nil {
				t.window.Show().Focus()
			}
		})
		menu.AddSeparator()
	}

	menu.Add("Show Window").OnClick(func(ctx *application.Context) {
		if t.window != nil {
			t.window.Show().Focus()
		}
	})

	menu.AddSeparator()
	menu.Add("Quit").OnClick(func(ctx *application.Context) {
		if t.recorder.IsRecording() {
			_, _ = t.recorder.StopRecording()
		}
		t.app.Quit()
	})

	t.tray.SetMenu(menu)
}
