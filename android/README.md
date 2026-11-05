# 知了 Android 版

Cicada 的 Android 版：把手机里播放的声音（或面对面时麦克风听到的话）变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录。面对面时按住“按住说话”说一句，松开后手机用对方的语言读出来。方案和取舍见 [docs/android-plan.md](../docs/android-plan.md)。

- 声音来源：手机里的声音（`AudioPlaybackCapture`，Android 10 起，排除知了自己；会议和通话 app 系统不让采集）或面对面（麦克风）。
- 识别：Ming（`Ming-3.0-audio-flash`）分段识别，一次请求返回语言、原文和译文；需要 Ling key。和 Windows 版同一套做法。
- 悬浮窗：纪要或字幕条，`FLAG_NOT_FOCUSABLE` 不抢输入，`FLAG_SECURE` 默认不出现在截图和录屏里；打开“共享屏幕时让对方看到”后显示“对方可见”。
- 纪要、记录格式（逐字节和 Mac 一致）、提示词、文案都和 Mac 版一致；英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Android 独有的在 `app/src/main/strings/`。
- 检查更新：每天在后台查一次 GitHub Releases，有新版本时在首页、设置和通知里提示，点“更新”用浏览器下载 APK，由系统安装器覆盖安装（签名一致才行），不需要安装权限。
- 只用 Kotlin 标准库和 Android 框架，不用 AndroidX、Compose 或其他库。

## 目录

| 路径 | 内容 |
|---|---|
| `core` | 不依赖 Android 的引擎（纯 JVM，Mac 上能编译、运行、测试） |
| `cli` | 单元测试，以及在 Mac 上用 WAV 跑完整流程、检查会议记录 |
| `app` | Android 应用：前台服务和通知、悬浮窗、会议记录、设置、引导（代码写界面，不用 XML 布局） |
| `tools/player` | 测试用的小播放器（不发布）：像视频 app 一样播放 WAV，给“手机里的声音”当声源 |

## 命令（在 Mac 上）

```bash
scripts/install-sdk.sh        # 一次：JDK、Gradle、Android SDK、模拟器装到 ~/.cicada-android，不用 sudo；版本固定，下载都校验哈希；--old 再装一个 Android 10 模拟器
scripts/test.sh               # 单元测试
scripts/build.sh              # 开发版 build/Cicada-dev.apk（com.wquguru.cicada.dev）；RELEASE=1 出签名的 build/Cicada-<版本>-Android.apk
scripts/keystore.sh           # 一次：生成发布签名密钥（~/.cicada-android/release.jks，密码在钥匙串）；--github 顺便存进 Actions secrets。文件和密码都要备份，丢了就没法给已装的人升级
python3 scripts/strings.py    # 查缺翻译的文案（--write 追加 TODO）
scripts/cli.sh listen ../windows/spike/clips/en.wav --target zh-CN --notes   # 真实调用 Ming 和 Ling
scripts/cli.sh roundtrip ~/Library/Application\ Support/LiveSubs/Sessions/*/session.json
```

`cli.sh` 读 Mac 版的 key 文件，不打印 key；环境里的代理会传给 Java。`gradle.sh` 自己设好 `ANDROID_HOME`，不需要 `local.properties`。

## 在模拟器里验证

```bash
scripts/emulator.sh                 # 启动 cicada 模拟器（AVD=cicada29 是 Android 10；HEADLESS=1 不开窗口；走本机代理）
scripts/build.sh && scripts/install.sh   # 装开发版，授好麦克风、通知、悬浮窗
scripts/cicadactl.sh key            # 把 Mac 版的 Ling key 放进去
scripts/cicadactl.sh sample         # 示例会议；state 看状态，log 看日志
scripts/cicadactl.sh start playback && scripts/consent.sh   # 听手机里的声音（替人点系统授权）
scripts/shot.sh                     # 截图：悬浮窗应是黑块；capture on 之后能看到并带“对方可见”
scripts/tap.sh "开始听"             # 按屏幕上的文字点（系统对话框也行），用来走真实界面
```

`cicadactl.sh` 的命令见 `app/src/main/kotlin/com/wquguru/cicada/DebugReceiver.kt`（state、start、stop、feed、sample、view、capture、overlay show|hide|collapse|expand、target、ui、show main|live|records|record|settings|onboarding、import、updatefeed、update check|download|job|notify）。只有开发版有，且只接受 adb。开发版默认不检查更新（点设置里的“检查更新”或用下面的命令后才查）：`cicadactl.sh push feed.json && cicadactl.sh updatefeed feed.json` 指向一份测试用的 release JSON（不带参数就是 GitHub），`adb shell cmd jobscheduler run -f com.wquguru.cicada.dev 7` 立刻跑一次后台检查。

界面按 claude.ai 上的设计画布实现：首页、正在听、悬浮窗（纪要卡片 / 字幕条 / 小圆点）、三步引导、会议记录、会议详情、设置。文案用 Gemini（`google/gemini-4-argon`）审过一遍，与 Mac 共用的文案沿用 Mac 的译法。

播放其他 app 的声音：`adb push clip.wav /sdcard/Music/`，装上 `tools/player`（`scripts/gradle.sh :tools:player:assembleDebug`，`adb install -g`），再 `am start -n com.wquguru.cicada.player/.Play -d file:///sdcard/Music/clip.wav`。Android 14 以上的模拟器也可以用自带的 YouTube Music 预览。注意：目标 SDK 低于 29 的 app（比如 Android 10 模拟器自带的 Play Music）系统一律不让采集；Android 10 模拟器里的 Chrome 也采集不到。

调试接收器只在开发版的 manifest 里（`app/src/debug/`），没运行或被强行停止时 `cicadactl.sh` 也能叫醒它。

需要真人和真机：系统授权对话框和厂商系统的后台限制、面对面模式和“我说”的真实声音（模拟器拿不到 Mac 的麦克风），以及手机外放读出来时会不会被自己的麦克风听进去、蓝牙耳机。
