# 05 · RecorderService、事件与媒体中间件

← [04 ScreenCaptureKit](./04-screencapturekit.md) · [目录](./README.md) · [下一篇：前端 UI →](./06-frontend-ui.md)

## 目标

把 `internal/capture` 包装成前端可调用的 Wails v3 Service，并让录好的 MP4 能在 WebView 里用 `<video>` 播放。

## 注册 Service（`main.go`）

```go
recorder := NewRecorderService()

app := application.New(application.Options{
    Name: "Video Editor Wails",
    Services: []application.Service{
        application.NewService(recorder),
    },
    Assets: application.AssetOptions{
        Handler:    application.AssetFileServerFS(assets),
        Middleware: mediaMiddleware(recorder.MediaDir()),
    },
    // ...
})
```

导出方法会被绑定生成器扫到，例如：

- `RequestScreenAccess`
- `ListSources`
- `StartRecording` / `StopRecording` / `IsRecording`
- `GetClips` / `SetClips`
- `ExportVideo`

## 强类型事件

```go
func init() {
    application.RegisterEvent[RecordingFinishedEvent]("recording:finished")
    application.RegisterEvent[RecordingFailedEvent]("recording:failed")
}
```

录制结束或失败时：

```go
app.Event.Emit("recording:finished", ev)
```

前端：

```ts
Events.On('recording:finished', (ev) => { /* ev.data */ })
```

## 临时媒体目录

录制文件写到：

```text
$TMPDIR/video-editor-wails/rec-<nanosecond>.mp4
```

前端不能直接读任意磁盘路径，因此加 **Asset Middleware**：请求 `/media/<filename>` 时从该目录 `ServeFile`。

`StopRecording` 返回的 `mediaUrl` 形如 `/media/rec-….mp4`，正好给 `<video src={mediaURL}>`。

## 生成绑定

```bash
mkdir -p frontend/dist && echo '<!doctype html><title>ok</title>' > frontend/dist/index.html
wails3 generate bindings -ts -i ./...
```

（`//go:embed frontend/dist` 需要目录存在；正式构建时 Task 会先编前端。）

前端引用：

```ts
import { RecorderService } from '../bindings/github.com/cyper/video-editor-wails'
import type { Source } from '../bindings/github.com/cyper/video-editor-wails/internal/capture/models'
```

## `StartRecording` 流程

1. 校验 `sourceId`  
2. 生成输出路径  
3. `capture.Start(..., excludePID=os.Getpid())`  
4. 失败则 Emit `recording:failed`  

`StopRecording` 用 `ffprobe` 探时长，初始化一条覆盖全片的 clip，再 Emit `recording:finished`。

下一篇：[React 三态界面 →](./06-frontend-ui.md)
