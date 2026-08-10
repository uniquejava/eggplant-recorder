# 02 · 用 Wails v3 搭脚手架

← [01 环境](./01-setup.md) · [目录](./README.md) · [下一篇：macOS 权限 →](./03-macos-permissions.md)

## 目标

从空目录生成 **React + TypeScript** 的 Wails v3 工程，并认识默认结构。

## 创建项目

在空目录（或上级目录）执行：

```bash
wails3 init \
  -n "Video Editor Wails" \
  -t react \
  -mod github.com/cyper/video-editor-wails \
  -d . \
  -productname "Video Editor Wails" \
  -productidentifier com.cyper.videoeditorwails
```

说明：

| 参数 | 作用 |
|------|------|
| `-t react` | React + TypeScript + Vite（v3 里 TS 是默认变体） |
| `-mod` | Go module path |
| `-productidentifier` | Bundle ID，后面权限与签名都靠它 |

若 CLI 在子目录里生成了 `Video_Editor_Wails/`，把文件挪到仓库根即可。

## 默认长什么样

```
.
├── main.go              # application.New + Window
├── greetservice.go      # 示例 Service（本仓库已换成 RecorderService）
├── Taskfile.yml         # wails3 task / build / package
├── build/
│   ├── config.yml       # 产品信息、dev_mode
│   └── darwin/          # Info.plist、图标、darwin 任务
├── frontend/
│   ├── src/App.tsx
│   ├── package.json
│   └── bindings/        # `wails3 generate bindings` 生成
└── go.mod
```

## v3 和 v2 的直觉差异

- **Service**：用 `application.NewService(&YourStruct{})` 挂到 `Options.Services`
- **事件**：`application.RegisterEvent[T]("name")` + `app.Event.Emit(...)`
- **绑定**：`wails3 generate bindings -ts -i`，前端从 `frontend/bindings/...` import
- **构建**：Taskfile 驱动，`wails3 build` / `wails3 package` / `wails3 task dev`

## 先跑通 Hello

```bash
cd frontend && npm install && cd ..
wails3 task dev
```

能看到默认问候页，说明 WebView ↔ Go 通道正常。下一篇会改掉示例 Service，换成录屏。

## `.gitignore` 建议

至少忽略：

```gitignore
.task/
bin/
frontend/dist/
frontend/node_modules/
.DS_Store
```

不要把打包产物 `bin/*.app` 和 `node_modules` 提交进库。生成的 `frontend/bindings/` **建议提交**，方便克隆后直接看类型；本地 `wails3 build` 仍会重新生成。

下一篇：[Info.plist 与隐私权限 →](./03-macos-permissions.md)
