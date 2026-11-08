"""Refit E5's fused path (Sources/Fjord/RouterJevPath.swift) on Fjord's own decision log.

    python3 evals/router/t3/refit.py [~/Library/Application Support/Fjord/decider-log.jsonl] [--bar 0.9] [--guard 0.25]

Reads the log (local, never committed), joins each decision's `fused` rows with where the message really went, refits the
8 weights (conditional logit over the places, L2 1.0: fusion.py's `fit`), and prints:
  - how the shipped weights did on the log (top-1, sends at the bar, wrong sends);
  - the same for leave-one-day-out refits (honest: each day scored by weights fit without it);
  - the refit on everything, as the Swift line to paste into `JevPath.weights`.
Prints counts and weights only, never message text.

Where a message went (the gold), per decision id:
  - an ask's pick (`outcome: picked`) or a pick after Send elsewhere: that place;
  - a send (`sent: sent`) never moved (no `sent_elsewhere`): the place it was sent to;
  - anything else (dismissed, answered here, still asking): left out.
A message sent where you picked from the preview's menu has no fused rows to fit (type `preview`) and is only counted.
"""
import collections, json, math, pathlib, sys

import numpy as np
from scipy.optimize import minimize

FEATS = ["lp", "fin0", "fin1", "new", "nc", "an", "nc_lead", "lx_said"]
SHIPPED = [0.6340, 0.7668, 0.4248, 0.0661, 1.9248, 1.1790, 0.2214, 0.7726]
DEFAULT = pathlib.Path.home() / "Library/Application Support/Fjord/decider-log.jsonl"


def target_id(kind, target):
    return {"thread": "t3-thread:", "new_thread": "new_thread:"}.get(kind, "?") + target


def load(path):
    decisions, outcomes, previews = {}, collections.defaultdict(list), []
    for line in open(path):
        r = json.loads(line)
        if r.get("type") == "decision" and r.get("fused"):
            decisions[r["id"]] = r
        elif r.get("type") == "outcome":
            outcomes[r["id"]].append(r)
        elif r.get("type") == "preview":
            previews.append(r)
    moments = []
    for i, d in decisions.items():
        outs = outcomes.get(i, [])
        picked = [o["target"] for o in outs if o["what"] == "picked" and o.get("target")]
        moved = any(o["what"] in ("sent_elsewhere", "reverted") for o in outs)
        if picked:
            gold = picked[-1]
        elif d.get("sent") == "sent" and not moved:
            gold = target_id(d["kind"], d["target"])
        else:
            continue
        rows = d["fused"]["rows"]
        X = np.array([[r["features"].get(f, 0.0) for f in FEATS] for r in rows])
        y = [j for j, r in enumerate(rows) if r["target"] == gold]
        moments.append(dict(id=i, day=d["at"][:10], X=X, y=y, rows=rows, gold=gold,
                            mass=d["fused"].get("runningMass", 0.0), fjord=d["fused"].get("fjord", 0.0)))
    return moments, previews


def fit(ms, l2=1.0):
    data = [(m["X"], m["y"]) for m in ms if m["y"]]

    def nll(w):
        tot = l2 * (w @ w); g = 2 * l2 * w
        for X, y in data:
            z = X @ w; z -= z.max(); e = np.exp(z); P = e / e.sum()
            py = P[y].sum(); tot -= math.log(max(py, 1e-12))
            g += X.T @ P - (X[y].T @ P[y]) / py
        return tot, g
    w0 = np.zeros(len(FEATS)); w0[0] = 1.0
    return minimize(nll, w0, jac=True, method="L-BFGS-B").x


def decide(m, w, bar, guard):
    z = m["X"] @ w; z -= z.max(); P = np.exp(z); P /= P.sum()
    j = int(P.argmax()); top = m["rows"][j]
    send = (top["target"].startswith("t3-thread:") and not top["running"] and P[j] >= bar
            and m["mass"] < guard and (m["fjord"] or 0) < 0.3)
    return top["target"], send


def score(ms, weights, bar, guard):
    top = sent = wrong = 0
    for m in ms:
        pick, send = decide(m, weights(m), bar, guard)
        top += pick == m["gold"]; sent += send; wrong += send and pick != m["gold"]
    n = max(len(ms), 1)
    return f"n={len(ms)} top1={100 * top / n:.0f}% sent={100 * sent / n:.0f}% wrong={wrong} ({100 * wrong / n:.1f}%/msg)"


def main():
    args = sys.argv[1:]
    bar = float(args[args.index("--bar") + 1]) if "--bar" in args else 0.90
    guard = float(args[args.index("--guard") + 1]) if "--guard" in args else 0.25
    paths = [a for a in args if not a.startswith("--") and not a.replace(".", "").isdigit()]
    ms, previews = load(paths[0] if paths else DEFAULT)
    print(f"{len(ms)} decisions with fused rows and a known place; {len(previews)} preview picks "
          f"({sum(p.get('changed', False) for p in previews)} changed the place shown)")
    if not ms:
        return
    shipped = np.array(SHIPPED)
    print("shipped weights        ", score(ms, lambda m: shipped, bar, guard))
    days = sorted({m["day"] for m in ms})
    if len(days) > 1:
        folds = {d: fit([m for m in ms if m["day"] != d]) for d in days}
        print("leave-one-day-out refit", score(ms, lambda m: folds[m["day"]], bar, guard))
    w = fit(ms)
    print("refit on all, in-sample", score(ms, lambda m: w, bar, guard))
    print("weights:", {f: round(float(x), 4) for f, x in zip(FEATS, w)})
    print("Swift:   static let weights: [Double] = [" + ", ".join(f"{x:.4f}" for x in w) + "]")


if __name__ == "__main__":
    main()
