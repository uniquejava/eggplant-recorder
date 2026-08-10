# AGENTS.md — Video Editor Wails

## What this is

macOS **15+** screen recorder + light timeline editor, built with **Wails v3** (`v3.0.0-beta.6`).

Flow: pick screen/window → record → preview/trim → Export MP4. Inspiration / demo link: see `README.md`.

Step-by-step tutorial (Chinese): `docs/README.md`.

## Stack

| Layer | Tech |
|-------|------|
| Desktop shell | Wails v3, React + TypeScript + Vite |
| Capture | ScreenCaptureKit via CGo (`internal/capture/*.m`) |
| Export / probe | system `ffmpeg` / `ffprobe` |
| Tray | Wails `SystemTray` (menu bar on macOS) |

Module: `github.com/uniquejava/video-editor-wails`  
Bundle ID: `com.cyper.videoeditorwails`

## Layout

```
main.go / tray.go / recorderservice.go   # app, tray, Go service
internal/capture/                        # ObjC modules by feature (see docs/04)
frontend/src/App.tsx                     # select → recording → editor
frontend/bindings/                       # generated; commit OK, rebuild regenerates
build/darwin/Info*.plist                 # LSMinimumSystemVersion 15.0 + privacy strings
docs/                                    # from-zero tutorial series
```

`internal/capture` ObjC split (darwin): `capture_perm` / `capture_mic` / `capture_sources` / `capture_recorder` + `capture_util` + `capture_darwin.h` C API.
## Commands

```bash
wails3 task dev          # hot reload
wails3 build             # bin/video-editor-wails
wails3 package           # bin/video-editor-wails.app (use this for TCC)
open bin/video-editor-wails.app
```

CLI: `go install github.com/wailsapp/wails/v3/cmd/wails3@v3.0.0-beta.6`

## Network / proxy (China)

Local HTTP/HTTPS proxy is usually on **`127.0.0.1:7897`** (Clash / similar). When fetching docs, GitHub, Apple, npm, or searching the web from this machine, set:

```bash
export http_proxy=http://127.0.0.1:7897
export https_proxy=http://127.0.0.1:7897
export HTTP_PROXY=http://127.0.0.1:7897
export HTTPS_PROXY=http://127.0.0.1:7897
export ALL_PROXY=http://127.0.0.1:7897
```

Agents should prefer this proxy for outbound lookups so requests are not blocked by the GFW. If `7897` is down, try `7890` once, then report the failure.

## Hard rules / pitfalls

1. **macOS only for capture** — `internal/capture` is darwin + stub; do not expect Windows capture.
2. **Screen Recording permission is required** by the OS for listing windows/displays.
   - **Ad-hoc signing** (`codesign -s -`) changes the CDHash every rebuild → macOS treats it as a new app → you must re-authorize. This is painful and expected.
   - **Fix once:** `./scripts/setup-dev-codesign.sh` then `wails3 package`. Packaging prefers that stable identity (or an Xcode **Apple Development** cert). Authorize Screen Recording once for `bin/video-editor-wails.app`.
   - Closing the window does **not** quit (tray keeps the process). After toggling permission, use **Relaunch** / Quit from the tray, then reopen.
   - Prefer testing the packaged `.app`, not a bare binary.
3. **Never block `ListSources` on per-window screenshots** — sync `SCScreenshotManager` + semaphore on the binding thread hung/emptied the window list. List titles first; load thumbs via `GetSourceThumbnail` asynchronously (see `App.tsx`).
4. **Pause** skips writing samples but compresses the output timeline (no freeze-frames). Elapsed time excludes paused wall time.
5. **Tray keeps the process alive** — `ApplicationShouldTerminateAfterLastWindowClosed: false`; Quit from tray menu. The red close button **hides** the window (`WindowClosing` hook + `Cancel`); do not destroy it or tray **Show Window** cannot bring it back.
6. **Export** needs `ffmpeg`/`ffprobe` on PATH (GUI apps may have a thinner PATH than Terminal).

## Product behaviour to preserve

- Source picker: screens + windows, System audio / Microphone toggles, **microphone input device select**, Record
- Recording: elapsed clock, Pause / Resume / Stop; tray label `● m:ss` / `⏸ m:ss`
- Editor: preview, timeline split/delete, New recording, Export MP4 (native save dialog)
- When recording a display, exclude this app’s windows (`excludePID = os.Getpid()`)
- System audio + mic are **separate MP4 audio tracks** (do not mux both into one `AVAssetWriterInput`)
- Mic capture uses `SCStreamConfiguration.microphoneCaptureDeviceID`; request Microphone TCC before start

## Git

- Author for this repo (local): use shell alias `usegmail` → `uniquejava` / `uniquejava@gmail.com` when the user asks to commit that way
- Ignore: `bin/`, `.task/`, `frontend/node_modules/`, `frontend/dist/`, `*.mp4`
- Do not commit unless the user asks

## Prefer

- Small, focused diffs; match existing style
- Wails v3 Service + `application.RegisterEvent` / `Events.On` patterns already in the repo
- Keep privacy usage strings in both `Info.plist` and `Info.dev.plist`
