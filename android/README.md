# 知了 Android 版

Cicada 的 Android 版：把手机里播放的声音（或面对面时麦克风听到的话）变成双语字幕和实时纪要，存成和 Mac 版同一格式的会议记录。面对面时按住“按住说话”说一句，松开后手机用对方的语言读出来。方案和取舍见 [docs/android-plan.md](../docs/android-plan.md)。

- 声音来源：手机里的声音（`AudioPlaybackCapture`，Android 10 起，排除知了自己；会议和通话 app 系统不让采集）或面对面（麦克风）。
- 识别：分段发给 AI 服务的“听的模型”，一次请求返回语言、原文和译文。默认 Ling 的 Ming（`Ming-3.0-audio-flash`，片段压成 AAC 再传）；用不了 Ling 时可在 设置 › AI 服务 或引导里换成 OpenRouter、ZenMux 或兼容 OpenAI 的自建服务（`core/.../Providers.kt`，推荐 Qwen 3.8 Omni Flash，比 Ming 慢 1–2 秒，片段按 WAV 传，流量大约是 AAC 的 10 倍）。纪要和翻译跟着换；“我说”在有声音模型的服务上用它的声音（OpenRouter、ZenMux 是 Gemini），其余用手机自带的声音；只有“你自己的声音”只能用 Ling。都需要一个 key（自建服务在这台手机或局域网里时可不填，也可以用 http），声音都会发到所选服务（自建服务的听的模型可以另填地址）。和 Windows、Linux 同一套做法。
- 悬浮窗：纪要或字幕条，`FLAG_NOT_FOCUSABLE` 不抢输入，`FLAG_SECURE` 默认不出现在截图和录屏里；打开“共享屏幕时让对方看到”后显示“对方可见”。
- 纪要、记录格式（逐字节和 Mac 一致）、提示词、文案都和 Mac 版一致；英日韩翻译直接用 `Resources/*.lproj/Localizable.strings`，Android 独有的在 `app/src/main/strings/`。
- 检查更新：每天在后台查一次 GitHub Releases，有新版本时在首页、设置和通知里提示，点“更新”用浏览器下载 APK，由系统安装器覆盖安装（签名一致才行），不需要安装权限。
- 说话人识别（默认打开，和 Mac 一样）：每句话的声音在手机上算一个声纹，按 Mac 的阈值分组，标出说话人 1、2…，Ling 从对话里认出名字。声纹模型和 Mac 是同一个（WeSpeaker ResNet34-LM，VoxCeleb，CC BY 4.0）；推理用 Linux 版自己写的 C（`linux/native/voiceprint.c`），由 NDK 编成 `libcicada-voice.so`（arm64-v8a、armeabi-v7a、x86_64），权重是 `linux/models/voiceprint.bin`（13 MB），构建时拷进 assets。库加载不了时只显示别处分好的说话人，听照常。
- 只用 Kotlin 标准库和 Android 框架，不用 AndroidX、Compose 或其他库；唯一的原生库是上面自己写的 C。

## 目录

| 路径 | 内容 |
|---|---|
| `core` | 不依赖 Android 的引擎（纯 JVM，Mac 上能编译、运行、测试） |
| `cli` | 单元测试，以及在 Mac 上用 WAV 跑完整流程、检查会议记录 |
| `app` | Android 应用：前台服务和通知、悬浮窗、会议记录、设置、引导（代码写界面，不用 XML 布局） |
| `tools/player` | 测试用的小播放器（不发布）：像视频 app 一样播放 WAV，给“手机里的声音”当声源 |

## 命令（在 Mac 上）

```bash
scripts/install-sdk.sh        # 一次：JDK、Gradle、Android SDK、NDK、模拟器装到 ~/.cicada-android，不用 sudo；版本固定，下载都校验哈希；--old 再装一个 Android 10 模拟器
scripts/test.sh               # 单元测试
scripts/build.sh              # 开发版 build/Cicada-dev.apk（com.wquguru.cicada.dev）；RELEASE=1 出签名的 build/Cicada-<版本>-Android.apk
scripts/keystore.sh           # 一次：生成发布签名密钥（~/.cicada-android/release.jks，密码在钥匙串）；--github 顺便存进 Actions secrets。文件和密码都要备份，丢了就没法给已装的人升级
python3 scripts/strings.py    # 查缺翻译的文案（--write 追加 TODO）
scripts/cli.sh listen ../windows/spike/clips/en.wav --target zh-CN --notes   # 真实调用 Ming 和 Ling
scripts/cli.sh roundtrip ~/Library/Application\ Support/LiveSubs/Sessions/*/session.json
```

`cli.sh` 读 Mac 版的 key 文件，不打印 key；环境里的代理会传给 Java。`--provider zenmux|openrouter`（可加 `--hear-model <id>`）换 AI 服务，读对应的 `ai-key-<服务>`；`cli.sh say <wav> --to en --provider zenmux` 把一句话听写、翻译，再用服务的声音读成 WAV。`gradle.sh` 自己设好 `ANDROID_HOME`，不需要 `local.properties`。

## 在模拟器里验证

```bash
scripts/emulator.sh                 # 启动 cicada 模拟器（AVD=cicada29 是 Android 10；HEADLESS=1 不开窗口；走本机代理）
scripts/build.sh && scripts/install.sh   # 装开发版，授好麦克风、通知、悬浮窗
scripts/cicadactl.sh key            # 把 Mac 版的 Ling key 放进去
scripts/cicadactl.sh provider zenmux && scripts/cicadactl.sh aikey ai-key-zenmux   # 换成 ZenMux，并把 Mac 版的 ZenMux key 封进去（明文副本随即删掉）
scripts/cicadactl.sh sample         # 示例会议；state 看状态，log 看日志
scripts/cicadactl.sh start playback && scripts/consent.sh   # 听手机里的声音（替人点系统授权）
scripts/shot.sh                     # 截图：悬浮窗应是黑块；capture on 之后能看到并带“对方可见”
scripts/tap.sh "开始听"             # 按屏幕上的文字点（系统对话框也行），用来走真实界面
```

`cicadactl.sh` 的命令见 `app/src/main/kotlin/com/wquguru/cicada/DebugReceiver.kt`（state、start、stop、feed、sample、view、capture、overlay show|hide|collapse|expand、target、ui、show main|live|records|record|settings|ai|onboarding、import、provider、ai-model（hear|text|voice|notes）、ai-base、ai-notes same|own、ai-notes-base、notes-key import|remove、ai-custom-only on|off、key import、voice-try、updatefeed、update check|download|job|notify，以及改正听错的词的 fixes on|off、asknames on|off、silent、heard、vocab add|remove|state、fixstate、fixanswer yes|no、fixrevert、fixlater、fixundo、fixedit、pinyin，分享链接的 share <id>[,full][,pw]、unshare、shares、shareSheet、delete、shareserver、clipboard，存到文件夹的 export state|pick|folder <tree uri>|all|retry|off）。`export pick` 打开系统的文件夹选择器（“使用此文件夹”和“允许”可以用 `tap.sh` 点）；`export folder` 只接受已经授权过的 tree URI，没授权时显示“找不到”那一行。`share` 用正式的 cicada.indaloop.app（`adb reverse tcp:<端口> tcp:<端口>` 后 `shareserver http://127.0.0.1:<端口>` 改指本机的 wrangler dev（模拟器走代理时 10.0.2.2 连不上），另用 files/share-device-local.json），设备只注册一次（files/share-device.json，别删）；测试只用合成的会议记录，用完 unshare。`silent` 开一场没有声音的会，`heard <一句话>` 当作听到一整句，翻译和改词都走当前的 AI 服务，不用放声音。只有开发版有，且只接受 adb。开发版默认不检查更新（点设置里的“检查更新”或用下面的命令后才查）：`cicadactl.sh push feed.json && cicadactl.sh updatefeed feed.json` 指向一份测试用的 release JSON（不带参数就是 GitHub），`adb shell cmd jobscheduler run -f com.wquguru.cicada.dev 7` 立刻跑一次后台检查。

界面按 claude.ai 上的设计画布实现：首页、正在听、悬浮窗（纪要卡片 / 字幕条 / 小圆点）、三步引导、会议记录、会议详情、设置。文案用 Gemini（`google/gemini-4-argon`）审过一遍，与 Mac 共用的文案沿用 Mac 的译法。

播放其他 app 的声音：`adb push clip.wav /sdcard/Music/`，装上 `tools/player`（`scripts/gradle.sh :tools:player:assembleDebug`，`adb install -g`），再 `am start -n com.wquguru.cicada.player/.Play -d file:///sdcard/Music/clip.wav`。Android 14 以上的模拟器也可以用自带的 YouTube Music 预览。注意：目标 SDK 低于 29 的 app（比如 Android 10 模拟器自带的 Play Music）系统一律不让采集；Android 10 模拟器里的 Chrome 也采集不到。

调试接收器只在开发版的 manifest 里（`app/src/debug/`），没运行或被强行停止时 `cicadactl.sh` 也能叫醒它。

需要真人和真机：系统授权对话框和厂商系统的后台限制、面对面模式和“我说”的真实声音（模拟器拿不到 Mac 的麦克风），以及手机外放读出来时会不会被自己的麦克风听进去、蓝牙耳机。
