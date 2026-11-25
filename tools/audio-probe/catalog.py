"""Lists the models a service offers that take audio in: python3 catalog.py zenmux|openrouter."""
import json
import os
import sys
import urllib.request

BASES = {"zenmux": "https://zenmux.ai/api/v1/", "openrouter": "https://openrouter.ai/api/v1/"}
SUPPORT = os.path.expanduser("~/Library/Application Support/LiveSubs Dev")


def key(service):
    path = os.path.join(SUPPORT, "ai-key-" + service)
    return open(path).read().strip() if os.path.exists(path) else None


def main():
    service = sys.argv[1]
    headers = {"User-Agent": "Cicada-probe"}
    k = key(service)
    if k:
        headers["Authorization"] = "Bearer " + k
    with urllib.request.urlopen(urllib.request.Request(BASES[service] + "models", headers=headers), timeout=30) as r:
        data = json.load(r)["data"]
    print(len(data), "models")
    for m in data:
        arch = m.get("architecture") or {}
        ins = m.get("input_modalities") or arch.get("input_modalities") or []
        if "audio" in ins:
            price = m.get("pricings") or m.get("pricing")
            print(m["id"], ins, json.dumps(price, ensure_ascii=False)[:240])


main()
