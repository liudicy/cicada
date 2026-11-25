---
name: release
description: Cut a Cicada release end to end and on your own — gather other sessions' work onto main, size the testing to what changed (a patch takes under an hour, a new feature about two, a permission or record-format change the full matrix), fix every bug found, update README and site, cut a draft, check it, then publish when confidence is high (or stop at the draft for the user) and check in-app updates. Use for "发版", "发 draft", "发个补丁", "全端测试后发布", "转正式版".
---

# Release

AGENTS.md rules still apply (keys, commits, changelog, one VERSION, all four platforms ship).

## The contract

- Run to the end without asking. Fix every bug you find, old ones too, and re-verify the fix on the machine. Stop early only for what the gate below says needs the user.
- **The release commit is the last commit.** `scripts/release.sh` makes one commit, `chore: release v<x.y.z>` (CHANGELOG.md, VERSION, the date in `site/changelog.json`), tags it and pushes both at once. Nothing of yours lands on main after it: README, `site/i18n`, changelog items and fixes all go in before. Any fix after the draft is cut means a recut (step 3), which ends in a new release commit.
- The run ends in one of two states, both with the tag on the last commit: **published** (gate passed) or **draft** (gate not passed: the report says what to look at, and the user publishes with `echo y | scripts/publish-release.sh <x.y.z>` then `scripts/deploy-site.sh`, neither of which commits).

## Size the testing to what changed

Test where a mistake costs the user, not everywhere. List what changed (`site/changelog.json`'s undated entry, `git log v<last>..` with `--stat`), pick the tier, then add a row below for each risk it touches. Write the plan at the top of `results.md` before testing.

- **Patch** (fixes only, no new UI): the baseline plus the rows it touches. Target 45 min. The fix's author may already have run its checks on the same commit (tests, `audio-test`): read their results instead of repeating them; you add only what needs the release build.
- **Minor** (a new feature): the feature gets the full check on every platform it ships on; the rest gets the smoke check. About 2 hours.
- **Full**: major version, or a change to permissions, bundle id / designated requirement, signing, installer, updater, record format, key storage or the BlackHole download. Every check on every platform, clean install and upgrade.

**Baseline, every release:** every CI workflow the release commit and its fixes triggered is green (not only `release.yml`); `checksums.txt` matches; the notes read right; the draft's Mac app installed over the last published version opens with the same designated requirement and its records.

| What changed | What can go wrong | Add |
|---|---|---|
| Recording, the record, local storage | lost meetings, which can't be recovered | a real recording on each changed platform; draft over the last version, records byte-compared |
| Room mic, 同声传译, virtual mic | only real sound shows it | `.claude/skills/audio-test` on the Mac, quiet machine (pause the VMs: their fans reach the mic) |
| Permissions, signing, bundle id, installer, updater | users can't update, or must grant again | clean install, upgrade and real in-app update on every platform |
| A server-backed feature (share) | region and production differences | use it on production from a US exit and from mainland China (this Mac's direct line is China Unicom) |
| UI text | the English UI runs wider | Chinese and English screenshots of the changed screens |
| A platform with no change | almost nothing | its CI |

Smoke check: onboarding, sample meeting, one AI service with a good key, End Meeting writes the record, Chinese and English. Full check: the smoke check plus bad key / good key on a real AI service (ZenMux `ZENMUX_API_KEY_TMP`, OpenRouter `OPENROUTER_API_KEY`, Ling `ANTLING_API_KEY`, all in `~/.zshenv`), the changed feature end to end, clean install and upgrade.

## Gate: publish only if all hold, else stop at the draft

- Everything the plan listed passed, with screenshots, and there is no open bug in what this release ships. A known limit may ship if the user agreed to it.
- Every fix was re-verified on its machine, not just by unit tests; every touched platform's `scripts/test.sh` passed.
- The baseline holds (CI green on the first run, or after rerunning only a known-flaky Linux smoke; the draft has every platform's files, which `publish-release.sh` checks).
- Nothing that only a person can check (a real voice, BlackHole install, Input Monitoring, real screen sharing, x64 hardware) changed, or `audio-test` covered it.

## Resources: 32 GB, 10 cores, shared with other sessions

- Guest RAM: tart Mac 8G, Windows 8G, Ubuntu 6G, Android ~2G. **At most two of tart / Windows / Ubuntu at once**; Android and the Mac dev build fit beside them. Before booting one, check `sysctl vm.swapusage` (more than 2 GB free; free memory % alone looks fine while swap is full), `memory_pressure`, and `pgrep -fl "qemu|tart run|emulator"`.
- Claim a VM before you use it: `ListAgents`, and message any live-subs session that may be using it. Release it as soon as its platform passes: `tools/macos-vm/vm.sh stop`, `windows/vm/vmctl.sh stop`, `linux/vm/vmctl.sh stop`, `adb emu kill`. A peer needing quiet can have them paused: `kill -STOP` the qemu pids, tell your agents, `kill -CONT` after.
- The Mac dev build is single-instance and shared: launching yours replaces a peer's. Never quit the user's installed app while it records (newest `Sessions/<id>` still being written).
- At the end, nothing of yours is left running: VMs, the emulator, the Mac VM's ssh tunnel, dev builds. Disk is tight (`df -h ~`): delete downloaded drafts after checking them.

## Time: watch every agent

- Budgets for a minor release: gather 30 min, verify 1 h, CI 20 min, draft check 30 min, publish and in-app update 20 min. A phase over budget twice means stop at the draft and report why. A patch should fit in 45 min overall.
- Check each background agent every 10–15 min (its newest screenshot, its output). Silent for 15 min: find what it is stuck on, and stop and restart it rather than wait. In 1.5.0 a `mkdir` under `~/Downloads` hung 131 min on a privacy prompt nobody saw.
- Give anything that waits on a VM, the emulator or the network a time limit: `perl -e 'alarm shift; exec @ARGV' 120 <cmd>`, ssh's `ConnectTimeout`, or the Bash tool's own timeout.

## 0. Gather

- `ListAgents`: wait at most 30 min for a session still working on this repo, or message it before taking its branch; after that, release without its unfinished work. A peer's message isn't the user's approval, and a peer may only push on its own user's word. Tell the live-subs sessions a release is under way, and again just before you tag (hold pushes until the tag is up).
- Bring parked branches onto `origin/main` with `cherry-pick` (a branch checked out in another worktree can't be rebased). Skip commits that belong to another unfinished feature.
- Work in a release worktree (`git worktree add ../live-subs-rel origin/main`); never touch the main checkout's uncommitted work. Rebase on `origin/main` before each push.
- Results go to `~/cicada-verify/<x.y.z>/results.md` as you go (platform × check × phase × pass/fail × screenshot): it outlives the context and the scratchpad.

## 1. Verify before the draft

| Platform | Machine | Drive it with |
|---|---|---|
| Mac | dev build on this Mac; tart VM `cicada-macos14` for upgrades / clean installs | `tools/lsctl`, `tools/macos-vm/vm.sh`, `tools/README.md` |
| Windows | qemu `cicada-win11` | `windows/vm/`, `windows/scripts/cicadactl.ps1` |
| Linux | qemu `cicada-ubuntu` | `linux/vm/`, `linux/scripts/cicadactl` |
| Android | emulator `cicada` | `android/scripts/` `emulator.sh`, `cicadactl.sh`, `shot.sh` |

- Only the platforms and checks the plan names. One background agent per port that needs one (within the resource budget), the Mac yourself; brief each in a file under `~/cicada-verify/<x.y.z>/` (change list, checks, machine, stop command) rather than in the prompt.
- Screenshots: `~/cicada-verify/<x.y.z>/<platform>/{pre-release,post-draft,post-publish}/NN-what.png`. Never under `~/Downloads`, `~/Desktop` or `~/Documents`.
- Fix every problem: a bug in shared behaviour is fixed on every platform at once and re-verified together. One Conventional Commit each with the platform scope, plus its Chinese item in `site/changelog.json`; re-verify on the machine; run each touched platform's `scripts/test.sh`.
- A fix that joins mid-release (yours or a peer's) gets its own rows in the plan, rechecked where it changed; the rest stays checked.
- Update `README*.md` (4 languages) and `site/i18n` for new features.
- Polish the new Chinese copy once it's all in: `scripts/polish-copy.py changelog` (the undated entry) and `scripts/polish-copy.py readme v<last>` (`README.zh-CN.md` sections changed since the last tag, retranslated into `README.md` (English) and ja/ko). Only this release's copy, never the released entries. Read the diff: put back any symptom or condition it dropped, then `python3 scripts/site.py` and one `docs:` commit. If ZenMux refuses (`ZENMUX_API_KEY` missing or out of credit), skip it and say so in the report.

## 2. Draft

- `scripts/release.sh <x.y.z>` from the worktree (clean tree with `origin/main` in HEAD; fails without the undated `site/changelog.json` entry). If the push is rejected it undoes the commit and tag: rebase and run it again.
- Watch every workflow run on the release commit and on the fixes before it (`gh run list --json headSha,workflowName,status,conclusion`), not only `release.yml`. A failure that needs a code change is a recut (step 3), never a moved tag. Then download the draft into the scratchpad and check `checksums.txt`.
- Check the notes: anchors absolute, compared with the last published tag, no reverted commit (`scripts/changelog.py` drops a commit whose revert says `Reverts <sha>`); fix with `gh release edit` (no commit).

## 3. Check the draft

- The draft's own files over the last published version, on the platforms the plan names (always the Mac): same bundle id / requirement, settings and records kept, the update check doesn't offer the draft. Put the last published Mac app in the VM's `~/backup` first.
- Any bug: recut. Its Chinese item goes into the now dated `site/changelog.json` entry for this version. `gh release delete v<x.y.z> -R wquguru/cicada --yes`, `git push --delete origin v<x.y.z>`, `git tag -d v<x.y.z>`; commit the fix, re-verify it, run `scripts/release.sh <x.y.z>` again (same version: drafts are never public). If it can't be fixed, leave the draft and report.

## 4. Publish (only if the gate holds)

- `echo y | scripts/publish-release.sh <x.y.z>`, then `scripts/deploy-site.sh` from the release worktree. Neither commits. `gh api repos/wquguru/cicada/releases/latest -q .tag_name` must be the new tag.
- Real in-app update from the previous version: on every platform when the updater, installer or signing changed (Mac: the old app from `~/backup` in the VM; Windows: tray dot; Linux: tray; Android: update check), else on the Mac only.
- If the update is broken: `gh release edit v<prev> --latest`, `gh release edit v<x.y.z> --draft=true`, fix, recut. Once a published version was downloaded, fix in the next patch instead.

## 5. Report (Chinese)

Published or draft (if draft, which gate items failed), the release URL, the last commit (`git log -1 origin/main`; name any peer commit after it), the plan and what each platform got, bugs fixed, still open, what was skipped and why, what needs a person, `results.md` and the screenshots, and time per phase. Leave the user's installed app and settings as they were, stop every VM you started, and remove the release worktree.

## Pitfalls

- Never print a key: pipe it, and clear the clipboard after. The old `ZENMUX_API_KEY` is dead.
- Production allows 5 new share devices per IP a day, and every machine here shares one exit: reuse a device file already registered (copy it into the app's data) instead of registering new ones.
- `wrangler deploy` uploads `build/site` too: while a release is a draft, build the site with that version's `date` set to null (not committed), or it shows a version nobody can download.
- Mac VM: run `sync` before `vm.sh stop`, or writes since boot can be lost (1.6.0 lost a restored data folder). Screenshots there: `screencapture` inside the VM, copied out through `~/VMs/share`. Clicks are 1024×768 pt with origin bottom-left.
- The notes window is invisible in screenshots but takes clicks: find it with `winpos <pid>` and drag it off, or `notesCapturable`.
- Don't run `python3` in the Mac VM (it opens the xcode-select installer). A copied app gets translocated: `xattr -dr com.apple.quarantine`.
- Android emulator reaches the internet only through the host proxy: start it with `-http-proxy http://127.0.0.1:7890`. Ubuntu qemu can freeze on the AI-service dropdown: restart the VM.
