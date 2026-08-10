# 03 · macOS 15、Info.plist 与权限

← [02 脚手架](./02-scaffold.md) · [目录](./README.md) · [下一篇：ScreenCaptureKit →](./04-screencapturekit.md)

## 目标

让应用声明「我是 macOS 15+ 录屏工具」，并在首次访问敏感 API 时弹出正确的系统提示。

## 最低系统版本

编辑：

- `build/darwin/Info.plist`（正式包）
- `build/darwin/Info.dev.plist`（`wails3 task run` / dev 包）

```xml
<key>LSMinimumSystemVersion</key>
<string>15.0.0</string>
```

同时把 darwin 编译部署目标抬到 15（见 `build/darwin/Taskfile.yml`）：

```yaml
CGO_CFLAGS: "-mmacosx-version-min=15.0"
CGO_LDFLAGS: "-mmacosx-version-min=15.0"
MACOSX_DEPLOYMENT_TARGET: "15.0"
```

否则会出现「.m 按 15.0 编译、链接却按 12.0」的警告。

## 隐私用途说明（必写）

没有这些 key，系统可能直接拒绝或静默失败：

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>…需要屏幕录制权限以捕获显示器与窗口。</string>

<key>NSMicrophoneUsageDescription</key>
<string>…在启用麦克风录制时需要麦克风权限。</string>

<key>NSAudioCaptureUsageDescription</key>
<string>…在启用系统音频时需要音频捕获权限。</string>
```

## Bundle 可执行文件名

`CFBundleExecutable` 必须与 `bin/` 里二进制文件名一致。本仓库 Task 的 `APP_NAME` 是 `video-editor-wails`，因此：

```xml
<key>CFBundleExecutable</key>
<string>video-editor-wails</string>
```

名字对不上时，双击 `.app` 会打不开。

## `build/config.yml`

同步产品元数据（名称、identifier、版本），避免打包资产和 plist 各写各的：

```yaml
info:
  companyName: "Cyper"
  productName: "Video Editor Wails"
  productIdentifier: "com.cyper.videoeditorwails"
  version: "0.1.0"
```

改完 `info` 后，如需刷新生成资产，可按 Wails 文档运行 `wails3 task common:update:build-assets`（注意会覆盖你手改过的资产）。

## 开发时如何授权

1. 用 **`.app` 包**跑（`wails3 package` 或 `task run` 生成的 `*.dev.app`），不要只跑裸二进制——权限是按 Bundle ID 记的。
2. 系统设置 → 隐私与安全性 → 屏幕录制 → 勾选本应用。
3. 改过代码重新签名后，有时要关掉再打开权限开关。

下一篇：[用 CGo 接 ScreenCaptureKit →](./04-screencapturekit.md)
