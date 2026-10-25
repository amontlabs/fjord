"""The Router's own traffic (v2/build/traffic.py export) replayed through RouteFusion as Swift decides, with variants for
new sessions and old ones. No Jev call: the trace holds his answers.

python3 -m v2.build.traffic export
python3 -m explore.v2_new.traffic [--since 2026-10-15]

A variant changes the weights, drops old sessions from the destinations (`prune`, hours), drops the recency features of
old sessions (`old`, hours: RouteFusion.oldHours) or offers only what was offered before a card could add its session
(the 20 latest finished, the running, those waiting on you). Old: finished (not running, not waiting on you) and idle
that long.
"""
import argparse
import collections
import json
import math
import pathlib
import sys

sys.dont_write_bytecode = True

from v2.run import episodes as E

DATA = pathlib.Path(__file__).resolve().parents[2] / "v2" / "data" / "traffic" / "decisions.jsonl"
W0, V0 = E._shipped_weights()
OLD_HOURS = E._shipped_old_hours()
VI = V0.pop("_intent")
INTENTS = ("question", "compound", "change_fjord")
RECENCY = ("fin0", "fin1", "fin2", "told0", "fin0u", "idle5u", "nxt")

# RouterTools' bars, RouteFusion's
SESSION_SURE, NEW_SURE, INTENT_SURE = 0.7, 0.6, 0.6
ANSWERS_SURE, ANSWERS_OTHERS, ANSWERS_CONFLICT = 0.5, 0.4, 0.5
GATE_SURE, COMPOUND2_SURE, YOU_VETO = 0.75, 0.5, 0.5
NEXT_SURE, NEXT_LEAD, NEXT_AGREE = 0.5, 0.3, 0.4
AGREES, RULES_SURE, SURE, FUSED_WORDS, SHORT_SURE = 0.5, 0.6, 0.93, 3, 0.95


def session_of(fz):
    m = {o["target"]: o.get("session") for o in fz["options"]}
    return lambda t: m.get(t)


def verdict(route, reply, gates, nxt, sess):
    """RouterTools.verdict on the trace's signals (a card's check is its session's surest)."""
    ranked = sorted(route.items(), key=lambda t: (-t[1], t[0]))

    def first(t, p):
        return [(t, p)] + [x for x in ranked if x[0] != t]
    nexts = sorted(nxt, key=lambda t: -t[1])
    if nexts:
        best = nexts[0]
        lead = best[1] - (nexts[1][1] if len(nexts) > 1 else 0)
        top = ranked[0] if ranked else None
        if best[1] >= NEXT_SURE and lead >= NEXT_LEAD and top and (top[0] == best[0] or top[0] == "unclear" or top[1] < NEXT_AGREE):
            return first(*best), True
    vetoed = gates.get("gate_you", 0) >= YOU_VETO
    if not vetoed and gates.get("gate_compound", 0) >= GATE_SURE and gates.get("gate_compound2", 1) >= COMPOUND2_SURE:
        return first("compound", gates["gate_compound"]), True
    if not vetoed and gates.get("gate_setting", 0) >= GATE_SURE:
        return first("change_fjord", gates["gate_setting"]), True
    checks = sorted(reply, key=lambda t: -t[2])
    if checks and checks[0][2] >= ANSWERS_SURE and (len(checks) < 2 or checks[1][2] <= ANSWERS_OTHERS):
        pick = ranked[0] if ranked else None
        if pick and sess(pick[0]) and sess(pick[0]) != checks[0][1] and pick[1] >= ANSWERS_CONFLICT:
            return ranked, False
        return first(checks[0][0], checks[0][2]), True
    if not ranked or ranked[0][0] == "unclear":
        return ranked, False
    t, p = ranked[0]
    if t in INTENTS and vetoed:
        return ranked, False
    bar = NEW_SURE if t.startswith("new:") else INTENT_SURE if t in INTENTS else SESSION_SURE
    return ranked, p >= bar


def decide(r, w=W0, prune=None, gate=None, cap=False):
    """(send or ask, target, fused P), as RouteFusion.decide."""
    fz = r["frozen"]
    sig, facts = fz["signals"], fz["facts"]
    sess = session_of(fz)
    idle, running = facts.get("idle") or {}, set(facts.get("running") or [])

    # A session waiting on you has a card check (RouterTools.waiting): it isn't old, however long it has waited.
    waiting = set(sig.get("reply") or {})

    def old(t, hours):
        s = sess(t)
        return bool(s) and s not in running and s not in waiting and idle.get(s, 0) >= hours * 60
    fs = {t: dict(x) for t, x in fz["fs"].items()}
    route = {t: p for t, p in sig["route"].items()}
    drop = set()
    if prune is not None:
        drop |= {t for t in fs if old(t, prune)}
    if cap:
        # As offered before a card could add its session: running, then the 20 latest others; beyond them only a
        # session whose card waits on you (it has a card check).
        others = sorted((s for s in idle if s not in running), key=lambda s: idle[s])
        recent = set(others[:20]) | running
        drop |= {t for t in fs if sess(t) and sess(t) not in recent and sess(t) not in waiting}
    if drop:
        fs = {t: x for t, x in fs.items() if t not in drop}
        route = {t: p for t, p in route.items() if t not in drop}
        z = sum(route.values()) or 1
        route = {t: p / z for t, p in route.items()}
        for t in fs:
            fs[t]["lp"] = math.log(max(route.get(t, 0), 0.001))
    if gate is not None:
        for t, x in fs.items():
            if old(t, gate):
                for k in RECENCY:
                    x.pop(k, None)
    target_of = {s: t for s, t in (facts.get("targetOf") or {}).items() if t not in drop}
    reply = [(target_of.get(s, ""), s, p) for s, p in (sig.get("reply") or {}).items() if s in target_of]
    nxt = [(target_of[s], p) for s, p in (sig.get("next") or {}).items() if s in target_of]
    rules, rules_sure = verdict(route, reply, sig.get("gates") or {}, nxt, sess)
    scores = {t: sum(w.get(k, 0) * v for k, v in x.items()) for t, x in fs.items()}
    if not scores:
        return "ask", None, {}
    m = max(scores.values())
    e = {t: math.exp(s - m) for t, s in scores.items()}
    Z = sum(e.values())
    P = {t: v / Z for t, v in e.items()}
    ranked = sorted(P.items(), key=lambda t: (-t[1], t[0]))
    top, p = ranked[0]
    second = ranked[1][1] if len(ranked) > 1 else 0
    jev_best = max((q for t, q in route.items() if t != "unclear"), default=0)
    x = fs[top]
    latest = [s for s in (facts.get("latest") or []) if s not in running]
    recent = sum(1 for s, v in idle.items() if s not in running and v <= 5)
    msg = facts.get("message") or ""
    mf = {"bias": 1, "lPtop": math.log(p / max(1 - p, 1e-4)), "lgap": math.log(max(p - second, 1e-3)),
          "ljev": math.log(max(route.get(top, 0), 1e-3)), "agree": 1 if route.get(top, 0) >= jev_best else 0,
          "u": route.get("unclear", 0), "lenlog": math.log(1 + len(msg)), "recent2": 1 if recent >= 2 else 0,
          "top_fin0": x.get("fin0", 0), "top_intent": 1 if top in INTENTS else 0, "top_new": x.get("new", 0),
          "top_reply": x.get("reply", 0)}
    v = VI if top in INTENTS else V0
    sure = 1 / (1 + math.exp(-sum(v.get(k, 0) * val for k, val in mf.items())))
    if rules_sure and rules:
        d = rules[0][0]
        own = (facts.get("targetOf") or {}).get(sess(d), d) if sess(d) else d
        if P.get(own, 0) >= AGREES and top == own and sure >= RULES_SURE:
            return "send", d, P
    words = len(msg.split())
    if top not in INTENTS and words >= FUSED_WORDS and sure >= SURE:
        return "send", top, P
    if top not in INTENTS and words < FUSED_WORDS and sure >= SHORT_SURE and sess(top) in set(facts.get("leaves") or []):
        return "send", top, P
    return "ask", top, P


def same(a, b):
    """A card's answer is its session's, as Lookout's evals count it."""
    def norm(t):
        if t and t.startswith("answer:"):
            return "session:" + t[7:].split("#")[0]
        return t
    return norm(a) == norm(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="2026-10-15")
    ap.add_argument("--data", default=str(DATA))
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    rows = [json.loads(l) for l in open(a.data)]
    rows = [r for r in rows if r["at"] >= a.since and r["frozen"] and r["gold"]["intended"]]
    # Every row with the weights Swift carries and the changes named; "before" is the Router before v2_new.
    variants = [("before (new 0.66, no old hours)", {"new": 0.66}, None, None), ("Swift now", {}, None, OLD_HOURS)]
    for nw in (0.66, 1.0, 1.5, 2.0):
        variants.append((f"new {nw}", {"new": nw}, None, None))
    for h in (12, 24, 48):
        variants.append((f"new 0.66, old {h}h", {"new": 0.66}, None, h))
        variants.append((f"new 0.66, prune {h}h", {"new": 0.66}, h, None))
        variants.append((f"new 1.5, old {h}h", {"new": 1.5}, None, h))
        variants.append((f"new 1.5, prune {h}h", {"new": 1.5}, h, None))
    for h in (72, 168):
        variants.append((f"new 0.66, prune {h}h", {"new": 0.66}, h, None))
    variants.append(("new 1.5, old 12h, offered as before cards added sessions", {"new": 1.5}, None, 12, True))
    print(f"{len(rows)} routings with gold since {a.since}: "
          f"{sum(r['gold']['intended'].startswith('new:') for r in rows)} for a new session")
    print("| variant | top right | sent right | sent wrong | asked | gold new: top new | gold session: top new | top a session idle ≥ 24 h |")
    print("|---|---|---|---|---|---|---|---|")
    for name, dw, prune, gate, *cap in variants:
        cap = bool(cap and cap[0])
        w = {**W0, **dw}
        c = collections.Counter()
        for r in rows:
            g = r["gold"]["intended"]
            kind, t, P = decide(r, w, prune, gate, cap)
            top = max(P, key=P.get) if P else None
            ok = same(top, g)
            c["top"] += ok
            if kind == "send":
                c["right" if same(t, g) else "wrong"] += 1
            else:
                c["ask"] += 1
            if g.startswith("new:"):
                c["gnew"] += 1
                c["gnew_top_new"] += bool(top and top.startswith("new:"))
            else:
                c["gsess"] += 1
                c["gsess_top_new"] += bool(top and top.startswith("new:"))
            s = session_of(r["frozen"])(top) if top else None
            idle = (r["frozen"]["facts"].get("idle") or {}).get(s, 0) if s else 0
            c["old_top"] += bool(s) and idle >= 24 * 60
            if a.verbose:
                print("   ", name, r["at"][:16], g[:40], "→", kind, (t or "")[:40], f"P={P.get(top, 0):.2f}" if top else "")
        if name.startswith("before"):
            agree = sum((decide(r, w)[0] == "send") == bool(r["frozen"]["shipped"]["sure"]) for r in rows)
            print(f"(replica agrees with the trace's sure flag on {agree}/{len(rows)})")
        print(f"| {name} | {c['top']}/{len(rows)} | {c['right']} | {c['wrong']} | {c['ask']} | {c['gnew_top_new']}/{c['gnew']} "
              f"| {c['gsess_top_new']}/{c['gsess']} | {c['old_top']} |")


if __name__ == "__main__":
    main()
