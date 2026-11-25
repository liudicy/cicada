# 知了 Linux 版

Cicada 的 Linux 版：把电脑播放的声音变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录；打开同声传译后，把你说的话翻成对方的语言，用“知了 麦克风”传进会议。方案和取舍见 [docs/linux-plan.md](../docs/linux-plan.md)。

- 原生：Python 3 + PyGObject + GTK 3，声音走 PulseAudio / PipeWire（`libpulse-simple`，读默认输出的 monitor，不用授权）。只用 Ubuntu 桌面自带的库，不用 pip 包。
- 识别：分段发给 AI 服务的“听的模型”，一次请求返回语言、原文和译文。默认 Ling 的 Ming（`Ming-3.0-audio-flash`）；用不了 Ling 时可在 设置 › AI 服务 换成 OpenRouter、ZenMux 或兼容 OpenAI 的自建服务（`cicada/core/providers.py`，推荐的听写模型是 Qwen 3.8 Omni Flash，比 Ming 慢 1–2 秒，测试见 `tools/audio-probe`），纪要、翻译和同传声音跟着换，只有“用你自己的声音”只能用 Ling。都需要一个 key，声音都会发到所选服务。和 Windows、Android 同一套做法。
- 纪要窗：浮在最上面、点它也不抢焦点（app 走 XWayland，窗口类型是 notification；GNOME 的 Wayland 不给普通窗口这两个能力）。**Linux 没法让窗口避开屏幕共享**，所以纪要窗一直带“可能被共享”。
- 纪要、记录格式（逐字节和 Mac 一致）、提示词、文案都和 Mac 版一致；英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Linux 独有的在 `strings/`。
- 同声传译：声音服务器里建一个虚拟麦克风“知了 麦克风”（`module-null-sink` + `module-remap-source`，PipeWire 和 PulseAudio 都行，不用装驱动），打开时设成默认输入，关掉或退出时把原来的麦克风还回去（被 `kill -9` 后下次启动也会还）。点纪要窗的麦克风、托盘的“开始说”或快捷键（Super + Shift + S，`cicada --speak`）开始 / 停止；Ming 一次请求识别并翻译，Ming 的声音流式播进知了 麦克风，下一句的声音在上一句播完前就已经在取。不戴耳机时，同声传译打开期间还会加载 `module-echo-cancel`（WebRTC 回声消除）：它的输出“知了 · 防回声”接在原来的默认输出前面并设为默认（声音仍从原来的扬声器出来，关掉、退出、被杀后下次启动都会把默认输出还回去），按下说话时从它的麦克风录音，对方从扬声器传进来的声音被去掉，你压着对方说的话照常说出去。声音服务器加载不了它、或默认输出被换走时，这一次用原来的麦克风，对方说话期间说的那句会丢掉，不说出去。
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

`cli.py` 读 Mac 版的 key 文件，不打印 key；环境里的代理会传给 urllib。`--provider zenmux|openrouter`（可加 `--hear-model <id>`）换 AI 服务，读对应的 `ai-key-<服务>`。

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

在虚拟机里 `~/cicada-linux/bin/cicada --dev` 启动开发版（记录在 `~/.local/share/cicada-dev`，日志在 `~/.local/state/cicada-dev/debug.log`），再用 `scripts/cicadactl` 驱动它：`state`、`start`、`stop`、`feed <wav>`、`sample`、`view notes|subtitles`、`show records|notes|settings|onboarding`、`windows`、`quit`；在 Dock 中显示用 `dock [on|off]`（打开时会议记录窗口最小化留在 Dock 里，`windows` 的 `iconified` 看它）、`close records`（点会议记录的 ×）；结束会议用 `calls zoom=Zoom|none|real`（假装会议软件在通话）、`realcalls`、`endtimes <没人说话秒数> <倒计时> <挂断宽限>|off`、`endkeep`；纪要窗用 `notes-tab notes|transcript`、`notes-search <词>`、`notes-wide on|off`、`notes-end ask|keep|end`（结束前的确认）、`notes-status failed|invalidKey|rateLimited|idle`（看出错横幅）；记录用 `rename <id> [标题]`（不给标题即恢复自动标题）、`delete <id>`；还有 `onboarding-step <0-4>`、`settings-scroll <0-1>`；AI 服务检查用 `ai-check`（现在查一次）、`ai-check-sim <原因|lowBalance|off>`（每次检查都按这个原因结束，截各状态的图）、`ask settings|fix|close`（回答开始听时的对话框）、`settings-ai`、`tray-menu`（顶栏菜单的各项）；只有你能修的问题（key、余额、模型、地址）在顶栏图标上加橙点，纪要窗收起时每场会议发一次通知（连不上的话持续 2 分钟后才发），`hide notes` 收起纪要窗、`problem-wait <秒>|off` 缩短这 2 分钟、`state` 的 `aiProblem` 看结果。保存会议录音用 `codecs`（这台电脑有没有 AAC 编码器 / 解码器）、`play [秒]`、`pause`、`rate`、`playstate`（播放到哪、亮着哪一句）、`settings-general`；Ubuntu 默认没有 AAC 编码器，测录音要先在虚拟机里 `sudo apt install gstreamer1.0-libav`，测完再删掉，看默认的灰开关。改正听错的词：`start` 后用 `heard <一句话>`（不用声音，当作听到的一整句，走真实的翻译 + 改词请求），`fix-state` 看每句的改法，`fix-answer yes|no`、`fix-later`、`fix-revert <句子 id>`、`fix-edit <句子 id>=<改后>[|one][|keep0]`、`fix-undo`，`fix-editor <句子 id>=<改后>` 在会议记录里打开“改这句…”，`vocab-add Morpho=莫拉`、`vocab-state`、`word-list [import <文字>|edit <词>|heard <词>=<听成>|delete <词>]` 看设置里的词表。分享成链接（`cicada/core/share.py`，设备密钥是纯 Python 的 Ed25519，`cicada/core/ed25519.py`）：`share <id>[,full][,pw]`、`unshare <id>`、`share-last`、`shareSheet <id>` 打开“分享…”，`share-ui scope|days|names|pw|summary|options|go|strip|back|confirm|copy all|link|password|revoke|close|state` 操作它（`options` 即“更改”，`state` 的 `clipboard` 是剪贴板里的那条消息）；虚拟机连不上 cicada.indaloop.app 时用 `https_proxy=http://10.0.2.2:7890` 启动。存到文件夹（`cicada/core/folder_export.py`，会后把会议存成 Markdown 到选的文件夹，索引在记录旁的 `FolderExport.json`）：`export-folder <路径>|off|on`（选文件夹并当场检查能不能写）、`export-state`（文件夹、问题、索引、还没存的记录）、`export-all`（也存一份）、`export-retry`、`export-choose`（打开“存到哪里”）；测没权限用 `chmod a-w` 那个文件夹，测找不到就把它的上一级挪走。`scripts/smoke.sh` 一步跑完：开窗口、放一段声音、确认 monitor 听到了。

焦点：`bin/focus_test.sh` 开一个最大化的“会议 app”（`focus_probe.py`），用 `click.py`（uinput，真实指针）点纪要窗和“字幕”链接，再在 Mac 上 `linux/vm/vmctl.sh type ok`；`/tmp/focus-probe.log` 里不能出现 `active=False`，最后一行应是 `text=…ok`。xdotool 只到 XWayland，测不了这个。

再检查：放一段视频再 `start`，字幕跟得上；中文和英文界面都看一遍。

需要真人和真机：x86_64 真机、真实声卡和蓝牙耳机、切换输出设备、KDE 等其他桌面、会议软件的屏幕共享。
