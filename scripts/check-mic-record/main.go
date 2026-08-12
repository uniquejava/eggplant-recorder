//go:build darwin

// Repro: record a short clip with/without microphone and print stop errors.
// Prefer running the binary that already has Screen Recording TCC
// (e.g. copy into the .app Contents/MacOS and invoke that path).
//
// Usage:
//   go build -o /tmp/check-mic-record ./scripts/check-mic-record
//   /tmp/check-mic-record
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/uniquejava/eggplant-recorder/internal/capture"
)

func runCase(name, sourceID, sourceKind, dir string, systemAudio, mic bool) {
	out := filepath.Join(dir, name+".mp4")
	fmt.Printf("\n== %s (systemAudio=%v mic=%v) ==\n", name, systemAudio, mic)
	err := capture.Start(sourceID, sourceKind, out, systemAudio, mic, "", os.Getpid())
	if err != nil {
		fmt.Printf("START FAIL: %v\n", err)
		return
	}
	time.Sleep(2 * time.Second)
	path, err := capture.Stop()
	if err != nil {
		fmt.Printf("STOP FAIL: %v\n", err)
		return
	}
	fi, _ := os.Stat(path)
	size := int64(0)
	if fi != nil {
		size = fi.Size()
	}
	fmt.Printf("STOP OK: %s (%d bytes)\n", path, size)
}

func main() {
	if !capture.HasScreenAccess() {
		fmt.Println("HasScreenAccess=false — grant Screen Recording to this binary first")
		os.Exit(2)
	}
	list, err := capture.ListSources()
	if err != nil || len(list) == 0 {
		fmt.Fprintf(os.Stderr, "ListSources failed: %v (count=%d)\n", err, len(list))
		os.Exit(1)
	}
	var src capture.Source
	for _, s := range list {
		if s.Kind == "screen" {
			src = s
			break
		}
	}
	if src.ID == "" {
		src = list[0]
	}
	fmt.Printf("Using source [%s] %s (%s)\n", src.Kind, src.Name, src.ID)

	dir, err := os.MkdirTemp("", "ve-mic-repro-*")
	if err != nil {
		panic(err)
	}
	fmt.Printf("outdir=%s\n", dir)

	// Match UI defaults: system audio on; then toggle mic like the user.
	runCase("sys_only", src.ID, src.Kind, dir, true, false)
	runCase("sys_plus_mic", src.ID, src.Kind, dir, true, true)
	runCase("mic_only", src.ID, src.Kind, dir, false, true)
	runCase("neither", src.ID, src.Kind, dir, false, false)
}
