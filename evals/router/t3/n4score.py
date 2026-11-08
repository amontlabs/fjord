"""N4 scoring on clean gold with N3's day-grouped CV bars (n3bars.fit / cv), aggregates only.

  python3 n4score.py dev <variant> […]        CV table at 1% and 2% (n4 variants by N4b's rule, n3 variants by N3's rule)
  python3 n4score.py test <variant> […]       bars fitted on all of dev, applied once to the sealed test subsample
  python3 n4score.py cost <variant> […]       latency, tokens and $/decision

Variant names: n4 runs as in n4ctx.py (`ctx`, `lean`, …), with `+noguard` to drop rule 3 (owned_by / referent_unique);
N3 runs as `n3:agent`, `n3:othink`.
N4b rule: p_new >= bar_pnew with a known project -> new; new_work >= bar_new -> new; follow_up with the session a known thread,
owned_by naming it and referent_unique -> send at bar_idle (bar_running when it runs), else ask; answer_here >= 0.80; else ask."""
import json
import statistics
import sys

import n3common as C
import n3score as SC
import n3bars as NB
import n4ctx as N

DATA = C.DATA


def resolver(variant, b):
    if variant.startswith("lean"):
        return lambda s: (b.thread((s or "").strip()) or type("x", (), {"key": None})).key
    return N.key_of


def rule4(a, b, resolve, idle, running, new, pnew, guard=True):
    project = b.project_named(a.get("project") or "")
    conf = a.get("confidence") or 0; act = a.get("action")
    if pnew is not None and (a.get("p_new") or 0) >= pnew and project: return ("new", project)
    if act == "new_work" and conf >= new and project: return ("new", project)
    if act == "follow_up":
        k = resolve(a.get("session"))
        if k:
            if guard and (not a.get("referent_unique") or resolve(a.get("owned_by")) != k): return ("ask",)
            t = next((t for t in b.threads if t.key == k), None)
            if conf >= (running if t is not None and t.running else idle): return ("thread", k)
    if act == "answer_here" and conf >= 0.80: return ("answer",)
    return ("ask",)


def load_rows(variant, split):
    if variant.startswith("n3:"): return SC.load(f"n3_{variant[3:]}_{split}")
    return SC.load(f"n4_{variant.replace('+noguard', '')}_{split}")


def prepare(variant, M, G, S, split="dev"):
    R = load_rows(variant, split); out = []
    for i, r in R.items():
        if i not in G or i not in M: continue
        m = M[i]; b = C.make_board(m); a = r["answer"] or {}
        if variant.startswith("n3:"):
            rule = lambda bars, a=a, b=b: NB.rule(a, b, *bars)
        else:
            rs = resolver(variant, b); guard = not variant.endswith("+noguard")
            rule = lambda bars, a=a, b=b, rs=rs, guard=guard: rule4(a, b, rs, *bars, guard=guard)
        memo = {}
        def oc(bars, m=m, g=G[i]["places"], memo=memo, rule=rule):
            d = SC.tup(rule(bars))
            if d not in memo: memo[d] = SC.outcome(m, g, d)
            return memo[d]
        k = SC.klass(G[i]["places"])
        shown = {t.key for t in b.candidates()}
        gk = {p[1] for p in G[i]["places"] if p[0] == "thread"}
        extra = {"terse": k == "follow" and len(m["message"].split()) <= 5, "offboard": k == "follow" and not (gk & shown)}
        out.append((m["day"], k, S["weight"][i], oc, extra, i))
    return out


def sub_rates(rows, dec, flag):
    sel = [(r[2], dec[n]) for n, r in enumerate(rows) if r[4][flag]]
    w = sum(x[0] for x in sel) or 1
    f = lambda pred: sum(x[0] for x in sel if pred(x[1])) / w
    return len(sel), f(lambda o: o == "right"), f(lambda o: o.startswith(("wrong_thread", "to_new")))


def table(rows, dec):
    rs = [(r[0], [["new", "x"]] if r[1] == "new" else ([["thread", "x"]] if r[1] == "follow" else [["new", "x"], ["thread", "x"]]), dec[n], r[2])
          for n, r in enumerate(rows)]
    keys = ("new: right", "new: pushed", "follow: right", "follow: wrong thread", "follow: to new", "pooled wrong", "wrong project")
    cells = {k: SC.pct(SC.rate(rs, kl, f), SC.boot(rs, kl, f) if k in SC.CI_KEYS else None) for k, kl, f in SC.METRICS if k in keys}
    nt, tr, tw = sub_rates(rows, dec, "terse"); no, orr, ow = sub_rates(rows, dec, "offboard")
    return [cells[k] for k in keys] + [f"{tr:.0%} / {tw:.1%} (n={nt})", f"{orr:.0%} / {ow:.1%} (n={no})"]


HEAD = "| Decider | target | new right | new pushed | follow right | follow wrong thread | follow to new | pooled wrong | wrong project | terse follow sent right / wrong | off-board follow right / wrong |"


ONLY = None


def dev_main(variants, targets=(0.01, 0.02)):
    S = C.load_sample(); M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    print(HEAD); print("|---" * 11 + "|")
    for v in variants:
        rows = prepare(v, M, G, S)
        if ONLY: rows = [r for r in rows if r[5] in ONLY]
        if not rows: print("no rows", v); continue
        for t in targets:
            dec, chosen = NB.cv([r[:4] for r in rows], t)
            print(f"| {v} (n={len(rows)}) | {t:.0%} | " + " | ".join(table(rows, dec)) + " |")
            sys.stdout.flush()


def test_main(variants, targets=(0.01, 0.02)):
    S = C.load_sample(); M = C.moments(); G = json.load(open(DATA / "n3_gold.json"))
    GT = json.load(open(DATA / "n3_gold_test_sub.json")); ST = {"weight": {i: 1.0 for i in GT}}
    print(HEAD.replace("target", "target, bars")); print("|---" * 11 + "|")
    for v in variants:
        dev = prepare(v, M, G, S); tst = prepare(v, M, GT, ST, split="test")
        if not tst: print("no test rows", v); continue
        for t in targets:
            bars = NB.fit([r[:4] for r in dev], t)
            dec = {n: r[3](bars) for n, r in enumerate(tst)}
            print(f"| {v} (n={len(tst)}) | {t:.0%} {bars} | " + " | ".join(table(tst, dec)) + " |")


def cost_main(variants, split="dev"):
    print("| Decider | n | p50 / p95 s | tokens in uncached / cache read / cache write / out (mean) | $/decision measured | $/decision warm est. | cold est. |")
    print("|---|---|---|---|---|---|---|")
    for v in variants:
        R = load_rows(v, split)
        if not R: continue
        rows = list(R.values())
        secs = sorted(r["sec"] for r in rows if r.get("sec"))
        p50, p95 = (statistics.median(secs), secs[int(.95 * len(secs)) - 1]) if secs else (float('nan'), float('nan'))   # batch rows carry no latency
        if v.startswith("n3:"):
            c = statistics.mean(r["cost"] for r in rows)
            print(f"| {v} | {len(rows)} | {p50:.1f} / {p95:.1f} | out {statistics.mean(r['out_tokens'] for r in rows):.0f} | ${c:.4f} | - | - |")
            continue
        U = [r["usage"] for r in rows]
        inp = statistics.mean(u["input_tokens"] for u in U); rd = statistics.mean(u.get("cache_read_input_tokens", 0) for u in U)
        wr = statistics.mean(u.get("cache_creation_input_tokens", 0) for u in U); out = statistics.mean(u["output_tokens"] for u in U)
        meas = statistics.mean(r["cost"] for r in rows)
        warm, cold = [], []
        for r in rows:
            u = r["usage"]; z = r["sizes"]
            tot = u["input_tokens"] + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
            chars = sum(x for k, x in z.items() if not k.startswith("n_"))
            pre = tot * (z.get("A", 0) + z.get("B", 0) + z.get("C", 0)) / chars    # the 1 h prefix, A+B+C
            if v == "lean": pre = tot * z["A"] / chars
            warm.append((pre * 0.2 + (tot - pre) * 2.0 + u["output_tokens"] * 10) / 1e6)
            cold.append((pre * 4.0 + (tot - pre) * 2.0 + u["output_tokens"] * 10) / 1e6)
        print(f"| {v} | {len(rows)} | {p50:.1f} / {p95:.1f} | {inp:.0f} / {rd:.0f} / {wr:.0f} / {out:.0f} | ${meas:.4f} | ${statistics.mean(warm):.4f} | ${statistics.mean(cold):.4f} |")


if __name__ == "__main__":
    cmd, vs = sys.argv[1], sys.argv[2:]
    if "--only" in vs:   # restrict to the moments another run covers (paired comparison on a subset)
        j = vs.index("--only"); ONLY = set(load_rows(vs[j + 1], vs[j + 2] if len(vs) > j + 2 and vs[j + 2] in ("dev", "devhalf", "test") else "dev")); vs = vs[:j]
    {"dev": dev_main, "test": test_main, "cost": cost_main}[cmd](vs)
