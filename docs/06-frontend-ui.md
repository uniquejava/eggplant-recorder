# 06 · 前端：选源 / 录制中 / 剪辑

← [05 Service](./05-recorder-service.md) · [目录](./README.md) · [下一篇：导出 →](./07-export-timeline.md)

## 目标

复刻演示应用的三态深色 UI，而不是默认的 Wails 模板首页。

## 状态机

```text
select  --Record-->  recording  --Stop-->  editor
  ^                                         |
  +------------- New recording -------------+
```

对应 `frontend/src/App.tsx` 里的 `View = 'select' | 'recording' | 'editor'`。

## 选源页（select）

- 标题：**Record your screen**
- 副文案：Pick a screen or window…
- 网格卡片：`SCREEN` / `WINDOW` + 名称；有 `thumbnail` 则显示 `data:image/png;base64,…`
- 底栏：System audio / Microphone 勾选 + 红色 **Record**

进入页面时：

```ts
await RecorderService.RequestScreenAccess()
const list = await RecorderService.ListSources()
```

## 录制中（recording）

居中红点动画 + **Stop recording**，提示也可从菜单栏停止（系统录屏指示器）。真正停止走：

```ts
await RecorderService.StopRecording()
```

同时监听 `recording:finished` / `recording:failed`，避免只依赖单次 Promise。

## 剪辑页（editor）

- 上方 `<video src={mediaURL}>` 预览  
- 蓝色时间线条带表示 clip；点击定位 playhead  
- **Play / Split / Delete clip**  
- **New recording / Export MP4**  
- 快捷键：Space 播放、`S` 分割、Backspace 删除  

样式在 `frontend/public/style.css`：深灰背景、蓝色选中框、红色录制按钮，贴近演示观感。

## 去掉模板噪音

- `index.html` 去掉全屏背景图层，只留 `#root`  
- 标题改为 `EggplantRecorder`  
- 删除示例 `GreetService` 相关代码  

## 开发热重载

```bash
wails3 task dev
```

改 Go / `.m` 会触发重建；改前端由 Vite 热更新。`build/config.yml` 的 `dev_mode.ignore` 已排除 `frontend/`，避免和 Vite 抢监听。

下一篇：[时间线与 Export MP4 →](./07-export-timeline.md)
