#!/usr/bin/env python3
"""Writes a version's CHANGELOG.md section from the commits since the last tag.

scripts/changelog.py 1.0.1            # replaces "## Unreleased" (or adds a section) dated today
scripts/changelog.py 1.0.1 --print    # only prints the section

Release notes are the commit subjects, grouped by platform (one version covers them all): the scope
picks it, (windows) (android) (linux) or (site) for the website, (ios) none yet, anything else Mac; feat: goes under
New and fix: under Fixed; chore/docs/build/test/refactor stay out. Every release ships every
platform, so one with no feat or fix still gets a group saying so. `fix(windows,linux):` lands in both.
Each line links its commit. Lines written by hand under "## Unreleased" stay on top, as the
release's one-line summary.
"""
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "https://github.com/wquguru/cicada"
SUBJECT = re.compile(r"^(feat|fix|perf)(?:\(([^)]*)\))?!?: (.+)$")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def commits():
    try:
        since = git("describe", "--tags", "--abbrev=0") + "..HEAD"
    except subprocess.CalledProcessError:
        since = "HEAD"  # no tag yet: everything
    out = git("log", "--reverse", "--format=%H%x09%s", since)
    return [line.split("\t", 1) for line in out.splitlines() if line]


PLATFORMS = {"mac": "Mac", "windows": "Windows", "android": "Android", "linux": "Linux", "site": "Website"}
# Platforms in the repo that no release builds yet: their commits stay out of the notes instead of
# falling to Mac (a `feat(ios):` line would read as a Mac feature).
UNSHIPPED = {"ios"}


def platforms(scope):
    """The groups a commit's scope puts it in: Mac unless it names another platform."""
    scopes = re.split(r"[,\s]+", scope or "")
    names = [PLATFORMS[s] for s in scopes if s in PLATFORMS]
    if not names and any(s in UNSHIPPED for s in scopes):
        return []
    return names or ["Mac"]


def section(version, summary, entries=None):
    groups = {name: {"New": [], "Fixed": []} for name in PLATFORMS.values()}
    for sha, subject in commits() if entries is None else entries:
        m = SUBJECT.match(subject)
        if not m:
            continue
        kind, scope, text = m.groups()
        line = f"- {text[0].upper() + text[1:]} ([{sha[:7]}]({REPO}/commit/{sha}))"
        for name in platforms(scope):
            groups[name]["New" if kind == "feat" else "Fixed"].append(line)
    lines = [f"## {version} — {datetime.date.today().isoformat()}", ""]
    if summary:
        lines += [summary, ""]
    for name, kinds in groups.items():
        if not any(kinds.values()):
            # Every release ships every platform (one version for all), so an app with nothing new
            # still gets its group: scripts/release_platforms.sh and the site read the groups.
            if name != "Website":
                lines += [f"### {name}", "", "No changes; released to keep every platform on the same version.", ""]
            continue
        lines += [f"### {name}", ""]
        if name == "Website":  # the site has no new/fixed split, as before
            lines += [*kinds["New"], *kinds["Fixed"], ""]
            continue
        for kind, items in kinds.items():
            if items:
                lines += [f"#### {kind}", "", *items, ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2 or not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]):
        sys.exit("usage: scripts/changelog.py <x.y.z> [--print]")
    version = sys.argv[1]
    path = os.path.join(ROOT, "CHANGELOG.md")
    text = open(path, encoding="utf-8").read()
    # The "## Unreleased" block, if any: its text becomes the summary.
    m = re.search(r"^## Unreleased\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    summary = m.group(1).strip() if m else ""
    new = section(version, summary)
    if "--print" in sys.argv:
        print(new)
        return
    if m:
        text = text[:m.start()] + new + "\n" + text[m.end():]
    else:
        first = re.search(r"^## ", text, re.M)
        at = first.start() if first else len(text)
        text = text[:at] + new + "\n" + text[at:]
    open(path, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    main()
