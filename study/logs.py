import json, os, re, subprocess, sys, collections
def mint():
    for _ in range(5):
        o = subprocess.run(["bao-mint-github","V-Sekai-fire"],capture_output=True,text=True).stdout.strip().split("\n")
        t = o[-1].split()[0] if o and o[-1] else ""
        if len(t) > 100: return t
    sys.exit("mintfail")
tok = mint(); env = dict(os.environ, GH_TOKEN=tok)
def gh(*a):
    r = subprocess.run(["gh","api","--allow-escape-sequences",*a],capture_output=True,text=True,env=env)
    return r.stdout.replace(tok,"***")
R = "V-Sekai-fire/transport-iouring-feed-server"
D = json.load(open("runs.json"))[ "transport-iouring-feed-server"]
clean = lambda s: re.sub(r"\x1b\[[0-9;]*[A-Za-z]","",s)
def jobs(rid): return json.loads(gh(f"repos/{R}/actions/runs/{rid}/jobs?per_page=100"))["jobs"]
print("### failure causes (one run per failing SHA)")
seen = set()
for r in sorted(D, key=lambda r: r["created"]):
    if r["concl"] != "failure" or r["sha"] in seen: continue
    seen.add(r["sha"])
    for j in jobs(r["id"]):
        if j["conclusion"] != "failure": continue
        log = clean(gh(f"repos/{R}/actions/jobs/{j['id']}/logs"))
        errs = [re.sub(r"^\S+Z ","",l)[:170] for l in log.split("\n") if re.search(r"error|Error|FAIL|failed|Segmentation|signal|cannot|not found|Unable|timed out", l, re.I) and "##[group]" not in l]
        print(f"-- {r['sha'][:7]} {r['branch']} job={j['name']} steps={[s['name'] for s in j['steps'] if s['conclusion']=='failure']}")
        for e in errs[:5]: print("     ", e)
print("### tick-budget margins (successful jobs)")
cp, pp, runs_n = [], [], 0
for r in sorted(D, key=lambda r: r["created"]):
    for j in jobs(r["id"]) if any(x["name"]=="tick-budget" and x["concl"]=="success" for x in r["jobs"]) else []:
        if j["name"] != "tick-budget" or j["conclusion"] != "success": continue
        runs_n += 1
        log = clean(gh(f"repos/{R}/actions/jobs/{j['id']}/logs")).split("\n")
        for i, l in enumerate(log):
            m = re.search(r"p99=(\d+)", l)
            if not m: continue
            vals = [int(x) for x in re.findall(r"p99=(\d+)", l)]
            nxt = log[i+1] if i+1 < len(log) else ""
            if re.search(r"\bplanted \d+:", l): pp += vals[1:]; cp += vals[:1]
            elif re.search(r"\bclean \d+:", l): cp += vals
            elif "PASS" in nxt: cp += vals
            elif "FAIL: p99" in nxt: pp += vals
print("tick-budget jobs read:", runs_n)
print("clean p99 samples:", len(cp), "max %.0f us" % (max(cp)/1000), "median %.0f us" % (sorted(cp)[len(cp)//2]/1000))
print("planted p99 samples:", len(pp), "min %.2f ms" % (min(pp)/1e6), "max %.2f ms" % (max(pp)/1e6))
print("budget 4000 us; headroom clean-max: %.1fx ; planted-min over budget: %.2fx" % (4e6/max(cp), min(pp)/4e6))
