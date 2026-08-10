package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed all:frontend/dist
var assets embed.FS

func init() {
	application.RegisterEvent[RecordingFinishedEvent]("recording:finished")
	application.RegisterEvent[RecordingFailedEvent]("recording:failed")
	application.RegisterEvent[RecordingStatusEvent]("recording:status")
}

func main() {
	recorder := NewRecorderService()

	app := application.New(application.Options{
		Name:        "Video Editor Wails",
		Description: "Screen recorder and video editor for macOS 15+",
		Services: []application.Service{
			application.NewService(recorder),
		},
		Assets: application.AssetOptions{
			Handler:    application.AssetFileServerFS(assets),
			Middleware: mediaMiddleware(recorder.MediaDir()),
		},
		Mac: application.MacOptions{
			// Keep running when the window is closed so the menu-bar tray can control recording.
			ApplicationShouldTerminateAfterLastWindowClosed: false,
		},
	})

	window := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:  "Video Editor Wails",
		Width:  1100,
		Height: 720,
		Mac: application.MacWindow{
			Backdrop: application.MacBackdropNormal,
			TitleBar: application.MacTitleBarDefault,
		},
		BackgroundColour: application.NewRGB(28, 28, 30),
		URL:              "/",
	})

	setupTray(app, recorder, window)

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
