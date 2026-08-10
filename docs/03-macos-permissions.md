# 03 · macOS 权限、TCC 与代码签名

← [02 脚手架](./02-scaffold.md) · [目录](./README.md) · [下一篇：ScreenCaptureKit →](./04-screencapturekit.md)

## 目标

让应用能稳定拿到 **屏幕录制**（以及可选的麦克风 / 系统音频）权限，并理解为什么「每编译一次就要重新授权」——以及怎么避免。

本页覆盖：

- `Info.plist` 隐私声明与最低系统版本
- macOS **TCC**（Transparency, Consent, and Control）如何记住授权
- **adhoc vs Apple Development** 签名对权限的影响
- 重置权限、查签名、稳定签名的命令
- 授权后仍无窗口列表时的处理（进程未真正退出）

---

## Bundle ID 与本仓库常量

| 项 | 值 |
|----|-----|
| Bundle ID | `com.cyper.videoeditorwails` |
| 产品名 | Video Editor Wails |
| 正式包 | `bin/video-editor-wails.app` |
| 开发包 | `bin/video-editor-wails.dev.app`（`wails3 task run` / dev） |

TCC 重置、隐私列表里的条目，都按 **Bundle ID**（再叠加上代码签名身份）识别应用。

---

## Info.plist：最低版本与隐私文案

编辑：

- `build/darwin/Info.plist`（正式包）
- `build/darwin/Info.dev.plist`（dev 包）

```xml
<key>LSMinimumSystemVersion</key>
<string>15.0.0</string>

<key>NSScreenCaptureUsageDescription</key>
<string>Video Editor Wails needs screen recording access to capture your display and windows.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Video Editor Wails needs microphone access when you enable mic recording.</string>

<key>NSAudioCaptureUsageDescription</key>
<string>Video Editor Wails needs system audio capture permission to record computer sound.</string>
```

同时保证 `build/darwin/Taskfile.yml` 里：

```yaml
CGO_CFLAGS: "-mmacosx-version-min=15.0"
CGO_LDFLAGS: "-mmacosx-version-min=15.0"
MACOSX_DEPLOYMENT_TARGET: "15.0"
```

`CFBundleExecutable` 必须等于 `Contents/MacOS/` 下的二进制名（本仓库为 `video-editor-wails`）。

`build/config.yml` 的 `productIdentifier` 应与 Bundle ID 一致：`com.cyper.videoeditorwails`。

---

## TCC 在干什么

macOS 用 **TCC** 记住「哪个 App 可以录屏 / 用麦」。对屏幕录制：

1. 应用出现在 **系统设置 → 隐私与安全性 → 屏幕录制** 里（首次请求后，或你用 **+** / Finder 手动添加）。
2. 勾选后，**只有新启动的进程**会拿到权限；正在跑的旧进程通常仍然看不到窗口列表。
3. 识别应用不只看 Bundle ID，还看 **代码签名**（Team ID / 证书，或 adhoc 的 CDHash）。

因此会出现这些坑：

| 现象 | 常见原因 |
|------|----------|
| 每次 `package` 后都要重新授权 | 用了 **adhoc** 签名，CDHash 每次都变，系统当成新 App |
| 设置里勾着，但列表仍空 | 关窗口没退出（托盘还在）；或签名变了、勾的是旧身份 |
| 一打开就弹出系统设置 | 未授权时调用了 `SCShareableContent` / `CGRequestScreenCaptureAccess`（本仓库已避免启动时自动请求） |
| `*.app` 和 `*.dev.app` 各要授一次 | 路径不同，TCC 里可能是两条 |

**应用不会预先出现在隐私列表里**——要么它第一次请求权限，要么你在设置里用 **+** 选 `.app`。

---

## 签名：adhoc 为什么痛苦，怎么一劳永逸

### 打包时实际用的签名

`wails3 package` / `task run` 会走 `scripts/sign-app.sh`：

1. 若有有效的 **`Apple Development: …`** 或本地 **`Video Editor Wails Dev`** → 用稳定身份签名  
2. 否则 → **adhoc**（`codesign --sign -`），并打印警告

查看当前 `.app` 签名：

```bash
codesign -dv --verbose=2 bin/video-editor-wails.app 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|CDHash'
```

期望（稳定开发签名）类似：

```text
Identifier=com.cyper.videoeditorwails
Authority=Apple Development: … (…)
TeamIdentifier=XXXXXXXXXX
```

若看到 `Signature=adhoc` / `TeamIdentifier=not set`，重建后屏幕录制授权很容易丢。

### 推荐：续期 / 创建 Apple Development（免费 Apple ID）

本机查可用签名身份：

```bash
security find-identity -v -p codesigning
```

若显示 `CERT_EXPIRED` 或没有任何 valid identity：

1. 打开 **Xcode → Settings… → Accounts**
2. 选中 Apple ID → **Manage Certificates…**
3. **+** → **Apple Development**
4. 再确认：

```bash
security find-identity -v -p codesigning
# 应出现：1 valid identities found … "Apple Development: …"
```

然后重新打包：

```bash
wails3 package
codesign -dv --verbose=2 bin/video-editor-wails.app 2>&1 | grep -E 'Authority|TeamIdentifier|Signature'
```

之后用**同一证书**打包，一般只需给 `bin/video-editor-wails.app` **授权一次**。

也可强制指定身份：

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" wails3 package
# 或只签已有包：
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/sign-app.sh bin/video-editor-wails.app
```

### 可选：本地自签证书

```bash
./scripts/setup-dev-codesign.sh
```

若已有过期的 Apple Development，脚本会提示你去 Xcode 续期（优先）。若导入了本地 `Video Editor Wails Dev`，还需在 **钥匙串访问** 里把该证书的 **代码签名** 信任设为允许，直到：

```bash
security find-identity -v -p codesigning
# 能在 Valid identities 里看到 "Video Editor Wails Dev"
```

---

## 首次授权正确流程

1. 打带稳定签名的包并打开：

```bash
wails3 package
# 确认不是 adhoc 后再开
open bin/video-editor-wails.app
```

2. 应用内点 **Grant access** / **Open Settings**，或手动：  
   **系统设置 → 隐私与安全性 → 屏幕录制** → 勾选 **Video Editor Wails**  
   （列表没有时：点 **+**，用 Finder 选到 `bin/video-editor-wails.app`。）

3. **必须真正退出再开**：本应用关窗口不会退出（菜单栏托盘还在）。用应用内 **Relaunch**，或托盘 **Quit** 后再 `open`。

4. 屏幕 / 窗口列表应出现；此后同一签名重建通常不用再授。

探针（仅当该二进制身份已有权限时才有意义；裸 `go run` 身份不同）：

```bash
go run ./scripts/check-screen-access
```

---

## 重置权限（TCC）

勾着却无效、或签名刚从 adhoc 换成 Apple Development、或一打开就弹设置且开关动不了时，先重置本 Bundle 的屏幕录制条目：

```bash
# 只清本应用的屏幕录制（ScreenCapture）授权
tccutil reset ScreenCapture com.cyper.videoeditorwails
```

然后：

```bash
# 确保旧进程死透（关窗口不够）
pkill -f 'video-editor-wails.app/Contents/MacOS/video-editor-wails' || true
pkill -f 'video-editor-wails.dev.app/Contents/MacOS/video-editor-wails' || true

open bin/video-editor-wails.app
```

再走一遍「勾选 → Relaunch」。

说明：

- `tccutil reset ScreenCapture` **不带 Bundle ID** 会清掉本机所有 App 的屏幕录制授权，一般别用。
- 麦克风等其它服务是另一类 TCC（例如 `Microphone`），与屏幕录制分开。
- 重置后隐私列表里可能暂时看不到本 App，属正常；重新请求或手动 **+** 添加即可。

---

## 常用命令速查

```bash
# —— 签名身份 ——
security find-identity -v -p codesigning
./scripts/setup-dev-codesign.sh          # 引导续期 Apple Development / 可选本地证

# —— 打包与签名 ——
wails3 package
./scripts/sign-app.sh bin/video-editor-wails.app
CODESIGN_IDENTITY="Apple Development: …" ./scripts/sign-app.sh bin/video-editor-wails.app

codesign -dv --verbose=2 bin/video-editor-wails.app 2>&1
codesign -dv --verbose=2 bin/video-editor-wails.app 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|CDHash'

# —— TCC 重置 ——
tccutil reset ScreenCapture com.cyper.videoeditorwails

# —— 进程 ——
pkill -f 'video-editor-wails.app/Contents/MacOS/video-editor-wails' || true
open bin/video-editor-wails.app

# —— 权限探针（身份需已授权）——
go run ./scripts/check-screen-access
```

相关脚本：

| 路径 | 作用 |
|------|------|
| `scripts/sign-app.sh` | 优先稳定身份，否则 adhoc 并警告 |
| `scripts/setup-dev-codesign.sh` | 检查/引导 Apple Development；可选创建本地证 |
| `scripts/check-screen-access/main.go` | 打印 `HasScreenAccess` + `ListSources` 数量 |

代码侧：

| API | 行为 |
|-----|------|
| `HasScreenAccess` | `CGPreflightScreenCaptureAccess`，无 UI |
| `RequestScreenAccess` | 未授权时才 `CGRequestScreenCaptureAccess`（可能打开设置） |
| `OpenScreenCaptureSettings` | 打开「屏幕录制」隐私页 |
| `Relaunch` | `open -n` 同 `.app` 后退出当前进程 |
| 启动时 `ListSources` | **仅在 preflight 已授权时调用**，避免每次打开都弹系统设置 |

---

## 排错对照

### 空列表 / Record 灰掉

1. 是否在跑 **`.app`**（不要只跑裸 `bin/video-editor-wails`）。  
2. 隐私里是否勾了**当前这个** `.app`（dev 与正式可能是两条）。  
3. 签名是否为 Apple Development（非 adhoc）。  
4. 授权后是否 **Relaunch / 托盘 Quit**。  
5. 仍不行：`tccutil reset ScreenCapture com.cyper.videoeditorwails` 后重授。

### 勾选已开，开关「没法设置」

多为 TCC 与当前签名不同步：重置该 Bundle 的 ScreenCapture，Quit 干净，再打开后重新勾选（可先关再开一次开关）。

### 每次编译都要授权

当前在用 adhoc。按上文续好 Apple Development 后再 `wails3 package`，确认 `Authority=Apple Development`。

### 一启动就弹出系统设置

旧版本在未授权时也会 `ListSources`，系统会强行打开隐私页。当前逻辑：未授权只显示应用内说明，由用户点 **Grant access**。若仍弹，确认跑的是新打包的 `.app`，并清掉旧托盘进程。

---

下一篇：[用 CGo 接 ScreenCaptureKit →](./04-screencapturekit.md)
