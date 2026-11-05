#!/usr/bin/env python3
"""Lists Android UI text with no translation: every L("…") / LF("…") key in android/app and
android/core that is in neither the Mac's Resources/<lang>.lproj/Localizable.strings nor
android/app/src/main/strings/<lang>.lproj/Android.strings. --write appends the missing keys to
Android.strings as TODO lines (value = the Chinese)."""
import re, sys, pathlib
here = pathlib.Path(__file__).resolve().parent.parent
root = here.parent
keys = []
for f in sorted(list((here / "app/src").rglob("*.kt")) + list((here / "core/src").rglob("*.kt"))):
    for k in re.findall(r'\bLF?\("((?:[^"\\]|\\.)*)"', f.read_text(encoding="utf-8")):
        if k not in keys: keys.append(k)
def table(path):
    if not path.exists(): return {}
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(encoding="utf-8"), re.M))
missing_any = False
for lang in ["en", "ja", "ko"]:
    mine = here / f"app/src/main/strings/{lang}.lproj/Android.strings"
    have = table(root / f"Resources/{lang}.lproj/Localizable.strings") | table(mine)
    missing = [k for k in keys if k not in have]
    if missing:
        missing_any = True
        print(f"{lang}: {len(missing)} missing")
        for k in missing: print(f"  {k}")
        if "--write" in sys.argv:
            mine.parent.mkdir(parents=True, exist_ok=True)
            with mine.open("a", encoding="utf-8") as f:
                for k in missing: f.write(f'"{k}" = "{k}"; /* TODO */\n')
sys.exit(1 if missing_any else 0)
