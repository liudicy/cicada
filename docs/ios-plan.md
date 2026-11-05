# 知了 iPhone / iPad 版技术方案

状态：设计稿已有（claude.ai 画布“知了 iOS 设计”，9 屏）。M0 已在 Mac 上完成（2026-11-04，worktree `../live-subs-ios-core`、分支 `ios-core`，还没提交）：12 个文件能脱离 Mac app 单独通过类型检查，Mac 的 117 个测试通过，开发版放示例会议的字幕、翻译、纪要、诊断、录音和三种导出都正常，英文界面也看过。M1 也已完成（同一天，Xcode 27.2 / iOS 27.2 模拟器）：共用的 13 个文件用 iOS SDK 编译通过；iPhone 和 iPad 模拟器里能读 Mac 生成的会议记录，列表、文字记录、纪要、搜索、设置都能显示，中文和英文界面都正常，iPad 上是双栏；Mac 的测试在 Xcode 27 的编译器下也通过。

iPhone 和 iPad 拿不到其他 app 的声音，也不能往别的 app 的麦克风里送声音，所以 iOS 版不是 Mac 版的移植，而是“面对面会议 + 导入录音 + 会议记录”的随身版：

- 用麦克风听会议室，实时双语字幕和纪要
- 面对面同声传译：按住说话，从扬声器念出译文
- 导入录音或视频，在本机转成双语记录
- 会议记录：搜索、双语全文、纪要、原声回放、导出 Markdown / Word / SRT
- 引导、设置、实时活动和灵动岛

第一版不做：听其他 app 的声音（ReplayKit 广播扩展，单独做原型再说）、往会议里送语音、会议软件挂断时自动结束（iOS 看不到别的 app 用不用麦克风，只靠 10 分钟没人说话结束）。

## 关键决策

| 决策 | 选择 | 原因 |
|---|---|---|
| 最低系统 | iOS / iPadOS 26 | 只用 `SpeechAnalyzer` 和 Apple 本机翻译，不需要 Mac 上 14.4–15 那条 `SFSpeechRecognizer` 退路；设计稿按 iOS 26 的液态玻璃做 |
| 代码放哪 | 同仓库 `ios/`，引擎和 Mac 共用 | 和 Windows 不同，这里是同一种语言、同一套系统框架，共用比照抄省事，也最能保证纪要提示词和记录格式一致 |
| 怎样共用 | 文件级共用：`ios/shared-sources.txt` 列出 Mac 的源文件，iOS 构建直接把它们和 `ios/Sources` 编成一个模块 | 不用拆 SwiftPM 库：拆库要给跨模块的类型和成员都加 `public`，还要改测试，Mac 端改动太大。现在 Mac 端只是拆了几个文件、加了几处 `#if`。iOS 能编译以后再看要不要拆成库 |
| 构建 | `ios/scripts/build.sh`：`xcrun --sdk iphonesimulator swiftc` 编译，自己拼 `.app`，`simctl install` | 沿用 Mac“不用 `.xcodeproj`、脚本拼包”的做法；根目录“不建 `.xcodeproj`”这条只管 Mac。真机签名如果脚本搞不定，再评估 `.xcodeproj`，先在这里记下 |
| 界面 | SwiftUI，按设计稿；iPad 用 `NavigationSplitView` 三栏 | 设计稿是真相来源，颜色、文案沿用 Mac |
| 文案 | 中文作 key，和 Mac 共用 `Resources/*.lproj/Localizable.strings` | Mac 是参照；有 iOS SDK 时 `scripts/strings.py` 会一起检查 iOS 构建 |
| Ling key | app 沙盒里的 `ling-api-key` 文件，保护级别是第一次解锁后可读（`completeFileProtectionUntilFirstUserAuthentication`），不进备份 | 对应 Mac 的 0600 文件。不用 `complete`：锁屏时还在听，从操作按钮锁屏启动时也要读 key 才能出纪要 |
| 记录同步 | 第一版不做；以后用 iCloud Drive 放同一份 `session.json` | 格式本来就逐字节一致，能直接共用 |

## 能共用的代码

`ios/scripts/typecheck.sh` 会把共用的文件和 `ios/Sources` 一起做类型检查，还会挡住 iOS 没有的框架导入（AppKit、CoreAudio、SwiftUI…）。现在没有 Xcode，只能用 `SDK=macosx` 跑。两种 `#if` 的用法：需要 AppKit 的用 `#if os(macOS)`；需要 Mac app 其他部分的用 `#if !CICADA_IOS`，iOS 构建会设这个标志。

M0、M1 已经共用的 13 个文件，以及 M1 起要做的：

| 文件 | 状态 |
|---|---|
| `Ling.swift`、`Notes.swift`、`HeardText.swift`、`MeetingEnd.swift`、`Localization.swift`、`Translator.swift` | 已共用。`LingCall` 从 `Diagnostics.swift` 搬进 `Ling.swift`，`appDisplayName` 从 `SettingsWindow.swift` 搬进 `Localization.swift`，`Translator.swift` 去掉了用不到的 AppKit 和 CoreAudio 导入；iOS 上 key 文件加了文件保护 |
| `SessionStore.swift` | 已共用。记录格式、Markdown、SRT 两边一样。Word 导出靠 `NSAttributedString` 的 `.officeOpenXML`，这个只有 macOS 有，所以放在 `#if os(macOS)` 里；iOS 在 M3 写一个不靠第三方的最小 `.docx` 生成器（几个 XML 文件加一个不压缩的 zip，CRC32 自己算），做好后两端都换成它 |
| `SpeakerID.swift` | 已共用。声纹、聚类、起名留在这里，界面拆到只给 Mac 用的 `SpeakerViews.swift` |
| `Diagnostics.swift` | 已共用。记录器留在这里，设置里的诊断页拆到 `DiagnosticsView.swift` |
| `AudioFiles.swift` | 新文件，从 `AudioRouter.swift` 原样搬来 `PCMConverter` 和 `AudioFileWriter` |
| `RecordList.swift` | 新文件，会议列表的分组、标题、时间和时长，从 Mac 的 `Views.swift` 原样搬来 |
| `Voices.swift` | 已共用。声音列表和参考音频共用；克隆用的录音器 `VoiceRecorder` 绑在 Mac 的输入设备上，放在 `#if !CICADA_IOS` 里，iOS 在 M3 自己写 |
| `ios/Sources/Cicada/DevBuild.swift` | iOS 版的 `DevBuild` 和 `debugLog`，日志写在 app 容器的 Caches 里 |
| `Recognition.swift`、`FileImport.swift` | 还没共用：这两个文件正在改，等改完提交后再搬。`SpeechAnalyzer` 部分共用，`SFSpeechRecognizer` 退路只留给 Mac |
| `Settings.swift` 的 `AppSettings` | M2：拆成共用的听写和翻译设置，以及 Mac 独有的设置 |

留在 Mac：`SystemAudioTap`、`AudioRouter`（Core Audio HAL）、`VirtualMic`、`SystemMic`、`MicUsers`、`Shortcuts`、`LoginItem`、`Updater` / `Updates` / `UpdateChecker`、所有窗口和菜单。

iOS 新写：

| 文件 | 作用 | 对应 Mac |
|---|---|---|
| `ios/Sources/Cicada/RoomListen.swift` | `AVAudioSession`（`.playAndRecord`、`.measurement`）+ `AVAudioEngine` 麦克风 → 共用的识别和翻译 | `RoomMic.swift`、`ListenEngine.swift` 的会议室部分 |
| `FaceToFace.swift` | 按住说话 → Ming（有 key）或本机识别 + 翻译 → 扬声器；念的时候暂停听 | `SpeakEngine.swift` 去掉虚拟麦克风 |
| `AppModel.swift` | 把引擎接到界面；调试命令 | `AppModel.swift` |
| `Views/…` | 设计稿的 9 屏 | `Views.swift`、`NotesViews.swift`、`Onboarding.swift`… |
| `LiveActivity/`（扩展） | 灵动岛和锁屏卡片，按钮走 App Intent，只能点按 | 无 |
| `Intents.swift` | “开始听”给操作按钮、控制中心和 Siri | 无 |

## 后台和权限

- 正在听时开 `audio` 后台模式，锁屏也继续听；状态栏有橙点。Ling 和翻译请求在后台照常发。
- 导入用 `BGContinuedProcessingTask`（iOS 26），切到别的 app 也继续转，系统显示进度。
- 权限只问麦克风和语音识别，分别在第一次听和引导第一步时问；拒绝了，导入和会议记录照常能用。

## 开发环境和验证

- 装 Xcode 26（App Store，要 Apple ID），然后 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`、`xcodebuild -downloadPlatform iOS`。模拟器不需要开发者账号；真机要在 Xcode 里登录 Apple ID。
- `ios/scripts/build.sh` 编译模拟器版，`ios/scripts/run.sh` 装进 iPhone 和 iPad 模拟器并启动。
- 调试通道：`ios/scripts/ctl.sh <命令>` 把命令写进 app 容器的 `Library/Caches/debug-command`，再发一个 Darwin 通知叫醒 app。命令名和 Mac 的 `AppModel.debugCommand` 一致。`simctl openurl` 打开 `cicada-dev://` 也行，但模拟器每次都要人点确认。日志在 app 容器的 `Library/Caches/livesubs-dev-debug.log`；截图用 `simctl io <设备> screenshot`，对照设计稿。
- 听会议室在模拟器里用 Mac 的麦克风：`afplay Resources/sample/sample.m4a` 就能当输入。
- 要人来验证的：真机麦克风、锁屏后台、灵动岛、外接键盘的右 ⌥、TestFlight 分发。

## 里程碑

| 阶段 | 产出 | 怎样算完成 |
|---|---|---|
| **M0 共用引擎**（已完成） | `ios/shared-sources.txt`、`ios/scripts/typecheck.sh`，第一批 12 个文件 | macOS SDK 下类型检查通过；Mac 的 `scripts/test.sh` 通过；开发版播 `sample.m4a`，字幕、纪要、录音、导出都正常；英文界面正常 |
| **M1 跑起来**（已完成） | `ios/` 骨架、构建脚本、模拟器里能启动；会议记录列表和详情读 Mac 生成的 `session.json`；`scripts/strings.py` 也扫 `ios/` | iPhone 和 iPad 模拟器截图和设计稿对得上 |
| **M2 听会议室** | 麦克风 → 字幕 → 纪要 → 存记录；引导、设置、Ling key | 模拟器里放示例会议，字幕和纪要跟上；生成的记录 Mac 能打开 |
| **M3 说和导入** | 面对面同声传译、导入录音或视频、导出 | 导入 `sample.m4a` 得到和 Mac 一致的记录；按住说话能念出译文 |
| **M4 能发布** | 实时活动和灵动岛、App Intents、四种界面语言、TestFlight；`scripts/changelog.py` 加 `(ios)` 分组 | 一台没装过的 iPhone 从 TestFlight 装上到第一次出字幕顺利走完 |

## 风险

1. **不用 `.xcodeproj` 能不能签真机、打 TestFlight 包**：模拟器肯定可以；真机要描述文件，扩展还要单独签。M1 先做出模拟器版，M4 前定方案，不行就只给 `ios/` 加一个最小的 `.xcodeproj`。
2. **共用引擎拖累 Mac**：每次只搬几个文件，搬完跑 Mac 的测试和真机行为；搬的时候逻辑一行不改。
3. **macOS SDK 的类型检查不够**：它只能证明共用的文件不依赖 Mac app 的其余部分；只有 macOS 才有的 Foundation 或 AVFoundation 接口（比如 `.officeOpenXML`）它查不出来，要等 Xcode 装好后用 iOS SDK 再跑一遍。
4. **App Store 审核**：麦克风和语音识别的用途说明要写清楚；Ling key 由用户自己填，不涉及内购。
5. **iPhone 内存**：`SpeechAnalyzer`、声纹模型和录音同时跑，在旧机型上要实测；不够就默认关说话人识别。

## 发布时要一起改

- `README.md`、`README.en.md` 的路线图，`docs/ROADMAP.md`、`docs/ROADMAP.zh-CN.md` 里“iPhone / iPad 暂不计划”那一行
- 根目录 `AGENTS.md` 开头的平台列表（iOS 也会说，不只是听）
- `site/` 的下载入口和 `site/changelog.json`
