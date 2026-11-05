# 测试小工具

开发版（`scripts/build.sh`，bundle id `com.wquguru.cicada.dev`）默认就接受这些调试命令，日志在 `/tmp/livesubs-dev-debug.log`。
正式版需要先打开调试模式：`defaults write com.wquguru.cicada debug -bool true`，然后重启 App；日志在 `/tmp/livesubs-debug.log`。

编译：`swiftc -O lsctl.swift -o lsctl`（其他几个文件同理）。

- `lsctl <命令>`：通过分布式通知 `com.wquguru.cicada.debug` 遥控 App。
  - 开关字幕：`start` / `stop`
  - 听哪里：`listenSource:<system|room>`（room 用麦克风听会议室，日志里 `room mic started: <设备>`，念译文时 `room mic muted` / `open`），`roomPrompt:<room|no>` 等于在“在会议室里开会？”里点“改听会议室”或“不是”（听电脑 60 秒没声音才出现，日志 `mac silent true`）
  - 打开界面：`open`（主窗口）、`panel`（菜单栏面板）、`settings[:speak]`（设置，可指定栏目）
  - 虚拟麦克风：`micTest` 试音（往虚拟麦克风播一句再听回来，结果写进日志），`micNext` 做清单里的下一步
  - 会议软件的麦克风：`micUsers` 把每个读麦克风的进程和列表写进日志，`micGuide:<bundle id 或名字>` 打开怎么改，`micGuideRender:<bundle id>=<png>`
  - 快捷键：`talkKey:right` 或 `talkKey:<keyCode>:<Carbon 修饰键>` 换说话键（被拒的原因写进日志），`toggleKey:…` 同理，`shortcuts` 把当前状态写进日志
  - 字幕条：`frame` 把位置写进日志，`place:x,y,宽,字号` 摆到指定位置
  - 系统麦克风：`sysMic` 把状态、默认输入、要换回的麦克风和知了实际在录的麦克风写进日志，`sysMicSet:<设备名片段>` 假装别人改了系统麦克风，`sysMicRestore` 还原，`sysMicSwitch` 换成虚拟麦克风，`sysMicAuto:<on|off>`，`speakMic:<设备名片段>` 固定知了用的麦克风（留空 = 自动）。会改本机的系统麦克风：测完 `sysMicRestore` 或退出 App
  - 说话同传：`speakOn` / `speakOff` 开关，`speakAsk[:off]` 面板里第一次打开时的确认卡，`speakConfirmed:<on|off>` 是否已确认过，`speakFile:<音频>` 把文件按实时速度当作麦克风输入，`speakOut:<路径>` 把译文语音另存一份，`speakOutput:<设备名片段>` 改输出设备（留空 = 虚拟麦克风）
  - 试一句：`speakTest:sample`（Mac 读一句示例）或 `speakTest:voice`（再发 `speakTestBegin` / `speakTestEnd` 当作按住、松开），结果以 `speak test:` 写进日志；`speakTestState`、`speakTestRender:<png>`、`speakTestClose`
  - 识别引擎：`recognizer:legacy` 在 macOS 26 上改用 14 / 15 的识别（`SFSpeechRecognizer`，第一次会要“语音识别”权限），`recognizer:auto` 换回；下一次开始听起生效（或启动时 `open --env CICADA_RECOGNIZER=legacy`），日志里 `transcriber started recognizer=…`
  - 多开：两边都设 `CICADA_DEBUG_CHANNEL=x`（`open -n --env CICADA_DEBUG_CHANNEL=x build/Cicada.app`），命令只发给这一份，日志在 `/tmp/livesubs-dev-debug-x.log`
  - 导出：`export:<目录>`
  - 导入录音或视频：`import:<路径>[,<路径>…]`（等于拖进会议记录窗口），`importState` 把进度写进日志，`importCancel` 停止转写，`importRetry:<会议 id>[=<locale>]` 重新转写（带 locale 等于在“这场会议只留下了录音”里选了这种语言），`importNotify` 把通知权限写进日志
  - 新手引导与窗口：`onboarding:<步骤>[,skip|ask|setup]`（1–5，5 是收尾页；skip 是第 3 步点了“先不接”，ask / setup 是第 4 步的二选一 / 清单）、`samplePlay`、`speakers:<on|off>`（“说话人识别”）、`speakerGuess:<会议 id>`（马上让 Ling 认一遍名字）、`speakersRender:<会议 id>=<png>`、`voiceprintFile:<音频>=<json>`（用 app 里的声纹模型算整个文件的声纹，和参考模型对比）、`closeWindow:<main|settings|onboarding>`、`settings:<overlay|language|speak|records|ai|diagnostics>`、`about`
  - 显示与字幕：`display:<notes|bar|none>`、`subtitles:<both|translation|original>`、`meetingSubtitles:<…>`、`overlayState`、`overlayToggle`、`pillClick`（等于点主窗口顶部的“正在听”）、`overlayAuto[:off]`、`hideAfter:<秒>`
  - 纪要：`notesLang:<mine|source>`、`meetingNotesLang:<…>`、`notesRegenerate:<id>=<mine|source>`、`notesWindow[:x,y,w,h]`、`notesClose`、`notesMinimize`、`notesFrame`、`notesNow`、`notesState`、`notesShow:<id>`、`notesReplay:<id>`、`notesCapturable[:off]`（只改窗口能否被截屏）、`notesShare:<on|off>`（改“共享屏幕时让对方看到”这个设置，等于点图标或开关）
  - 结束会议：`endSim:<应用名>[,…]` 假装这些会议应用在通话（`endSim:` 全部挂断，`endSim:off` 回到真实情况），`endTimes:<静默秒>,<倒计时秒>,<挂断宽限秒>` 缩短等待（`endTimes:` 回到设置），`endKeep` 等于点“继续记录”，`endState` 写进日志
  - 渲染（不需要录屏权限）：`panelRender:<png>`（菜单栏面板，离屏画）、`windowsRender:<目录>`、`settingsRender:<栏目>=<png>`、`notesRender:<png>`、`mainShow:<id>[,transcript]`、`mainWindow:x,y,宽,高`（摆好主窗口并暂时浮在最上层，方便模拟点击；不带参数恢复）、`mainRender:<png>`、`speakTestRender:<png>`
  - AI：`aiKeyFile:<路径>`（从 0600 文件读 key，不经过日志；测完就删掉文件）、`aiCheck`、`aiRemove`、`aiHide:<on|off>`（只在内存里当作没有 key，文件不动；用于截图）、`aiState`、`lingSimulate:<429|hijack|timeout|off>`、`translateFail:<n>`（接下来 n 句在所有翻译来源都失败，用来测重试）
  - 声音：`voice:<语言>[=<id>]`、`voicePreview:<语言>=<id>`、`voiceCloneFile:<wav>`、`voicePicker:<on|off>`
  - 诊断：`diagnostics:<on|off>`、`diagReport`
  - 语音模型与“听不出”：`models:<已装,…>/<系统语言,…>` 假装本机只装了这些语音模型、系统是这些语言（`models:none/zh-Hans-CN` 是一个都没装，末尾加 `@<秒>` 让后台下载至少花这么久；之后下载的会加进来），`models:off` 回到真实情况；`source:<auto|locale>` 改“听到”（自动识别或指定语言），`pickLanguage:<locale>` 等于在“听不出”里点这种语言，`releaseModel:<locale>` 退还一个本 App 保留的语音模型。`modelFail:<offline|disk|limit|other>` 让之后的语音模型下载都按这个原因失败（`modelFail:off` 结束），`network:<on|off|real>` 假装断网、联网或跟随真实网络，`modelRetry` 等于点“再试一次”。用没装过的语言（比如法语）能测真实的后台下载；注意 macOS 每个 App 最多保留 5 种语音模型
  - 更新与登录项：`updateFeed:<url>`、`updateCheck`、`updateInstall`、`updateState`、`loginItem[:on|off]`
  - 完整、最新的清单以 `AppModel.debugCommand` 里的 `switch` 为准。

- `macos-vm/vm.sh setup|start|deploy|listen|ssh|stop`：macOS 14 测试虚拟机（tart，镜像实际是 14.5），在旧识别引擎上跑开发版。第一次 `setup`（约 18 GB），之后 `start`、`deploy`（装 `build/Cicada.app`）、`listen en.aiff`（片段放在 `~/VMs/share`）。截图用 `screencapture -l <tart 窗口 ID>`，点按用虚拟机里的 `~/bin/mouse`。虚拟机的声卡带麦克风，开始听时会先弹“麦克风”权限。

## 测试技巧

- 英文界面：`defaults write com.wquguru.cicada.dev AppleLanguages -array en` 后重启，测完 `defaults delete com.wquguru.cicada.dev AppleLanguages`；或启动时加 `--args -AppleLanguages "(en)"`。
- 纪要窗口不出现在截屏里：先发 `notesCapturable` 再 `screencapture -l`，或直接 `notesRender:`。
- 合成的按键会发给所有 App：别的 App 的启动器可能抢走 ⌥ Space。模拟鼠标和按键需要终端有“辅助功能”权限。
- 试一句可以测整条同传链路和延迟：`speakTest:sample` 连发几次，读日志里的 `speak test:` 行。
- 端到端测更新：把根目录的 `VERSION` 调高再构建（构建完改回去），`ditto -c -k --keepParent build/Cicada.app Cicada-<v>-macOS-AppleSilicon.zip`，`shasum -a 256` 写进 `checksums.txt`，写一个资源地址用 `file://` 的 release JSON，从 scratchpad 运行旧版开发版（不要用 `build/` 里的），再 `updateFeed:file://…` 和 `updateInstall`。
- `mouse move|drag|dclick|click|scroll ...`：模拟鼠标移动、拖动、双击、单击、滚轮（`scroll x y 行数`，正数往上翻），坐标原点在主屏左下角。
- `key`：模拟按住说话键。`key right [秒]` 单按右 ⌥；`key <keyCode> <Carbon 修饰键> [秒]` 按组合键（如 `key 122 0` 是 F1）；不带参数是 ⌥ Space。
- `toggle-key`：模拟按一下 ⌃⌥S。
- `winall <pid>`：列出某个进程的窗口 ID，配合 `screencapture -l <ID>` 截图。
- `transcribe <音频> <locale>`：用本机模型转写一个文件，用来核对输出。


