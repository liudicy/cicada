"""UI text. The Chinese text is the key, as on the Mac, and the translations are the Mac's own
`Resources/{en,ja,ko}.lproj/Localizable.strings`, plus `Linux.strings` (linux/strings/<lang>.lproj)
for text only the Linux app has. Placeholders are the Mac's `%@`, filled in order (or `%1$@`).
Never for prompts, logs or stored values."""
from __future__ import annotations

import os

_table: dict = {}
language = "zh-Hans"


def load(ui: str, folders: list) -> None:
    """Loads the table for `ui` ("en", "ja", "ko"; anything else is Chinese) from each folder's
    <lang>.lproj/{Localizable,Linux}.strings, later folders over earlier ones."""
    global _table, language
    head = ui.replace("_", "-").split("-")[0]
    language = head if head in ("en", "ja", "ko") else "zh-Hans"
    t: dict = {}
    for folder in folders:
        for name in ("Localizable.strings", "Linux.strings"):
            path = os.path.join(folder, language + ".lproj", name)
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as f:
                    t.update(parse(f.read()))
    _table = t


def L(key: str) -> str:
    v = _table.get(key)
    return v if v else key


def LF(key: str, *args) -> str:
    """L() with the Mac's `%@` placeholders, filled in order."""
    text = L(key)
    out = []
    nxt = 0
    i = 0
    while i < len(text):
        # %@, and the Mac's numbers (%lld, %d) the same way: the Mac keys 说话人 N as "说话人 %lld".
        if text.startswith("%%", i):  # a literal %, as in the Mac's "%lld%%"
            out.append("%")
            i += 2
            continue
        m = next((t for t in ("%@", "%lld", "%d") if text.startswith(t, i)), None)
        if m:
            out.append(str(args[nxt]) if nxt < len(args) else "")
            nxt += 1
            i += len(m)
            continue
        if text[i] == "%" and i + 3 < len(text) and text[i + 1].isdigit() and text[i + 2] == "$":
            spec = next((t for t in ("@", "lld", "d") if text.startswith(t, i + 3)), None)
            if spec:
                n = int(text[i + 1]) - 1
                out.append(str(args[n]) if 0 <= n < len(args) else "")
                i += 3 + len(spec)
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


def parse(text: str) -> dict:
    """`"key" = "value";` lines, with /* */ and // comments and \\" \\\\ \\n escapes."""
    result = {}
    i = 0
    n = len(text)

    def read():
        nonlocal i
        while i < n:
            if text[i] == '"':
                break
            if text.startswith("/*", i):
                e = text.find("*/", i + 2)
                i = n if e < 0 else e + 2
                continue
            if text.startswith("//", i):
                e = text.find("\n", i)
                i = n if e < 0 else e + 1
                continue
            i += 1
        if i >= n:
            return None
        i += 1
        b = []
        while i < n and text[i] != '"':
            if text[i] == "\\" and i + 1 < n:
                i += 1
                b.append({"n": "\n", "t": "\t"}.get(text[i], text[i]))
            else:
                b.append(text[i])
            i += 1
        i += 1
        return "".join(b)

    while True:
        k = read()
        if k is None:
            break
        v = read()
        if v is None:
            break
        result[k] = v
    return result
