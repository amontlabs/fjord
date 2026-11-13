"""Replay real sequences through open-items reads the way the app makes them (claude -p, streamed, no tools, effort low).

    python3 evals/router/items/run.py NAME [--model M] [--message-model M] [--turn-system FILE] [--conc 4]
Reads data/cases.json and the SummaryEvalDump-style parts written by the ItemsEvalDump test (data/parts.json, system-*.txt,
schema-*.json). Each case is replayed in order: a ledger starts empty; a turn is read with the open items; your words are
read only when something is open (as the app does); closes, merges and adds are applied as RouterLedger does. Writes
data/runs/NAME/<id>.json: the trace per step (open before, the answer, the ledger after, seconds, cost). Cases already run
are skipped.
"""
import argparse, json, os, pathlib, subprocess, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

D = pathlib.Path(os.environ.get("ITEMS_DATA") or pathlib.Path(__file__).parent / "data")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def age(m):
    m = max(int(m), 0)
    return f"{m} min" if m < 60 else f"{m // 60} h" if m < 2880 else f"{m // 1440} days"


def open_block(items, now):
    """RouterItemsPrompt.openBlock (the dump's open-sample.txt checks the format)."""
    if not items:
        return "Open items: none"
    out = ["Open items:"]
    for i in items:
        mins = (now - i["since"]).total_seconds() / 60 if now and i.get("since") else 0
        line = f"- id {i['id']} ({i['kind']}, open {age(mins)}): {i['sentence']}"
        if i.get("options"):
            line += " Options: " + " / ".join(i["options"])
        out.append(line)
    return "\n".join(out)


def call(a, kind, text):
    """kind: turn, said (a mid-run message: finds, no line) or message."""
    own = {"turn": a.turn_system, "said": a.said_system, "message": a.message_system}[kind]
    system = pathlib.Path(own).read_text() if own else (D / f"system-{kind}.txt").read_text()
    schema = (D / f"schema-{kind}.json").read_text()
    model = a.message_model or a.model if kind == "message" else a.model
    args = ["claude", "-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--settings", '{"alwaysThinkingEnabled":false}', "--effort", "low", "--json-schema", schema, "--system-prompt", system]
    t0 = time.time()
    p = subprocess.run(args, input=text, capture_output=True, text=True, cwd="/tmp")
    out = dict(answer=None, end=round(time.time() - t0, 2), first=None)
    for raw in p.stdout.splitlines():
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if out["first"] is None and o.get("type") == "stream_event":
            ev = o.get("event") or {}
            if ev.get("type") == "content_block_delta" and (ev.get("delta") or {}).get("type") == "input_json_delta":
                out["first"] = round(time.time() - t0, 2)
        if o.get("type") == "result":
            out["answer"] = o.get("structured_output")
            out["cost"] = o.get("total_cost_usd")
            u = o.get("usage") or {}
            out["in_tokens"] = sum(u.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            out["out_tokens"] = u.get("output_tokens")
    return out


def replay(a, case, parts):
    ledger, n, trace = [], 0, []
    for k, step in enumerate(case["steps"]):
        now = ts(step.get("at"))
        turn = step["kind"] == "turn"
        finds = step["kind"] in ("turn", "said")
        live = [i for i in ledger]
        rec = dict(step=k, kind=step["kind"], open=[dict(id=i["id"], kind=i["kind"], sentence=i["sentence"]) for i in live])
        if not finds and not live:
            rec["skipped"] = "nothing open"
            trace.append(rec)
            continue
        text = "\n".join([parts["head"], open_block(live, now), parts["steps"][k]])
        r = call(a, step["kind"], text)
        rec.update(end=r["end"], first=r["first"], cost=r.get("cost"), in_tokens=r.get("in_tokens"), out_tokens=r.get("out_tokens"))
        ans = r["answer"]
        rec["answer"] = ans
        if not ans:
            rec["failed"] = True
            trace.append(rec)
            continue
        ids = {i["id"] for i in live}
        # RouterItemsReading.quote: a quote is kept only when it is, trimmed, in the agent's words read, word for word.
        source = step.get("reply") if turn else step.get("text") if finds else None
        rec["quotes"] = {"given": 0, "kept": 0}
        for f in ans.get("found", []) if finds else []:
            q = (f.get("quote") or "").strip()
            if q:
                rec["quotes"]["given"] += 1
                if source and q in source:
                    rec["quotes"]["kept"] += 1
                else:
                    rec.setdefault("dropped_quotes", []).append(q)
        closes = {e["id"]: (e.get("how") or "obsolete") for e in ans.get("open", []) if e.get("verdict") == "close" and e.get("id") in ids}
        ledger = [i for i in ledger if i["id"] not in closes]
        for f in ans.get("found", []) if finds else []:
            same = f.get("same_as") if f.get("same_as") in ids and f.get("same_as") not in closes else None
            if same:
                for i in ledger:
                    if i["id"] == same:
                        i.update(sentence=f["sentence"], since=now, options=f.get("options") or i.get("options"))
            else:
                n += 1
                ledger.append(dict(id=f"i{n}", kind=f["kind"], sentence=f["sentence"], options=f.get("options") or [], since=now))
        rec["closed"] = closes
        rec["after"] = [dict(id=i["id"], kind=i["kind"], sentence=i["sentence"]) for i in ledger]
        trace.append(rec)
    return trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--message-model")
    ap.add_argument("--turn-system")
    ap.add_argument("--message-system")
    ap.add_argument("--said-system")
    ap.add_argument("--conc", type=int, default=4)
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    out = D / "runs" / a.name
    out.mkdir(parents=True, exist_ok=True)
    cases = json.load(open(D / "cases.json"))
    parts = {p["id"]: p for p in json.load(open(D / "parts.json"))}
    if a.only:
        cases = [c for c in cases if c["id"] in a.only]

    def run(c):
        f = out / f"{c['id']}.json"
        if f.exists():
            return
        f.write_text(json.dumps(dict(id=c["id"], trace=replay(a, c, parts[c["id"]])), indent=1, default=str))

    with ThreadPoolExecutor(a.conc) as ex:
        list(ex.map(run, cases))
    rs = [json.load(open(out / f"{c['id']}.json")) for c in cases]
    calls = [s for r in rs for s in r["trace"] if "end" in s]
    ends = sorted(s["end"] for s in calls)
    firsts = sorted(s["first"] for s in calls if s.get("first"))
    print(f"{a.name}: {len(rs)} cases, {len(calls)} calls, {sum(1 for s in calls if s.get('failed'))} failed, "
          f"end p50 {ends[len(ends)//2]:.1f}s p90 {ends[int(len(ends)*0.9)]:.1f}s, first p50 {firsts[len(firsts)//2] if firsts else 0:.1f}s, "
          f"cost ${sum(s.get('cost') or 0 for s in calls):.3f} (${sum(s.get('cost') or 0 for s in calls)/max(len(calls),1):.4f}/call)")


if __name__ == "__main__":
    main()
