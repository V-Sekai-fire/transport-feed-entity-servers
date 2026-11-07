import json, os, subprocess, sys
def mint():
    for _ in range(5):
        out = subprocess.run(["bao-mint-github","V-Sekai-fire"],capture_output=True,text=True).stdout.strip().split("\n")
        t = out[-1].split()[0] if out and out[-1] else ""
        if len(t) > 100: return t
    sys.exit("mintfail")
tok = mint()
env = dict(os.environ, GH_TOKEN=tok)
def api(path, paginate=False):
    cmd = ["gh","api"] + (["--paginate"] if paginate else []) + [path]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode: raise SystemExit(r.stderr.replace(tok,"***")[:300])
    txt = r.stdout
    if paginate:  # concatenated JSON objects
        dec, i, objs = json.JSONDecoder(), 0, []
        while i < len(txt):
            while i < len(txt) and txt[i].isspace(): i += 1
            if i >= len(txt): break
            o, j = dec.raw_decode(txt, i); objs.append(o); i = j
        return objs
    return json.loads(txt)
out = {}
for repo in ["transport-iouring-feed-server","contract-entity-packet"]:
    runs = []
    for page in api(f"repos/V-Sekai-fire/{repo}/actions/runs?per_page=100", True):
        runs += page["workflow_runs"]
    rows = []
    for r in runs:
        jobs = api(f"repos/V-Sekai-fire/{repo}/actions/runs/{r['id']}/jobs?per_page=100")["jobs"]
        rows.append(dict(id=r["id"], wf=r["name"], event=r["event"], branch=r["head_branch"], sha=r["head_sha"],
            attempt=r["run_attempt"], status=r["status"], concl=r["conclusion"], created=r["created_at"],
            started=r["run_started_at"], updated=r["updated_at"],
            jobs=[dict(name=j["name"], concl=j["conclusion"], started=j["started_at"], completed=j["completed_at"],
                       failed=[s["name"] for s in j["steps"] if s["conclusion"]=="failure"]) for j in jobs]))
    out[repo] = rows
    print(repo, len(rows), "runs")
json.dump(out, open("runs.json","w"), indent=1)
