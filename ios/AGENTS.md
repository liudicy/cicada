# AGENTS.md (iOS / iPadOS)

The iPhone and iPad app: listens to the room with the microphone, interprets face to face through the speaker, imports recordings and keeps meeting records. It cannot hear other apps or speak into them. The root `AGENTS.md` applies too (Ling key, `LingClient`, no third-party dependencies, the Mac app as the reference, one `VERSION`). The plan is `docs/ios-plan.md`; the design canvas on claude.ai (知了 iOS 设计) is the source of truth for the UI.

- iOS / iPadOS 26 and later, SwiftUI. Engines are the Mac's own files, listed in `ios/shared-sources.txt` and compiled into the iOS app; `ios/Sources` has the iOS side. Change a shared file and keep both working: `ios/scripts/typecheck.sh`, then `scripts/test.sh` and a Mac dev build.
- Built by `ios/scripts/build.sh` with `xcrun swiftc`, no `.xcodeproj` until device signing proves it needs one. Needs full Xcode, not only the Command Line Tools.
- The key: the `ling-api-key` file in the app container readable only after the first unlock (listening goes on while locked), excluded from backups; never UserDefaults, logs or exports.
- UI text: the same Chinese keys and `Resources/*.lproj/Localizable.strings` as the Mac; reuse a Mac key where the feature is the same. `python3 scripts/strings.py` checks the iOS build too when Xcode is there.
- Verify in the iPhone and iPad simulators: `ios/scripts/build.sh`, `ios/scripts/run.sh "<device>" [--seed <Mac meeting folders>]`, drive it with `ios/scripts/ctl.sh` (commands in `Debug.swift`), read `Library/Caches/livesubs-dev-debug.log` in the app container, `xcrun simctl io <device> screenshot` against the design; pass `-AppleLanguages "(zh-Hans)"` to `simctl launch` for Chinese. A real microphone, the lock screen, the Dynamic Island and TestFlight need a person.
- Commits use the `(ios)` scope. `scripts/changelog.py` has no iOS group yet (M4 in the plan); until then such commits land under Mac.
