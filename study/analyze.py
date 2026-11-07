import json, math, collections
from datetime import datetime
D = json.load(open("runs.json"))
P = lambda s: datetime.fromisoformat(s.replace("Z","+00:00")) if s else None
def wilson_upper(k, n, z=1.96):
    if n == 0: return 1.0
    p = k/n; d = 1+z*z/n
    c = p + z*z/(2*n); a = z*math.sqrt(p*(1-p)/n + z*z/(4*n*n))
    return (c+a)/d
for repo, runs in D.items():
    print("="*70); print(repo, len(runs), "runs")
    print("by event/concl:", dict(collections.Counter((r["event"], r["concl"]) for r in runs)))
    print("by workflow:", dict(collections.Counter(r["wf"] for r in runs)))
    print("rerun attempts>1:", [r["id"] for r in runs if r["attempt"]>1])
    q = [(P(r["started"])-P(r["created"])).total_seconds() for r in runs if r["started"]]
    print("queue s: max %.0f median %.0f" % (max(q), sorted(q)[len(q)//2]))
    print("span:", min(r["created"] for r in runs), "->", max(r["created"] for r in runs))
    bysha = collections.defaultdict(list)
    for r in runs: bysha[r["sha"]].append(r)
    print("distinct head SHAs:", len(bysha))
    print("--- non-success runs")
    for r in sorted(runs, key=lambda r: r["created"]):
        if r["concl"] != "success":
            fj = [(j["name"], j["failed"]) for j in r["jobs"] if j["concl"] not in ("success","skipped")]
            print(r["created"][11:19], r["event"], r["branch"], r["sha"][:7], r["concl"], fj)
    print("--- same SHA, differing outcomes (flake signature)")
    for sha, rs in bysha.items():
        o = {(r["event"], r["concl"]) for r in rs}
        concl = {r["concl"] for r in rs if r["concl"] != "cancelled"}
        if len(concl) > 1: print(sha[:7], sorted(o))
    print("--- per job")
    jb = collections.defaultdict(list)
    for r in runs:
        for j in r["jobs"]: jb[(r["wf"], j["name"])].append((r, j))
    for k, v in sorted(jb.items()):
        c = collections.Counter(j["concl"] for _, j in v)
        done = [(P(j["completed"])-P(j["started"])).total_seconds() for _, j in v if j["completed"] and j["started"] and j["concl"]=="success"]
        print(k, dict(c), "dur s: %s" % (("min %.0f med %.0f max %.0f" % (min(done), sorted(done)[len(done)//2], max(done))) if done else "-"))
