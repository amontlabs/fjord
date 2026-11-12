"""Run verdict calls exactly as the app sends them (ClaudePrint.arguments, streaming), with variants, and time them.

    python3 evals/router/verdict/run.py NAME [--model M] [--effort E] [--env K=V ...] [--clip N] [--system FILE]
            [--schema FILE] [--limit N] [--ids a,b] [--kind finished|ask] [--conc 4] [--seq]
Reads data/cases.json and data/inputs/*.txt (written by the VerdictEvalDump test), writes data/runs/NAME/<id>.json:
{id, kind, verdict, state, line, end (seconds from process start), cost, out_tokens, think_tokens}.
--clip N keeps only the last N characters of the reply block in the input. Answered cases are skipped (resumable).
"""
import argparse, json, os, pathlib, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

D = pathlib.Path(__file__).parent / "data"


def clip_input(text, n):
    # the reply is the last <session-content> block under "Its last reply:"
    m = re.search(r"(Its last reply:\n<session-content untrusted=\"true\">\n)(.*?)(\n</session-content>)", text, re.S)
    if not m or len(m.group(2)) <= n:
        return text
    return text[:m.start(2)] + "…" + m.group(2)[-n:] + text[m.end(2):]


def call(a, case):
    kind = case["kind"]
    text = (D / "inputs" / f"{case['id']}.txt").read_text()
    if a.clip: text = clip_input(text, a.clip)
    system = pathlib.Path(a.system).read_text() if a.system else (D / f"system-{kind}.txt").read_text()
    schema = pathlib.Path(a.schema).read_text() if a.schema else (D / f"schema-{kind}.json").read_text()
    args = ["claude", "-p", "--model", a.model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--settings", '{"alwaysThinkingEnabled":false}']
    if a.effort: args += ["--effort", a.effort]
    args += ["--json-schema", schema, "--system-prompt", system]
    env = dict(os.environ)
    for kv in a.env: k, v = kv.split("=", 1); env[k] = v
    t0 = time.time()
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd="/tmp")
    p.stdin.write(text.encode()); p.stdin.close()
    buf, state_t, line_t, end_t, final, cost, think, outtok = "", None, None, None, None, None, 0, None
    for raw in p.stdout:
        now = time.time() - t0
        try: o = json.loads(raw)
        except Exception: continue
        if o.get("type") == "stream_event":
            d = o["event"].get("delta", {})
            if d.get("type") == "input_json_delta":
                buf += d["partial_json"]
                if state_t is None and re.search(r'"state":\s*"[a-z_]+"', buf): state_t = now
                if line_t is None and re.search(r'"line":\s*"(?:[^"\\]|\\.)*"', buf): line_t = now
        if o.get("type") == "assistant":
            for c in o["message"]["content"]:
                if c.get("type") == "tool_use": final = c["input"]
        if o.get("type") == "result":
            cost = o.get("total_cost_usd"); end_t = now
            u = o.get("usage", {}); outtok = u.get("output_tokens")
            think = (u.get("output_tokens_details") or {}).get("thinking_tokens")
            if final is None: final = o.get("structured_output")
    p.wait()
    return dict(id=case["id"], kind=kind, verdict=final, state=state_t, line=line_t, end=end_t or time.time() - t0,
                cost=cost, out_tokens=outtok, think_tokens=think)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("--model", default="claude-haiku-5-5"); ap.add_argument("--effort")
    ap.add_argument("--env", action="append", default=[]); ap.add_argument("--clip", type=int)
    ap.add_argument("--system"); ap.add_argument("--schema"); ap.add_argument("--limit", type=int)
    ap.add_argument("--ids"); ap.add_argument("--kind"); ap.add_argument("--conc", type=int, default=4)
    a = ap.parse_args()
    cases = json.load(open(D / "cases.json"))
    if a.kind: cases = [c for c in cases if c["kind"] == a.kind]
    if a.ids: cases = [c for c in cases if c["id"] in a.ids.split(",")]
    if a.limit: cases = cases[:a.limit]
    out = D / "runs" / a.name; out.mkdir(parents=True, exist_ok=True)
    todo = [c for c in cases if not (out / f"{c['id']}.json").exists()]

    def work(c):
        try: r = call(a, c)
        except Exception as e: r = dict(id=c["id"], kind=c["kind"], verdict=None, error=str(e))
        (out / f"{c['id']}.json").write_text(json.dumps(r, indent=1))
    t = time.time()
    with ThreadPoolExecutor(a.conc) as ex: list(ex.map(work, todo))
    print(f"{a.name}: {len(todo)} cases in {time.time()-t:.0f}s", file=sys.stderr)


main()
