#!/usr/bin/env python3
"""UI strings: Chinese source text is the key; Resources/<lang>.lproj/Localizable.strings (en, ja, ko)
hold the translations, and each value must use the same format specifiers as its key.

    python3 scripts/strings.py          # check: every key in the code has an entry in every language
    python3 scripts/strings.py --write  # also add missing keys (value = TODO) and rewrite zh-Hans

Keys come from the compiler (-emit-localized-strings), so interpolations are exactly the format
keys the app looks up ("已听到 %lld 句"). zh-Hans/Localizable.strings maps every key to itself:
the development region is English, so without it Chinese systems would fall back to English.
English plurals live in en.lproj/Localizable.stringsdict.
"""
import glob, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["en", "ja", "ko"]
TABLE = os.path.join(ROOT, "Resources/{}.lproj/Localizable.strings")
ZH = os.path.join(ROOT, "Resources/zh-Hans.lproj/Localizable.strings")
DICT = os.path.join(ROOT, "Resources/en.lproj/Localizable.stringsdict")
CJK = re.compile(r"[\u4e00-\u9fff]")
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(lld|ld|d|@|f)")


def specs(s):
    return sorted(SPEC.findall(s))


def code_keys():
    out = tempfile.mkdtemp()
    subprocess.run(["swift", "build", "--product", "LiveSubs", "-Xswiftc", "-emit-localized-strings",
                    "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    # The iOS app's text shares the same tables (ios/AGENTS.md); it needs Xcode's iOS SDK.
    if subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True).returncode == 0:
        subprocess.run([os.path.join(ROOT, "ios/scripts/build.sh")], cwd=ROOT, check=True, stdout=subprocess.DEVNULL,
                       env={**os.environ, "STRINGS_OUT": os.path.join(out, "ios")})
    else:
        print("ios: no iOS SDK (needs Xcode), its strings are not checked")
    keys = {}
    # The shared files are in both builds: iOS writes into its own folder, not over the Mac's.
    for f in sorted(glob.glob(os.path.join(out, "*.stringsdata")) + glob.glob(os.path.join(out, "ios", "*.stringsdata"))):
        for entries in json.load(open(f))["tables"].values():
            for e in entries:
                if CJK.search(e["key"]):  # "%@ · %@" and the like need no translation
                    keys.setdefault(e["key"], os.path.basename(f).split(".")[0])
    return keys


def load(path):
    if not os.path.exists(path):
        return {}
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", path]))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(path, pairs):
    lines, last = [], None
    for k, v, group in pairs:
        if group != last:
            lines.append(f"\n/* {group} */")
            last = group
        lines.append(f'"{esc(k)}" = "{esc(v)}";')
    open(path, "w").write("\n".join(lines).lstrip() + "\n")


def main():
    keys = code_keys()
    bad = False
    for lang in LANGS:
        path = TABLE.format(lang)
        table = load(path)
        missing = [k for k in keys if k not in table]
        unused = [k for k in table if k not in keys]
        todo = [k for k, v in table.items() if v == "TODO"]
        mismatch = [k for k, v in table.items() if v != "TODO" and specs(k) != specs(v)]
        for k in missing: print(f"{lang} missing   {keys[k]}: {k}")
        for k in unused: print(f"{lang} unused    {k}")
        for k in todo: print(f"{lang} todo      {k}")
        for k in mismatch: print(f"{lang} specifier {k} -> {table[k]}")
        if "--write" in sys.argv:
            write(path, [(k, table.get(k, "TODO"), g) for k, g in keys.items()])
        subprocess.run(["plutil", "-lint", "-s", path], check=True)
        print(f"{lang}: {len(keys)} keys, {len(missing)} missing, {len(unused)} unused, {len(todo)} TODO, {len(mismatch)} bad specifiers")
        bad |= bool(missing or todo or mismatch)
    for k in load(DICT):
        if k not in keys: print(f"unused plural  {k}")
    if "--write" in sys.argv:
        write(ZH, [(k, k, g) for k, g in keys.items()])
    for p in (ZH, DICT):
        subprocess.run(["plutil", "-lint", "-s", p], check=True)
    sys.exit(1 if bad and "--write" not in sys.argv else 0)


main()
