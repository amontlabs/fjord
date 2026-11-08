"""N3 scoring on clean gold (data/n3_gold.json): T3 gold against clean gold, and every decider's table, reweighted to the
natural ratio by the sample's strata weights, with 95% CIs from a bootstrap over days. Aggregates only.

  python3 n3score.py gold                 the confusion between T3 gold and clean gold, judge agreement
  python3 n3score.py table [dev|test]     every decider on clean gold (and the N2 app on T3 gold, for reference)
  python3 n3score.py bars <variant>       a bar grid for one variant"""
import collections
import json
import pathlib
import random
import statistics
import sys

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
import n3common as C  # noqa: E402
import board as B  # noqa: E402

DATA = C.DATA


def tup(x):
    return tuple(tup(v) for v in x) if isinstance(x, list) else x


def load(name):
    p = DATA / f"{name}.jsonl"
    return {r["id"]: r for r in map(json.loads, open(p))} if p.exists() else {}


# ---------------------------------------------------------------- decisions (N2's rules, copied from n2score / n2eval)
def sonnet_rule(a, b, idle=0.80, running=0.90, new=0.80, answer=0.80, pnew=0.85):
    known = b.thread(a.get("session") or "")
    project = b.project_named(a.get("project") or "")
    conf = a.get("confidence") or 0
    act = a.get("action")
    if act == "follow_up" and known and conf >= (running if known.running else idle): return ("thread", known.key)
    if act == "new_work" and conf >= new and project: return ("new", project)
    if pnew is not None and (a.get("p_new") or 0) >= pnew and project: return ("new", project)
    if act == "answer_here" and conf >= answer: return ("answer",)
    return ("ask",)


def guess(a, b):
    """Top-1 whatever the bars."""
    known = b.thread(a.get("session") or "")
    if a.get("action") == "answer_here": return ("answer",)
    if known and a.get("action") in ("follow_up", "ask"): return ("thread", known.key)
    p = b.project_named(a.get("project") or "")
    return ("new", p) if p else ("ask",)


def jev_send(r):
    rows = r["rows"]
    if not rows: return None
    place, p, _, running = rows[0]
    if place[0] != "thread" or running or p < B.SEND_BAR or r["running_mass"] >= B.RUNNING_GUARD: return None
    if r["fjord"] is not None and r["fjord"] >= B.FJORD_BAR: return None
    return tuple(place)


# ---------------------------------------------------------------- outcomes
def klass(places):
    k = {p[0] for p in places}
    return "amb" if k == {"new", "thread"} else ("new" if k == {"new"} else "follow")


def proj_of(m, place):
    if place[0] == "new": return place[1]
    if place[0] == "thread":
        t = next((t for t in m["board"]["threads"] if t["key"] == place[1]), None)
        if t: return t["project"]
        h = C.history(); th = h.by_id.get(place[1])
        return h.projects.get(th["project"]) if th else None
    return None


def outcome(m, places, d):
    places = [tup(p) for p in places]
    k = klass(places)
    if d[0] in ("ask", "answer"): return d[0]
    if d in places: return "right"
    xp = proj_of(m, d) not in {proj_of(m, p) for p in places}
    if k == "new": o = "pushed" if d[0] == "thread" else "new_wrong_project"
    elif k == "follow": o = "to_new" if d[0] == "new" else "wrong_thread"
    else: o = "amb_wrong"
    return o + ("_xproj" if xp and o != "new_wrong_project" else "")


# ---------------------------------------------------------------- tables
SEND = lambda o: o not in ("ask", "answer")
WRONG = lambda o: SEND(o) and o != "right"
METRICS = [
    ("new: right", "new", lambda o: o == "right"),
    ("new: pushed", "new", lambda o: o.startswith("pushed")),
    ("new: asked", "new", lambda o: o in ("ask", "answer")),
    ("follow: right", "follow", lambda o: o == "right"),
    ("follow: wrong thread", "follow", lambda o: o.startswith("wrong_thread")),
    ("follow: to new", "follow", lambda o: o.startswith("to_new")),
    ("follow: asked", "follow", lambda o: o in ("ask", "answer")),
    ("amb: right", "amb", lambda o: o == "right"),
    ("pooled sent", None, SEND),
    ("pooled wrong", None, WRONG),
    ("wrong project", None, lambda o: o.endswith("_xproj") or o == "new_wrong_project"),
]


def rows_for(dec, gold, S, M):
    return [(M[i]["day"], gold[i]["places"], outcome(M[i], gold[i]["places"], dec[i]), S["weight"][i])
            for i in dec if i in gold]


def rate(rs, kl, f):
    sel = [r for r in rs if kl is None or klass(r[1]) == kl]
    w = sum(r[3] for r in sel)
    return sum(r[3] for r in sel if f(r[2])) / w if w else None


def boot(rs, kl, f, reps=1000, seed=3):
    g = collections.defaultdict(list)
    for r in rs: g[r[0]].append(r)
    days = sorted(g); rng = random.Random(seed); vals = []
    for _ in range(reps):
        v = rate([r for d in (rng.choice(days) for _ in days) for r in g[d]], kl, f)
        if v is not None: vals.append(v)
    vals.sort()
    return (vals[int(.025 * len(vals))], vals[int(.975 * len(vals)) - 1]) if vals else (None, None)


CI_KEYS = {"new: right", "new: pushed", "follow: right", "follow: wrong thread", "follow: to new", "pooled wrong"}


def pct(v, c=None):
    if v is None: return "-"
    s = f"{100 * v:.1f}%"
    return s + (f" ({100 * c[0]:.0f}–{100 * c[1]:.0f})" if c and c[0] is not None else "")


def table_row(name, dec, gold, S, M, sec=None, cost=None):
    rs = rows_for(dec, gold, S, M)
    cells = [pct(rate(rs, kl, f), boot(rs, kl, f) if k in CI_KEYS else None) for k, kl, f in METRICS]
    lat = ""
    if sec:
        xs = sorted(sec[i] for i in dec if i in sec)
        lat = f"{statistics.median(xs):.1f} s / {xs[int(.95 * len(xs)) - 1]:.1f} s"
    c = ""
    if cost:
        w = {i: S["weight"][i] for i in dec if i in cost}
        c = f"${sum(cost[i] * w[i] for i in w) / sum(w.values()):.4f}"
    return f"| {name} | " + " | ".join(cells) + f" | {lat} | {c} |"


HEAD = "| Decider | " + " | ".join(k for k, _, _ in METRICS) + " | p50 / p95 | $/decision |"


def decisions(variant, M, rule=sonnet_rule, top=False, split="dev", **bars):
    R = load(f"n3_{variant}_{split}") if not variant.startswith("n2_") else load(variant)
    dec, sec, cost = {}, {}, {}
    for i, r in R.items():
        if i not in M: continue
        b = C.make_board(M[i])
        a = r["answer"] or {}
        dec[i] = tup(guess(a, b)) if top else tup(rule(a, b, **bars))
        sec[i] = r.get("sec") or 0; cost[i] = r.get("cost") or 0
    return dec, sec, cost


def n2_app(M, top=False, split="dev"):
    """N2 as shipped (T2): Jev's fused path first, else Sonnet v4 at new_work 0.80 or p_new 0.85. Cached answers."""
    J = load("res_jev"); V = load(f"n2_v4_{split}")
    PR = {"claude-sonnet-5-5": (2.0, 0.2, 2.5, 10.0)}
    dec, sec, cost = {}, {}, {}
    for i in M:
        if i not in V or i not in J: continue
        b = C.make_board(M[i]); a = V[i]["answer"]
        js = None if top else jev_send(J[i])
        dec[i] = js or (tup(guess(a, b)) if top else tup(sonnet_rule(a, b)))
        u = V[i]["usage"]; p = PR["claude-sonnet-5-5"]
        cs = (u["input_tokens"] * p[0] + u.get("cache_read_input_tokens", 0) * p[1] + u.get("cache_creation_input_tokens", 0) * p[2] + u["output_tokens"] * p[3]) / 1e6
        sec[i] = (J[i].get("sec") or 0) + (0 if js else V[i]["sec"]); cost[i] = cs if not js else 0.0004
    return dec, sec, cost


def gold_report():
    S = C.load_sample(); M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    T3 = {i: [list(M[i]["gold"])] for i in G}
    print("judge labels (first, second):")
    print(collections.Counter((G[i]["opus"], G[i].get("second")) for i in G))
    agree = sum(1 for i in G if G[i]["opus"] == G[i].get("second")); n2 = sum(1 for i in G if G[i].get("second"))
    print(f"label agreement {agree}/{n2}")
    tab = collections.defaultdict(float); raw = collections.Counter()
    for i in G:
        st = S["ids"][i]; t3 = {"new": "T3 new", "nc": "T3 new (continues, N1 judge)"}.get(st, "T3 follow-up")
        cg = G[i]["places"]; k = klass(cg)
        if k == "follow" and st.startswith("f_"):
            k = "follow: same thread" if any(tup(p) == tuple(M[i]["gold"]) for p in cg) else "follow: other thread"
        tab[(t3, k)] += S["weight"][i]; raw[(t3, k)] += 1
    print("T3 gold x clean gold (weighted to the dev population; raw counts in brackets):")
    for (a, b), w in sorted(tab.items()): print(f"  {a:30} -> {b:22} {w:7.1f} [{raw[(a, b)]}]")
    # label noise in N2's errors
    dec, _, _ = n2_app({i: M[i] for i in G})
    noise = collections.defaultdict(float)
    for i, d in dec.items():
        o3 = outcome(M[i], T3[i], d); oc = outcome(M[i], G[i]["places"], d)
        if SEND(o3) and o3 != "right" or o3 in ("ask", "answer"):
            noise[(o3.replace("_xproj", ""), "clean: " + oc.replace("_xproj", ""))] += S["weight"][i]
    print("N2 app errors and asks on T3 gold -> outcome on clean gold (weighted):")
    for k, w in sorted(noise.items()): print(f"  {k}: {w:.1f}")


def main(cmd="table", *args):
    if cmd == "gold": return gold_report()
    if cmd == "test": return test_table(args)
    S = C.load_sample(); M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    print(HEAD); print("|---" * (len(METRICS) + 3) + "|")
    T3 = {i: {"places": [list(M[i]["gold"])]} for i in G}
    d, s, c = n2_app({i: M[i] for i in G})
    print(table_row("a. N2 as shipped (Jev path, then v4), T3 gold", d, T3, S, M, s, c))
    print(table_row("a. N2 as shipped, clean gold", d, G, S, M, s, c))
    d2, s2, c2 = n2_app({i: M[i] for i in G}, top=True)
    print(table_row("a. N2 v4 top-1 (no bars), clean gold", d2, G, S, M))
    for v in args or ("sthink", "othink", "agent", "agent_o", "rich", "sthink_newdef", "agent_newdef", "rich_newdef"):
        d, s, c = decisions(v, M)
        if not d: continue
        print(table_row(f"{v} (n={len(d)})", d, G, S, M, s, c))
        dt, _, _ = decisions(v, M, top=True)
        print(table_row(f"{v} top-1", dt, G, S, M))


if __name__ == "__main__":
    main(*sys.argv[1:])


def test_table(spec):
    """python3 n3score.py test <variant>:idle,running,new,pnew[,idle_latest] …   the sealed test subset on its clean gold."""
    import n3bars
    S = json.load(open(DATA / "n3_sample_test_sub.json")); M = C.moments(); G = json.load(open(DATA / "n3_gold_test_sub.json"))
    print(HEAD); print("|---" * (len(METRICS) + 3) + "|")
    sub = {i: M[i] for i in G}
    T3 = {i: {"places": [list(M[i]["gold"])]} for i in G}
    d, s, c = n2_app(sub, split="test")
    print(table_row("N2 as shipped, T3 gold", d, T3, S, M, s, c))
    print(table_row("N2 as shipped, clean gold", d, G, S, M, s, c))
    for x in spec:
        v, bars = x.split(":"); bars = tuple(float(b) for b in bars.split(","))
        d, s, c = decisions(v, sub, rule=lambda a, b: n3bars.rule(a, b, *bars), split="test")
        if d: print(table_row(f"{v} {bars} (n={len(d)})", d, G, S, M, s, c))
        dt, _, _ = decisions(v, sub, top=True, split="test")
        if dt: print(table_row(f"{v} top-1", dt, G, S, M))
