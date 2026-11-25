"""Prints each model's first-run reply per clip from probe.py's results.json, to read side by side."""
import json
import sys

for m, rows in json.load(open(sys.argv[1])).items():
    print("==", m)
    for r in rows:
        if r["run"] == 0:
            print("  %-9s %-6s cer=%-5s | %s | %s %s" % (r["clip"], r["lang"], r["cer"], (r["original"] or "-")[:70],
                                                       (r["translation"] or "-")[:70], r["err"] or ""))
