#!/usr/bin/env python3
"""Writes a synthetic long meeting (N lines, bilingual, with notes) into the dev build's records,
for checking how the UI copes.  long_session.py 1500"""
import json, os, sys
n = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
sid = "20261101-090000"
lines = [{"id": "h%d-%d" % (i + 1, i + 1), "t": i * 4.2, "speaker": "them", "src": "Line %d: we went through the release plan and the open questions in some detail." % (i + 1),
          "dst": "第 %d 句：我们详细过了一遍发布计划和未决问题。" % (i + 1), "srcLang": "en", "dstLang": "zh-CN"} for i in range(n)]
notes = {"title": "长会议测试", "summary": "一场很长的会议。", "covered": n, "final": True, "conclusions": [], "todos": [], "terms": [],
         "topics": [{"start": k * 600.0, "title": "话题 %d" % (k + 1), "summary": "", "points": ["要点 A", "要点 B"]} for k in range(8)]}
s = {"id": sid, "title": "会议 11月1日 09:00", "startedAt": "2026-11-01T01:00:00Z", "endedAt": "2026-11-01T02:45:00Z",
     "lines": lines, "hasAudio": False, "notes": notes}
d = os.path.expanduser("~/.local/share/cicada-dev/Sessions/" + sid)
os.makedirs(d, exist_ok=True)
json.dump(s, open(d + "/session.json", "w"), ensure_ascii=False)
print("wrote", n, "lines to", d)
