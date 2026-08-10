# 04 · ScreenCaptureKit：CGo + Objective-C

← [03 权限](./03-macos-permissions.md) · [目录](./README.md) · [下一篇：RecorderService →](./05-recorder-service.md)

## 目标

在 Go 里列出显示器/窗口，并开始/停止录制，写出 H.264 MP4。视频里 Better Stack 的做法是：**没有现成 Go crate 时，用 CGo 写约数百行 Objective-C 直接调苹果 API**。本仓库同路线。

## 文件布局

```
internal/capture/
├── capture_darwin.h    # 纯 C API，给 Go 和 .m 共用
├── capture_darwin.m    # ScreenCaptureKit + AVAssetWriter
├── capture_darwin.go   # //go:build darwin + cgo
└── capture_stub.go     # //go:build !darwin
```

为什么先暴露 C API？CGo 最稳的契约是 **C 类型**；ObjC 对象留在 `.m` 里，Go 只看到 `char*` / `int` / `bool`。

## Go 侧（`capture_darwin.go`）

```go
/*
#cgo CFLAGS: -x objective-c -fobjc-arc -mmacosx-version-min=15.0
#cgo LDFLAGS: -framework Foundation -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo \
  -framework ScreenCaptureKit -framework AppKit -framework CoreGraphics
#include <stdlib.h>
#include "capture_darwin.h"
*/
import "C"
```

对外方法：

| 方法 | 作用 |
|------|------|
| `ListSources()` | 显示器 + 窗口列表（含可选缩略图 base64） |
| `RequestAccess()` | 触发一次 shareable content 请求，弹出权限 |
| `Start(...)` | 按 source id/kind 开录，写入 `outputPath` |
| `Stop()` | 停流、finalize writer，返回路径 |
| `IsRecording()` | 是否在录 |

`excludePID` 传 `os.Getpid()`，录整屏时排除本应用窗口（演示里“应用本身不会进成片”）。

## ObjC 侧核心思路（`capture_darwin.m`）

1. **`SCShareableContent`** — 拿 displays / windows  
2. **`SCContentFilter`** — `initWithDisplay:excludingWindows:` 或 `initWithDesktopIndependentWindow:`  
3. **`SCStreamConfiguration`** — 分辨率、30fps、BGRA、`capturesAudio`、macOS 15 的 `captureMicrophone`  
4. **`SCStream`** — `addStreamOutput`（Screen / Audio / Microphone）  
5. **`AVAssetWriter` + PixelBufferAdaptor** — 把 sample 写成 MP4  

注意点：

- H.264 宽高必须为偶数  
- 用第一帧屏幕 sample 的 PTS 做时间原点，`startSessionAtSourceTime:kCMTimeZero`  
- `stopCapture` 后要在 writer queue 上 `markAsFinished`，再 `finishWriting`  
- 缩略图可用 `SCScreenshotManager`（macOS 14+）；失败时前端用占位图即可  

## 非 macOS 桩

`capture_stub.go` 在 `!darwin` 上返回明确错误，避免误编译进 Linux CI 时拖进 ObjC。

## 本地验证

```bash
go build ./internal/capture/
```

通过后再接 Service。完整应用还需在 `.app` 里跑才能拿到屏幕权限。

下一篇：[把捕获封成 Wails Service →](./05-recorder-service.md)
