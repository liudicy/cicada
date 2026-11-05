# AGENTS.md (Linux)

The Linux port: listening, and 同声传译 (speaking into the room through the 知了 麦克风 virtual mic). The root `AGENTS.md` applies too (Ling key, `LingClient`, no third-party dependencies, the Mac app as the reference, one `VERSION`). Commands, layout and how to verify are in `README.md`; the plan is `docs/linux-plan.md`.

- Python 3, PyGObject and GTK 3, PulseAudio / PipeWire through `libpulse-simple`: only what Ubuntu desktop ships, no pip packages. `cicada/core` is stdlib only and must run and test on the Mac.
- The key: `AIKey` in `cicada/core/ling.py`, the 0600 `ling-api-key` file in `~/.config/cicada`.
- The notes window floats and never takes focus (XWayland, notification type). Linux can't keep it out of screen sharing, so it always says it may be shared; don't claim otherwise.
- 知了 麦克风 is two sound-server modules (`cicada/app/room.py`), never a driver. While on it is the default input; every way out (off, 退出, SIGTERM, a crash then the next launch) gives the real microphone back. Never speak what Ming didn't interpret.
- 说话人识别 runs the Mac's voiceprint model in `native/voiceprint.c` (our own C, ctypes; no BLAS on Ubuntu). It must stay equal to the Mac: the voiceprint test checks it against a Core ML reference, and clustering thresholds, labels and Ling's name prompt are the Mac's. The Mac can't link Linux binaries: CI builds the `.so` per architecture on 22.04, `vm/push.sh` builds it in the VM.
- The look is the Mac's (canvas 知了 Linux · 对齐 Mac): sizes are the Mac's numbers in px through `ui.text` (which converts to points), bold only where the Mac is semibold, and every widget the theme draws is styled in `ui.py` (no Yaru orange or discs). Check a UI change against the canvas at the same size, not just that it works.
- Shared UI text comes from `Resources/*.lproj/Localizable.strings`; Linux-only text is in `strings/`. Run `python3 scripts/strings.py` after changing either.
- Verify with `scripts/test.sh` and `scripts/smoke.sh`, then in the VM (`vm/`) with `scripts/cicadactl`. Real hardware, other desktops and real screen sharing need a person.
- Commits use the `(linux)` scope: `feat(linux):` / `fix(linux):` are this platform's release notes.
