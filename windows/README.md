# 知了 Windows 版

Cicada 的 Windows 版：把电脑播放的声音变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录；同声传译（按住右 Ctrl 说话，翻译后的声音经 VB-Cable 虚拟麦克风进会议）；说话人识别（按声音标出说话人 1、2…，声纹模型是 WeSpeaker ResNet34-LM，CC BY 4.0，用 `scripts/compress-voiceprint.py` 压成 int8，6.7 MB，由系统自带的 Windows ML 在本机运行）。方案和取舍见 [docs/windows-plan.md](../docs/windows-plan.md)。

- 抓声音：WASAPI 进程回环，排除知了自己（Windows 10 2004 起）。
- 识别：Ming（`Ming-3.0-audio-flash`）分段识别，一次请求同时返回语言、原文和译文；需要 Ling key。
- 纪要、记录格式、提示词、多语言文案都和 Mac 版一致；文案的英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Windows 独有的在 `src/Cicada/Strings/`。
- 新版本：启动时和每 4 小时查一次 GitHub Releases（`UpdateChecker`），只认带 Windows zip 的发布；有新版本时托盘面板和设置 › 关于提示，浏览器下载这台电脑对应架构的 zip，还不能自动替换。开发版只在设了 `CICADA_UPDATE_FEED` 或用 `updatefeed` 调试命令时才查。

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

先 `scripts/dotnet.sh build src/Cicada.Cli -o build/cli` 编译命令行工具；它读 Mac 版的 key 文件，不打印 key。

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

VM 里没有麦克风：`cicadactl fakemic <wav>` 让按住右 Ctrl 时用这个文件代替麦克风，`speak <wav>` 直接说一句。`record <秒> <wav>` 录下 CABLE Output（会议软件会听到的声音），拷回 Mac 用 `cicada-cli hear` 核对语言和内容。`spike/clips/me-zh.wav`、`me-en.wav` 是“我说的话”，`silence.wav` 用来测什么都不发。
