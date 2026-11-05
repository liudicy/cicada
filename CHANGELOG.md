# Changelog

One section per release, newest first; one version covers every platform. `scripts/release.sh`
writes it from the `feat:` and `fix:` commits since the last tag, grouped by platform (the commit's
scope), and the release workflow publishes it as the release notes. Since 1.1.2 every release ships
every platform (one with nothing new says No changes); earlier ones shipped only those listed. Lines under `## Unreleased` become the release's summary. The Chinese changelog for users is `site/changelog.json`.

## 1.1.1 — 2026-11-04

### Android

#### Fixed

- Show the first-run setup screens again; they opened blank with only the Continue button ([c5acd7d](https://github.com/wquguru/cicada/commit/c5acd7da6c129baedc84eeff925ca2194b13a19c))

## 1.1.0 — 2026-11-04

### Mac

#### New

- Keep the "show when sharing screen" lamp in the notes window so one click turns it on or off ([10cd9f0](https://github.com/wquguru/cicada/commit/10cd9f0401ec288fd73ec52c1e67662fe2affd2a))
- Check for updates every 4 hours and from the menu bar panel, with the result shown in place ([76677e0](https://github.com/wquguru/cicada/commit/76677e00f4b37c72aa4dda665b39288aa37c05b0))
- Run on macOS 14.4 and 15, with the older on-device speech recognizer ([900c36e](https://github.com/wquguru/cicada/commit/900c36e3ac1c23a303590197db2d7b11d1bd6b7d))
- Listen to a meeting in the room through the Mac's microphone (听哪里 › 会议室) ([9236b26](https://github.com/wquguru/cicada/commit/9236b267fc15993b0a9caa2726f859c9709a9c23))
- Import a recording or video and turn it into a meeting record ([6f6eba2](https://github.com/wquguru/cicada/commit/6f6eba22cd4fe6f3ca36a182bedd0ad47a0bee12))
- Turn speaker identification on by default, out of 实验功能 and into 设置 › 通用 ([d0e8924](https://github.com/wquguru/cicada/commit/d0e89245eabeed0e0c71ceb2729faa6aec601d8e))
- Rename speakers, merge them or give a paragraph to someone else right in the live notes window ([b3e09a9](https://github.com/wquguru/cicada/commit/b3e09a9cbdd5b28a99f25823e235378463063667))
- Make the notes window's yellow button tuck it away to the menu bar, like 收起 ([89ecdff](https://github.com/wquguru/cicada/commit/89ecdffb8e7d112051707a1205e4a17a5d0d0708))
- Click 正在听 at the top of the records window to bring back the live notes or subtitle bar ([366cee0](https://github.com/wquguru/cicada/commit/366cee04c2f976ab954fbbe4c86e3d06863979e7))
- Say how far the notes are behind the meeting, and lay out the live notes window to read more easily ([32319e6](https://github.com/wquguru/cicada/commit/32319e68bf096cccff959edb22d39c9dd122fdd0))
- Switch AI Service to OpenRouter, ZenMux, OpenAI or any OpenAI-compatible service when Ling isn't an option ([e774220](https://github.com/wquguru/cicada/commit/e77422009e1baa3285afe4561cfc9818b292bdc1))
- A meeting whose language was never recognized keeps its recording, and you pick the language to transcribe it ([e31191e](https://github.com/wquguru/cicada/commit/e31191e8e34cd3c0d31d0cea74575ff94cb25bb2))
- Diagnostics shows each AI request by service, model and use, with time to first audio for the translated voice ([16d70e6](https://github.com/wquguru/cicada/commit/16d70e686fc7cd9b7fa55527999e98f4e4d80a41))
- Show a new version at the top of the menu bar panel and send one notification per version (held while a meeting is on), with a clearer dot on the menu bar icon ([bc68dfe](https://github.com/wquguru/cicada/commit/bc68dfef9d111447883d9a4983970ec512cef104))

#### Fixed

- Drop Ling's remarks about a garbled line instead of showing them as the translation ([9641ae4](https://github.com/wquguru/cicada/commit/9641ae437194336f274203d72d7da9c8a6afc555))
- Keep the words fast speech loses when a long line is ended ([2893a02](https://github.com/wquguru/cicada/commit/2893a023177dc3f1f702610013c411884f50beaa))
- Catch Ling's notes, Chinese remarks and leaked reasoning in translations, and keep quotes intact ([89e1727](https://github.com/wquguru/cicada/commit/89e1727c74a6a58b329e5d6aa61a97a6e6aa5d4f))
- Retry a sentence's translation when Ling, Google and the on-device model all fail ([0fe488c](https://github.com/wquguru/cicada/commit/0fe488cff49af9d6063d7ed9b77ac964a6ca3b4c))
- Switch to English within seconds when it follows Chinese with no pause ([d9c4462](https://github.com/wquguru/cicada/commit/d9c44626f67b7b13ab39497d3be8c9faa7ca9e31))
- Read what the Mac plays, not the microphone, when sound goes out through a device with one (a USB headset, AirPods) ([283dc5f](https://github.com/wquguru/cicada/commit/283dc5f71265672929a23fbb1c02cc8b828d22c0))
- Stop sticking on 正在识别语言 when only one speech model is installed ([328e250](https://github.com/wquguru/cicada/commit/328e2502053b87e7bc6022b078bff3cc32e811b5))
- Wrap long names and terms in 人名和术语 instead of running past the window ([e0ef1a5](https://github.com/wquguru/cicada/commit/e0ef1a56bd1a928347b8d3b1d7db6e039b32a00a))
- Keep the live transcript where you scrolled it on macOS 14 instead of jumping to the newest line ([ba85696](https://github.com/wquguru/cicada/commit/ba8569674b731e570b988facc15a82f39cc8872d))
- Keep every line on macOS 14 and 15 when a file is imported while a meeting is being listened to ([3a2a8c6](https://github.com/wquguru/cicada/commit/3a2a8c6e68fb897dbfc5ca4f9bd9e80365f0df41))
- Record meetings in the one Dictation language on macOS 14 and 15 instead of asking which language it is ([84ab3a1](https://github.com/wquguru/cicada/commit/84ab3a167819bd6a3b2791a10983e2d67b781b6e))
- Keep two speakers' lines apart on macOS 14 and 15 instead of joining them into one ([d354fa6](https://github.com/wquguru/cicada/commit/d354fa6df66cd32af5f1fc58b9e794a361ed5c01))
- Say a language added to Dictation works once it has downloaded, on macOS 14 and 15 ([317b98e](https://github.com/wquguru/cicada/commit/317b98efc790ba6f5ac5fd9d385871ee8d7c8634))
- The translated voice no longer goes silent for the rest of the meeting after the output device switches ([15a47a6](https://github.com/wquguru/cicada/commit/15a47a6d3472b8a796cadf0d93913331dc6e32d0))
- A cloned voice recorded too slowly is caught and flagged, so your translated voice no longer drags ([8e27bb0](https://github.com/wquguru/cicada/commit/8e27bb0429fca346706d24161c67d6faba9eddd4))

### Windows

#### New

- Speak into the meeting in its language: hold right Ctrl, the room hears the translation ([5844255](https://github.com/wquguru/cicada/commit/584425553f3f7e59e06de1ef7ae0c4400c01ac83))
- Label the other side's lines Speaker 1, 2… by voice, on this PC only ([0479977](https://github.com/wquguru/cicada/commit/04799773757062694a311bebec1fb73e703dc4e9))
- End a meeting by itself when the meeting app hangs up or nobody has spoken for a while ([e491656](https://github.com/wquguru/cicada/commit/e491656b39b0c1ca558b5819361494ca71c4b48a))
- Tell you when a new version is out and download the right one for your PC ([7d92199](https://github.com/wquguru/cicada/commit/7d921996c43aa2bcdae632113cc193050c405472))
- Install with one Cicada-Setup.exe, no admin rights, and upgrade the same way ([059a18c](https://github.com/wquguru/cicada/commit/059a18ca89a6f5312040a81375866ad620b9ac0a))
- Open to a main window that says what's left to set up, with a listening switch in the title bar ([1446b24](https://github.com/wquguru/cicada/commit/1446b24179e69a8927476ccadb2f63bc952eb87f))
- Windows now shows a dot on the tray icon and a notification for a new version, and installs it in one click without a SmartScreen warning ([a70eecb](https://github.com/wquguru/cicada/commit/a70eecbe0fbe02bddb2611f28a52c2334f035749))

#### Fixed

- Keep Mac records intact, ask before ending a meeting, and show when notes fail ([ced2825](https://github.com/wquguru/cicada/commit/ced28259520edb55eb5a016d819f8e1930cdfab1))
- Hold music, ringback tones and typing no longer show up as lines of filler words ([2f44821](https://github.com/wquguru/cicada/commit/2f44821a6be5f93edf4a772d288b1be84455de70))

### Android

#### New

- Redesign the app on the iPhone design, with saved meeting audio, export, import, speaker names and a full-screen face-to-face view ([b556497](https://github.com/wquguru/cicada/commit/b556497e57d3a3514196a87601e8750631e59068))
- Android now tells you when a new version is out and updates from the browser ([458324b](https://github.com/wquguru/cicada/commit/458324bafdb4e013f35708e8344d99682b34db8d))

#### Fixed

- Stop showing a meeting's first line twice ([658cc8e](https://github.com/wquguru/cicada/commit/658cc8e872273640e5ccb024a3898f081410e9c9))
- Follow the system language as the Mac does when they speak yours ([e3dcb11](https://github.com/wquguru/cicada/commit/e3dcb1131c4a4b4a73197aa40723e3e9077d872b))
- Keep the floating window from covering a picture-in-picture video after Watch over video ([22577bb](https://github.com/wquguru/cicada/commit/22577bbdc631129393feee966772789eb7f7423c))
- Hold music, ringback tones and typing no longer show up as lines of filler words ([7f07ee8](https://github.com/wquguru/cicada/commit/7f07ee838ba8d6827d46d391b431a599bccc8252))

### Linux

#### New

- Add the Linux app for Ubuntu with live notes, meeting records and Interpreting ([9216708](https://github.com/wquguru/cicada/commit/9216708960789fe0fab72ab877390c11a2d508de))
- Tell you when a new version is out and update in place with one click ([c8fd226](https://github.com/wquguru/cicada/commit/c8fd22613741554778b07c7ee864e9c798e03071))
- Open to the records window with a checklist of what's left to set up, and a test sound for the computer's audio ([e5c14eb](https://github.com/wquguru/cicada/commit/e5c14eb731df43317565ee83ffa44df771c3c6e2))
- Linux now shows a dot on the top bar icon and a desktop notification for a new version (held while a meeting is on); clicking it installs ([adc9d5e](https://github.com/wquguru/cicada/commit/adc9d5e3bad14e48a361456e5afa06d5ec80d30f))
- Change one meeting's notes language from the live notes window, and pick my language or the meeting's own in Settings, as on the Mac ([8bc6f81](https://github.com/wquguru/cicada/commit/8bc6f81264f6dc3a0f6d21328cb19007440eaf03))

#### Fixed

- Hold music, ringback tones and typing no longer show up as lines of filler words ([3a6e5e5](https://github.com/wquguru/cicada/commit/3a6e5e5e094fa3f19f77475d33de6469605ab644))

### Website

- Say Cicada runs on macOS 14.4 and later ([912781c](https://github.com/wquguru/cicada/commit/912781c6ea2c53aa7a4ef592e1422f324633f66e))
- Show the share card in the page's language when a link is shared ([10cad54](https://github.com/wquguru/cicada/commit/10cad54b313d0de4c853e4a6d96df6d8edcb4e5c))
- A download page for every platform, setup steps per platform and a changelog filter by platform ([1e4af22](https://github.com/wquguru/cicada/commit/1e4af22bf63d369c03e6787656ea5185cb411de5))
- Rewrite the 1.1.0 changelog and homepage copy ([9179573](https://github.com/wquguru/cicada/commit/91795735014ad5e39523038cd31e1ced00612f37))
- Describe Cicada by what it does rather than as a menu bar tool ([38771f1](https://github.com/wquguru/cicada/commit/38771f1a5ae691c848ea429f4a870defd92d9d26))
- Say Android shows the speakers Mac and Windows found instead of telling voices apart itself ([ab1d748](https://github.com/wquguru/cicada/commit/ab1d7489c1d4405765590b2607372a3f50e070ed))

## 1.0.0 — 2026-11-03

The first public release. Cicada turns whatever your Mac plays into live translated subtitles and meeting notes, keeps each meeting as a bilingual record, and speaks what you say back into the meeting in the other side's language.

### Highlights

- Live bilingual subtitles for any app that plays sound, with on-device speech recognition that detects the spoken language
- Live meeting notes with a Ling key: a summary, topics, conclusions, to-dos, names and terms, and a fishbone diagram when causes are discussed
- Meetings saved as bilingual records with the notes beside the original lines, exported to Markdown, Word or SRT, and ended by themselves when the call hangs up or goes quiet
- Interpreting: hold right ⌥ to talk, and Cicada speaks the translation into the meeting through BlackHole 2ch with a Ming voice, a Mac voice or your own, switching the system mic for you
- Speaker identification (experimental) tells the other side's voices apart and, with a Ling key, fills in their names
- The live notes window stays out of screen sharing unless you choose to show it
- English, Japanese, Korean and Chinese interface, a four-step first-run guide, and in-app updates checked against each release's SHA-256
