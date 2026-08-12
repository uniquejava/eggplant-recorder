//go:build darwin

// Quick probe: prints CGPreflight + ListSources counts without opening Settings.
// Usage: go run ./scripts/check-screen-access
package main

import (
	"fmt"
	"os"

	"github.com/uniquejava/eggplant-recorder/internal/capture"
)

func main() {
	granted := capture.HasScreenAccess()
	fmt.Printf("HasScreenAccess=%v\n", granted)
	if !granted {
		fmt.Println("Screen Recording not granted for this binary identity.")
		fmt.Println("Grant it for the .app (not a bare go run), then re-check.")
		os.Exit(2)
	}
	list, err := capture.ListSources()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ListSources error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("ListSources count=%d\n", len(list))
	for i, s := range list {
		if i >= 8 {
			fmt.Printf("  … %d more\n", len(list)-i)
			break
		}
		fmt.Printf("  - [%s] %s (%s)\n", s.Kind, s.Name, s.ID)
	}
	if len(list) == 0 {
		os.Exit(2)
	}
}
