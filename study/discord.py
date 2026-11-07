import json, math
from datetime import datetime, timedelta, timezone

P = datetime.fromisoformat
inc = json.load(open("inc.json"))["incidents"]
now = datetime(2026, 11, 7, 16, 0, tzinfo=timezone.utc)
lo = now - timedelta(days=90)

def minutes(pick):
    iv = []
    for i in inc:
        if not pick(i):
            continue
        s = max(P(i["created_at"]), lo)
        e = P(i["resolved_at"]) if i.get("resolved_at") else now
        if e > lo:
            iv.append([s, e])
    iv.sort()
    out = []
    for s, e in iv:
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return len(iv), sum((e - s).total_seconds() for s, e in out) / 60

total = 90 * 1440
cases = [
    ("major and minor, whole service", lambda i: i["impact"] in ("major", "minor")),
    ("major only, whole service", lambda i: i["impact"] == "major"),
    ("major and minor tagged API or Gateway", lambda i: i["impact"] in ("major", "minor") and any(c["name"] in ("API", "Gateway") for c in i.get("components", []))),
]
for name, pick in cases:
    n, m = minutes(pick)
    a = 1 - m / total
    print(f"{name}: {n} incidents, {m:.0f} of {total} min, availability {a*100:.3f}%, {-math.log10(1-a):.2f} nines")

for period in ("day", "week", "month"):
    d = json.load(open(f"m_{period}.json"))
    v = sorted(p["value"] for m in d["metrics"] for p in m["data"] if p.get("value") is not None)
    q = lambda f: v[min(len(v) - 1, int(f * len(v)))]
    mean = sum(v) / len(v)
    sd = math.sqrt(sum((x - mean) ** 2 for x in v) / len(v))
    print(f"{period}: n {len(v)} p50 {q(.5)} p95 {q(.95)} p99 {q(.99)} max {v[-1]} cs {sd/mean:.2f} p99/p50 {q(.99)/q(.5):.2f}")
