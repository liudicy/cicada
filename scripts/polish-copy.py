#!/usr/bin/env python3
"""Rewrites new Chinese copy in plainer, shorter words with Gemini Argon (ZenMux), then checks it.

scripts/polish-copy.py changelog [x.y.z]   # one site/changelog.json entry; default the undated one
scripts/polish-copy.py readme v1.5.1       # README.zh-CN.md sections changed since that ref, then the
                                           # same sections of README.md (English), README.{ja,ko}.md retranslated

Only what this release added is touched, so copy already on the site doesn't churn every release.
Needs ZENMUX_API_KEY. Refuses to write if the model changed what must not change: item count,
kind, platforms, dates, any “…”/「…」/`…` (UI text and key names that must match the strings files),
headings, links, images or code blocks. Read the diff before committing: it can still drop a detail.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

MODEL = "google/gemini-4-argon"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LANGS = {"en": "English", "ja": "Japanese", "ko": "Korean"}
# English is the README GitHub shows; Chinese stays the source the others are translated from.
READMES = {"zh": "README.zh-CN.md", "en": "README.md", "ja": "README.ja.md", "ko": "README.ko.md"}

STYLE = """文风：像一个懂行的朋友在说话，口语、直接、短句；先说用户得到什么，再说必要的条件。
去掉翻译腔和公文腔（“进行”“将”“该”“对…进行”“实现了”“得以”），去掉重复和不必要的解释，少用分号堆叠长句。
事实约束：
- 只能删减、合并、改说法，不得新增功能、数字、平台或承诺。
- “声音不出本机/本机识别”只适用于 Apple 芯片的 Mac；Intel Mac、Windows、Linux、Android 把声音交给云端 AI 服务。
- BlackHole 是下载安装的，从不内置。
- 中文引号“…”、「…」和反引号 `…` 里的文字是界面原文或键名，一个字都不能改。
- 知了、Ling、Ming、BlackHole、OpenRouter、ZenMux、Google 翻译等专有名词照旧。"""

QUOTE = re.compile(r"“[^”]*”|「[^」]*」|`[^`]*`")
LINK = re.compile(r"\]\([^)#]+\)|src=\"[^\"]+\"|href=\"[^\"]+\"")


def chat(system, prompt):
    body = json.dumps({"model": MODEL, "temperature": 0.4, "max_tokens": 16000, "messages": [
        {"role": "system", "content": system}, {"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request("https://zenmux.ai/api/v1/chat/completions", body, {
        "Authorization": "Bearer " + os.environ["ZENMUX_API_KEY"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        out = json.load(r)["choices"][0]["message"]["content"].strip()
    m = re.match(r"^```[a-zA-Z]*\n(.*)\n```$", out, re.S)
    return m.group(1) if m else out


def changelog(version=None):
    path = os.path.join(ROOT, "site/changelog.json")
    data = json.load(open(path, encoding="utf-8"))
    entry = next((v for v in data if (v["version"] == version if version else not v.get("date"))), None)
    if not entry:
        sys.exit("polish-copy: no such changelog entry")
    src = {"title": entry["title"], "summary": entry["summary"],
           "items": [{"title": i["title"], "text": i["text"]} for i in entry["items"]]}
    system = "你是知了（Cicada，实时会议字幕与同声传译应用）网站更新日志的中文编辑。\n" + STYLE + """
写法：版本 title 一个短语，最多 20 字；summary 一两句，最多 80 字，挑最重要的说；
条目 title 一句话说清用户得到什么，尽量 40 字以内；条目 text 只补充有用的条件和平台差异，不重复 title。
原文 text 为空的条目保持空字符串。输入 JSON，输出同样结构的 JSON（同样的键、同样数量和顺序的 items），只输出 JSON。"""
    for _ in range(3):
        try:
            out = json.loads(chat(system, json.dumps(src, ensure_ascii=False, indent=1)))
        except ValueError:
            continue
        ok = (set(out) == {"title", "summary", "items"} and out["title"].strip() and out["summary"].strip()
              and len(out["items"]) == len(src["items"])
              and all(set(o) == {"title", "text"} and o["title"].strip() and bool(o["text"].strip()) == bool(s["text"].strip())
                      for o, s in zip(out["items"], src["items"]))
              and not set(QUOTE.findall(json.dumps(out, ensure_ascii=False))) - set(QUOTE.findall(json.dumps(src, ensure_ascii=False))))
        if ok:
            break
    else:
        sys.exit("polish-copy: the model kept changing the structure or quoted UI text; nothing written")
    entry["title"], entry["summary"] = out["title"], out["summary"]
    for i, o in zip(entry["items"], out["items"]):
        i["title"], i["text"] = o["title"], o["text"]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"polished {entry['version']}: {len(entry['items'])} items")


def sections(text):
    """The header block, then one chunk per '## ' heading; the four READMEs share this order."""
    return re.split(r"(?m)^(?=## )", text)


def frozen(chunk):
    code = re.findall(r"(?s)```.*?```", chunk)
    return chunk.split("\n", 1)[0] if chunk.startswith("## ") else "", sorted(set(LINK.findall(chunk))), code


def write_sections(path, parts):
    open(path, "w", encoding="utf-8").write("".join(p if p.endswith("\n") else p + "\n" for p in parts))


def readme(ref):
    zh_path = os.path.join(ROOT, READMES["zh"])
    # Tags before the English README took over README.md kept the Chinese one there.
    shown = subprocess.run(["git", "show", f"{ref}:{READMES['zh']}"], cwd=ROOT, capture_output=True, text=True)
    if shown.returncode:
        shown = subprocess.run(["git", "show", f"{ref}:README.md"], cwd=ROOT, capture_output=True,
                               text=True, check=True)
    old = sections(shown.stdout)
    new = sections(open(zh_path, encoding="utf-8").read())
    if len(old) != len(new):
        sys.exit("polish-copy: README.zh-CN.md gained or lost a section since " + ref + "; polish it by hand")
    changed = [k for k, (a, b) in enumerate(zip(old, new)) if a != b]
    if not changed:
        return print("README.zh-CN.md: nothing changed since " + ref)
    system_zh = "你是知了（Cicada）GitHub README 的中文编辑。\n" + STYLE + """
改写给你的这一节：更短更自然，删掉重复说明和过细的实现细节，保留用户做决定需要的信息。
标题行、链接 URL、图片、代码块、命令原样保留；表格可以缩短单元格，但事实不能丢。只输出这一节的 Markdown。"""
    for k in changed:
        for _ in range(3):
            out = chat(system_zh, new[k]).rstrip() + "\n"
            if frozen(out) == frozen(new[k]) and not set(QUOTE.findall(out)) - set(QUOTE.findall(new[k])):
                new[k] = out + ("\n" if new[k].endswith("\n\n") else "")
                break
        else:
            sys.exit(f"polish-copy: README.zh-CN.md section {k} kept losing a heading, link or code block")
    write_sections(zh_path, new)
    for lang, name in LANGS.items():
        path = os.path.join(ROOT, READMES[lang])
        parts = sections(open(path, encoding="utf-8").read())
        if len(parts) != len(new):
            print(f"{READMES[lang]}: sections don't line up with README.zh-CN.md; update it by hand")
            continue
        system = f"""You translate one section of Cicada's (知了) Chinese README into natural, concise {name} for GitHub.
Follow the Chinese section in content and length; add nothing it lacks. Take terminology, UI names, the heading line,
link targets (this language's README and site pages) and badge text from the current {name} section.
Keep URLs, images, code blocks and commands verbatim. Apple-silicon-only on-device recognition must not be extended
to Intel, Windows, Linux or Android. Output only the Markdown of the section."""
        for k in changed:
            for _ in range(3):
                out = chat(system, f"Chinese section:\n\n{new[k]}\n---\nCurrent {name} section:\n\n{parts[k]}").rstrip() + "\n"
                head, links, _ = frozen(out)
                if head == frozen(parts[k])[0] and set(links) <= set(frozen(parts[k])[1]) | set(frozen(new[k])[1]):
                    parts[k] = out + ("\n" if parts[k].endswith("\n\n") else "")
                    break
            else:
                print(f"{READMES[lang]} section {k}: kept losing its heading or links; left as it was")
        write_sections(path, parts)
    print("polished README sections", changed)


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("changelog", "readme") or (sys.argv[1] == "readme" and len(sys.argv) < 3):
        sys.exit(__doc__)
    changelog(*sys.argv[2:3]) if sys.argv[1] == "changelog" else readme(sys.argv[2])
