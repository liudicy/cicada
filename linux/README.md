# 知了 Linux 版

Cicada 的 Linux 版：把电脑播放的声音变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录；打开同声传译后，把你说的话翻成对方的语言，用“知了 麦克风”传进会议。方案和取舍见 [docs/linux-plan.md](../docs/linux-plan.md)。

- 原生：Python 3 + PyGObject + GTK 3，声音走 PulseAudio / PipeWire（`libpulse-simple`，读默认输出的 monitor，不用授权）。只用 Ubuntu 桌面自带的库，不用 pip 包。
- 识别：Ming（`Ming-3.0-audio-flash`）分段识别，一次请求返回语言、原文和译文；需要 Ling key。和 Windows、Android 同一套做法。
- 纪要窗：浮在最上面、点它也不抢焦点（app 走 XWayland，窗口类型是 notification；GNOME 的 Wayland 不给普通窗口这两个能力）。**Linux 没法让窗口避开屏幕共享**，所以纪要窗一直带“可能被共享”。
- 纪要、记录格式（逐字节和 Mac 一致）、提示词、文案都和 Mac 版一致；英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Linux 独有的在 `strings/`。
- 同声传译：声音服务器里建一个虚拟麦克风“知了 麦克风”（`module-null-sink` + `module-remap-source`，PipeWire 和 PulseAudio 都行，不用装驱动），打开时设成默认输入，关掉或退出时把原来的麦克风还回去（被 `kill -9` 后下次启动也会还）。点纪要窗的麦克风、托盘的“开始说”或快捷键（Super + Shift + S，`cicada --speak`）开始 / 停止；Ming 一次请求识别并翻译，Ming 的声音流式播进知了 麦克风，下一句的声音在上一句播完前就已经在取。对方的声音从扬声器漏进麦克风的那句会丢掉，不说出去。
- 说话人识别（默认打开，和 Mac 一样）：每句话的声音算一个声纹，按 Mac 的阈值分组，标出说话人 1、2…，Ling 从对话里认出名字；会议记录里可以改名、合并、把一句改给别人，都能撤销。声纹模型和 Mac 是同一个（WeSpeaker ResNet34-LM，VoxCeleb，CC BY 4.0），由 `scripts/convert-voiceprint.py` 转成 `models/voiceprint.bin`；Ubuntu 桌面没有矩阵库、Python 也跑不动 ResNet，所以推理在我们自己的 C 代码里（`native/voiceprint.c`，不用第三方库），每个架构编一个 `libcicada-voice-<arch>.so` 随包附带。和 Mac 的 Core ML 结果余弦相似度 1.0000；在 4 核 arm64 虚拟机里 5 秒的一句约 0.3 秒。没有这个库时功能显示不可用，听照常。
- 支持 Ubuntu 22.04 / 24.04 桌面版。

## 目录

| 路径 | 内容 |
|---|---|
| `cicada/core` | 不依赖界面的引擎（只用 Python 标准库，Mac 上也能运行、测试） |
| `cicada/app` | GTK 应用：托盘、纪要窗 / 字幕条、会议记录、设置、引导、开发版的控制 socket |
| `native/` | 声纹推理（C）和 `build.sh`：Mac 上编 `.dylib` 给单元测试用，Linux 上编 `.so` |
| `models/` | 声纹模型权重（fp16，13 MB） |
| `cli.py` | 在 Mac 上用 WAV 跑完整流程、检查会议记录 |
| `tests/` | 单元测试（`unittest`） |
| `packaging/` | 菜单项、`install.sh` |
| `vm/` | Ubuntu 测试虚拟机（QEMU） |

## 命令（在 Mac 上）

```bash
scripts/test.sh               # 单元测试、文案检查、语法检查
scripts/build.sh              # build/cicada-linux/ 和 build/cicada-linux-<版本>.tar.gz
python3 scripts/strings.py    # 查缺翻译的文案（--write 追加 TODO）
python3 cli.py listen ../windows/spike/clips/en.wav --target zh-CN --notes   # 真实调用 Ming 和 Ling
python3 cli.py speak ../windows/spike/clips/zh.wav --from zh-CN --to en --out /tmp/out.wav   # 同声传译一句一句地跑
python3 cli.py roundtrip ~/Library/Application\ Support/LiveSubs/Sessions/*/session.json
```

`cli.py` 读 Mac 版的 key 文件，不打印 key；环境里的代理会传给 urllib。

## 安装（用户）

```bash
tar xzf Cicada-<版本>-Linux.tar.gz && cicada-linux/install.sh
```

装到 `~/.local`，不用 sudo，之后从应用列表打开“知了”。缺 `python3-gi`、`gir1.2-gtk-3.0`、`libpulse0` 时会提示用 apt 装（Ubuntu 桌面版默认都有）。

有新版本时顶栏菜单第一项和设置 › 关于会提示，点一下就下载、核对 SHA-256、装好并重新打开；正在听时等会议结束再装。测试用 `CICADA_UPDATE_FEED=<releases.json 的地址>` 换一个更新源（开发版只在设了它时才检查）。

## 在虚拟机里验证

```bash
VM=~/VMs/cicada-ubuntu linux/vm/run.sh     # 第一次：放好 noble-arm64.img（Ubuntu 云镜像）和 vm_key，cloud-init 装 GNOME
linux/vm/vmctl.sh ssh 'uptime'               # 在登录着的桌面会话里执行
linux/vm/vmctl.sh shot shot.png              # 截屏（QEMU，不受 Wayland 截图限制）
linux/scripts/build.sh && linux/vm/push.sh  # 把 build/cicada-linux 和测试工具放进虚拟机的 ~/cicada-linux
```

在虚拟机里 `~/cicada-linux/bin/cicada --dev` 启动开发版（记录在 `~/.local/share/cicada-dev`，日志在 `~/.local/state/cicada-dev/debug.log`），再用 `scripts/cicadactl` 驱动它：`state`、`start`、`stop`、`feed <wav>`、`sample`、`view notes|subtitles`、`show records|notes|settings|onboarding`、`windows`、`quit`；结束会议用 `calls zoom=Zoom|none|real`（假装会议软件在通话）、`realcalls`、`endtimes <没人说话秒数> <倒计时> <挂断宽限>|off`、`endkeep`；纪要窗用 `notes-tab notes|transcript`、`notes-search <词>`、`notes-wide on|off`、`notes-end ask|keep|end`（结束前的确认）、`notes-status failed|invalidKey|rateLimited|idle`（看出错横幅）；记录用 `rename <id> [标题]`（不给标题即恢复自动标题）、`delete <id>`；还有 `onboarding-step <0-4>`、`settings-scroll <0-1>`。`scripts/smoke.sh` 一步跑完：开窗口、放一段声音、确认 monitor 听到了。

焦点：`bin/focus_test.sh` 开一个最大化的“会议 app”（`focus_probe.py`），用 `click.py`（uinput，真实指针）点纪要窗和“字幕”链接，再在 Mac 上 `linux/vm/vmctl.sh type ok`；`/tmp/focus-probe.log` 里不能出现 `active=False`，最后一行应是 `text=…ok`。xdotool 只到 XWayland，测不了这个。

再检查：放一段视频再 `start`，字幕跟得上；中文和英文界面都看一遍。

需要真人和真机：x86_64 真机、真实声卡和蓝牙耳机、切换输出设备、KDE 等其他桌面、会议软件的屏幕共享。
