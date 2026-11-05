# 知了 Linux 版技术方案

状态：M1、M2 已完成（2026-11-04），引擎在 Mac 上测过，界面、抓声音和焦点在 Ubuntu 24.04 虚拟机里测过，见“已验证”。代码和命令见 [linux/README.md](../linux/README.md)。先做了“听”；同声传译（“说”）在 2026-11-04 加上，见“同声传译”。

## 范围

第一版要有：

- 托盘（对应 Mac 的菜单栏面板）：开始听 / 结束、显示纪要、会议记录、设置、退出。没有托盘的桌面（原版 GNOME）由会议记录窗口顶栏上的“开始听”代替
- 纪要窗和字幕条：浮在最上面、不抢焦点
- 会议记录：列表、双语全文、纪要、导出 Markdown、重命名、删除、补生成纪要
- 设置和四步引导（和 Mac 同样的布局）：接 Ling → 听声音（音量条）→ 看效果（示例会议）→ 同声传译；Linux 靠 Ming 识别，所以 Ling key 排第一（Mac 排第三）
- 结束会议（`core/meeting_end.py`，照 MeetingEnd.swift）：会议软件挂断（`pactl` 列出的麦克风流）或长时间没人说话时自己结束，倒计时可“继续记录”；新通话开始时自动开下一场

第一版不做：离线识别、录音文件、导入录音。

只正式支持一种配置：**Ubuntu 22.04 / 24.04 LTS 桌面版（GNOME，Wayland 或 X11，PipeWire 或 PulseAudio）**。别的发行版只要有 GTK 3、PyGObject、libpulse 也能跑，但不承诺。

## 关键决策

| 决策 | 选择 | 原因 |
|---|---|---|
| 代码放哪 | 同仓库 `linux/` | 和 Windows、Android 一样：提示词、记录格式、文案跟 Mac 对照修改 |
| “原生”指什么 | Linux 桌面自己的技术：GTK、PipeWire/PulseAudio、XDG 目录、`.desktop`、AppIndicator；不用 Electron、Avalonia 这类跨平台外壳，也不把 .NET 运行时带过来 | 用户要求“原生支持 Linux”。复用 Windows 的 C# 引擎省一次移植，但要带 70 MB 运行时、界面也不是 Linux 的 |
| 语言和界面 | Python 3 + PyGObject + GTK 3，只用系统自带的库；声音用 `ctypes` 调 `libpulse-simple` | Ubuntu 桌面自带 `python3-gi`，GNOME 自己的很多工具就是这么写的；不用编译，在 Mac 上就能跑引擎和单元测试；不用任何 pip 包，对应“不用第三方依赖” |
| 为什么 GTK 3 不用 GTK 4 | GTK 3 | 纪要窗要“浮在最上面、不抢焦点”。GTK 3 有 `set_keep_above`、`set_accept_focus`；GTK 4 把这两个都删了，只能自己去改 X11 属性。托盘的 AppIndicator 也只支持 GTK 3 |
| Wayland | 整个 app 走 XWayland（`GDK_BACKEND=x11`） | GNOME 的 Wayland 不给普通窗口“置顶”和“不抢焦点”，也不支持 layer-shell；XWayland 窗口的这两个属性 Mutter 认。Ubuntu 一直带着 XWayland |
| 纪要窗的窗口类型 | `NOTIFICATION`，输入提示 false，`WM_PROTOCOLS` 只留 `WM_DELETE_WINDOW`，拖动由 app 自己移窗口 | 实测：普通的 utility 窗口被点一下，Mutter 会把焦点从会议 app 拿走约 0.1 秒再还回去（网页会议会收到 blur）；去掉 `WM_TAKE_FOCUS` 也不够。notification 类型点了完全不动焦点，但窗口管理器不帮它拖动 |
| 托盘 | 用 ctypes 调 `libayatana-appindicator3` | Ubuntu 桌面装了这个 C 库和 AppIndicator 扩展，但没装它的 GObject typelib，PyGObject 直接用不了 |
| 语音识别 | Ming 分段识别，同 Windows / Android | 同一个 Ling key；M0 已在 Windows 方案里测过延迟和准确率 |
| key | `~/.config/cicada/ling-api-key`，权限 0600 | 和 Mac 的规则一样：只在这个文件里，不进设置、日志、导出 |
| 记录 | `~/.local/share/cicada/Sessions/<yyyyMMdd-HHmmss>/session.json`，和 Mac 逐字节一致 | 开发版用 `cicada-dev`，互不影响 |
| 打包 | 先发 tar.gz + `install.sh`（装到 `~/.local`，不用 sudo）；M3 出 `.deb` | `.deb` 能声明依赖，apt 自动补齐；Flatpak 要带整个 GNOME 运行时，AppImage 带 Python 和 GTK 都很重 |

和另外两个平台一样**不共享代码，只共享规格**：引擎从 Android 版（`android/core`）逐文件移植，提示词一字不改；单元测试里有一条直接拿 `Notes.kt` 的源码比对纪要提示词的每条规则，两边有人改了就会失败。

## 和 Mac 不一样的地方：共享屏幕

Linux 没有办法让某个窗口不出现在屏幕共享里：Wayland 下共享走 xdg-desktop-portal，共享整个屏幕时窗口全都在；X11 下也没有对应的属性。所以：

- 纪要窗一直带“可能被共享”的标记（Windows 在隐藏失败时也用这个标记）。
- 设置里不提供“共享屏幕时让对方看到”，换成一行灰字：“Linux 无法让窗口避开屏幕共享：共享屏幕前先关掉纪要窗”。
- 这是 AGENTS.md 里“纪要窗不出现在屏幕共享里”这条规则在 Linux 上做不到的地方，靠如实告诉用户来补。

## 架构

```
PulseAudio / PipeWire：默认输出的 monitor（@DEFAULT_MONITOR@），服务器直接给 16k 单声道 s16
  → ListenEngine 的队列 → Segmenter（停顿 0.6s 或满 8s）→ Ming 三行 → HeardLine
  → SessionStore（session.json）/ NotesEngine（45s）
  → GTK 主循环（GLib.idle_add 合并刷新）→ 托盘、纪要窗 / 字幕条、会议记录
```

| 文件（`linux/cicada/`） | 作用 | 对应 Android |
|---|---|---|
| `core/jsonfmt.py` | 按 Swift `JSONEncoder` 的格式写出（`"key" : value`、key 排序、`\/`、空数组 `[\n\n]`） | `Json.kt` |
| `core/models.py`、`session_store.py` | 会议记录 | 同名 |
| `core/segmenter.py`、`audio.py` | 分段、`AudioSource`、WAV | 同名 |
| `core/ling.py`、`translator.py`、`notes.py`、`listen.py` | 同 Android，提示词逐字照搬 | 同名 |
| `core/strings.py`、`support.py`、`settings.py` | 文案、路径和日志、设置 | 同名 |
| `app/capture.py` | `libpulse-simple` 读默认输出的 monitor | `Capture.kt` |
| `app/notes_window.py` | 纪要窗和字幕条 | `Overlay.kt` |
| `app/records_window.py` | 会议记录 | `MainActivity.kt` |
| `app/settings_window.py`、`onboarding.py` | 设置、引导 | 同名 |
| `app/tray.py` | AppIndicator 托盘（有就用） | 常驻通知 |
| `app/main.py` | 入口、`Controller`、单实例（`Gtk.Application`） | `App.kt` |
| `app/debug.py` | 开发版的控制 socket | `DebugReceiver.kt` |

听的时候 GNOME 顶栏会亮起“麦克风在用”的图标：读 monitor 也是一个录音流，系统分不出来。知了不碰麦克风，引导里那句“不用麦克风”仍然成立，但用户可能会问。

抓声音不用排除自己：知了听的时候自己不出声。示例会议直接把文件喂给引擎，同时用 `pw-play` 放出来给人听，这时不开系统声音采集，不会听两遍。

## 开发环境和验证

- 引擎：在 Mac 上 `linux/scripts/test.sh`（单元测试、文案检查）和 `linux/cli.py`（真实调用 Ming、Ling，读写 Mac 的记录）
- 界面和抓声音：`linux/vm/run.sh` 在 QEMU（HVF）里跑 Ubuntu 24.04 arm64 桌面，cloud-init 装好 GNOME 并自动登录；`vmctl.sh ssh` 进桌面会话执行命令，`vmctl.sh shot` 用 QEMU 截屏（不受 Wayland 截图限制），`vmctl.sh type` 用 QEMU 键盘打字
- 虚拟机里的坑：Intel HDA 声卡在 HVF 下会让客户机卡死，改用 `virtio-sound-pci`（要装 `linux-modules-extra`）；QEMU 的鼠标（HMP、VNC）只送按键不送坐标，点击改用客户机里的 `click.py`（`/dev/uinput` 造一个绝对定位指针，Mutter 当真设备处理）；xdotool 只能点到 XWayland，测不了焦点
- 驱动开发版：`linux/scripts/cicadactl`（state、start、feed、sample、view、show、windows…）
- 需要真人和真机：x86_64 真机、真实声卡和蓝牙耳机、KDE 等其他桌面、真实会议软件的屏幕共享

### 已验证（2026-11-04，Ubuntu 24.04.5 arm64，GNOME 46 Wayland，PipeWire 1.0.5）

- 引擎：25 个单元测试；Mac 上 94 份记录有 93 份读进来再写出去逐字节不变（剩下那份本来就不是 Mac 的格式）；英语片段真实调用 Ming 和 Ling，8 句全对，最终纪要正确
- 干净的 Ubuntu 桌面自带 `python3-gi`、GTK 3 typelib、`libpulse0`、AppIndicator 的 C 库，不用装任何东西
- 抓声音：别的 app 播放英语、中文片段，系统声音模式 8 句都识别、翻译，实时纪要和最终纪要都出来了；`smoke.sh` 通过
- 纪要窗：在最大化的窗口之上；真实点击（uinput）纪要窗正文和“字幕”链接，会议 app 一次也没失去焦点，之后打的字进了会议 app；拖动能移动窗口；字幕条在屏幕底部，高度贴合文字
- 引导四步、示例会议、会议记录、设置、托盘菜单；中文和英文界面都看过
- `install.sh` 装到 `~/.local`，从菜单项启动正式版

全面测试（54 张截图和逐项结果在 `~/Downloads/cicada-linux-test-20261104/README.md`）又覆盖了：key 校验的各种输入、删除和重填 key、没 key 时开始听、改名、导出、删除、读 Mac 的记录并补生成纪要、设置各项、四种界面语言、单实例、托盘退出、听的途中退出、声音服务停掉、Ling 连不上再恢复。测试中修了 10 个问题。其中两个别的平台也有：会外“生成纪要”的语言固定是中文（纪要语言只在开始听时设置，Windows 和 Android 都是）；导出的标题不用用户改的名字（只有 Android）。

还没验证：x86_64 真机、22.04、真实声卡切换输出设备、KDE、会议软件的屏幕共享、导出对话框和重命名的实际点击、`.github/workflows/linux.yml` 还没在 GitHub 上跑过。

## 界面重设计（2026-11-04）

设计稿在 claude.ai 画布“知了 Linux 版界面重设计”，按 GNOME HIG 做：每个窗口一个标题栏放主要操作，设置是分组列表（左标题右控件），空状态是状态页，图标用系统符号图标，导出、删除用底部提示条（删除可撤销 8 秒）。文案先由 gemini-4-argon 改了一轮（保留 Mac 已有的术语），英日韩翻译也由它完成后人工核对。逐项截图和结果在 `~/Downloads/cicada-linux-redesign-20261104/README.md`。

实现中的发现：

- Ubuntu 桌面版没装 `python3-gi-cairo`，GTK 的 cairo 绘图在 Python 里用不了；波形改成纯控件。
- GTK 3 的 `show_all()` 会跳过设了 no-show-all 的控件，哪怕直接对它调用；需要按状态显示的行要自己管可见性。
- 弹出菜单打开时插入新的输入设备会关掉菜单（测试工具的点击会这样）；菜单项用键盘选。
- 纪要窗跟随系统深色；主窗口和设置保持浅色，和系统里其他 GTK 3 应用一样（它们跟 GTK 主题，不跟深色开关）。
- 虚拟机的 QEMU 用户网络在大量短 ssh 连接后会卡死，`vmctl.sh` 改为复用一条连接（ControlMaster）。

## 常见坑的排查（2026-11-04）

逐项截图在 `~/Downloads/cicada-linux-pitfalls-20261104/README.md`。

| 坑 | 结果 |
|---|---|
| 全屏视频盖住纪要窗 | 不会：聚焦的全屏 Wayland 窗口之上纪要窗仍在 |
| 会中换输出设备（插耳机、连蓝牙） | PipeWire 自己把流跟过去；纯 PulseAudio（22.04）不会，所以每 3 秒用 libpulse 查默认输出，变了就重连。实测切换后继续出字幕 |
| 休眠唤醒、声音服务重启 | 以前直接结束；现在 20 秒内自动重连，实测重启 pipewire-pulse 后 1 秒接上 |
| 125% / 150% 缩放发糊 | XWayland 窗口会被放大，文字比系统的虚。GNOME 46 没有办法；GNOME 47 起的 `xwayland-native-scaling` 能解决。为了置顶和不抢焦点仍走 XWayland，暂不改 |
| 中文输入法 | ibus 拼音在搜索框、重命名里正常（预编辑和候选框都在） |
| 长会议 | 以前 1500 句的记录打开要 0.4 秒，会中每来一句整页重建 0.5 秒；改成只更新变了的行、长文字记录分批加载后，打开 15 ms，每句 2 ms。听的时候 CPU 约 7%（一个核），内存约 150 MB |
| 日文汉字用了中文字形 | CSS 不再指定中文字体，每段文字标上自己的语言，fontconfig 选对应的 CJK 字体 |

顺带做了：Ctrl+F 搜索、Ctrl+, 设置、Ctrl+Q 退出、Esc 关设置；`cicada --toggle` 开始 / 结束听，设置里一键添加 GNOME 快捷键 Super+Shift+C（实测按键有效）；采集流在系统里显示为“知了 · 系统声音”；日志移到 `~/.local/state/cicada/`；卸载会删掉登录自启动和快捷键。

虚拟机：QEMU 静音音频后端的计时器让主循环空转（宿主 CPU 约 97%），几十分钟后网络转发卡死；`timer-period=20000` 之后空闲 CPU 约 1%。

## 同声传译（2026-11-04）

- 知了 麦克风：`module-null-sink cicada_room` + `module-remap-source cicada_mic`（描述“知了 麦克风”），开着时设成默认输入，所以会议软件选“默认”也能用。原来的默认输入记在 `~/.local/state/cicada/real-mic`，关掉、退出、SIGTERM / SIGHUP、被杀后下次启动都会还回去。
- 开始 / 停止是切换，不是按住：GNOME 的 Wayland 不给普通应用全局按键事件。入口：纪要窗的麦克风、托盘、Super + Shift + S（`cicada --speak`，没在运行就先启动再开始说）。
- 一句：分段 → Ming 音频模型（ORIGINAL / TRANSLATION 两行，两行都有、译文不同于原文且是目标文字才算）→ Ming TTS 流式 24 kHz → 知了 麦克风。翻译三路并行，按顺序说；下一句的声音在上一句播完前开始取。
- 回声：听的同时记录系统声音的响度，一句里一半以上时间系统在放声音就丢掉，并提示“对方在说话时说的，没有说出去”。这也会丢掉戴耳机时和对方抢话的那句，所以设置里有“戴着耳机”，打开就不丢。
- 停止说：说完按停止，已经说完的句子照样传出去（和 Mac 松开按键一样）；关掉同声传译或退出时，排队的句子不再说。
- 虚拟机实测（假麦克风播 8 句中文、连续不停顿）：对方第一次听到声音在一句说完后 3.3–5.9 秒，8 句都没有越积越多（改并行前会涨到 13 秒）；录下知了 麦克风再识别回来，8 句英文都对。漏音测试 7 句全部丢掉；打开“戴着耳机”后抢话的 7 句都传出去。
- 没测：真麦克风和真人说话、真会议软件（Zoom / Meet / Teams 选知了 麦克风）、蓝牙耳机切换配置时默认输入的变化。

## 说话人识别（2026-11-04）

- 和 Mac 用同一个声纹模型、同一套规则：每句一个 256 维声纹，阈值 0.5 并入最近的人、2 秒以上又不像谁才算新的人，一个人有 5 句、至少两个人时才出现“说话人 N”，Ling 从称呼里认名字（同一提示词、同一证据检查），改名 / 合并 / 改给别人都能撤销，记录格式字段（`voice`、`voiceNames`、`voiceGuesses`）逐字节一致。
- 推理：Ubuntu 桌面只有 FFTW、没有 BLAS，也没有编译器，Python 跑 ResNet34 一句要几分钟。用户说“打包到安装包里，尽量对齐”，所以没有引入 numpy，而是自己写 C（`native/voiceprint.c`：Kaldi fbank、分块 im2col + GEMM、pthreads 最多 4 线程、用完即释放），权重由 ONNX（哈希固定）转成 fp16。CI 在 22.04 上为 x86_64 和 aarch64 各编一个 `.so`（需要 glibc 2.34，22.04 是 2.35）。GEMM 内循环向量化（GCC 报告：aarch64 NEON 16 字节，x86_64 SSE 16 字节 + AVX2 32 字节的 `target_clones` 版本，按 CPU 选；x86_64 只交叉编译过，没在真机上跑）。
- 对齐验证：7 段 0.8–30 秒的真实音频，C 和 Mac 的 Core ML 声纹余弦相似度都是 1.0000（Mac 和 VM 上都测了）；单元测试拿一段固定音频和 Core ML 的参考声纹比。
- 速度（4 核 arm64 虚拟机，宿主机当时负载很高）：5 秒一句约 0.27 秒（单线程 0.9 秒），20 秒约 1.1 秒；和 Ming 识别同时算，不加字幕延迟。CPU 跟不上时（排队两句以上）新句子不标人，字幕不等。
- 虚拟机实测（Ming 合成的三人会议，真实声音链路）：英文 22 句全部标对（George / Emma / Charlotte，两位女声也分开了），三个名字 Ling 都认对；中文 27 句 25 句标对，2 句短的半句留作“未识别”，没有标错人，名字也认对（“小锋”按转写写成“小峰”）。
- 没测：真人声音（测试音频都是 Ming 合成的）、真会议（AMI 那种多人抢话）、x86_64 真机速度、22.04 上加载 CI 编的 `.so`、CI 本身（工作流改了还没跑）、Mac app 读 Linux 写的带声纹记录（只用 Python 逐字节比过，Mac 编译当时被别的会话的改动卡住）。
- 已知：会议进行中有人刚凑够 5 句、或 Ling 的名字到了，记录页会整页重建，正开着的改名弹窗会被关掉。
- 测试虚拟机装了 `build-essential` 和 `gcc-x86-64-linux-gnu`（编 `.so` 用），不再是干净的桌面；验证“不用终端、不用编译器”要用新虚拟机或先卸掉。

## 里程碑

| 阶段 | 产出 | 怎样算完成 |
|---|---|---|
| **M1 字幕** | 抓声音 → 分段 → Ming → 纪要窗 / 字幕条 | 虚拟机里播放的声音变成字幕；点纪要窗后焦点还在原来的窗口；纪要窗在最大化窗口之上 |
| **M2 纪要和记录** | 纪要、记录、引导、设置、托盘、四种界面语言 | Mac 的记录 Linux 能读，写出去逐字节一致 |
| **M3 能发布** | `.deb`（声明依赖）、官网下载入口、x86_64 真机测试、CI | 一台干净的 Ubuntu 从下载到第一次出字幕不用开终端 |
| 以后 | 流式识别、按住说话（需要全局按键）、跨会议记住声音、Flatpak | 按反馈排 |

## 风险

1. **XWayland 以后被拿掉**：GNOME 已经在讨论默认不启动 XWayland。到时纪要窗只能当普通窗口，用户自己在窗口菜单里点“置顶”。应对：`GDK_BACKEND` 只在有 `DISPLAY` 时才设，没有就退回原生 Wayland，功能照常，只是不置顶。
2. **共享屏幕时纪要被看到**：见上文，只能提示。
3. **其他发行版和桌面**：只承诺 Ubuntu LTS + GNOME；KDE、Xfce 的托盘和置顶通常更好，但没测。
4. **Ming 的成本和延迟、国内网络**：同 Windows。
