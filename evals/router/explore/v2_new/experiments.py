"""New session or an existing one, and old sessions: why the shipped fusion sends new work to an existing session, and
variants on top of it. Grouped 10-fold CV on frozen dev moments (explore/v2_fusion/extract.py), no Jev call.

python3 -m explore.v2_new.experiments --freeze      once: dev episodes.jsonl (fully cached) frozen to /tmp/v2_new_moments.pkl
python3 -m explore.v2_new.experiments [--fit real-moment,real-rewrite] [--moments PATH] [NAME ...]
python3 -m explore.v2_new.experiments --fixed new=1.5 new=1.5,gate=12 prune=24     shipped weights with changes, no fit

Freeze with the Swift the variants are meant to start from (ROUTER_SWIFT=<an earlier RouterRoute.swift>): the frozen
features carry its `oldHours`.

Per variant, on each source: top-1; gold new → fused top a new session (recall); gold session → fused top a new session
(false new); fused top a session idle over 12 h, right or wrong; and the shipped decision (sure 0.93) on it: right,
wrong, ask, click loss.
"""
import argparse
import collections
import math
import sys

import numpy as np

sys.dont_write_bytecode = True

from explore.v2_fusion import core as C
from explore.v2_fusion import policy as Pol

RF = C.RANK_FEATS
VSURE = dict(feats=[k for k in C.CASE_FEATS if not k.startswith("_")], lam=1.0)
LAMS = [0.3, 1.0, 3.0, 10.0]
OLD_H = 12  # "old" in the report: a finished session idle this many hours


def age_features(x):
    """Per finished session (not running, not waiting on you): `age` = log(1 + idle hours), `stale` = idle ≥ 12 h."""
    board = {s["id"]: s for s in x.m["case"]["board"]["sessions"]}
    for d, f in x.fs.items():
        if not f.get("sess"):
            continue
        s = board.get(d, {})
        live = s.get("running") or s.get("waits_on_you")
        hours = 0.0 if live else (s.get("idle_min") or 0) / 60
        f["age"] = math.log1p(hours)
        f["stale"] = 1.0 if hours >= OLD_H else 0.0
        f["idle_h"] = hours


def V(name, rank=None, sure=VSURE):
    return C.Variant(name, rank, sure)


VARIANTS = {
    "shipped": C.Variant("shipped"),
    "sure": V("sure", None),
    "new": V("new", dict(feats=RF, free={"new"}, lams=LAMS)),
    "age": V("age", dict(feats=RF + ["age"], free={"age"}, lams=[1.0])),
    "age+new": V("age+new", dict(feats=RF + ["age"], free={"age", "new"}, lams=LAMS)),
    "stale+new": V("stale+new", dict(feats=RF + ["stale"], free={"stale", "new"}, lams=LAMS)),
    "age+new+rec": V("age+new+rec", dict(feats=RF + ["age"], free={"age", "new", "fin0", "fin1", "fin2", "f_said", "f_old"},
                                         lams=LAMS)),
}


def prune(data, hours):
    """Sessions idle ≥ `hours`, not running, not waiting on you, not the one you last told, offered to nobody: dropped
    from the moment's destinations (Jev's other answers kept as they were, an approximation of asking him without them)."""
    out, lost = [], 0
    for x in data:
        board = {s["id"]: s for s in x.m["case"]["board"]["sessions"]}
        keep = []
        for d in x.dests:
            f = x.fs[d]
            s = board.get(d)
            if f.get("sess") and s and not s.get("running") and not s.get("waits_on_you") and not f.get("told0") \
                    and not f.get("reply") and (s.get("idle_min") or 0) >= hours * 60:
                continue
            keep.append(d)
        y = x.dests[x.y] if x.y is not None else None
        if y is not None and y not in keep:
            lost += 1
        z = C.Moment()
        for k in C.Moment.__slots__:
            setattr(z, k, getattr(x, k))
        z.fs = {d: x.fs[d] for d in keep}
        z.dests = keep
        z.canon = [c for d, c in zip(x.dests, x.canon) if d in keep]
        z.y = keep.index(y) if y in keep else None
        out.append(z)
    return out, lost


RECENCY = ("fin0", "fin1", "fin2", "told0", "fin0u", "idle5u", "nxt")


def gated(data, hours):
    """Old sessions (finished, idle ≥ `hours`) keep their options but lose the recency features: fin*, told0, nxt."""
    out = []
    for x in data:
        z = C.Moment()
        for k in C.Moment.__slots__:
            setattr(z, k, getattr(x, k))
        z.fs = {d: ({k: v for k, v in f.items() if k not in RECENCY} if f.get("idle_h", 0) >= hours else f)
                for d, f in x.fs.items()}
        out.append(z)
    return out


def fixed(data, w):
    """Weights as given (no fit), the shipped sureness."""
    out = []
    for x in data:
        P = C.probs(x, w)
        top, cf = C.moment_feats(x, P)
        out.append(dict(top=top, P=P, s=C.sure_of(cf, C.V0), ok=C.correct(x, top)))
    return out


def kind(t):
    if t is None:
        return "none"
    if t.startswith("new:"):
        return "new"
    return "intent" if t in C.INTENTS else "session"


def report(data, preds, outs):
    by = collections.defaultdict(collections.Counter)
    for x, p, o in zip(data, preds, outs):
        src = x.source
        c = by[src]
        g = kind(x.m["gold"]["intended"])
        top = p["top"]
        c["n"] += 1
        c["top1"] += p["ok"]
        c[f"gold_{g}"] += 1
        tk = kind(top) if not x.fs.get(top, {}).get("sess") else "session"
        if g == "new":
            c["new_recall"] += tk == "new"
        if g == "session":
            c["false_new"] += tk == "new"
        if x.fs.get(top, {}).get("idle_h", 0) >= OLD_H:
            c["old_top"] += 1
            c["old_top_wrong"] += not p["ok"]
        c[o] += 1
        c["loss"] += Pol.LOSS[o]
        if g == "new":
            c["new_" + ("send" if o in ("right", "wrong") else "ask")] += 1
            c["new_right"] += o == "right"
    return by


def row(name, c):
    n = c["n"]
    pct = lambda k, d: f"{100 * c[k] / max(d, 1):.1f}"
    return (f"| {name} | {n} | {pct('top1', n)} | {c['new_recall']}/{c['gold_new']} | {c['false_new']}/{c['gold_session']} "
            f"| {c['old_top']} ({c['old_top_wrong']} wrong) | {pct('right', n)} | {pct('wrong', n)} "
            f"| {pct('ask_hit', n)}+{pct('ask_miss', n)} | {c['new_right']}/{c['gold_new']} | {c['loss'] / max(n, 1):.3f} |")


def freeze(out):
    from pathlib import Path
    from explore.v2_fusion import extract
    extract.DEV = Path(__file__).resolve().parents[2] / "v2" / "data" / "episodes" / "dev" / "episodes.jsonl"
    extract.main(Path(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--freeze", action="store_true")
    ap.add_argument("names", nargs="*", default=list(VARIANTS))
    ap.add_argument("--moments", default="/tmp/v2_new_moments.pkl")
    ap.add_argument("--fit", default="real-moment")
    ap.add_argument("--report", default="real-moment,real-rewrite,goal,scripted")
    ap.add_argument("--prune", type=float, nargs="*", default=[])
    ap.add_argument("--sure", type=float, default=0.93)
    ap.add_argument("--fixed", nargs="*", default=None,
                    help="instead of fitting: shipped weights with overrides, e.g. new=1.5 gate=24 prune=24")
    a = ap.parse_args()
    if a.freeze:
        return freeze(a.moments)
    fit_src = tuple(a.fit.split(","))
    rep_src = tuple(a.report.split(","))
    data = C.load(a.moments, sources=tuple(set(fit_src) | set(rep_src)))
    for x in data:
        age_features(x)
    fit = [x for x in data if x.source in fit_src]
    rest = [x for x in data if x.source not in fit_src]
    print("| variant | n | top-1 | gold new → top new | gold session → top new | top idle ≥ 12 h | right | wrong | ask (hit+miss) "
          "| gold new sent right | loss |\n|---|---|---|---|---|---|---|---|---|---|---|")
    if a.fixed is not None:
        for spec in [""] + a.fixed:
            kv = dict(p.split("=") for p in spec.split(",") if p)
            w = {**C.W0, **{k: float(v) for k, v in kv.items() if k not in ("gate", "prune")}}
            xs, lost = data, 0
            if "prune" in kv:
                xs, lost = prune(xs, float(kv["prune"]))
            if "gate" in kv:
                xs = gated(xs, float(kv["gate"]))
            preds = fixed(xs, w)
            outs = [Pol.outcome(x, Pol.decide(x, p["P"], p["top"], p["s"], sure=a.sure), p["P"]) for x, p in zip(xs, preds)]
            by = report(xs, preds, outs)
            for src in rep_src:
                if by[src]["n"]:
                    print(row(f"{spec or 'shipped'}{f' (gold lost {lost})' if lost else ''} · {src}", by[src]))
            sys.stdout.flush()
        return
    runs = [(n, None) for n in a.names] + [(n, h) for h in a.prune for n in a.names]
    for name, hours in runs:
        var = VARIANTS[name]
        f, r = fit, rest
        if hours is not None:
            f, lost_f = prune(fit, hours)
            r, lost_r = prune(rest, hours)
        # out of fold on the fitting sources; the others scored with weights fitted on all of them
        preds_f, _ = C.run_variant(f, var)
        w, v, _ = C.fit_full(f, var)
        preds_r = []
        for x in r:
            P = C.probs(x, w)
            top, cf = C.moment_feats(x, P)
            preds_r.append(dict(top=top, P=P, s=C.sure_of(cf, v), ok=C.correct(x, top)))
        allx, allp = f + r, preds_f + preds_r
        outs = [Pol.outcome(x, Pol.decide(x, p["P"], p["top"], p["s"], sure=a.sure), p["P"]) for x, p in zip(allx, allp)]
        by = report(allx, allp, outs)
        label = name + (f", idle ≥ {hours:g} h dropped (gold lost {lost_f}+{lost_r})" if hours is not None else "")
        for src in rep_src:
            if by[src]["n"]:
                print(row(f"{label} · {src}", by[src]))
        if var.rank is not None:
            print(f"|   weights: " + ", ".join(f"{k} {w[k]:.2f}" for k in sorted(var.rank.get("free") or []) if k in w) + " |")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
