"""N3 per-action bars on clean gold, fitted on dev with day-grouped cross-validation. Aggregates only.

  python3 n3bars.py <variant> [variant…]     CV table at a few safety targets (fit on 5/6 of the days, scored on the rest)
  python3 n3bars.py fit <variant> <target>   the bars fitted on every dev day (for the test run)

Rule: send to the top thread when action = follow_up and confidence >= the idle (or running) bar; start a new thread when
action = new_work and confidence >= the new bar, or p_new >= the p_new bar; answer_here at 0.80; else ask.
Fit: among bar settings whose weighted follow-up wrong-thread + follow-up-to-new <= target and new-work pushed <= 2*target
on the training days, maximise (new right + follow right) / 2."""
import itertools
import json
import random
import sys

import n3common as C
import n3score as SC

IDLE = [.5, .6, .7, .75, .8, .85, .9, .95, 1.01]
RUN = [.7, .8, .9, .95, 1.01]
NEW = [.4, .5, .6, .7, .75, .8, .85, .9, .95, 1.01]
PNEW = [.5, .6, .7, .8, .85, .9, .95, 1.01]
GRID = list(itertools.product(IDLE, RUN, NEW, PNEW))
CTX = "--ctx" in sys.argv
if CTX:
    sys.argv.remove("--ctx")
    GRID = list(itertools.product(IDLE, [.8], NEW, [.6, .7, .8, .85, .9, 1.01], IDLE))


def rule(a, b, idle, running, new, pnew, idle_latest=None):
    if idle_latest is not None:   # Fjord-context proxy: a lower (or higher) bar when the top thread is where the owner last wrote
        t = b.thread(a.get("session") or "")
        if t is not None and t.youLatest: idle = idle_latest
    return SC.sonnet_rule(a, b, idle=idle, running=running, new=new, answer=0.80, pnew=pnew)


def prepare(variant, M, G, S, split="dev"):
    R = SC.load(f"n3_{variant}_{split}")
    out = []
    for i, r in R.items():
        if i not in G or i not in M: continue
        m = M[i]; b = C.make_board(m); a = r["answer"] or {}
        memo = {}
        def oc(bars, a=a, b=b, m=m, g=G[i]["places"], memo=memo):
            d = SC.tup(rule(a, b, *bars))
            if d not in memo: memo[d] = SC.outcome(m, g, d)
            return memo[d]
        out.append((m["day"], SC.klass(G[i]["places"]), S["weight"][i], oc))
    return out


def stats(rows, bars):
    acc = {}
    for day, k, w, oc in rows:
        o = oc(bars)
        s = acc.setdefault(k, [0.0, {}]); s[0] += w; s[1][o] = s[1].get(o, 0) + w
    def r(k, f):
        if k not in acc or not acc[k][0]: return 0.0
        return sum(v for o, v in acc[k][1].items() if f(o)) / acc[k][0]
    return {"new_right": r("new", lambda o: o == "right"), "pushed": r("new", lambda o: o.startswith("pushed")),
            "f_right": r("follow", lambda o: o == "right"), "f_wrong": r("follow", lambda o: o.startswith("wrong_thread")),
            "f_new": r("follow", lambda o: o.startswith("to_new"))}


def fit(rows, target):
    best, bv = None, -1
    for bars in GRID:
        s = stats(rows, bars)
        if s["f_wrong"] + s["f_new"] > target or s["pushed"] > 2 * target: continue
        v = (s["new_right"] + s["f_right"]) / 2
        if v > bv: best, bv = bars, v
    return best


def cv(rows, target, folds=6, seed=7):
    days = sorted({r[0] for r in rows}); random.Random(seed).shuffle(days)
    fold = {d: n % folds for n, d in enumerate(days)}
    dec = {}
    chosen = []
    for f in range(folds):
        train = [r for r in rows if fold[r[0]] != f]
        bars = fit(train, target) or GRID[-1]
        chosen.append(bars)
        for n, r in enumerate(rows):
            if fold[r[0]] == f: dec[n] = r[3](bars)
    return dec, chosen


def main(variants, targets=(0.005, 0.01, 0.02, 0.03)):
    S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))
    print("| Decider, CV bars | target | " + " | ".join(k for k, _, _ in SC.METRICS) + " |")
    for v in variants:
        rows = prepare(v, M, G, S)
        if not rows: continue
        for t in targets:
            dec, chosen = cv(rows, t)
            rs = [(r[0], None, dec[n], r[2]) for n, r in enumerate(rows)]
            rs = [(d, [["new", "x"]] if k == "new" else ([["thread", "x"]] if k == "follow" else [["new", "x"], ["thread", "x"]]), o, w)
                  for (d, _, o, w), k in zip(rs, (r[1] for r in rows))]
            cells = [SC.pct(SC.rate(rs, kl, f), SC.boot(rs, kl, f) if k in SC.CI_KEYS else None) for k, kl, f in SC.METRICS]
            print(f"| {v}{' +last-written bar' if CTX else ''} | {t:.1%} | " + " | ".join(cells) + f" | folds' bars {sorted(set(chosen))[:3]}")
            sys.stdout.flush()


if __name__ == "__main__":
    if sys.argv[1] == "fit":
        S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))
        rows = prepare(sys.argv[2], M, G, S); b = fit(rows, float(sys.argv[3]))
        print(sys.argv[2], "bars (idle, running, new, p_new):", b, stats(rows, b))
    else:
        main(sys.argv[1:])
