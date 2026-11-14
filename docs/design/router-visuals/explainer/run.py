"""Run the creator on one case: run.py cases/<name>. Writes v1.js… (live previews), final.js, final/ frames, run.json."""
import json, subprocess, sys, pathlib, re, time, os
HERE = pathlib.Path(__file__).parent.resolve()
case = pathlib.Path(sys.argv[1]).resolve()
model = sys.argv[2] if len(sys.argv) > 2 else "claude-opus-5-5"
ask = (case / "ask.txt").read_text()
cfg = case / "mcp.json"
cfg.write_text(json.dumps({"mcpServers": {"explainer": {"command": "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3", "args": [str(HERE / "preview_server.py")],
                                                        "env": {"CASE_DIR": str(case), "ASK": ask}}}}))
for f in case.glob("v*.js"): f.unlink()
cmd = ["claude", "-p", "--model", model, "--system-prompt-file", str(HERE / "system.md"), "--tools", "",
       "--mcp-config", str(cfg), "--strict-mcp-config", "--allowedTools", "mcp__explainer__preview",
       "--setting-sources", "", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
t0 = time.time()
log = open(case / "stream.jsonl", "w")
r = subprocess.run(cmd, input=(case / "user.md").read_text(), stdout=log, stderr=subprocess.PIPE, text=True, timeout=1500, cwd=case)
log.close()
events = [json.loads(l) for l in open(case / "stream.jsonl") if l.strip().startswith("{")]
res = next((e for e in events if e.get("type") == "result"), {"error": r.stderr[-2000:]})
code = re.findall(r"```(?:js|javascript)\n(.*?)```", res.get("result", ""), re.S)
if code:
    (case / "final.js").write_text(code[-1])
meta = {k: res.get(k) for k in ("total_cost_usd", "duration_ms", "num_turns", "usage", "is_error", "error")}
meta["wall_s"] = round(time.time() - t0); meta["versions"] = len(list(case.glob("v*.js"))); meta["model"] = model
(case / "run.json").write_text(json.dumps(meta, indent=1))
print(case.name, json.dumps({k: meta[k] for k in ("total_cost_usd", "num_turns", "wall_s", "versions")}), "final" if code else "NO CODE")
