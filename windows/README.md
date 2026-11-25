# 知了 Windows 版

Cicada 的 Windows 版：把电脑播放的声音变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录，连同会议录音（`system.m4a`，Windows 自带的 AAC 编码），会后在会议记录里回放；同声传译（按住右 Ctrl 说话，没有这个键可以在 设置 › 同声传译 里换一个；翻译后的声音经 VB-Cable 虚拟麦克风进会议）；说话人识别（按声音标出说话人 1、2…，声纹模型是 WeSpeaker ResNet34-LM，CC BY 4.0，用 `scripts/compress-voiceprint.py` 压成 int8，6.7 MB，由系统自带的 Windows ML 在本机运行）。方案和取舍见 [docs/windows-plan.md](../docs/windows-plan.md)。

- 抓声音：WASAPI 进程回环，排除知了自己（Windows 10 2004 起）。
- 识别：Ming（`Ming-3.0-audio-flash`）分段识别，一次请求同时返回语言、原文和译文；需要 Ling key。用不了 Ling 的可以在 设置 › AI 服务 换成 OpenRouter、ZenMux 或兼容 OpenAI 的地址：听交给它能输入音频的模型（同样的提示词，字幕晚 1–2 秒），纪要和翻译用它的文字模型，同传声音用它的声音模型，没有时用 Windows 的声音。
- 改正听错的词：和 Mac 版同样的规则和提示词（读音相近才直接改，拼音用 `src/Cicada.Core/Data/pinyin.tsv`，由 Apple 的 ICU/CLDR 汉字转拼音一次生成；新名字先问；词表 `vocabulary.json` 和 Mac 同格式）。Ming 一次给出原文和译文，没有单独的文字翻译请求可搭，所以开着时每句话会多发一次文字请求。没有声音也能试：`cicadactl silentlisten zh-CN`，再 `heard <一句话>`。
- 纪要、记录格式、提示词、多语言文案都和 Mac 版一致；文案的英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Windows 独有的在 `src/Cicada/Strings/`。
- 新版本：启动时和每 4 小时查一次 GitHub Releases（`UpdateChecker`），只认带 Windows 安装包的发布；有新版本时托盘图标出现红点、每个版本发一次通知（正在听时等会议结束），托盘面板和设置 › 关于也会提示。点“安装”由知了自己下载这台电脑对应架构的 `Cicada-<版本>-Windows-x64.exe` / `-ARM64.exe`（1.1.0 只认 `Cicada-Setup.exe` 这两个旧名字，发布时一并附上）、对照 `checksums.txt` 校验后安装并重新打开，不经过浏览器，所以 SmartScreen 不拦。开发版只在设了 `CICADA_UPDATE_FEED` 或用 `updatefeed` 调试命令时才查。
- 存到文件夹：设置 › 隐私与启动 › 会后存一份。会议整理好后存成一个 Markdown 文件（文件名和开头的 frontmatter 和 Mac 版一样，`Tests/fixtures/folder-export` 是约定），默认放在最近打开的 Obsidian 库里的 `Cicada` 文件夹，没有就是 文档\Cicada；记了哪些写在记录旁边的 `FolderExport.json`。写入先写同一文件夹里的临时文件再改名。写不进去时（Defender 的受控文件夹访问，或文件夹本身的权限）设置里和会议记录里各有一行；文件夹在文档、桌面等受保护的位置时多一个“打开 Windows 安全中心”，这时 Windows 自己会发通知，知了不再发，其他位置会后发一次。调试：`cicadactl export folder <路径>`、`export all`、`export`（状态）。
- 分享：会议记录里的“分享…”把纪要（或纪要和双语全文）变成 cicada.indaloop.app 上的链接，分享文档和 Mac 版逐字节相同；上传前服务器检查有没有密钥等敏感内容。设备密钥是 Ed25519（.NET 没有自带，`Cicada.Core/Ed25519.cs` 按 RFC 8032 实现，用 RFC 的测试向量验证），它和每个链接的管理令牌、密码都用 DPAPI 封存在 `share-device.json` 和 `Shares\` 里，不进会议记录、导出和日志。

## 目录

| 路径 | 内容 |
|---|---|
| `src/Cicada.Core` | 不依赖界面的引擎（`net10.0`，Mac 上也能编译、运行、测试） |
| `src/Cicada` | Windows 应用：托盘、纪要窗 / 字幕条、会议记录、设置、引导（WPF，代码写界面，不用 XAML） |
| `src/Cicada.Cli` | 在 Mac 上用 WAV 文件跑完整流程、检查会议记录 |
| `tests/Cicada.Tests` | 单元测试（控制台程序，不用测试框架） |
| `spike/` | M0 验证：`ming_asr.py`、`LoopbackProbe` |

## 命令（在 Mac 上）

```bash
scripts/install-dotnet.sh          # 一次：.NET 10 SDK 装到 ~/.dotnet，不用 sudo
scripts/test.sh                    # 单元测试
scripts/build.sh                   # 开发版：build/Cicada-win-x64/、build/Cicada-win-arm64/
RELEASE=1 scripts/build.sh         # 发布版
python3 scripts/strings.py         # 查缺翻译的文案（--write 追加 TODO）
```

不依赖 Windows 的验证：

```bash
DOTNET_ROOT=~/.dotnet build/cli/cicada-cli listen spike/clips/en.wav --target zh-CN --notes   # 真实调用 Ming 和 Ling
DOTNET_ROOT=~/.dotnet build/cli/cicada-cli roundtrip ~/Library/Application\ Support/LiveSubs/Sessions/*/session.json
```

先 `scripts/dotnet.sh build src/Cicada.Cli -o build/cli` 编译命令行工具；它读 Mac 版的 key 文件，不打印 key。`--provider zenmux`（或 openrouter）换服务，`check` 检查 key 和听的模型，`speak <文字> <out.wav>` 试声音模型。

## 在 Windows 里验证

这一节是开发验证，不是给用户的安装说明；用户安装要等 M3 的安装包。

1. 在 Mac 上 `scripts/build.sh`，把整个 `build/Cicada-win-arm64`（ARM 虚拟机）或 `build/Cicada-win-x64`（x64 电脑）拷到 Windows 的本地磁盘（比如桌面），不要直接从共享文件夹运行。ARM 虚拟机里两个都能跑，x64 版走模拟，可顺便验证大多数用户会用的那份。
2. 没签名，第一次打开会弹“Windows 已保护你的电脑”：点“更多信息”→“仍要运行”。
3. 在 `test\` 里打开 PowerShell，先验证抓声音：`.\LoopbackProbe.exe` 应显示 `absent`，`.\LoopbackProbe.exe --include-self` 应显示 `PRESENT`。虚拟机要有声卡（VMware 默认有），并且没静音。
4. 双击 `Cicada Dev.cmd` 打开开发版（记录在 `%APPDATA%\Cicada Dev`，日志在 `%TEMP%\cicada-dev-debug.log`）。走完引导：填 key → 播放任意声音看音量条 → 示例会议。
5. 在 `test\` 的 PowerShell 里驱动它（Windows 默认禁止运行脚本，所以用 `-ExecutionPolicy Bypass`）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cicadactl.ps1 state
   powershell -ExecutionPolicy Bypass -File .\cicadactl.ps1 feed "$PWD\en.wav"
   ```
   其余命令：`start`、`stop`、`view subtitles`、`capture on`、`show records`、`quit`。
6. 检查：日志里 `tap:` 那行是实际的录音格式，不应出现 `display affinity failed`；纪要窗不抢焦点（点它之后原来的窗口仍能打字）；Win+Shift+S 截图和会议软件的屏幕共享里看不到它；打开“共享屏幕时让对方看到”后能看到，并显示“对方可见”；用浏览器放一段视频再 `start`，字幕跟得上。

## 在 Mac 上自动测（QEMU 虚拟机）

`vm/` 里是一台无界面的 Windows 11 ARM 测试机：QEMU + HVF，装机全自动（`autounattend.xml`），装好后用 SSH 驱动。

```bash
brew install qemu
# 放进 ~/VMs/cicada-win11/：win11.iso（微软官网 ARM64 ISO）、virtio-win.iso、vm_key（ssh-keygen 生成）
vm/run.sh                      # 第一次会自动装 Windows，约 30 分钟；之后几十秒开机
scripts/build.sh && vm/deploy.sh
vm/vmctl.sh g launch 'C:\cicada-test\Cicada-win-arm64\Cicada.exe' --dev
vm/vmctl.sh ssh '& C:\cicada-test\Cicada-win-arm64\test\cicadactl.ps1 state'
vm/vmctl.sh g play 'C:\cicada-test\Cicada-win-arm64\test\zh.wav'   # 另一个进程放声音
vm/vmctl.sh shot out.png       # 屏幕本身（看得到纪要窗）
vm/vmctl.sh g shot C:\x.png    # Windows 里截图（屏幕共享看到的，不应有纪要窗）
```

`vmctl.sh g …` 调 `guest.ps1`：SSH 会话没有桌面，要桌面的事（启动、放声音、截图、点击、看前台窗口）都通过计划任务在登录的桌面里做。测不到的：真机 x64、蓝牙耳机切换、多显示器 DPI、会议软件的真实屏幕共享。

## 同声传译怎么测

VM 里没有麦克风：`cicadactl fakemic <wav>` 让按住说话键时用这个文件代替麦克风（`talkkey <名字>` 换键，`talkkey choose` 等同点“更改”），`speak <wav>` 直接说一句。`record <秒> <wav>` 录下 CABLE Output（会议软件会听到的声音），拷回 Mac 用 `cicada-cli hear` 核对语言和内容。`spike/clips/me-zh.wav`、`me-en.wav` 是“我说的话”，`silence.wav` 用来测什么都不发。

按住说话键时麦克风用通话类别打开（`EchoMic`），走这台电脑的回声消除：日志 `speak: mic with echo cancellation` 时电脑放着会议声音也照发，`speak: mic plain` 时（Windows 10、驱动没有回声消除）对方说话期间按的照旧不发。`talkmic CABLE Output` 让按住说话键读这个输入（VM 只有它），和 `fakemic` 一起用时仍发文件里的话，但真的走一遍这条采集；虚拟线没有回声消除，所以 VM 里只能看到 plain 这条路。真正的回声消除要真机加扬声器测。
