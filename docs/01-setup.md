# 01 · 环境与工具链

← [目录](./README.md) · [下一篇：脚手架 →](./02-scaffold.md)

## 目标

装好能编译 **Wails v3 + CGo + ScreenCaptureKit** 的 macOS 开发环境。本项目要求 **macOS 15 Sequoia+**。

## 必备软件

1. **Xcode Command Line Tools**（提供 clang、SDK、ScreenCaptureKit 头文件）

   ```bash
   xcode-select --install
   ```

2. **Go 1.25+**

   ```bash
   go version
   ```

3. **Node.js + npm**（前端 Vite / React）

   ```bash
   node -v && npm -v
   ```

4. **Wails v3 CLI**（本仓库用 `v3.0.0-beta.6`）

   ```bash
   go install github.com/wailsapp/wails/v3/cmd/wails3@v3.0.0-beta.6
   wails3 version
   ```

5. **ffmpeg / ffprobe**（剪辑导出时裁切与拼接）

   ```bash
   brew install ffmpeg
   ffmpeg -version
   ```

## 可选但有用

```bash
wails3 doctor          # 检查本机依赖
wails3 setup           # 交互式环境向导
```

若在国内网络拉 GitHub / npm 较慢，可为终端配置 HTTP 代理后再执行 `go install` / `npm install`。

## 权限预习

录屏不是“装好就能录”。运行后系统会要求：

- **屏幕录制**（Screen Recording）— 必开
- **麦克风** — 仅当你勾选 Microphone
- **系统音频 / 音频捕获** — 勾选 System audio 时需要（macOS 15 起由 ScreenCaptureKit 原生支持）

权限文案写在 `Info.plist` 里，见 [03-macos-permissions.md](./03-macos-permissions.md)。

## 检查清单

- [ ] `sw_vers` 显示 15.x 或更高
- [ ] `wails3 version` 为 v3 beta
- [ ] `clang` / `ffmpeg` / `ffprobe` 在 `PATH` 中

下一篇：[用 wails3 生成项目 →](./02-scaffold.md)
