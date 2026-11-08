"""N1: score Sonnet, Jev's fused path and the app's combination (Jev sends when sure, else Sonnet) -> stdout tables.

Classes: new (a first message the judge didn't flag), new_continues (a first message the judge says continues an existing
thread's work), follow, fork_start, brief (a first message the judge reads as an agent-drafted brief). Pooled numbers weight the
sampled follow-ups back to the natural ratio. 95% CIs: bootstrap over days. Aggregates only."""
import collections
import json
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from run import load_moments, sonnet_set  # noqa: E402

DATA = pathlib.Path(__file__).parent / "data"


def tup(x):
    if isinstance(x, list): return tuple(tup(v) for v in x)
    return x


def load(name):
    p = DATA / f"{name}.jsonl"
    return {r["id"]: r for r in map(json.loads, open(p))} if p.exists() else {}


def classify(m, J):
    if m["cls"] == "follow": return "follow"
    if m["cls"] == "fork_start": return "fork_start"
    j = J.get(m["id"], {})
    if j.get("author") == "agent_brief": return "brief"
    if j.get("relation") == "continues": return "new_continues"
    return "new"


def proj_of(m, place):
    if place[0] == "new": return place[1]
    if place[0] == "thread":
        t = next((t for t in m["board"]["threads"] if t["key"] == place[1]), None)
        return t["project"] if t else None
    return None


def outcome(m, d):
    """d: ('thread', key) | ('new', p) | ('answer',) | ('ask', places)."""
    g = tuple(m["gold"])
    k = d[0]
    if k == "ask": return "ask"
    if k == "answer": return "answer"
    right = d == g
    wrong_proj = proj_of(m, d) != m["project"]
    if g[0] == "new":
        if right: return "new_right"
        return "pushed_into_thread" + ("_xproj" if wrong_proj else "") if k == "thread" else "new_wrong_project"
    if right: return "thread_right"
    if k == "new": return "follow_to_new" + ("_xproj" if wrong_proj else "")
    return "wrong_thread" + ("_xproj" if wrong_proj else "")


def decisions(M, S, Jv):
    out = {}
    for m in M:
        i = m["id"]
        s = S.get(i); j = Jv.get(i)
        dec = {}
        if s: dec["sonnet"] = tup(s["decision"])
        if j:
            dec["jev"] = tup(j["send"]) if j["send"] else ("ask", [])
        if s and j: dec["combined"] = tup(j["send"]) if j["send"] else tup(s["decision"])
        # top-1 (no bars)
        if s: dec["sonnet_top"] = tup(s["guess"])
        if j: dec["jev_fused_top"] = tup(j["rows"][0][0]) if j["rows"] else ("none",)
        out[i] = dec
    return out


def ci(groups, stat, reps=2000, seed=3):
    """groups: day -> list of items; stat(list) -> value. Percentile bootstrap over days."""
    days = list(groups)
    rng = random.Random(seed); vals = []
    for _ in range(reps):
        items = [x for d in (rng.choice(days) for _ in days) for x in groups[d]]
        v = stat(items)
        if v is not None: vals.append(v)
    vals.sort()
    return (vals[int(.025 * len(vals))], vals[int(.975 * len(vals)) - 1]) if vals else (None, None)


def rate(items, num):
    w = sum(x[2] for x in items)
    return sum(x[2] for x in items if num(x)) / w if w else None


def fmt(v, lo_hi=None):
    if v is None: return "-"
    s = f"{100 * v:.1f}%"
    if lo_hi and lo_hi[0] is not None: s += f" ({100 * lo_hi[0]:.0f}-{100 * lo_hi[1]:.0f})"
    return s


def main():
    M = load_moments()
    S, Jv, J = load("res_sonnet"), load("res_jev"), load("judge_new")
    SS = {m["id"] for m in sonnet_set(M)}
    D = decisions(M, S, Jv)
    for m in M: m["klass"] = classify(m, J)
    # weights: follow-ups sampled for Sonnet; weight = all follow-ups / sampled, per split
    wt = {}
    for sp in ("dev", "test"):
        allf = sum(1 for m in M if m["split"] == sp and m["cls"] == "follow")
        samp = sum(1 for m in M if m["split"] == sp and m["cls"] == "follow" and m["id"] in SS and m["id"] in S)
        wt[sp] = allf / samp if samp else 0
    print("follow-up weights", {k: round(v, 2) for k, v in wt.items()})
    print("classes", collections.Counter((m["split"], m["klass"]) for m in M))

    def items(split, decider, klasses, on_sonnet_set=True):
        out = []
        for m in M:
            if m["split"] not in split or m["klass"] not in klasses: continue
            if on_sonnet_set and m["id"] not in S: continue
            d = D[m["id"]].get(decider)
            if d is None: continue
            w = wt[m["split"]] if (on_sonnet_set and m["cls"] == "follow") else 1.0
            out.append((m, outcome(m, d), w))
        return out

    def by_day(its):
        g = collections.defaultdict(list)
        for x in its: g[x[0]["day"]].append(x)
        return g

    send = lambda x: x[1] not in ("ask", "answer")
    for split in (("dev",), ("test",)):
        print(f"\n===== {split[0]} =====")
        for dec in ("sonnet", "jev", "combined"):
            print(f"-- {dec}")
            # new work
            for kl in ("new", "new_continues", "brief", "fork_start"):
                its = items(split, dec, {kl})
                if not its: continue
                c = collections.Counter(x[1] for x in its)
                g = by_day(its)
                print(f"  {kl:14} n={len(its):4}  right {fmt(rate(its, lambda x: x[1] == 'new_right'), ci(g, lambda z: rate(z, lambda x: x[1] == 'new_right')))}"
                      f"  pushed {fmt(rate(its, lambda x: x[1].startswith('pushed')), ci(g, lambda z: rate(z, lambda x: x[1].startswith('pushed'))))}"
                      f"  asked {fmt(rate(its, lambda x: x[1] == 'ask'))}  answer {fmt(rate(its, lambda x: x[1] == 'answer'))}"
                      f"  new-wrong-proj {c['new_wrong_project']}  pushed-xproj {c['pushed_into_thread_xproj']}")
            its = items(split, dec, {"follow"})
            g = by_day(its); c = collections.Counter(x[1] for x in its)
            print(f"  follow         n={len(its):4}  right {fmt(rate(its, lambda x: x[1] == 'thread_right'), ci(g, lambda z: rate(z, lambda x: x[1] == 'thread_right')))}"
                  f"  wrong-thread {fmt(rate(its, lambda x: x[1].startswith('wrong_thread')), ci(g, lambda z: rate(z, lambda x: x[1].startswith('wrong_thread'))))}"
                  f"  to-new {fmt(rate(its, lambda x: x[1].startswith('follow_to_new')))}  asked {fmt(rate(its, lambda x: x[1] == 'ask'))}"
                  f"  xproj {c['wrong_thread_xproj'] + c['follow_to_new_xproj']}")
            its = items(split, dec, {"new", "new_continues", "follow"})
            g = by_day(its)
            wrong = lambda x: send(x) and x[1] not in ("new_right", "thread_right")
            xp = lambda x: x[1].endswith("_xproj") or x[1] == "new_wrong_project"
            print(f"  pooled(natural) sent {fmt(rate(its, send), ci(g, lambda z: rate(z, send)))}"
                  f"  right-sent {fmt(rate(its, lambda x: x[1] in ('new_right', 'thread_right')))}"
                  f"  wrong-sent {fmt(rate(its, wrong), ci(g, lambda z: rate(z, wrong)))}"
                  f"  wrong-project {fmt(rate(its, xp))}"
                  f"  precision {fmt(rate([x for x in its if send(x)], lambda x: not wrong(x)))}")
        for dec in ("sonnet_top", "jev_fused_top"):
            for kl in ("new", "follow"):
                its = items(split, dec, {kl})
                ok = lambda x: x[1] in ("new_right", "thread_right")
                print(f"  top-1 {dec:13} {kl:7} {fmt(rate(its, ok))}  pushed {fmt(rate(its, lambda x: x[1].startswith('pushed')))}")
        # Jev on every moment (no sampling), as a check
        its = items(split, "jev", {"new", "new_continues", "follow"}, on_sonnet_set=False)
        print(f"  jev all moments n={len(its)} sent {fmt(rate(its, send))} wrong {fmt(rate(its, lambda x: send(x) and x[1] not in ('new_right', 'thread_right')))}")


if __name__ == "__main__":
    main()
