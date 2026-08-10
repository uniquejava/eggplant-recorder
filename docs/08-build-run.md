# 08 · 构建、打包与排错

← [07 导出](./07-export-timeline.md) · [目录](./README.md)

## 日常开发

```bash
wails3 task dev
```

等价于按 `build/config.yml` 的 `dev_mode`：编后端、起 Vite、跑 `.dev.app`。

## 生产构建

```bash
wails3 build          # 产出 bin/video-editor-wails
wails3 package        # 产出 bin/video-editor-wails.app（adhoc 签名）
open bin/video-editor-wails.app
```

## Git 提交前注意

确认 `.gitignore` 覆盖：

- `bin/`、`.task/`
- `frontend/node_modules/`、`frontend/dist/`
- 本地录制的 `*.mp4`、`.DS_Store`

应提交：源码、`go.mod`/`go.sum`、`frontend/src`、`frontend/bindings`、`docs/`、`build/darwin/Info*.plist` 等。

## 常见问题

### 1. ListSources 失败 / 空列表

- 隐私设置里未勾选本应用的屏幕录制  
- 跑的是裸二进制而不是带 Bundle ID 的 `.app`  
- 改完签名后权限条目失效，重新打开开关  

### 2. 能录但成片没有系统声音

- 确认勾了 System audio  
- 检查系统是否授权音频捕获  
- macOS 版本是否 ≥ 15（本项目假设 15+）  

### 3. Export 报 ffmpeg 找不到

```bash
which ffmpeg ffprobe
brew install ffmpeg
```

GUI 应用的 `PATH` 可能比终端短；若仅 Terminal 能找到 ffmpeg，可在 Service 里写绝对路径，或用 `launchctl`/`LSEnvironment` 注入 PATH。

### 4. 链接警告 macosx-version-min

确保 `build/darwin/Taskfile.yml` 里 `MACOSX_DEPLOYMENT_TARGET=15.0`，与 `#cgo CFLAGS` 一致。

### 5. 双击 .app 没反应

检查 `CFBundleExecutable` 是否等于 `Contents/MacOS/` 下的文件名（本仓库为 `video-editor-wails`）。

## 建议的迭代顺序（回顾）

1. 脚手架跑通 Greet  
2. plist + 权限  
3. `ListSources` 打到前端网格  
4. `Start`/`Stop` 写出 MP4 并能 `/media/` 播放  
5. 时间线 Split/Delete  
6. Save 对话框 + ffmpeg 导出  

回到 [目录](./README.md)。
