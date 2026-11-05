# 知了 Android 版技术方案

状态：M1、M2 的代码已写完（2026-11-03），引擎在 Mac 上测过，界面在 Android 16 和 Android 10 的模拟器里按主流程测过。代码和命令见 [android/README.md](../android/README.md)。先做“听”，“说”不做。

## 能做什么、不能做什么

Android 10 起可以采集其他 app 播放的声音（`AudioPlaybackCapture`），但只采集愿意被采集的 app：视频、直播、播客、浏览器里的网页大多可以；**通话和会议 app（微信通话、腾讯会议、Zoom、Teams）系统不让采集**，同传也送不进通话。所以 Android 版的“听”有两个来源：

| 来源 | 用在哪 | 系统要求 |
|---|---|---|
| 手机里播放的声音 | 外语视频、直播、网课 | 每次开始都要用户在系统对话框里点“开始”（录屏授权，只录声音） |
| 麦克风（面对面） | 线下会议、对面有人说外语、会议 app 开外放 | 麦克风权限 |

第一版要有：

- 常驻通知（对应 Mac 的菜单栏面板 / Windows 的托盘）：正在听、时长，“结束”按钮
- 悬浮窗：实时纪要卡片（默认）、深色字幕条，或收起成小圆点（拖到 × 关掉）；浮在其他 app 上、不抢焦点、默认不出现在截图和录屏里
- 界面按 claude.ai 上的设计画布「知了 Android 重新设计」实现；文案用 Gemini（`google/gemini-4-argon`）审过，与 Mac 共用的文案沿用 Mac 的译法
- 会议记录：列表、双语全文、纪要、分享 Markdown、重命名、删除
- 设置和引导：Ling key → 声音来源（试听）→ 示例会议

面对面里的“我说”：按住说话，松开后 Ming 译成对方的语言，用系统的文字转语音读出来；读的时候不把手机自己的声音当成对方的话。说进别的 app 的通话做不到（Android 没有虚拟麦克风），不做。

第一版不做：说话人识别、离线识别、录音文件。

最低系统 Android 10（API 29），目标 API 36。

## 关键决策

| 决策 | 选择 | 原因 |
|---|---|---|
| 代码放哪 | 同仓库 `android/` | 和 Windows 一样：提示词、记录格式、文案要跟 Mac 对照修改 |
| 技术栈 | Kotlin + Android 框架自带的 View，代码写界面；不用 AndroidX、Compose、协程库 | 对应 Mac / Windows 的“不用第三方依赖”。只用 Kotlin 标准库、`java.*` 和 `android.*` |
| 构建 | Gradle + Android Gradle Plugin，工具链由 `scripts/install-sdk.sh` 装到 `~/.cicada-android`（JDK、Gradle、SDK、模拟器），不用 Android Studio | 和 Windows 的 `install-dotnet.sh` 一样，不用 sudo，命令行就能编译和测试 |
| 引擎放哪 | `android/core` 是纯 JVM 的 Kotlin 库，不依赖 Android | 在 Mac 上直接跑单元测试和真实调用（`cli`），像 `Cicada.Core` |
| JSON | 自己写的小解析器和写出器（`Json.kt`） | `org.json` 只在 Android 上有、不排序 key；自己写才能和 Mac 的 `session.json` 逐字节一致 |
| 语音识别 | Ming 分段识别，同 Windows | 同一个 Ling key；M0 已在 Windows 方案里测过延迟和准确率 |
| key | `filesDir/ling-api-key`（只有本 app 能读），内容用 Android Keystore 的 AES-GCM 加密，`keystore:` 开头 | 对应 Mac 的 0600 文件、Windows 的 DPAPI |
| 应用标识 | `com.wquguru.cicada`，开发版 `com.wquguru.cicada.dev` | 和 Mac 一致；开发版和正式版的记录互不影响 |

和 Windows 一样**不共享代码，只共享规格**：提示词、`session.json` 字段、文案（中文作 key，构建时把 `Resources/*.lproj/Localizable.strings` 拷进 assets，再叠加 `android/app/src/main/strings/*.lproj/Android.strings`）。

## 界面对应

| Mac | Windows | Android |
|---|---|---|
| 菜单栏面板 | 托盘 | 常驻通知 + 主界面顶部的“开始听” |
| 纪要窗 / 字幕条（不抢焦点、`sharingType = .none`） | `WS_EX_NOACTIVATE` + `WDA_EXCLUDEFROMCAPTURE` | `TYPE_APPLICATION_OVERLAY` + `FLAG_NOT_FOCUSABLE` + `FLAG_SECURE`；打开“共享屏幕时让对方看到”后去掉 `FLAG_SECURE`，显示“对方可见” |
| 菜单栏面板 | 托盘 | `MainActivity`（首页：开始听、进行中的会议、最近的会议）+ `ListeningActivity`（正在听：字幕 / 实时纪要） |
| 主窗口（会议记录） | `MainWindow` | `RecordsActivity`（搜索、筛选、按天分组）→ `RecordActivity`（纪要 / 文字记录） |
| 设置、引导 | 同 | `SettingsActivity`、`OnboardingActivity` |
| `tools/lsctl` | 命名管道 + `cicadactl.ps1` | 开发版的广播接收器 + `scripts/cicadactl.sh`（`adb shell am broadcast`，回一行 JSON） |

悬浮窗要“显示在其他应用上层”权限；没给时只在 app 里显示纪要，不影响听。

## 架构

```
MediaProjection → AudioPlaybackCapture（排除知了自己） ┐
麦克风 AudioRecord（VOICE_RECOGNITION）                ├→ 16k 单声道 Int16 → ListenEngine 的队列
文件（示例会议、调试 feed）                             ┘
  → Segmenter（停顿 0.6s 或满 8s）→ Ming 三行 → HeardLine → SessionStore / NotesEngine（45s）
  → ListenService（前台服务，类型 mediaProjection 或 microphone）→ 通知、悬浮窗、主界面
```

| 文件（`android/core/src/main/kotlin/`） | 作用 | 对应 Windows |
|---|---|---|
| `Json.kt` | 解析、按 Swift `JSONEncoder` 的格式写出（`"key" : value`、key 排序、`\/`） | `Json.cs` |
| `Models.kt`、`SessionStore.kt` | 会议记录 | 同名 |
| `Segmenter.kt`、`Audio.kt` | 分段、`AudioSource`、WAV | 同名 |
| `Ling.kt`、`Translator.kt`、`Notes.kt`、`ListenEngine.kt` | 同 Windows，提示词逐字照搬 | 同名 |
| `Strings.kt`、`Support.kt`、`Settings.kt` | 文案、路径和日志、设置 | 同名 |

`android/app` 里：`App.kt`（把引擎接起来）、`ListenService.kt`（前台服务、通知）、`Capture.kt`（两种声音来源）、`Overlay.kt`（悬浮窗的三种样子）、`NotesViews.kt`（字幕流和纪要，正在听和悬浮窗共用）、`MainActivity.kt`、`ListeningActivity.kt`、`RecordsActivity.kt`、`SettingsActivity.kt`、`OnboardingActivity.kt`、`Ui.kt`（调色板、按钮、列表行、分段按钮、标签页）、`KeyStore.kt`、`DebugReceiver.kt`。

线程：引擎在工作线程上发事件，界面用主线程的 `Handler` 合并刷新；音频线程只把数据放进 `ListenEngine` 的队列。

## Android 的坑

- Android 14 起：前台服务必须声明类型（`mediaProjection`、`microphone`）和对应的 `FOREGROUND_SERVICE_*` 权限；**先启动前台服务，再调用 `getMediaProjection()`**；授权结果只能用一次，每次开始听都要重新请求。
- 采集其他 app 的声音也要 `RECORD_AUDIO` 权限；Android 13 起通知要 `POST_NOTIFICATIONS`。
- 采集不到的情况：对方 app 设了 `allowAudioPlaybackCapture=false`、目标 SDK 低于 29（系统默认不让采集），或用的是通话用途（`USAGE_VOICE_COMMUNICATION`）。听了 20 秒还是静音时，界面提示改用“面对面”。
- Android 11 起，“显示在其他应用上层”的设置页不再直接打开某个 app，而是全部 app 的列表：引导里多一句“在列表里点‘知了’”。
- 悬浮窗只在别的 app 在前台时出现；回到知了自己的界面时隐藏（那里本来就有同样的字幕和纪要），听结束时关掉。
- 国内手机厂商会杀后台：前台服务 + 通知是底线，必要时引导用户关掉电池优化（M3）。

## 会议记录

- 位置：`filesDir/Sessions/<yyyyMMdd-HHmmss>/session.json`，字段与 Mac 一致；`hasAudio` 为 false（第一版不录音）
- 写出格式和 Mac 逐字节一致：`cli roundtrip` 把 Mac 上的所有记录读进来再写出去比对
- 分享：系统分享面板发 Markdown 文本，和 Windows 的导出内容一致

## 开发环境和验证

- `scripts/install-sdk.sh`：一次装好工具链和名为 `cicada` 的 arm64 模拟器（Apple 芯片的 Mac 原生运行）
- `scripts/test.sh`：引擎单元测试（无网络）；`scripts/build.sh`：开发版 APK
- `scripts/emulator.sh`：启动模拟器（走本机代理，Google 翻译才能用）；`scripts/install.sh`：装好 APK，授好权限
- `scripts/cicadactl.sh state|start|feed|sample|view|capture|show|stop`：驱动开发版
- 在模拟器里验证：`feed` 示例音频出字幕和纪要；`screencap` 截图里悬浮窗是黑的，打开“共享屏幕时让对方看到”后能看到并显示“对方可见”；用 `tools/player`（测试用的小播放器）或 YouTube Music 预览播放音频，系统声音模式能听到；记录拉回 Mac 用 `cli roundtrip` 检查
- 需要真人和真机：真实系统授权对话框的文案、厂商系统的后台限制、蓝牙耳机、真实会议外放

## 里程碑

| 阶段 | 产出 | 怎样算完成 |
|---|---|---|
| **M1 字幕** | 前台服务、两种声音来源、分段 → Ming、悬浮字幕 | 模拟器里播放的视频声音变成字幕；截图里看不到悬浮窗 |
| **M2 纪要和记录** | 纪要引擎、`session.json`、会议记录、引导、设置、四种界面语言 | Mac 生成的记录 Android 能打开，写出去逐字节一致 |
| **M3 能发布** | 签名的 APK（GitHub Release 下载，校验 SHA-256）、官网入口、电池优化引导、真机测试（至少一台国产手机） | 一台干净的真机从下载到第一次出字幕不用电脑 |
| 以后 | 应用商店、录音、流式识别、说话人识别 | 按反馈排 |

## 风险

1. **能采集的 app 比用户以为的少**：会议 app 一律不行。应对：引导里一句话说清，采集不到声音时提示切到“面对面”。
2. **Ming 的成本和延迟**：同 Windows，识别接口独立，以后可换流式服务。
3. **国内网络**：Google 翻译不可用；第一版没有草稿字幕，只在 Ming 没给译文时用到它，Ling 优先。
4. **厂商后台限制**：长会议中途被杀。应对：前台服务、记录 1.5s 去抖保存，被杀也只丢最后几句。
