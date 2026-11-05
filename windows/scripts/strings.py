#!/usr/bin/env python3
"""Lists Windows UI text with no translation: every L("…") / LF("…") key in windows/src that is in
neither the Mac's Resources/<lang>.lproj/Localizable.strings nor windows/src/Cicada/Strings/<lang>.lproj/Windows.strings.
--write appends the missing keys to Windows.strings as TODO lines (value = the Chinese)."""
import re, sys, pathlib
win = pathlib.Path(__file__).resolve().parent.parent
root = win.parent
keys = []
for f in sorted((win / "src").rglob("*.cs")):
    for k in re.findall(r'\bLF?\("((?:[^"\\]|\\.)*)"', f.read_text(encoding="utf-8")):
        if k not in keys: keys.append(k)
def table(path):
    if not path.exists(): return {}
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(encoding="utf-8"), re.M))
missing_any = False
for lang in ["en", "ja", "ko"]:
    have = table(root / f"Resources/{lang}.lproj/Localizable.strings") | table(win / f"src/Cicada/Strings/{lang}.lproj/Windows.strings")
    missing = [k for k in keys if k not in have]
    if missing:
        missing_any = True
        print(f"{lang}: {len(missing)} missing")
        for k in missing: print(f"  {k}")
        if "--write" in sys.argv:
            out = win / f"src/Cicada/Strings/{lang}.lproj/Windows.strings"
            out.parent.mkdir(parents=True, exist_ok=True)
            with out.open("a", encoding="utf-8") as f:
                for k in missing: f.write(f'"{k}" = "{k}"; /* TODO */\n')
sys.exit(1 if missing_any else 0)
