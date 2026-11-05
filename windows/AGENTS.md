# AGENTS.md (Windows)

The Windows port: listening only. The root `AGENTS.md` applies too (Ling key, `LingClient`, no third-party dependencies, the Mac app as the reference, one `VERSION`). Commands, layout and how to verify are in `README.md`; the plan is `docs/windows-plan.md`.

- .NET 10, WPF with the UI in code (no XAML), no NuGet packages. `src/Cicada.Core` is UI-free and must build and test on the Mac.
- The key: `AIKey` in `Cicada.Core/Ling.cs`, the `ling-api-key` file only; every Ling or Ming call goes through `LingClient`.
- The notes window never takes focus (`WS_EX_NOACTIVATE`) and stays out of captures (`WDA_EXCLUDEFROMCAPTURE`) unless 共享屏幕时让对方看到 is on.
- Shared UI text comes from `Resources/*.lproj/Localizable.strings`; Windows-only text is in `src/Cicada/Strings/`. Run `python3 scripts/strings.py` after changing either.
- Verify with `scripts/test.sh`, then in the VM (`vm/`) with `cicadactl.ps1`. Real x64 hardware, Bluetooth and real screen sharing need a person.
- Commits use the `(windows)` scope: `feat(windows):` / `fix(windows):` are this platform's release notes.
