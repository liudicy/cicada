# 知了 Windows 版技术方案

状态：M1、M2 已在 Windows 11 ARM 虚拟机里跑通（2026-11-04，`windows/vm/`）：抓声音不含知了自己、纪要窗不抢焦点也不进截图、引导、字幕条、会议记录、设置、四种界面语言、托盘、再次打开，x64 版在模拟下也跑过；Windows 写的记录和 Mac 格式一致。同声传译（2026-11-04）：按住右 Ctrl → Ming 识别并翻译 → Ming 声音（或 Windows 自带）→ VB-Cable；在虚拟机里录下 CABLE Output 核对过中→英、中→日、英→中，以及没翻译成功时什么都不发。没测到：真人麦克风、会议软件里真的选 CABLE Output、真机 x64、125–150% 缩放、蓝牙耳机切换、多显示器、会议软件里的真实屏幕共享。代码和命令见 [windows/README.md](../windows/README.md)。还没做（M3）：录音、安装包、签名、自动更新。先做“听”：系统声音 → 实时翻译字幕 → 会议纪要 → 双语记录。“说”（同传进会议）放到后面。

## 范围

第一版要有：

- 托盘图标和菜单（对应 Mac 的菜单栏面板）
- 字幕条和纪要窗：置顶、不抢焦点、默认不出现在屏幕共享里
- 会议记录主窗口：列表、双语全文、纪要、导出 Markdown
- 设置和引导：系统声音（Windows 不用授权，只要试听一下）、示例会议、Ling key

第一版不做：说话（虚拟麦克风）、说话人识别、离线识别。

最低系统：Windows 10 2004（build 19041）。按进程排除的回环采集和“不出现在屏幕共享里”都从这个版本开始支持。架构同时发 x64 和 ARM64。

## 关键决策

| 决策 | 选择 | 原因 |
|---|---|---|
| 代码放哪 | 同仓库 `windows/` 目录 | 纪要提示词、记录格式、多语言文案、官网都要和 Mac 保持一致，放一起最容易对照修改 |
| 技术栈 | C# / .NET 10（LTS，支持到 2028 年 11 月）+ WPF，只用 .NET 自带库和 Windows API | 对应 Mac 版“不用第三方依赖”的做法。WPF 原生支持不抢焦点的置顶透明窗口；设了 `EnableWindowsTargeting` 后能在 Mac 上用 `dotnet` 命令行编译，不用装 Visual Studio |
| 语音识别 | 先用 Ming 分段识别加翻译；把识别做成接口，之后再接流式识别服务 | 用户用同一个 Ling key，不用再注册别的服务。一次调用同时拿到原文和译文，和 Mac 版“说”的做法一样 |
| 会议记录格式 | 和 Mac 的 `session.json` 字段一致 | 以后可以互相导入、同步，测试数据也能共用 |

**不共享代码，只共享规格。** 走云端以后，核心逻辑（分段、调 Ling、纪要、存储）大约 1–2 千行，不值得为它引入跨语言的共享核心。共享的是下面这些文件，两边各自实现：

- 纪要和翻译的提示词：Mac 现在写在 `Notes.swift`、`Translator.swift` 里，Windows 版先原样复制，并在文件里注明出处
- `session.json` 的字段：见下文“会议记录”一节
- 多语言文案：用脚本把 `Resources/*.lproj/Localizable.strings` 转成 Windows 用的资源文件，仍以中文原文作为 key

如果以后要做 Linux，再评估要不要换成 Rust 共享核心或 Avalonia。

## 架构

```
WASAPI 进程回环（排除知了自己）
  → 48k 浮点 → 16k 单声道 Int16
  → 分段（音量检测：停顿 ≥ 0.6s 或满 8s 就切一段）
  → 识别接口 ISpeechSource
      ├─ MingSource（第一版）：每段 WAV → Ming-3.0-audio-flash
      │     → ORIGINAL / TRANSLATION / LANG 三行
      └─ StreamingSource（以后）：流式识别，带草稿和逐词时间
  → HeardLine（原文、译文、语言、起止时间）
  → 字幕条、纪要窗 ← NotesEngine（Ling，每 45s 更新一次）
  → SessionStore（session.json + system.m4a）
```

### 模块

引擎在 `windows/src/Cicada.Core/`（`net10.0`，Mac 上也能编译和测试），界面在 `windows/src/Cicada/`：

| 文件 | 作用 | 对应 Mac |
|---|---|---|
| `Core/Segmenter.cs` | 按音量分段：停顿 0.6s 切段，满 8s 在最后 2s 里最安静处切 | `AudioRouter.swift` 的一部分 |
| `Core/Audio.cs` | `IAudioSource` 接口、`FileAudioSource`（测试和示例会议用）、WAV 读写 | 无 |
| `Core/ListenEngine.cs` | 整条“听”的流程：请求并行发出、按段的顺序交付、断句接回、语言判断 | `ListenEngine.swift` |
| `Core/Ling.cs` | `LingClient`（请求间隔至少 0.6s、优先级、`thinking: disabled`、内容放 system 消息）和 `AIKey` | `Ling.swift` |
| `Core/Translator.cs` | Ming 三行识别（`Hear`）；文字翻译先 Ling 后 Google，草稿只走 Google | `Translator.swift` |
| `Core/Notes.cs` | 纪要引擎，提示词和解析逐字照搬 | `Notes.swift` |
| `Core/SessionStore.cs`、`Models.cs`、`Json.cs` | 会议记录，`session.json` 格式与 Mac 一致 | `SessionStore.swift` |
| `Core/Strings.cs` | 中文作 key，读 Mac 的 `Localizable.strings`，叠加 `Windows.strings` | `L()` |
| `SystemAudioTap.cs` | WASAPI 进程回环，排除知了自己 | `SystemAudioTap.swift` |
| `NotesWindow.cs` | 纪要窗和字幕条（同一个窗口的两种样子） | `NotesWindow.swift`、`Overlay.swift` |
| `MainWindow.cs` | 会议记录 | `Views.swift` |
| `SettingsWindow.cs`、`Onboarding.cs` | 设置、引导 | `SettingsWindow.swift`、`Onboarding.swift` |
| `App.cs` | 入口、`Controller`（把引擎接到窗口）、托盘、调试管道 | `AppModel.swift`、`AppMenu.swift` |
| `Native.cs` | 不抢焦点、不被截屏、DPAPI | 无 |

引擎内部用锁保护状态，事件在工作线程上发出，界面统一转到 UI 线程再更新；音频回调只把数据放进 `ListenEngine` 的队列。

### 识别：Ming 分段方案的细节和代价

- 每段 16k 单声道 WAV，长度 0.25–8s，上限沿用 Mac 版“说”的 60s。用 base64 放进 `chat/completions` 的 `audio_url`，和 `Translator.swift:137-166` 的做法相同。
- 提示词要求输出三行：`LANG:`、`ORIGINAL:`、`TRANSLATION:`。语言检测就靠这一行，不需要 Mac 版那套多模型打分。
- 没有草稿字幕。一句话说完到字幕出现，大约要“这段的长度 + 1–2s 请求时间”。
- 没有逐词时间戳。Mac 版的接句、强制断句依赖逐词时间，Windows 第一版改成按分段边界处理，接句只看标点和文字。
- 限流：账号限制大约每秒 2 个请求，请求间隔至少 0.6s。按每段平均 4s 算，识别每秒约占 0.25 个请求，纪要每 45s 一次，余量够用。但优先级要重新排：识别 > 纪要。
- 风险：Ming 用来做连续转写，准确率和成本都还没测过。所以 M0 先测，测完再定。

### M0 实测（2026-11-03，合成录音）

脚本：`windows/spike/ming_asr.py`。测试素材：用 macOS `say` 生成的三段模拟会议，每段 8 句、40–50 秒，句子之间留 0.8 秒停顿。语言设为自动检测。

| 语言 | 分段数 | 平均每段 | 延迟中位数 / 最大 | 字错率 | 每小时 token（输入 / 输出） |
|---|---|---|---|---|---|
| 英语 → 中文 | 8 | 4.3s | 2.2s / 2.4s | 8.9% | 11.8 万 / 3.8 万 |
| 中文 → 英语 | 8 | 5.0s | 2.2s / 2.2s | 7.8% | 10.1 万 / 3.4 万 |
| 日语 → 中文 | 8 | 5.8s | 2.2s / 2.4s | 8.6% | 9.3 万 / 3.1 万 |

- 字错率主要来自数字的写法：参考文本写“two percent”，Ming 写“2%”；参考写“千分之三”，Ming 写“3‰”。去掉这类差异后，英语和中文几乎没有错误。日语有两处真错误：“第四四半期”识别成“第44版期”，“決済”识别成“決算”。
- 24 次请求全部成功，回复都符合三行格式，语言全部判断正确。
- 延迟和每段长度基本无关，稳定在约 2.2 秒。加上判断停顿的 0.6 秒，一句话说完后约 3 秒出字幕。
- 还没测：真实会议录音（有噪音、多人抢话、没有停顿的长句被 8 秒强制切开）、Ming 的单价。

## 会议记录

- 位置：`%APPDATA%\Cicada\Sessions\<yyyyMMdd-HHmmss>\`，开发版用 `Cicada Dev`
- 文件：`session.json`；录音先存成 WAV，M3 再用 Media Foundation 的 AAC 编码器转成 `system.m4a`
- JSON：缩进格式、key 排序、ISO-8601 日期，字段和 `SessionStore.swift:4-40` 一致：
  - `Session`：`id`、`title`、`startedAt`、`endedAt?`、`lines[]`、`hasAudio`、`notes?`、`renamed?`、`voiceNames?`、`voiceGuesses?`
  - `TranscriptLine`：`id`（`h<n>-<segId>`）、`t`、`speaker`（`them`）、`src`、`dst?`、`srcLang`、`dstLang`、`voice?`
- 保存去抖 1.5s；没有任何内容的会议结束时删除。这两条和 Mac 一致。
- 测试：把一份 Mac 生成的 `session.json` 放进测试数据，Windows 读进来再写出去，结果要和原文件逐字节相同。

## 窗口：不抢焦点、不被截屏

- 窗口设 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`、`Topmost`、`ShowActivated=false`，并处理 `WM_MOUSEACTIVATE`，返回 `MA_NOACTIVATE`
- 调用 `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)`。用户打开“共享屏幕时让对方看到”后改成 `WDA_NONE`，并显示提示标记，和 Mac 一样
- 验证：Win+Shift+S 截图、Teams 或腾讯会议的屏幕共享里都看不到这个窗口；点击窗口后，原来的前台窗口仍然保持焦点

## 开发环境和验证

- Mac 上用 VMware Fusion 装 Windows 11 ARM。把仓库作为共享文件夹挂进虚拟机，在 Mac 上用 `dotnet` 编译，在虚拟机里运行。注意：现在 Mac 磁盘只剩约 22GB，需要先清理出 60–80GB，或者把虚拟机放到外接 SSD
- `windows/scripts/build.sh`：在 Mac 上编译 x64 和 ARM64 两个版本
- `windows/scripts/test.sh`：单元测试，覆盖分段、`session.json` 往返、Ming 回复解析和纪要解析
- 调试：命令行工具 `cicadactl` 通过命名管道发命令（开始听、喂入文件、导出状态），日志写到 `%TEMP%\cicada-dev-debug.log`
- CI：GitHub Actions 的 `windows-latest`（x64）跑编译和测试；CI 里用 `FileAudioSource` 喂音频，因为云上的 Windows 没有声卡
- 发布前必须用一台 x64 真机测：真实声卡和蓝牙耳机、切换输出设备、Windows Defender 和 SmartScreen 的拦截

## 里程碑

| 阶段 | 产出 | 怎样算完成 |
|---|---|---|
| **M0 验证**（1–2 天） | 一个控制台程序 | ① 在虚拟机里播放 `Resources/sample/sample.m4a`，能抓成 WAV，而且不含知了自己的声音；② 把同一段音频切段后交给 Ming，记下延迟、准确率和每小时费用。数字不理想就换流式识别服务 |
| **M1 字幕** | 托盘、字幕条、抓声音 → 分段 → Ming → 显示 | 在虚拟机里放会议录音，字幕跟上；截图和屏幕共享里看不到字幕条 |
| **M2 纪要和记录** | 纪要窗、纪要引擎、`session.json`、会议记录窗口、导出 Markdown | Mac 生成的记录 Windows 能打开；Windows 生成的纪要和 Mac 的结构一致 |
| **M3 能发布** | 引导、设置、四种界面语言、m4a 录音、安装包、签名（Azure Trusted Signing）、自动更新（查 GitHub Release，校验 SHA-256）、官网下载入口 | 一台干净的 x64 真机从下载到第一次出字幕不用开终端 |
| 以后 | 流式识别（带草稿）、说话（VB-Cable，下载后校验哈希，不打包进安装包）、说话人识别 | 按用户反馈排 |

## 风险

1. **Ming 不适合连续转写**：准确率不够、延迟太高或费用太贵。应对：M0 先测；识别接口一开始就抽象好，改接阿里云、Azure、Deepgram 等流式识别服务时，只换 `ISpeechSource` 的实现。
2. **国内网络**：Google 翻译在国内用不了，草稿翻译会失效。第一版没有草稿，不受影响；接流式识别以后，草稿翻译改用 Ling 低优先级请求，或者干脆不翻译草稿。
3. **ARM 虚拟机和 x64 真机表现不同**：靠 CI 跑 x64，加上 M3 的真机测试兜底。
4. **未签名的 exe 被 Defender 或 SmartScreen 拦截**：M3 前完成签名。内测阶段用 zip 发，并在说明里写清怎么放行。

## 待定

- 产品名、托盘图标沿用知了的 logo，应用标识用 `com.wquguru.cicada`。
- `windows/` 是否需要自己的 `AGENTS.md`。根目录的 `AGENTS.md` 有 6 KB 上限，Windows 的规则不宜写进去。
