"""Wave 2 track 5 eval: the N4 `ctx` decider with the shipped additions, through `claude -p` (the app's transport; API credits are out).

  python3 w2run.py run <variant> [dev] [--limit N] [--ids FILE] [--workers 3]   -> data/n4_<variant>_dev.jsonl (n4score-compatible rows)

Variants (all = N4 `ctx` blocks A-F, thinking off, effort high, as the app calls it):
  w2        + launchRole in the system prompt, `launch`/`launch_words` in the schema, no open card
  w2gold    w2 + the Now block's "The owner has the card of <id> open" line naming the GOLD thread (when it is on the live board)
  w2wrong   w2 + that line naming a live thread that is NOT gold (the worst case of the prior)
Reads local gitignored data only; prints counts and cost, never text."""
import concurrent.futures as cf, json, subprocess, sys, time, collections, pathlib
import n3common as C, n4ctx as N, board as B

DATA = C.DATA
MODELS = [("claude-fable-5-2", "Fable 5.2", ["fable"], ["low", "medium", "high", "xhigh", "max"]),
          ("claude-opus-5-5", "Opus 5.5", ["opus"], ["low", "medium", "high", "xhigh", "max"]),
          ("claude-sonnet-5-5", "Sonnet 5.5", ["sonnet"], ["low", "medium", "high", "max"]),
          ("claude-haiku-5-5", "Haiku 5.5", ["haiku"], [])]
ACCESS = ["approval-required", "auto-accept-edits", "auto", "full-access"]
EFFORTS = ["low", "medium", "high", "xhigh", "max"]


def launch_role():   # ports DeciderContext.launchRole verbatim
    models = "\n".join(f"- {i}: {n} (claudeAgent), also called {', '.join(a)}" + (f"; efforts {', '.join(e)}" if e else "") for i, n, a, e in MODELS)
    return f"""

A new thread can be started with settings. A message that starts new work may say how: its model, its reasoning effort, its runtime mode (how much it may do unasked) or its interaction mode (plan: it writes a plan and waits for the owner's go; default: it builds). Fill launch with only what the message itself names, never a default, and only when the message starts a new thread; otherwise launch is empty and launch_words is "". The models T3 has (model is one of these ids, runtime_mode and effort are T3's own words):
{models}
Runtime modes: {', '.join(ACCESS)}.
In launch_words put the message's words that only say those settings, copied exactly from the message, nothing added or changed; empty when the message names none. Words that are part of the work itself ("make the summary use opus-style headings") are the work: they are not settings and stay out of launch_words. Never rewrite, shorten or correct the message."""


def schema_launch(base=None):   # ports DeciderContext.schema(launch:)
    s = json.loads(json.dumps(base or N.SCHEMA))
    s["required"] = s["required"] + ["launch", "launch_words"]
    s["properties"]["launch"] = {"type": "object", "additionalProperties": False, "description": "only what the message names for a NEW thread; {} otherwise",
        "properties": {"model": {"type": "string", "enum": [m[0] for m in MODELS]}, "effort": {"type": "string", "enum": EFFORTS},
                       "runtime_mode": {"type": "string", "enum": ACCESS}, "interaction_mode": {"type": "string", "enum": ["default", "plan"]}}}
    s["properties"]["launch_words"] = {"type": "string", "description": "the message's words that only say those settings, copied exactly; empty if none"}
    return s


def claude(system, user, schema, model="claude-sonnet-5-5", effort="high", timeout=240):
    args = ["claude", "-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
            "--output-format", "json", "--settings", '{"alwaysThinkingEnabled":false}', "--effort", effort,
            "--json-schema", json.dumps(schema), "--system-prompt", system]
    t0 = time.time()
    p = subprocess.run(args, input=user, capture_output=True, text=True, timeout=timeout, cwd="/tmp")
    sec = time.time() - t0
    o = json.loads(p.stdout)
    so = o.get("structured_output")
    if so is None:
        try: so = json.loads(o.get("result") or "")
        except ValueError: so = {}
    return so, o, sec


def build(m, variant, open_id=None):
    body, sizes = N.build(m, "ctx")
    system = body["system"][0]["text"] + launch_role()
    blocks = [c["text"] for c in body["messages"][0]["content"]]
    if open_id:
        marker = "## Now\n"
        i = blocks[2].index(marker); j = blocks[2].index("\n", i + len(marker))
        sel, b = N.live_threads(m); t = next(t for t in sel if t.id == open_id or t.key == open_id)
        line = f"\nThe owner has the card of {N.tid(t.key)} open ({t.project}, {B.one(t.title, 60)})."
        blocks[2] = blocks[2][:j] + line + blocks[2][j:]
    return system, "\n\n".join(blocks), sizes


def pick_open(m, variant, gold):
    if variant == "w2": return None
    sel, b = N.live_threads(m)
    gk = {p[1] for p in gold["places"] if p[0] == "thread"}
    if variant == "w2gold":
        c = [t for t in sel if t.key in gk]
    else:
        c = sorted([t for t in sel if t.key not in gk], key=lambda t: t.minutesIdle)
    return c[0].key if c else None


def run(variant, limit=None, workers=3, idsfile=None):
    M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    path = DATA / f"n4_{variant}_dev.jsonl"
    done = {json.loads(l)["id"] for l in open(path)} if path.exists() else set()
    ids = json.load(open(idsfile)) if idsfile else N.ids_of("dev")
    if limit: ids = ids[:limit]
    todo = [i for i in ids if i not in done]
    byday = collections.defaultdict(list)
    for i in todo: byday[M[i]["day"]].append(M[i])
    fails = [0]; sch = schema_launch()

    def day_job(ms):
        out = []
        for m in sorted(ms, key=lambda m: m["at"]):
            try:
                oid = pick_open(m, variant, G[m["id"]]) if m["id"] in G else None
                if variant != "w2" and not oid: continue   # no live gold / non-gold thread to name: nothing to test
                system, user, sizes = build(m, variant, oid)
                for att in range(2):
                    try: a, o, sec = claude(system, user, sch); break
                    except Exception as e:  # noqa: BLE001
                        if att: raise
                        time.sleep(5)
                u = o.get("usage", {})
                out.append({"id": m["id"], "answer": a, "sec": sec, "usage": u, "cost": o.get("total_cost_usd") or 0, "stop": o.get("stop_reason"),
                            "sizes": sizes, "at": m["at"], "day": m["day"], "open": oid})
            except Exception as e:  # noqa: BLE001
                fails[0] += 1; print("fail", type(e).__name__, str(e)[:160], file=sys.stderr)
        return out
    with cf.ThreadPoolExecutor(workers) as ex, open(path, "a") as f:
        for fu in cf.as_completed([ex.submit(day_job, v) for v in byday.values()]):
            for r in fu.result(): f.write(json.dumps(r) + "\n")
            f.flush()
    rows = [json.loads(l) for l in open(path)]
    print(variant, len(rows), "fails", fails[0], f"cost ${sum(r['cost'] for r in rows):.2f}",
          "actions", dict(collections.Counter((r['answer'] or {}).get('action') for r in rows)))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "run":
        kw = {}
        if "--limit" in a: kw["limit"] = int(a[a.index("--limit") + 1])
        if "--workers" in a: kw["workers"] = int(a[a.index("--workers") + 1])
        if "--ids" in a: kw["idsfile"] = a[a.index("--ids") + 1]
        run(a[1], **kw)
