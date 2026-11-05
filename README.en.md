<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Cicada icon">
</p>

<h1 align="center">Cicada · 知了</h1>

<p align="center">
  Every call. Every stream. No language barrier.<br>
  Live meeting notes, bilingual transcripts, subtitles and interpreting on Mac, Windows, Linux and Android.
</p>

<p align="center">
  <a href="https://cicada.indaloop.app"><img src="https://img.shields.io/badge/Website-cicada.indaloop.app-E8552B?style=for-the-badge" alt="Website: cicada.indaloop.app" height="36"></a>
  &nbsp;
  <a href="https://cicada.indaloop.app/en/download/"><img src="https://img.shields.io/badge/Download-Mac%20·%20Windows%20·%20Linux%20·%20Android-15171C?style=for-the-badge" alt="Download for Mac, Windows, Linux and Android" height="36"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.4%2B%20·%20Apple%20silicon-black" alt="macOS 14.4+, Apple silicon">
  <img src="https://img.shields.io/badge/Windows-10%202004%2B-black" alt="Windows 10 2004+">
  <img src="https://img.shields.io/badge/Ubuntu-22.04%2B-black" alt="Ubuntu 22.04+">
  <img src="https://img.shields.io/badge/Android-10%2B-black" alt="Android 10+">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0">
</p>

<p align="center"><a href="README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a></p>

Cicada works with whatever is playing on your computer, from Zoom, Teams, and Feishu calls to X Spaces, Discord stages, and YouTube livestreams. By listening directly to system audio, it gives you live bilingual subtitles and structured meeting notes without sending bots into the call or asking anyone else to install a thing. And when you need to jump in, just hold the talk key (right `⌥` on the Mac, right `Ctrl` on Windows) to speak and broadcast your translated voice straight into the meeting. On the Mac, speech is recognized on your computer, so audio never leaves it.

<p align="center">
  <img src="docs/demo.gif" width="800" alt="A Bloomberg English livestream on YouTube with Cicada's live Chinese notes, topics, and fishbone diagram on the right and bilingual subtitles at the bottom">
</p>

## Platforms

| Platform | Requirements | Notes |
|---|---|---|
| Mac | macOS 14.4+, Apple silicon | The full feature set; recognizes speech on your Mac, works without a key |
| Windows | Windows 10 2004+, x64 / ARM64 | Needs a Ling key, speech recognized by Ming; see [windows/](windows/README.md) |
| Linux | Ubuntu 22.04 / 24.04 desktop | Needs a Ling key; the notes window shows in screen sharing; see [linux/](linux/README.md) |
| Android | Android 10+ | Needs a Ling key; subtitles for videos and streams, face-to-face interpreting; see [android/](android/README.md) |

All four share one version number and one meeting record format; downloads are on [the website](https://cicada.indaloop.app/en/download/) and [Releases](https://github.com/wquguru/cicada/releases). The features below describe the Mac app.

## Features

### Live notes and bilingual transcript

While the meeting runs, the notes window organizes a summary, topics and key points, conclusions, to-dos, a fishbone diagram, and a glossary of names and terms, and every conclusion or to-do clicks straight back to the supporting lines in the bilingual transcript. Cicada unifies names and terms across the notes and remembers misrecognized spellings, so `⌘F` searches both the canonical spelling and the variants.

### Live subtitles and language detection

Cicada detects the spoken language on device within seconds and translates into your system language, and pressing `⌃⌥S` switches between the notes window, a compact subtitle bar, and hidden. The subtitle bar appears only when someone speaks and turns see-through under your pointer so you can click right through it.

### Meetings in the room

For a meeting around a table, set **Listen to** in the menu bar panel to **Room** and Cicada listens through the Mac's microphone, with the same subtitles, notes and records as an online meeting. Speak-back then reads the translation out of the speakers, no virtual mic needed, and the microphone stops listening while it does so the translation isn't recorded as someone else. If nothing plays on the Mac for a minute while it listens to the computer, the panel asks whether to listen to the room instead; every launch starts with the computer again.

### Speak back in their language

Hold the right `⌥` key and speak so the room hears your translated voice through BlackHole 2ch, a virtual microphone you can install from the app with one click and that Cicada switches to automatically while interpreting is on. With a Ling API key, the other side hears natural Ming voices or a clone of your own voice from an 8 to 30 second sample, and without a key it uses macOS system voices.

<p align="center">
  <img src="docs/interpreting.png" width="640" alt="Interpreting settings showing the right Option talk key, target language, Ming voice previews, and macOS voices">
</p>

### Meeting records

Every session saves its bilingual transcript, notes, and audio recording on your Mac, speaker identification separates voices on the other side and fills in their names when a Ling key is set; if it gets someone wrong, rename, merge, or reassign a passage right in the live notes window. Cicada ends the session and trims the silent tail when the call hangs up or after 10 minutes of silence, and you can generate notes later or export to Markdown, Word, or SRT subtitles. Drop an existing recording or video on the records window (or use File › Import Recording or Video…) and it is transcribed on your Mac, much faster than real time, into a bilingual record; click a line's time to play the original file from there. Right now "you" in the transcript covers only what you say while holding the talk key; recording what you say directly into the meeting is on the [roadmap](#roadmap).

<p align="center">
  <img src="docs/records.png" width="640" alt="Meeting records window showing identified speakers and a line-by-line English and Chinese transcript">
</p>

## Privacy & Permissions

On the Mac, audio capture, language detection, speech recognition (Apple SpeechAnalyzer; on macOS 14.4–15, SFSpeechRecognizer in on-device mode), and meeting recordings all stay on your computer. The only data that leaves your device is the recognized text sent for translation and meeting notes, plus the short audio clips you speak while holding the talk key when using a Ling API key. Without an API key, subtitles, translation (via Google, with Apple on-device fallback on macOS 26), meeting records, and push-to-talk interpreting all work. Live meeting notes, one-step voice translation, and voice cloning use your own Ling API key (Ant Group's model service, see [below](#ling-api-key)), and an hour of live notes costs roughly ¥0.15 to ¥1 at current Ling pricing. Ling gives ¥10 of credit every month, enough for about 10 to 50 hours of meetings.

The Windows, Linux and Android apps recognize speech with Ming: what is said goes to Ling in short pieces, recognized and translated in one step, so they need a Ling key. Recordings and meeting records stay on the device there too.

The rest of this section is about the Mac app. Cicada asks for a permission only when you use the feature that needs it, and everything else keeps working if you decline.

| Permission | What it's for | When it's asked | Without it |
|---|---|---|---|
| System audio recording (Screen & System Audio Recording) | Hearing what your Mac plays, for subtitles. Never records the screen or its own sound | Onboarding step 1, or the first time it listens | No subtitles or notes |
| Microphone | Your voice while you hold the talk key, for speak-back; the people in the room when **Listen to** is **Room** | When you turn on speak-back or first listen to the room | No speak-back, no listening to the room |
| Input Monitoring | Only to tell whether the right `⌥` was pressed on its own (listen-only; nothing is blocked or logged) | The first time you talk with right `⌥` | Pick a `⌃`/`⌘` combination in Settings instead; it needs no permission |
| Administrator password | Installing the BlackHole 2ch virtual microphone and restarting the system audio service | When you click Install in onboarding or Settings, once | The room can't hear your translation; everything else works |

- **Network and virtual microphone**. Cicada only connects to Google Translate (`translate.googleapis.com`), Ling / Ming when a key is configured (`api.ant-ling.com`), the official BlackHole download, and GitHub once a day for update checks. BlackHole is downloaded from the official Apple-notarized package and verified against a hardcoded SHA-256 checksum before installing.
- **No analytics or servers of our own**. There is no analytics, no tracking, and no backend server. Diagnostics only log timings and counts locally in the meeting folder.
- **Local storage**. Meetings, recordings, and notes live in `~/Library/Application Support/LiveSubs`. Your Ling key and voice sample are readable only by your user account, excluded from Time Machine backups, and never written to logs or exports.
- **Private notes window**. Hidden from screen sharing, screen recording, and screenshots, unless you turn on the option to show it during screen sharing to record a demo.

## Models

Without a Ling key, everything runs on Apple's on-device models plus Google Translate. With a key, Ling and Ming models handle the tasks below and fall back automatically if a request fails.

| Feature | With a Ling key | Without a key / fallback |
|---|---|---|
| Speech recognition and language detection | Apple `SpeechAnalyzer` / `SpeechTranscriber` (on device); macOS 14.4–15: `SFSpeechRecognizer` (on device, needs Dictation) | same |
| Translating finished sentences | Ling `Ling-3.1-flash` (or `Ling-3.0-flash`, set in Settings › AI Service) | Google Translate → Apple `Translation` (on device, macOS 26 only) |
| Translating the sentence still being spoken | Google Translate (saves Ling's rate limit) | Apple `Translation` (on device, macOS 26 only) |
| Live notes and the final version | Ling `Ling-3.1-flash` (same setting) | not available |
| Checking the key | Ling `Ling-3.0-tiny` (one token) | — |
| Interpreting: hearing and translating what you say | Ming `Ming-3.0-audio-flash`, one step | Apple on-device transcript, then the translation chain above |
| Interpreting: the voice the room hears, voice cloning | Ming `Ming-3.0-tts-0.5B` | macOS system voices (`AVSpeechSynthesizer`); no cloning |
| Speaker identification (说话人识别, on by default) | WeSpeaker ResNet34-LM voiceprints, bundled, on device (Core ML) | same |

<a id="ling-api-key"></a>
## Setting up a Ling API key

1. Sign up or log in on the [Ling open platform](https://chat.ant-ling.com/platform/api).
2. Click **创建令牌** (create token) and copy the key that starts with `sk-`.
3. In Cicada, open **Settings › AI Service**, paste the key, and click **Save and check** (or paste it in the prompt at the top of the notes window). A one-token request confirms it works.
4. Optionally pick the model (`Ling-3.1-flash` by default) on the same page, and the Ming voice for each language under **Settings › Interpreting**. To remove the key, click **Remove** on the same page.

If you can't sign up for Ling, switch to OpenRouter, ZenMux or OpenAI from the menu at the top right of **Settings › AI Service**, or enter the address of any OpenAI-compatible service (a model running on your Mac, for example). Live notes and sentence translation work with all of them, with models picked for quality and price that you can change; OpenRouter and ZenMux also give interpreting natural Gemini voices. One-step voice translation and voice cloning are Ling only; with other services, interpreting recognizes on your Mac and then translates. Each service keeps its own key, so switching back needs no re-entry.

## Requirements & Installation

### Mac

Requires **macOS 14.4 or later** on **Apple silicon**. macOS 26 uses the newer on-device speech recognizer, which is more accurate; on 14.4–15 Cicada uses the system's earlier recognizer, which needs **Dictation** turned on in **System Settings › Keyboard**, with each language you want heard added to its languages. The UI is available in English, Chinese, Japanese, and Korean, following your macOS language or set per app in **System Settings › General › Language & Region**.

Download `Cicada-<version>-macOS-AppleSilicon.dmg` from [Releases](https://github.com/wquguru/cicada/releases/latest) or [the website](https://cicada.indaloop.app), open it, and drag **Cicada** into **Applications**. Builds are ad-hoc signed and not notarized yet (see [roadmap](#roadmap)), so if macOS blocks the first launch, open **System Settings › Privacy & Security** and click **Open Anyway**. Each release includes `checksums.txt`, which you can verify with `shasum -a 256 Cicada-*.dmg`. For questions, reach out to the author [@wquguru](https://x.com/wquguru) on X.

The first-launch guide asks for one permission, plays a short two-person sample meeting so you can see live subtitles right away, helps you connect your Ling key (or skip it for now), and sets up the virtual microphone if you want interpreting. Later updates show as an orange dot on the menu bar icon and install in one click without losing your permissions.

<p align="center">
  <img src="docs/onboarding.png" width="640" alt="Onboarding step 2 playing a two-person sample meeting with live bilingual subtitles">
</p>

### Windows

Requires **Windows 10 2004** or later. Download `Cicada-Setup.exe` (`Cicada-Setup-arm64.exe` for Snapdragon laptops) and double-click it: it installs with no admin rights. The installer isn't code-signed yet, so if SmartScreen stops it, click **More info › Run anyway**. Cicada opens to a main window that lists the steps left: connect your Ling key, play a test sound, watch the sample meeting. Interpreting needs the free VB-Cable virtual microphone, which the guide helps you install. New versions are announced in the app and install in one click.

### Linux

Requires the **Ubuntu 22.04 or 24.04 desktop** (x86_64 or arm64). Download `Cicada-<version>-Linux.tar.gz` and run `tar xzf Cicada-<version>-Linux.tar.gz && cicada-linux/install.sh` in a terminal; Cicada appears in the app menu. Interpreting makes its own "Cicada Microphone", with no driver to install. Linux can't keep a window out of screen sharing, so the notes window always says it is visible when you share.

### Android

Requires **Android 10** or later. Download `Cicada-<version>-Android.apk` on your phone, open it and allow installing unknown apps when asked; on Android 15 and later, the first time you turn on floating subtitles you also allow restricted settings in App info. Calls and meeting apps don't let other apps record their sound: put the call on speaker and switch to **In person**.

Every platform's files can be checked against `checksums.txt` on the Releases page.

## Roadmap

In rough order; tell us what you need in Issues.

- **Recording what you say**, listening to your microphone during meetings with echo cancellation so your own proposals and to-dos are included in the transcript and notes.
- **Developer ID signing and notarization**, removing the "Open Anyway" prompt on first launch and storing the AI key in the macOS Keychain; code signing for the Windows installer too.
- **Speaker recognition**, building on today's speaker identification to remember frequent meeting participants by voice on your Mac, so they're named in the next meeting too.
- **Local notes without an API key** using Apple's on-device model on supported Macs.
- **Android in the app stores**, so the APK no longer has to come from a browser.
- **iPhone and iPad**: iOS doesn't let apps capture other apps' audio, so they start with listening to the room, face-to-face interpreting and meeting records.

See [docs/ROADMAP.md](docs/ROADMAP.md) for details and trade-offs on each item.

## Uninstall

Quit Cicada and drag it from **Applications** to the Trash. To remove all saved transcripts, notes, and audio recordings, delete `~/Library/Application Support/LiveSubs`. To clear preferences, run:

```bash
defaults delete com.wquguru.cicada
```

## Development

Building the Mac app from source requires Xcode Command Line Tools (`xcode-select --install`). Cicada has no third-party dependencies and builds directly against macOS system frameworks. On macOS 27, if the build fails because `SwiftUIMacros` is missing, that version of the Command Line Tools lacks SwiftUI's macro plugin: install the full Xcode and run `sudo xcode-select -s /Applications/Xcode.app`. For Windows, Linux and Android, see [windows/README.md](windows/README.md), [linux/README.md](linux/README.md) and [android/README.md](android/README.md).

```bash
scripts/build.sh            # dev build → build/Cicada.app ("Cicada Dev", runs beside the installed app)
open build/Cicada.app
scripts/package.sh          # release DMG + zip + checksums
```

See [AGENTS.md](AGENTS.md) for architecture details and release workflows. The website source lives in `site/` and is generated by `scripts/site.py`. Release history is in [CHANGELOG.md](CHANGELOG.md) and on the website at [cicada.indaloop.app/changelog](https://cicada.indaloop.app/changelog/).

## License

[Apache-2.0](LICENSE). The BlackHole 2ch virtual audio driver is licensed under the GPL; Cicada does not bundle it and downloads the official release on demand when you choose to install it. The bundled voiceprint model is [WeSpeaker](https://github.com/wenet-e2e/wespeaker)'s ResNet34-LM trained on VoxCeleb, licensed CC BY 4.0, converted to Core ML by `scripts/convert-voiceprint.py`.
