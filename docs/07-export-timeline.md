# 07 · 时间线与 Export MP4

← [06 前端](./06-frontend-ui.md) · [目录](./README.md) · [下一篇：构建运行 →](./08-build-run.md)

## 目标

在浏览器端维护 clip 列表，导出时用系统「存储」对话框选路径，再交给本机 `ffmpeg` 裁切拼接。

## Clip 模型

```go
type Clip struct {
    ID        string  `json:"id"`
    Start     float64 `json:"start"`
    End       float64 `json:"end"`
    SourceURL string  `json:"sourceUrl"`
}
```

录制结束时默认一条 `[0, duration]`。Split 在 playhead 处拆成两段；Delete 至少保留一段。

前端改完调用 `RecorderService.SetClips(clips)`，保证导出读到最新时间线。

## 保存对话框（Wails v3）

```go
dialog := app.Dialog.SaveFileWithOptions(&application.SaveFileDialogOptions{
    Title:                "Export MP4",
    CanCreateDirectories: true,
    Filename:             "export.mp4",
    Filters: []application.FileFilter{
        {DisplayName: "MP4 Video", Pattern: "*.mp4"},
    },
})
dest, err := dialog.PromptForSingleSelection()
```

用户取消时返回空字符串，前端当作「什么都不做」。

## ffmpeg 策略

`exportClips`：

1. 每个 clip：`ffmpeg -ss <start> -to <end> -i source -c copy part-N.mp4`  
2. copy 失败则回退重编码：`libx264` + `aac`  
3. 写 `list.txt`，`ffmpeg -f concat -safe 0 -i list.txt -c copy dest`  
4. 若只有一段且几乎等于整片，直接文件拷贝  

时长探测：

```bash
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 file.mp4
```

## 限制（诚实版）

- 时间线是「逻辑片段」，不是专业 NLE；没有转场、多轨、特效  
- `-c copy` 在非关键帧处可能略不准，故有重编码回退  
- 系统音频 + 麦克风目前写入同一条 audio input，进阶混音可后续用 `AVAudioEngine` / 分轨再混  

下一篇：[构建、打包与排错 →](./08-build-run.md)
