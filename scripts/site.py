#!/usr/bin/env python3
"""Builds the website (served from Cloudflare, see scripts/deploy-site.sh) from site/ into build/site/.

Languages: Chinese at /, English, Japanese and Korean under /en/, /ja/, /ko/. Each has the home page
(site/index.html), the downloads (site/download.html → download/) and the setup guide (site/start.html
→ start/); {{t.key}} in a template is filled
from site/i18n/<lang>.json, and the build stops if a language lacks a key the others have.
header.html and footer.html are shared. site/changelog.json is the Chinese changelog (newest first;
"date": null = not released yet) and only exists in Chinese: the other languages link to GitHub Releases.
Also writes changelog/index.html, feed.xml (Atom), sitemap.xml and robots.txt.

Download links go to each platform's own newest release (scripts/release_platforms.sh): since 1.1.2
every release ships every platform, but 1.0.0 to 1.1.1 shipped only the ones that changed. A version counts once changelog.json gives it a date; a platform with none yet shows 即将发布.

    python3 scripts/site.py                 # → build/site
    python3 -m http.server -d build/site    # preview at http://localhost:8000/
SITE_URL overrides the public address (default: https://cicada.indaloop.app/).
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT_DIR, "site")
OUT = os.path.join(ROOT_DIR, "build", "site")
SITE = (os.environ.get("SITE_URL") or "https://cicada.indaloop.app/").rstrip("/") + "/"
REPO = "https://github.com/wquguru/cicada"
DOWNLOAD = REPO + "/releases/latest"
# The files each platform's release carries (release.yml); {v} is the version. The Windows installer
# has no version in its name: Cicada.exe installs and updates itself from it.
PLATFORMS = ["mac", "windows", "linux", "android"]
ASSETS = {
    "mac": {"dmg": "Cicada-{v}-macOS-AppleSilicon.dmg", "zip": "Cicada-{v}-macOS-AppleSilicon.zip"},
    "windows": {"x64": "Cicada-Setup.exe", "arm64": "Cicada-Setup-arm64.exe"},
    "linux": {"tar": "Cicada-{v}-Linux.tar.gz"},
    "android": {"apk": "Cicada-{v}-Android.apk"},
}
# The author on X: the app is not notarized yet, so a real person to ask helps people trust the first launch.
X = "https://x.com/wquguru"
STATIC = ["style.css", "icon.svg", "icon.png", "og.png", "og-en.png", "og-ja.png", "og-ko.png", "img", "audio"]
# The home page's meeting with sound, in the language its reader listens to (the English page's is
# Chinese): file, length in seconds, and who talks when as (person, start, end), one turn per
# subtitle. Both clips come from scripts/make-sample.sh; the English one is the app's onboarding
# sample (keep its turns in step with `SamplePlayer.turns`) and is copied in at build time.
SAMPLES = {
    "en": ("audio/meeting-en.m4a", 8.8, [(0, 0.25, 2.34), (1, 2.56, 6.97), (0, 7.17, 8.45)]),
    "zh": ("audio/meeting-zh.m4a", 7.8, [(0, 0.25, 2.21), (1, 2.43, 5.89), (0, 6.09, 7.45)]),
}
SAMPLE_FOR = {"zh": "en", "ja": "en", "ko": "en", "en": "zh"}
# The 同声传译 scene's line as the room hears it (make-sample.sh speak), and when in the scene's
# 10 s loop it starts: at 说进会议.
SPEAK_AT = 5.5
# (code, path prefix); the first is the default language, served at the root.
LANGS = [("zh", ""), ("en", "en/"), ("ja", "ja/"), ("ko", "ko/")]
FONT_BASE = "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&amp;family=Noto+Sans+SC:wght@400;500;700;900"
FONT_EXTRA = {"ja": "&amp;family=Noto+Sans+JP:wght@400;500;700;900", "ko": "&amp;family=Noto+Sans+KR:wght@400;500;700;900"}
KINDS = [("new", "新功能"), ("improved", "改进"), ("changed", "改动"), ("fixed", "修复")]

e = html.escape


def read(name):
    with open(os.path.join(SRC, name), encoding="utf-8") as f:
        return f.read()


def write(rel, text):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def strings():
    """site/i18n/<lang>.json, checked to have the same keys in every language."""
    out = {}
    for code, _ in LANGS:
        with open(os.path.join(SRC, "i18n", code + ".json"), encoding="utf-8") as f:
            out[code] = json.load(f)
    keys = set(out[LANGS[0][0]])
    for code, t in out.items():
        if set(t) != keys:
            sys.exit(f"site.py: i18n/{code}.json differs: missing {sorted(keys - set(t))}, extra {sorted(set(t) - keys)}")
    return out


def translate(text, t):
    """{{t.key}} → the string (HTML allowed; a bare & is escaped)."""
    def value(m):
        v = t.get(m.group(1))
        if not isinstance(v, str):
            sys.exit(f"site.py: no string for t.{m.group(1)}")
        return v.replace("&", "&amp;").replace("&amp;amp;", "&amp;")
    return re.sub(r"\{\{t\.([a-z0-9_]+)\}\}", value, text)


def fill(text, values):
    for k, v in values.items():
        text = text.replace("{{" + k + "}}", v)
    if "{{" in text:
        sys.exit("site.py: unfilled placeholder near: " + text[text.index("{{"):][:40])
    return text


def zh_date(d):
    y, m, day = d.split("-")
    return f"{int(y)} 年 {int(m)} 月 {int(day)} 日"


def anchor(version):
    return "v" + version.replace(".", "-")


def rev():
    try:
        return subprocess.check_output(["git", "rev-parse", "--short=12", "HEAD"], cwd=ROOT_DIR, text=True).strip()
    except Exception:
        return "dev"


def shipped_platforms():
    """{version: platforms it shipped}, from CHANGELOG.md's groups as scripts/release_platforms.sh reads
    them: a section with no platform group (1.0.0's Highlights) shipped the Mac app."""
    out, cur = {}, None
    for line in open(os.path.join(ROOT_DIR, "CHANGELOG.md"), encoding="utf-8"):
        m = re.match(r"^## (\d+\.\d+\.\d+)\b", line)
        if m:
            cur = out.setdefault(m.group(1), set())
            continue
        m = re.match(r"^### (Mac|Windows|Android|Linux)\s*$", line)
        if m and cur is not None:
            cur.add(m.group(1).lower())
    return {v: (ps or {"mac"}) for v, ps in out.items()}


def downloads(released):
    """{platform: (version, {asset: url})} for each platform's newest released version that has it."""
    shipped, out = shipped_platforms(), {}
    for r in released:  # newest first
        for p in shipped.get(r["version"], ()):
            if p not in out:
                v = r["version"]
                out[p] = (v, {k: f"{REPO}/releases/download/v{v}/{name.format(v=v)}" for k, name in ASSETS[p].items()})
    return out


PLATFORM_NAMES = {"mac": "Mac", "windows": "Windows", "linux": "Linux", "android": "Android"}


def download_cards(t, dl):
    """One card per platform: its system, its buttons for its own newest release, or 即将发布."""
    arrow = ('<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" '
             'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v12"/><path d="M6 11l6 6 6-6"/><path d="M5 20h14"/></svg>')
    cards = []
    for p in PLATFORMS:
        if p in dl:
            v, urls = dl[p]
            if p == "mac":
                acts = (f'<a class="btn btn-orange" href="{urls["dmg"]}">{arrow}{t["dlp_mac_btn"]}</a>'
                        f'<a class="alt" href="{urls["zip"]}">{t["dlp_mac_zip"]}</a>')
            elif p == "windows":
                acts = (f'<div class="pair"><a class="btn btn-dark" href="{urls["x64"]}">x64<small>{t["dlp_win_x64"]}</small></a>'
                        f'<a class="btn btn-light" href="{urls["arm64"]}">ARM64<small>{t["dlp_win_arm"]}</small></a></div>')
            elif p == "linux":
                acts = (f'<a class="btn btn-dark" href="{urls["tar"]}">{arrow}{t["dlp_linux_btn"]}</a>'
                        f'<code class="cmd">tar xzf Cicada-{v}-Linux.tar.gz &amp;&amp; cicada-linux/install.sh</code>')
            else:
                acts = f'<a class="btn btn-dark" href="{urls["apk"]}">{arrow}{t["dlp_android_btn"]}</a>'
            ver = f'<span class="dlver">{t["version"]} {v}</span>'
        else:
            acts, ver = f'<span class="soon">{t["dlp_soon"]}</span>', ""
        cards.append(f'<section class="card dlcard" id="{p}" data-platform="{p}"><div class="dlhead"><h2>{PLATFORM_NAMES[p]}</h2>'
                     f'<span class="yours" hidden>{t["dlp_yours"]}</span></div>'
                     f'<p class="sys">{t["dlp_" + p + "_sys"]}</p>{acts}<p class="note">{t["dlp_" + p + "_note"]}</p>{ver}</section>')
    return "".join(cards)


def compare_table(t):
    head = "".join(f"<th scope=\"col\">{PLATFORM_NAMES[p]}</th>" for p in PLATFORMS)
    rows = "".join(f'<tr><th scope="row">{e(row[0])}</th>' + "".join(f"<td>{e(c)}</td>" for c in row[1:]) + "</tr>"
                   for row in t["cmp_rows"])
    return f'<table class="cmp"><thead><tr><td></td>{head}</tr></thead><tbody>{rows}</tbody></table>'


def release_html(r, latest_released):
    date = (f'<time datetime="{r["date"]}">{zh_date(r["date"])}</time>' if r["date"]
            else '<span>即将发布</span>')
    badge = '<span class="new">最新</span>' if r["version"] == latest_released else ""
    img = ""
    if r.get("image"):
        img = f'<img src="../{e(r["image"]["src"])}" alt="{e(r["image"]["alt"])}" loading="lazy">'
    groups = []
    for kind, name in KINDS:
        items = [i for i in r["items"] if i["kind"] == kind]
        if items:
            lis = "".join(f'<li data-platforms="{" ".join(i["platforms"])}"><strong>{e(i["title"])}</strong>{e(i["text"])}</li>'
                          for i in items)
            groups.append(f'<div class="group" data-kind="{kind}"><h3><i></i>{name}</h3><ul>{lis}</ul></div>')
    a = anchor(r["version"])
    dl = (f'<a class="btn btn-dark desk" href="{REPO}/releases/tag/v{r["version"]}">下载 {r["version"]}</a>'
          if r["date"] else "")
    return (f'<article class="card release rv" id="{a}">'
            f'<div class="line"><span class="ver">{r["version"]}</span>{date}{badge}'
            f'<a class="perma" href="#{a}" aria-label="{r["version"]} 的永久链接">#</a></div>'
            f'<h2>{r["version"]}：{e(r["title"])}</h2><p>{e(r["summary"])}</p>{img}{"".join(groups)}'
            f'<div class="acts">{dl}<a class="btn btn-light" href="{REPO}/releases">在 GitHub 上看</a></div></article>')


def main():
    with open(os.path.join(SRC, "changelog.json"), encoding="utf-8") as f:
        log = json.load(f)
    released = [r for r in log if r["date"]]
    if not released:
        sys.exit("site.py: changelog.json has no released version")
    latest = released[0]
    for r in log:
        for i in r["items"]:
            if not set(i.get("platforms") or ()) <= set(PLATFORMS) or not i.get("platforms"):
                sys.exit(f"site.py: changelog.json {r['version']} “{i['title']}”: platforms must be some of {PLATFORMS}")
    dl = downloads(released)
    mac_dl = dl["mac"][1]["dmg"] if "mac" in dl else DOWNLOAD
    common = {"SITE": SITE, "REPO": REPO, "DOWNLOAD": mac_dl, "VERSION": latest["version"], "REV": rev(),
              "X": X, "X_LINK": f'<a href="{X}">@wquguru</a>'}

    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for name in STATIC:
        src = os.path.join(SRC, name)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(OUT, name))
        elif os.path.exists(src):
            shutil.copy2(src, OUT)
    shutil.copy2(os.path.join(ROOT_DIR, "Resources", "sample", "sample.m4a"), os.path.join(OUT, SAMPLES["en"][0]))

    tr = strings()
    urls = []  # (absolute url, last modified) for the sitemap

    def page(template, code, rel, extra, alternates=True, current=None):
        """Writes one page: `rel` is its path under the site ("en/start/"), `code` its language."""
        t = tr[code]
        prefix = dict(LANGS)[code]
        depth = rel.count("/")
        root = "../" * depth
        kind = rel[len(prefix):]  # "" or "start/" or "changelog/"
        langs = LANGS if alternates else [(code, prefix)]
        alts = {c: root + p + kind for c, p in langs}
        links = "".join(
            f'<a href="{alts[c]}" hreflang="{tr[c]["html_lang"]}" lang="{tr[c]["html_lang"]}"'
            + (' aria-current="true"' if c == code else "") + f'><span class="tick" aria-hidden="true"></span>{e(tr[c]["lang_name"])}</a>'
            for c, _ in langs)
        foot_links = " · ".join(
            (f'<b>{e(tr[c]["lang_name"])}</b>' if c == code
             else f'<a href="{alts[c]}" hreflang="{tr[c]["html_lang"]}" lang="{tr[c]["html_lang"]}">{e(tr[c]["lang_name"])}</a>')
            for c, _ in langs)
        hreflang = "\n".join(f'<link rel="alternate" hreflang="{tr[c]["html_lang"]}" href="{SITE}{p}{kind}">' for c, p in langs)
        if alternates:
            hreflang += f'\n<link rel="alternate" hreflang="x-default" href="{SITE}en/{kind}">'
        # What the download buttons become on another system (footer.html's script); the page itself
        # always works as the Mac download, without JS too.
        primary = {"mac": "dmg", "windows": "x64", "linux": "tar", "android": "apk"}
        dl_json = {p: {"url": dl[p][1][primary[p]], "label": t["dl_" + p]} for p in PLATFORMS if p in dl}
        v = dict(common, ROOT=root, HOME=root + prefix, LANG=code,
                 DOWNLOAD_PAGE=root + prefix + "download/", DL_JSON=json.dumps(dl_json, ensure_ascii=False),
                 DOWNLOAD_CURRENT=' aria-current="page"' if current == "download" else "",
                 OG_IMAGE=SITE + ("og.png" if code == "zh" else f"og-{code}.png"),  # share card in the page's language (scripts/site-og.html)
                 CHANGELOG=(root + "changelog/") if code == "zh" else REPO + "/releases",
                 START_CURRENT=' aria-current="page"' if current == "start" else "",
                 CANONICAL=SITE + rel, HREFLANG=hreflang, LANG_LINKS=links, LANG_LINKS_FOOT=foot_links,
                 ALTS_JSON=json.dumps(alts), FONTS=FONT_BASE + FONT_EXTRA.get(code, "") + "&amp;display=swap",
                 SCENES="".join(f"<span>{e(x)}</span>" for x in t["scenes"]),
                 SEND_JSON=json.dumps({"title": "知了 Cicada" if code == "zh" else "Cicada",
                                       "copied": t["send_copied"], "prompt": t["send_prompt"]}, ensure_ascii=False))
        v["HEADER"] = fill(translate(read("header.html"), t), v)
        v["FOOTER"] = fill(translate(read("footer.html"), t), v)
        v.update(extra)
        write(rel + "index.html", fill(translate(read(template), t), v))
        urls.append(SITE + rel)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    for code, prefix in LANGS:
        t = tr[code]
        # Home
        apps = "".join(f"<li>{e(a)}</li>" for a in t["apps"])
        apps += "".join(f'<li aria-hidden="true">{e(a)}</li>' for a in t["apps"])  # second copy for the seamless loop
        latest_section = ""
        if code == "zh":
            cards = []
            for r in log[:2]:
                when = zh_date(r["date"]) if r["date"] else t["upcoming"]
                cards.append(f'<a class="card ucard rv" href="changelog/#{anchor(r["version"])}">'
                             f'<span class="when"><span class="ver">{r["version"]}</span>{when}</span>'
                             f'<strong>{e(r["title"])}</strong><span class="d">{e(r["summary"])}</span></a>')
            latest_section = ('  <section class="wrap latest" aria-labelledby="latest-t">\n'
                              f'    <div class="head rv"><h2 id="latest-t">{t["latest_h"]}</h2><a href="changelog/">{t["latest_all"]}</a></div>\n'
                              f'    <div class="rows">{"".join(cards)}</div>\n  </section>')
        app_ld = {
            "@context": "https://schema.org", "@type": "SoftwareApplication",
            "name": "知了 Cicada", "alternateName": ["知了", "Cicada"], "inLanguage": t["html_lang"],
            "description": t["ld_desc"],
            "applicationCategory": "BusinessApplication",
            "operatingSystem": ["macOS 14.4", "Windows 10", "Ubuntu 22.04", "Android 10"],
            "softwareVersion": latest["version"], "url": SITE + prefix, "downloadUrl": DOWNLOAD,
            "image": SITE + "icon.png", "license": "https://www.apache.org/licenses/LICENSE-2.0",
            "isAccessibleForFree": True, "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "releaseNotes": SITE + "changelog/", "codeRepository": REPO,
        }
        def road(items):
            return "".join(f"<li><b>{e(h)}</b><span>{e(p)}</span></li>" for h, p in items)
        # The second item is the older-macOS one: it carries the tag that ties it to the FAQ's first answer.
        road_next = "".join(
            f'<li><b>{e(h)}</b>' + (f'<em>{e(t["road_tag"])}</em>' if i == 1 else "") + f'<span>{e(p)}</span></li>'
            for i, (h, p) in enumerate(t["road_items"]))
        # The first answer ("will it run on my Mac?") is open and has a fixed id the setup page links to.
        faq = "".join(
            f'<details class="card rv"{" open" if i == 0 else ""} id="faq-{"mac" if i == 0 else i + 1}">'
            f'<summary>{e(q)}<i aria-hidden="true"></i></summary><p>{e(a)}</p></details>'
            for i, (q, a) in enumerate(t["faq"]))
        faq_ld = {"@context": "https://schema.org", "@type": "FAQPage", "inLanguage": t["html_lang"],
                  "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
                                 for q, a in t["faq"]]}
        src, length, turns = SAMPLES[SAMPLE_FOR[code]]
        sample = {"src": "../" * prefix.count("/") + src + "?v=" + common["REV"], "len": length, "turns": turns}
        page("index.html", code, prefix, {
            "SAMPLE_JSON": json.dumps(sample),
            "SPEAK_JSON": json.dumps({"src": "../" * prefix.count("/") + f"audio/speak-{'zh' if code == 'en' else 'en'}.m4a?v=" + common["REV"], "at": SPEAK_AT}), "SAMPLE_LEN": f"0:{round(length):02d}",
            "APPS": apps, "LATEST_SECTION": latest_section,
            "ROAD_NEXT": road_next, "ROAD_LATER": road(t["road_later_items"]), "ROAD_NONE": road(t["road_none_items"]),
            "REQS": "".join(f"<div><dt>{e(k)}</dt><dd>{e(val)}</dd></div>" for k, val in t["reqs"]),
            "FAQ": faq, "FAQLD": json.dumps(faq_ld, ensure_ascii=False).replace("</", "<\\/"),
            "JSONLD": json.dumps(app_ld, ensure_ascii=False).replace("</", "<\\/")})
        # Downloads
        page("download.html", code, prefix + "download/", {
            "CARDS": download_cards(t, dl), "CMP": compare_table(t)}, current="download")
        # Setup guide
        howto = {"@context": "https://schema.org", "@type": "HowTo", "name": t["start_h1"], "inLanguage": t["html_lang"],
                 "description": t["start_desc"], "totalTime": "PT5M",
                 "step": [{"@type": "HowToStep", "position": i + 1, "name": t[k]} for i, k in enumerate(["s1_h", "s2_h", "s3_h"])]}
        page("start.html", code, prefix + "start/", {
            "JSONLD": json.dumps(howto, ensure_ascii=False).replace("</", "<\\/")}, current="start")

    # Changelog
    counts = {k: sum(1 for r in log for i in r["items"] if i["kind"] == k) for k, _ in KINDS}
    filters = f'<button type="button" data-kind="all" aria-pressed="true">全部<span>{sum(counts.values())}</span></button>'
    filters += "".join(f'<button type="button" data-kind="{k}" aria-pressed="false">{n}<span>{counts[k]}</span></button>'
                       for k, n in KINDS)
    pcounts = {p: sum(1 for r in log for i in r["items"] if p in i["platforms"]) for p in PLATFORMS}
    pfilters = '<button type="button" data-platform="all" aria-pressed="true">全部平台</button>'
    pfilters += "".join(f'<button type="button" data-platform="{p}" aria-pressed="false">{PLATFORM_NAMES[p]}<span>{pcounts[p]}</span></button>'
                        for p in PLATFORMS)
    versions = "".join(f'<a href="#{anchor(r["version"])}"><b>{r["version"]}</b>'
                       f'<span>{r["date"] or "即将发布"}</span></a>' for r in log)
    crumbs_ld = {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "知了", "item": SITE},
        {"@type": "ListItem", "position": 2, "name": "更新日志", "item": SITE + "changelog/"}]}
    page("changelog.html", "zh", "changelog/", {
        "LATEST_VERSION": latest["version"], "LATEST_TITLE": e(latest["title"]),
        "FILTERS": filters, "PFILTERS": pfilters, "VERSIONS": versions,
        "RELEASES": "".join(release_html(r, latest["version"]) for r in log),
        "JSONLD": json.dumps(crumbs_ld, ensure_ascii=False)}, alternates=False, current="changelog")

    # Atom feed: released versions only
    entries = []
    for r in released:
        body = "".join(f"<li><strong>{e(i['title'])}</strong>{e(i['text'])}</li>" for i in r["items"])
        entries.append(
            f"<entry><title>{r['version']}：{e(r['title'])}</title>"
            f"<id>{SITE}changelog/#{anchor(r['version'])}</id>"
            f"<link href=\"{SITE}changelog/#{anchor(r['version'])}\"/>"
            f"<updated>{r['date']}T00:00:00Z</updated>"
            f"<summary>{e(r['summary'])}</summary>"
            f"<content type=\"html\">{e('<p>' + e(r['summary']) + '</p><ul>' + body + '</ul>')}</content></entry>")
    write("feed.xml", '<?xml version="1.0" encoding="utf-8"?>\n'
          '<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="zh-CN">'
          f'<title>知了更新日志</title><id>{SITE}changelog/</id>'
          f'<link href="{SITE}changelog/"/><link rel="self" href="{SITE}feed.xml"/>'
          f'<updated>{latest["date"]}T00:00:00Z</updated><author><name>wquguru</name><uri>{X}</uri></author>'
          + "".join(entries) + "</feed>\n")

    write("sitemap.xml", '<?xml version="1.0" encoding="utf-8"?>\n'
          '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
          + "".join(f"<url><loc>{u}</loc><lastmod>{today}</lastmod></url>" for u in urls) + "</urlset>\n")
    write("robots.txt", f"User-agent: *\nAllow: /\nSitemap: {SITE}sitemap.xml\n")
    print("site.py: wrote", os.path.relpath(OUT, ROOT_DIR), "for", SITE)


if __name__ == "__main__":
    main()
