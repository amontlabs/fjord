"""Run working summary calls the way the app sends them (Haiku, streamed, no tools, effort low), and time them.

    python3 evals/router/summary/run.py NAME [--model M] [--system FILE] [--schema FILE] [--conc 4]
Reads data/cases.json, data/system.txt, data/schema.json and data/inputs/*.txt (written by the SummaryEvalDump test),
writes data/runs/NAME/<id>.json: {id, line, end (s), cost, in_tokens, out_tokens}. A moment whose case has `prev` is run
after it and told its line ("Your previous line: …", as RouterSummaryPrompt.text adds it). Answered cases are skipped.
"""
import argparse, json, pathlib, subprocess, time
from concurrent.futures import ThreadPoolExecutor

D = pathlib.Path(__file__).parent / "data"


def call(a, case, prev_line):
    text = (D / "inputs" / f"{case['id']}.txt").read_text()
    if prev_line:
        text += "\nYour previous line: " + prev_line
    system = pathlib.Path(a.system).read_text() if a.system else (D / "system.txt").read_text()
    schema = pathlib.Path(a.schema).read_text() if a.schema else (D / "schema.json").read_text()
    args = ["claude", "-p", "--model", a.model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--settings", '{"alwaysThinkingEnabled":false}', "--effort", "low",
            "--json-schema", schema, "--system-prompt", system]
    t0 = time.time()
    p = subprocess.run(args, input=text, capture_output=True, text=True, cwd="/tmp")
    end = time.time() - t0
    out = dict(id=case["id"], line=None, end=round(end, 2), input=text)
    for raw in p.stdout.splitlines():
        try: o = json.loads(raw)
        except Exception: continue
        if o.get("type") == "result":
            so = o.get("structured_output") or {}
            out["line"] = so.get("line")
            out["cost"] = o.get("total_cost_usd")
            u = o.get("usage") or {}
            out["in_tokens"] = (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
            out["out_tokens"] = u.get("output_tokens")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--model", default="claude-haiku-5-5")
    ap.add_argument("--system")
    ap.add_argument("--schema")
    ap.add_argument("--conc", type=int, default=4)
    a = ap.parse_args()
    out = D / "runs" / a.name
    out.mkdir(parents=True, exist_ok=True)
    cases = json.load(open(D / "cases.json"))

    def run(c):
        f = out / f"{c['id']}.json"
        if f.exists():
            return
        prev = None
        if c.get("prev"):
            pf = out / f"{c['prev']}.json"
            prev = json.load(open(pf)).get("line") if pf.exists() else None
        f.write_text(json.dumps(call(a, c, prev), indent=1))

    # Earlier moments first (their lines feed the later ones).
    for wave in ([c for c in cases if not c.get("prev")], [c for c in cases if c.get("prev")]):
        with ThreadPoolExecutor(a.conc) as ex: list(ex.map(run, wave))
    rs = [json.load(open(out / f"{c['id']}.json")) for c in cases]
    ends = sorted(r["end"] for r in rs)
    print(f"{a.name}: {sum(1 for r in rs if r['line'])}/{len(rs)} lines, end p50 {ends[len(ends)//2]:.1f}s, "
          f"cost ${sum(r.get('cost') or 0 for r in rs):.4f}, mean in {sum(r.get('in_tokens') or 0 for r in rs)/len(rs):.0f} tok")


if __name__ == "__main__":
    main()
