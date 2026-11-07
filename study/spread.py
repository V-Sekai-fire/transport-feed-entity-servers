import json, os, re, statistics as st, subprocess, sys
from patterns import CHECK, LAYOUT

def mint():
    for _ in range(5):
        o = subprocess.run(["bao-mint-github", "V-Sekai-fire"], capture_output=True, text=True).stdout.strip().split("\n")
        t = o[-1].split()[0] if o and o[-1] else ""
        if len(t) > 100:
            return t
    sys.exit("mintfail")

tok = mint()
env = dict(os.environ, GH_TOKEN=tok)
R = "V-Sekai-fire/transport-iouring-feed-server"

def gh(*a):
    return subprocess.run(["gh", "api", "--allow-escape-sequences", *a], capture_output=True, text=True, env=env).stdout

def lines(job):
    raw = gh(f"repos/{R}/actions/jobs/{job}/logs").split("\n")
    return [re.sub(r"^\S+Z ", "", re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", l)) for l in raw]

q = lambda v, f: sorted(v)[min(len(v) - 1, int(f * len(v)))]
runs = json.load(open("runs.json"))["transport-iouring-feed-server"]
check, layout, planted, jobs, overruns = [], [], [], 0, 0
for r in runs:
    if not any(j["name"] == "tick-budget" and j["concl"] == "success" for j in r["jobs"]):
        continue
    for j in json.loads(gh(f"repos/{R}/actions/runs/{r['id']}/jobs?per_page=100"))["jobs"]:
        if j["name"] != "tick-budget" or j["conclusion"] != "success":
            continue
        jobs += 1
        L = lines(j["id"])
        for i, l in enumerate(L):
            m = CHECK.search(l)
            if m and i + 1 < len(L):
                t, o, p50, p95, p99, mx = map(int, m.groups())
                if "PASS" in L[i + 1]:
                    check.append((t, p50, p99, mx))
                    overruns += o
                elif "FAIL: p99" in L[i + 1]:
                    planted.append(p99)
            if l.startswith("clean "):
                for m in LAYOUT.finditer(l):
                    a, _, c, d = map(int, m.groups())
                    layout.append((192, a, c, d))

def report(name, rows):
    if not rows:
        sys.exit(f"{name}: 0 rows parsed from {jobs} tick-budget jobs; the log format changed")
    p50 = [x[1] for x in rows]
    p99 = [x[2] for x in rows]
    mx = [x[3] for x in rows]
    print(f"{name}: {len(rows)} runs, {sum(x[0] for x in rows)} ticks, p99 equals max in {sum(a == b for a, b in zip(p99, mx))} runs")
    print(f"  p50 us min {min(p50)/1e3:.0f} median {st.median(p50)/1e3:.0f} max {max(p50)/1e3:.0f}, between-run cs {st.pstdev(p50)/st.mean(p50):.2f}")
    print(f"  p99 us min {min(p99)/1e3:.0f} median {st.median(p99)/1e3:.0f} max {max(p99)/1e3:.0f}")
    r = [c / a for a, c in zip(p50, p99)]
    print(f"  p99/p50 median {st.median(r):.2f} p95 {q(r, .95):.2f} max {max(r):.2f}")
    r = [d / a for a, d in zip(p50, mx)]
    print(f"  max/p50 median {st.median(r):.2f} p95 {q(r, .95):.2f} max {max(r):.2f}")

print("tick-budget jobs:", jobs, "entity_check overruns:", overruns)
report("entity_check, 64 ticks", check)
report("layout servers, 192 ticks", layout)
if planted:
    print(f"planted p99 ms min {min(planted)/1e6:.2f} max {max(planted)/1e6:.2f}, {len(planted)} samples")
