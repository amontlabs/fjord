"""The routing benchmark: a format on every case set, scored per set by one policy.

python3 bench.py FORMAT [FORMAT...] [--policy final|<module>:<name>] [--orders 1] [--sets synth,heldout,real,style]

Sets:
  synth    cases/*.jsonl              210 written cases (everyday, hard, traps), 2 labelers
  heldout  heldout/*.jsonl            150 written independently, bigger boards
  real     real/data/real.jsonl       611 real moments from your sessions: the message you typed, the board then,
                                      where it went; label (clear / plausible / unclear) says whether the board alone
                                      shows it. Strict: a send anywhere else is wrong.
  style    real/data/routerstyle_*.jsonl  Router-style messages written on those real boards
Score per set: right, wrong (of which to a session), ask, needless ask (asked where the destination was clear)."""
import argparse
import collections
import glob
import importlib
import json
import pathlib

import analyze
import run

HERE = pathlib.Path(__file__).parent
SETS = {"synth": "cases/*.jsonl", "heldout": "heldout/*.jsonl", "real": "real/data/real.jsonl",
        "style": "real/data/routerstyle_*.jsonl"}
INTENTS = {"question", "compound", "change_fjord"}

FINAL = dict(p_min=0.7, lead=0, reply=0.5, reply_other=0.4, p_new=0.6, p_intent=0.6, conflict=0.5, g_compound=0.75,
             g_setting=0.75, g_question=2)


def labels():
    out = {}
    for f in glob.glob(str(HERE / "real" / "data" / "labels_*.jsonl")):
        for line in open(f):
            if line.strip():
                j = json.loads(line)
                out[j["id"]] = j
    return out


def half(case_id):
    """realA or realB, by the session the message went to: tune on one half, test on sessions never seen."""
    import hashlib
    sid = case_id.split("-")[1] if case_id.startswith("re-") else case_id
    return "realA" if int(hashlib.sha256(sid.encode()).hexdigest(), 16) % 2 == 0 else "realB"


_BOARDS = None


def style_half(case):
    """realA or realB for a Router-style case: the half of the real moment whose board it reuses (a style case is
    written on a real board, so splitting by its own id put ~56 of 150 styleA cases on realB boards)."""
    global _BOARDS
    if _BOARDS is None:
        _BOARDS = {}
        for c in load_set("real"):
            _BOARDS.setdefault(frozenset((s["id"], s["idle_min"]) for s in c["board"]["sessions"]), []).append(c)
    reals = _BOARDS.get(frozenset((s["id"], s.get("idle_min")) for s in case["board"]["sessions"]))
    if not reals:
        return half(case["id"])
    same = [c for c in reals if set(c["gold"]["to"]) & set(case["gold"]["to"])]
    return half((same or reals)[0]["id"])


def load_set(name):
    if name in ("realA", "realB"):
        return [c for c in load_set("real") if half(c["id"]) == name]
    if name in ("styleA", "styleB"):
        return [c for c in load_set("style") if style_half(c) == name.replace("style", "real")]
    cases = []
    for f in sorted(glob.glob(str(HERE / SETS[name]))):
        for line in open(f):
            if line.strip():
                cases.append(json.loads(line))
    if name == "real":
        lab = labels()
        for c in cases:
            l = lab.get(c["id"], {})
            c["gold"]["label"] = l.get("label")
            c["gold"]["ask_ok"] = l.get("label") != "clear"
    return cases


def policy(spec):
    if spec == "final":
        return analyze.policy("gates", **FINAL)
    mod, name = spec.split(":")
    return getattr(importlib.import_module(mod), name)


def score(cases, rows, pol):
    by = {c["id"]: c for c in cases}
    t = collections.Counter()
    for row in rows:
        c = by[row["id"]]
        r = run.reading(row)
        # A policy that reads the board too (recency) says so with `needs_case`.
        k, w = pol(r, c) if getattr(pol, "needs_case", False) else pol(r)
        gold = set(c["gold"]["to"])
        ask_ok = c["gold"].get("ask_ok") or not gold
        t["n"] += 1
        ranked = run.ranked_targets(r)
        t["top1"] += bool(ranked) and ranked[0] in gold
        if k == "send":
            if w in gold:
                t["right"] += 1
            else:
                t["wrong"] += 1
                t["wrong_session"] += w not in INTENTS
        else:
            t["ask"] += 1
            t["needless"] += not ask_ok
    return t


def line(name, t):
    n = max(t["n"], 1)
    pct = lambda k: 100 * t[k] / n
    return (f"{name:10} n={t['n']:4} right={pct('right'):5.1f}% wrong={pct('wrong'):4.1f}% (session {pct('wrong_session'):4.1f}%) "
            f"ask={pct('ask'):5.1f}% needless={pct('needless'):5.1f}% top1={pct('top1'):5.1f}%")


def bench(fmt, sets, pol, orders=1, rerun=True):
    out = {}
    for s in sets:
        cases = load_set(s)
        if not cases:
            continue
        if rerun:
            rows = run.run(fmt, cases, orders)
        else:
            ids = {c["id"] for c in cases}
            whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
            rows = [r for r in run.load(f"{fmt}@{whole}") if r["id"] in ids]
        if rerun:
            run.save(f"{fmt}@{s}", rows)
        out[s] = score(cases, rows, pol)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("formats", nargs="+")
    ap.add_argument("--policy", default="final")
    ap.add_argument("--orders", type=int, default=1)
    ap.add_argument("--sets", default="synth,heldout,real,style")
    ap.add_argument("--saved", action="store_true", help="score saved runs, ask Jev nothing")
    a = ap.parse_args()
    pol = policy(a.policy)
    for fmt in a.formats:
        res = bench(fmt, a.sets.split(","), pol, a.orders, rerun=not a.saved)
        print(f"== {fmt}  ({a.policy})")
        for s, t in res.items():
            print("  " + line(s, t))


if __name__ == "__main__":
    main()
