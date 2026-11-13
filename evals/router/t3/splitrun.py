"""Split eval (a): the 300 dev moments with the shipped split prompt and schema (`sends`), through `claude -p` as the app runs it.

  python3 splitrun.py run [--limit N] [--workers 3]   -> data/n4_split_dev.jsonl (n4score-compatible rows)
  python3 splitrun.py score                            -> main decision at the shipped bars vs N4 `ctx` and `w2`, and what splits did

Every dev message has one gold destination, so any split is a risk: a sure part to a place that isn't gold is a wrong send. The
message as sent is the split's when the Swift checks keep one (`splitParts`), else the N4b rule's decision. Aggregates only."""
import collections, json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "w2"))
import n3common as C, n4ctx as N, n4score as S4, w2run as W, n3score as SC
import splitcommon as SP

DATA = C.DATA


def run(limit=None, workers=3):
    M = C.moments(); path = DATA / "n4_split_dev.jsonl"
    done = {json.loads(l)["id"] for l in open(path)} if path.exists() else set()
    ids = [i for i in N.ids_of("dev")[:limit] if i not in done]
    byday = collections.defaultdict(list)
    for i in ids: byday[M[i]["day"]].append(M[i])
    system, schema = SP.system(), SP.schema()
    import concurrent.futures as cf, time

    def day_job(ms):
        out = []
        for m in sorted(ms, key=lambda m: m["at"]):
            body, sizes = N.build(m, "ctx")
            user = "\n\n".join(c["text"] for c in body["messages"][0]["content"])
            for att in range(3):
                try: a, o, sec = W.claude(system, user, schema); break
                except Exception as e:  # noqa: BLE001
                    if att == 2: print("fail", type(e).__name__, file=sys.stderr); a = None
                    time.sleep(5)
            if a is None: continue
            out.append({"id": m["id"], "answer": a, "sec": sec, "usage": o.get("usage", {}), "cost": o.get("total_cost_usd") or 0,
                        "sizes": sizes, "at": m["at"], "day": m["day"]})
        return out
    with cf.ThreadPoolExecutor(workers) as ex, open(path, "a") as f:
        for fu in cf.as_completed([ex.submit(day_job, v) for v in byday.values()]):
            for r in fu.result(): f.write(json.dumps(r) + "\n")
            f.flush()
    rows = [json.loads(l) for l in open(path)]
    print("split", len(rows), f"cost ${sum(r['cost'] for r in rows):.2f}")


def shipped(variant):
    """Rows of `variant` decided at the shipped bars; for `split`, the split's parts override when the Swift checks keep them."""
    St = C.load_sample(); M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    rows = S4.prepare(variant, M, G, St)
    bars = (SP.BARS["idle"], SP.BARS["running"], SP.BARS["new"], SP.BARS["pnew"])
    R = S4.load_rows(variant, "dev"); out = []; stats = collections.Counter()
    for day, k, w, oc, extra, i in rows:
        o = oc(bars)
        if variant == "split":
            m = M[i]; b = C.make_board(m); a = R[i]["answer"] or {}
            if len(a.get("sends") or []) >= 2: stats["model wrote sends"] += 1
            def place(to, b=b):
                key = N.key_of(to)
                if key: return ("thread", key)
                p = b.project_named(to)
                return ("new", p) if p else None
            run = lambda key, b=b: any(t.key == key and t.running for t in b.threads)
            ps = SP.parts(a, m["message"], place, run)
            if ps:
                stats["split kept"] += 1
                gold = {tuple(p) if p[0] == "thread" else ("new", p[1]) for p in G[i]["places"]}
                gk = {p[1] for p in gold}
                sure_wrong = [p for p in ps if p[1] and p[0][0][1] not in gk]
                stats["split parts sure"] += sum(1 for p in ps if p[1])
                if sure_wrong: stats["split with a sure wrong part"] += 1; o = "wrong_thread(split)"
                else: o = "split_ok" if any(p[1] for p in ps) else "ask"
        out.append((day, [["new", "x"]] if k == "new" else ([["thread", "x"]] if k == "follow" else [["new", "x"], ["thread", "x"]]), o, w, i, k))
    return out, stats


def score():
    print("| | n | new right | new pushed | follow right | follow wrong thread | follow to new | pooled wrong | wrong project |")
    print("|---|---|---|---|---|---|---|---|---|")
    for v in ("ctx", "w2", "split"):
        rows, stats = shipped(v)
        rs = [(r[0], r[1], r[2] if not r[2].startswith(("split_ok",)) else "right", r[3]) for r in rows]
        rs = [(d, kl, ("wrong_thread" if str(o).startswith("wrong_thread") else o), w) for d, kl, o, w in rs]
        keys = ("new: right", "new: pushed", "follow: right", "follow: wrong thread", "follow: to new", "pooled wrong", "wrong project")
        cells = {k: SC.pct(SC.rate(rs, kl, f), SC.boot(rs, kl, f) if k in SC.CI_KEYS else None) for k, kl, f in SC.METRICS if k in keys}
        print(f"| {v} | {len(rows)} | " + " | ".join(cells[k] for k in keys) + " |")
        if stats: print("  ", dict(stats))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "run":
        run(int(a[a.index("--limit") + 1]) if "--limit" in a else None, int(a[a.index("--workers") + 1]) if "--workers" in a else 3)
    else: score()
