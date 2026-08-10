# From Zero: Build a macOS Screen Recorder with Wails v3

这组文档按真实搭建顺序，把本仓库从空目录做到可录屏、可剪辑、可导出 MP4 的过程写清楚。目标平台：**macOS 15+**，框架：**Wails v3**。

灵感来自 [Better Stack 的 Wails 演示](https://www.youtube.com/watch?v=Q1TL2AKoy00)（选源 → 录制 → 预览剪辑 → Export MP4）。

## 你将得到什么

- Go 后端 + React/TypeScript 前端的桌面应用
- 通过 **CGo + Objective-C** 调用 **ScreenCaptureKit**
- 系统音频 / 麦克风开关、排除本应用窗口
- 简单时间线（Split / Delete）+ `ffmpeg` 导出

## 阅读顺序

| # | 文档 | 内容 |
|---|------|------|
| 1 | [01-setup.md](./01-setup.md) | 环境与工具链 |
| 2 | [02-scaffold.md](./02-scaffold.md) | `wails3 init` 脚手架 |
| 3 | [03-macos-permissions.md](./03-macos-permissions.md) | Info.plist、权限、最低系统版本 |
| 4 | [04-screencapturekit.md](./04-screencapturekit.md) | ScreenCaptureKit CGo 桥 |
| 5 | [05-recorder-service.md](./05-recorder-service.md) | Go Service、事件、媒体中间件 |
| 6 | [06-frontend-ui.md](./06-frontend-ui.md) | 三态 UI：选源 / 录制中 / 剪辑 |
| 7 | [07-export-timeline.md](./07-export-timeline.md) | 时间线与导出 |
| 8 | [08-build-run.md](./08-build-run.md) | 开发、打包、排错 |

## 仓库地图（对照代码）

```
video-editor-wails/
├── main.go                 # 应用入口、窗口、中间件
├── recorderservice.go      # 前端可调用的录屏服务
├── internal/capture/       # ObjC ScreenCaptureKit 桥
├── frontend/               # React + Vite UI
├── build/darwin/           # Info.plist / 打包任务
└── docs/                   # 本教程
```

下一篇：[环境与工具链 →](./01-setup.md)
