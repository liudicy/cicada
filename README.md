<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="知了图标">
</p>

<h1 align="center">知了 · Cicada</h1>

<p align="center">
  任何会议、任何直播，没有语言障碍。<br>
  听得懂，说得出，记得住。Mac 上的实时纪要、双语文字记录、字幕与同声传译。
</p>

<p align="center">
  <a href="https://cicada.indaloop.app"><img src="https://img.shields.io/badge/官网-cicada.indaloop.app-E8552B?style=for-the-badge" alt="官网 cicada.indaloop.app" height="36"></a>
  &nbsp;
  <a href="https://github.com/wquguru/cicada/releases/latest"><img src="https://img.shields.io/badge/下载-macOS 版-15171C?style=for-the-badge&logo=apple&logoColor=white" alt="下载 macOS 版" height="36"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20silicon-only-black" alt="Apple 芯片">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0">
</p>

<p align="center"><a href="README.md">简体中文</a> · <a href="README.en.md">English</a></p>

无论是用 Zoom、飞书、腾讯会议开会，还是听 X Spaces 和 YouTube 直播，知了都能实时给出双语字幕、边听边写结构化纪要。遇到需要发言的时候，按住键盘右边的 `⌥` 键开口，对方就能在会里直接听到翻译好的语音。这一切都靠直接读取 Mac 系统声音并在本机识别来完成，声音不出电脑，不用往会里塞机器人，对方更是完全无感。

<p align="center">
  <img src="docs/demo.gif" width="800" alt="YouTube 播着 Bloomberg 英文直播，右边是知了实时整理的中文纪要、议题与鱼骨图，底部是双语字幕">
</p>

## 主要功能

### 实时纪要与双语文字记录

开会时纪要窗口边听边整理总结、议题要点、结论、待办、鱼骨图和人名术语表，点一下结论或待办就能跳回双语文字记录里的原话。纪要会统一文中人名和术语的写法并记下听错的变体，按 `⌘F` 搜索时能连同识别错的写法一起搜出来。线上会议记录 Mac 播放的声音；大家围坐在会议室里时，把菜单栏面板的“声源”切成“麦克风”，就改用麦克风收录房间里的说话声，纪要和文字记录完全一样。

### 实时字幕与语言识别

对方开口几秒钟就能在本地自动认出语言并翻成你的系统语言，按 `⌃⌥S` 可以在纪要窗口、字幕条和不显示之间切换。字幕条只在有人说话时出现，鼠标划过时自动变透明，不会挡住底下的按钮。

### 同声传译

按住键盘右边的 `⌥` 键说话，对方在会议软件里就能直接听到翻译后的语音，打开同声传译时知了会自动把系统麦克风切到一键安装的虚拟驱动 BlackHole 2ch。填了 Ling API key 后可以用自然人声或用 8 到 30 秒录音克隆你自己的声音，不填也能用 Mac 自带语音。

<p align="center">
  <img src="docs/interpreting.png" width="640" alt="同声传译设置页，包含按住右 Option 键说话、目标语言、Ming 声音试听与本机声音选择">
</p>

### 会议记录

每场会议的双语文字记录、纪要和原始录音都保存在本机，打开实验性的说话人识别后还能区分对方不同的说话人并在有 Ling key 时填上名字。会议软件挂断或 10 分钟没人说话时会自动结束并截掉空白，会后随时可以补生成纪要，或导出成 Markdown、Word 和 SRT 字幕。目前记录里的你只包含按住说话键说的话，会上直接开口的部分见[路线图](#路线图)。

<p align="center">
  <img src="docs/records.png" width="640" alt="会议记录窗口，显示识别出的说话人名字和逐句英中双语文字记录">
</p>

## 隐私与权限

声音采集、语言识别、语音识别（Apple SpeechAnalyzer）和会议录音全部在本机完成。会离开电脑的只有识别出来的文字（发去做翻译和生成纪要），以及填了 Ling API key 并按住说话键用同声传译时你说的那几句语音。不填 API key 时，实时字幕、翻译（走 Google 或退回 Apple 本机翻译）、会议记录和同声传译都能正常用。实时纪要、一步语音翻译和声音克隆需要你自己的 Ling（蚂蚁集团的大模型服务）API key（配置方法见[下文](#配置-ling-api-key)），开一小时会大约花 0.15 到 1 元人民币，Ling 每月赠送 10 元额度，约够 10 到 50 小时会议；翻译和纪要也可以改用任何 OpenAI 兼容接口的模型服务。

知了只在用到某项功能时才请求对应的权限，拒绝后其他功能照常可用。

| 权限 | 用来做什么 | 什么时候问 | 不给的话 |
|---|---|---|---|
| 录制系统声音（屏幕与系统录音） | 听 Mac 正在播放的声音来出字幕，不录屏幕，也不听知了自己的声音 | 新手引导第一步，或第一次开始听 | 字幕和纪要都用不了 |
| 麦克风 | 按住说话键时录音做同声传译；“声源”选了麦克风时收录现场会议的声音 | 打开同声传译，或第一次把声源选成麦克风时 | 不能说话翻译，也不能记录现场会议 |
| 输入监控 | 只用来判断右 `⌥` 是否被单独按下（只监听、不拦截、不记录别的按键） | 第一次用右 `⌥` 说话时 | 在设置里改成 `⌃`/`⌘` 组合键，就不需要这个权限 |
| 管理员密码 | 安装虚拟麦克风 BlackHole 2ch，并重启系统音频服务 | 在引导或设置里点“安装”时，只问一次 | 不能让对方听到翻译，其余照常 |

- **联网与虚拟麦克风**。只有翻译（`translate.googleapis.com`）、填了 key 后的 Ling / Ming（`api.ant-ling.com`）、下载 BlackHole 驱动和每天去 GitHub 检查一次新版本会联网；添加了自定义模型服务商后，也会连你自己填的对应接口地址。BlackHole 从官方下载已经过苹果公证的安装包，安装前会核对代码里写死的 SHA-256。
- **没有统计和自建服务器**。应用没有统计、没有埋点，也没有我们自己的服务器，诊断功能只把耗时和次数记在本机会议文件夹里。
- **本机数据位置**。会议记录、录音和纪要存在 `~/Library/Application Support/LiveSubs`。Ling key 和你录的声音样本只对当前系统账户可读，不进 Time Machine 备份，也不写进日志和导出文件。
- **共享屏幕看不到纪要窗口**。屏幕共享、录屏和截图都拍不到它，要录演示时可以打开“共享屏幕时让对方看到”。

## 用到的模型

不填 Ling key 时全部由 Apple 本机模型加 Google 翻译完成，填了 key 后由 Ling 和 Ming 模型负责并支持失败自动退回。

| 功能 | 填了 Ling key | 不填 key / 退回 |
|---|---|---|
| 语音识别、语言识别 | Apple `SpeechAnalyzer` / `SpeechTranscriber`（本机） | 同左 |
| 整句翻译 | Ling `Ling-3.1-flash`（可在“设置 › AI 服务”改为 `Ling-3.0-flash`，或改用自选服务商的模型） | Google 翻译 → Apple `Translation`（本机） |
| 正在说的半句话的翻译 | Google 翻译（不占 Ling 的频率额度） | Apple `Translation`（本机） |
| 实时纪要、会后完整版 | Ling `Ling-3.1-flash`（同上设置） | 不可用 |
| 检查 key 是否有效 | Ling `Ling-3.0-tiny`（只用一个 token） | — |
| 同声传译：听懂并翻译你说的话 | Ming `Ming-3.0-audio-flash`，一步完成 | Apple 本机识别，再走上面的翻译链 |
| 同声传译：对方听到的声音、声音克隆 | Ming `Ming-3.0-tts-0.5B` | Mac 自带语音（`AVSpeechSynthesizer`），不能克隆 |
| 说话人识别（实验功能，默认关闭） | WeSpeaker ResNet34-LM 声纹模型，随 app 附带，本机运行（Core ML） | 同左 |

## 配置 Ling API key

1. 打开 [Ling 开放平台](https://chat.ant-ling.com/platform/api)，注册或登录。
2. 点创建令牌，复制以 `sk-` 开头的那串 key。
3. 在知了里打开设置里的 AI 服务，粘贴后点保存并检查，也可以直接粘贴到纪要窗口顶部的提示框里。知了会发一个只用一个 token 的请求确认 key 可用。
4. 同一页面可以选模型（默认 `Ling-3.1-flash`），每种语言用哪个 Ming 声音在同声传译设置里选。想移除 key，在同一页面点移除即可。

## 换用自己的模型服务

纪要和翻译不一定要用 Ling：在“设置 › AI 服务”的服务商一行点添加，填名称、接口地址（OpenAI 兼容的 `/v1` 地址）和模型名，就能添加任意 OpenAI 兼容的模型服务，加几个都行，随时在这一行切换，每个服务商的 key 分开只读本机保存。切到其他服务商时，同声传译的 Ming 声音、一步语音翻译和声音克隆是 Ling 专属能力，会自动退回本机识别加翻译、Mac 自带语音。语音识别始终在本机进行。

## 系统要求与安装

需要 macOS 26 或更新版本、Apple 芯片的 Mac。界面有中文、英文、日文和韩文，默认跟随系统语言，也可以在系统设置的语言与地区里单独给知了指定。

从 [Releases 页面](https://github.com/wquguru/cicada/releases/latest) 或 [官网](https://cicada.indaloop.app) 下载 `Cicada-<版本>-macOS-AppleSilicon.dmg`，打开后把知了拖进应用程序文件夹。应用目前是本地签名，还没有苹果公证（见[路线图](#路线图)），第一次打开被拦下时，去系统设置的隐私与安全性里点仍要打开。下载页同时提供 `checksums.txt`，可以用 `shasum -a 256 Cicada-*.dmg` 核对。有疑问可以去 X 找作者 [@wquguru](https://x.com/wquguru)。

打开后跟着首次引导开一个权限、听一段双人示例会议直接看字幕效果、接上 Ling key（也可以先跳过），要用同声传译时再装虚拟麦克风。之后有新版本时菜单栏图标会出现橙点，点一下就能更新，权限不会丢。

<p align="center">
  <img src="docs/onboarding.png" width="640" alt="首次引导第二步，播放双人示例会议并实时显示双语字幕">
</p>

## 路线图

按先后排，想要哪一项欢迎在 Issues 里说。

- **记录我的发言**，开会时持续听麦克风并做回声消除，把你直接开口说的话也记进文字记录和纪要。
- **支持更早的 macOS（14.4 起）**，在旧系统上改用较早的系统语音识别与翻译接口。
- **正式签名与公证**，首次打开不再需要点仍要打开，AI key 也能放回系统钥匙串。
- **声纹识别**，在现有的说话人识别基础上，在本机记住常一起开会的人的声音，下次开会也能自动认出。
- **不用 key 也有纪要**，在支持的 Mac 上用 Apple 本机模型整理纪要。
- **Windows 和 Android**，共用纪要与会议记录格式，iPhone 和 iPad 因系统限制暂不计划。

每项的细节和取舍见 [docs/ROADMAP.zh-CN.md](docs/ROADMAP.zh-CN.md)。

## 卸载

退出知了，去应用程序文件夹里把它拖进废纸篓即可。会议记录和录音都在 `~/Library/Application Support/LiveSubs` 文件夹里，不需要的话可以手动删掉。想清除软件设置可以运行：

```bash
defaults delete com.wquguru.cicada
```

## 开发

从源码构建只需要安装 Xcode Command Line Tools（`xcode-select --install`），项目没有任何第三方依赖。

```bash
scripts/build.sh            # 编译开发版 → build/Cicada.app（名为 Cicada Dev，可与正式版同时运行）
open build/Cicada.app
scripts/package.sh          # 打包正式版 DMG、zip 和 SHA-256 校验值
```

代码架构等说明写在 [AGENTS.md](AGENTS.md) 里。官网源码放在 `site/` 目录，由 `scripts/site.py` 生成。历次更新记录见 [CHANGELOG.md](CHANGELOG.md) 或官网的[更新日志页](https://cicada.indaloop.app/changelog/)。

## 开源协议

本项目采用 [Apache-2.0](LICENSE) 协议开源。同声传译用到的虚拟麦克风驱动 BlackHole 2ch 采用 GPL 协议，知了安装包里不打包它，在你点安装时直接从它的官方发布地址下载。随 app 附带的声纹模型是 [WeSpeaker](https://github.com/wenet-e2e/wespeaker) 在 VoxCeleb 上训练的 ResNet34-LM，采用 CC BY 4.0 协议，由 `scripts/convert-voiceprint.py` 转成 Core ML。
