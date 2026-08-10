//go:build darwin

// Lists AVCapture audio inputs (no Screen Recording needed).
package main

import (
	"fmt"
	"os"

	"github.com/uniquejava/video-editor-wails/internal/capture"
)

func main() {
	ok := capture.RequestMicrophoneAccess()
	fmt.Printf("RequestMicrophoneAccess=%v\n", ok)
	list, err := capture.ListMicrophones()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ListMicrophones: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("count=%d\n", len(list))
	for _, m := range list {
		mark := ""
		if m.Default {
			mark = " [default]"
		}
		fmt.Printf("  - %s%s\n    id=%s\n", m.Name, mark, m.ID)
	}
}
