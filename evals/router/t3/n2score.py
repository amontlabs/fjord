"""N2 scoring helpers: decisions from saved answers under any bars and stage rules, N1's table with day-bootstrap CIs, paired
day-bootstrap differences, latency and cost. Imported by n2eval.py; aggregates only."""
import collections
import json
import math
import pathlib
import random
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import board as B  # noqa: E402
from run import load_moments, make_board  # noqa: E402
from score import classify, outcome  # noqa: E402

DATA = pathlib.Path(__file__).parent / "data"
JEV_PER_MTOK = 0.051   # N1: about $0.75 for 2,758 calls at a mean 5.3k input tokens
PRICE = {"claude-sonnet-5-5": (2.0, 0.2, 2.5, 10.0), "claude-haiku-5-5": (1.0, 0.1, 1.25, 5.0)}

M = {m["id"]: m for m in load_moments()}
JUDGE = {r["id"]: r for r in map(json.loads, open(DATA / "judge_new.jsonl"))}
for _m in M.values(): _m["klass"] = classify(_m, JUDGE)
N_FOLLOW = {sp: sum(1 for m in M.values() if m["split"] == sp and m["klass"] == "follow") for sp in ("dev", "test")}
_BOARDS = {}


def board(i):
    if i not in _BOARDS: _BOARDS[i] = make_board(M[i])
    return _BOARDS[i]


def load(name):
    p = DATA / f"{name}.jsonl"
    out = {}
    if p.exists():
        for r in map(json.loads, open(p)): out[r["id"]] = r
    return out


def tup(x):
    return tuple(tup(v) for v in x) if isinstance(x, list) else x


# ---------------------------------------------------------------- decisions
def sonnet_rule(a, b, idle=0.80, running=0.90, new=0.80, answer=0.80, project_bar=None):
    """B.sonnet_decision with a bar per action (and an optional project_confidence bar for new threads)."""
    known = b.thread(a.get("session") or "")
    project = b.project_named(a.get("project") or "")
    conf = a.get("confidence") or 0
    act = a.get("action")
    if act == "follow_up" and known and conf >= (running if known.running else idle): return ("thread", known.key)
    if act == "new_work" and conf >= new and project and (project_bar is None or (a.get("project_confidence") or 0) >= project_bar):
        return ("new", project)
    if act == "answer_here" and conf >= answer: return ("answer",)
    places = []
    if known: places.append(("thread", known.key))
    elif act == "new_work" and project: places.append(("new", project))
    for alt in a.get("alternatives") or []:
        t = b.thread(alt)
        k = ("thread", t.key) if t else (("new", alt.strip()) if b.project_named(alt) else None)
        if k and k not in places: places.append(k)
    return ("ask", tuple(places[:3]))


def staged(st, base_dec, bar=0.7, veto=None, project_bar=None):
    """A "new work or continuation?" stage in front of a router decision: new at p_new >= bar starts a new thread in the stage's
    project; with `veto`, a router send to an existing thread is turned into an ask when p_new >= veto."""
    a = st["answer"]
    p = a.get("p_new") or 0
    proj = st.get("project_ok")
    if a.get("kind") == "new" and p >= bar and proj and (project_bar is None or (a.get("project_confidence") or 0) >= project_bar):
        return ("new", proj)
    if veto is not None and base_dec[0] == "thread" and p >= veto:
        return ("ask", (base_dec,))
    return base_dec


# ---------------------------------------------------------------- tables
def items(dec, split, klasses):
    present = [i for i in dec if M[i]["split"] == split]
    nf = sum(1 for i in present if M[i]["klass"] == "follow")
    w = N_FOLLOW[split] / nf if nf else 0
    return [(M[i], outcome(M[i], dec[i]), w if M[i]["klass"] == "follow" else 1.0, i) for i in present if M[i]["klass"] in klasses]


def rate(its, f):
    w = sum(x[2] for x in its)
    return sum(x[2] for x in its if f(x)) / w if w else None


def by_day(its):
    g = collections.defaultdict(list)
    for x in its: g[x[0]["day"]].append(x)
    return g


def boot(g, stat, reps=1000, seed=3):
    days = sorted(g); rng = random.Random(seed); vals = []
    for _ in range(reps):
        its = [x for d in (rng.choice(days) for _ in days) for x in g[d]]
        v = stat(its)
        if v is not None: vals.append(v)
    vals.sort()
    return (vals[int(.025 * len(vals))], vals[int(.975 * len(vals)) - 1]) if vals else (None, None)


SEND = lambda x: x[1] not in ("ask", "answer")
WRONG = lambda x: SEND(x) and x[1] not in ("new_right", "thread_right")
XPROJ = lambda x: x[1].endswith("_xproj") or x[1] == "new_wrong_project"
METRICS = {
    "new_right": ({"new"}, lambda x: x[1] == "new_right"),
    "new_pushed": ({"new"}, lambda x: x[1].startswith("pushed")),
    "new_asked": ({"new"}, lambda x: x[1] == "ask"),
    "new_answer": ({"new"}, lambda x: x[1] == "answer"),
    "nc_right": ({"new_continues"}, lambda x: x[1] == "new_right"),
    "nc_pushed": ({"new_continues"}, lambda x: x[1].startswith("pushed")),
    "follow_right": ({"follow"}, lambda x: x[1] == "thread_right"),
    "follow_wrong": ({"follow"}, lambda x: x[1].startswith("wrong_thread")),
    "follow_to_new": ({"follow"}, lambda x: x[1].startswith("follow_to_new")),
    "follow_asked": ({"follow"}, lambda x: x[1] == "ask"),
    "pooled_sent": ({"new", "new_continues", "follow"}, SEND),
    "pooled_wrong": ({"new", "new_continues", "follow"}, WRONG),
    "wrong_project": ({"new", "new_continues", "follow"}, XPROJ),
}
CI = ("new_right", "new_pushed", "follow_right", "follow_wrong", "pooled_sent", "pooled_wrong")


def metrics(dec, split, cis=CI):
    out = {}
    for k, (kl, f) in METRICS.items():
        its = items(dec, split, kl)
        out[k] = (rate(its, f), boot(by_day(its), lambda z: rate(z, f)) if k in cis else None, len(its))
    return out


def paired(decA, decB, split, key, reps=1000, seed=5):
    """Day-bootstrap CI of metric(A) - metric(B) on the moments both decided."""
    common = [i for i in decA if i in decB and M[i]["split"] == split]
    kl, f = METRICS[key]
    A = items({i: decA[i] for i in common}, split, kl); Bb = {x[3]: x for x in items({i: decB[i] for i in common}, split, kl)}
    g = collections.defaultdict(list)
    for x in A: g[x[0]["day"]].append((x, Bb[x[3]]))
    def stat(pairs):
        w = sum(a[2] for a, _ in pairs)
        return (sum(a[2] for a, _ in pairs if f(a)) - sum(b[2] for _, b in pairs if f(b))) / w if w else None
    pts = [p for d in g for p in g[d]]
    days = sorted(g); rng = random.Random(seed); vals = []
    for _ in range(reps):
        v = stat([p for d in (rng.choice(days) for _ in days) for p in g[d]])
        if v is not None: vals.append(v)
    vals.sort()
    return stat(pts), (vals[int(.025 * len(vals))], vals[int(.975 * len(vals)) - 1])


def pct(v, c=None):
    if v is None: return "-"
    s = f"{100 * v:.1f}%"
    if c and c[0] is not None: s += f" ({100 * c[0]:.0f}–{100 * c[1]:.0f})"
    return s


HEAD = ("| | New: right | New: pushed | New: asked | Cont. new: right / pushed | Follow: right | Follow: wrong thread | Follow: to new | "
        "Follow: asked | Pooled sent | Pooled wrong | Wrong project | p50 | $/decision |")


def row(name, mt, p50=None, cost=None):
    g = lambda k: pct(mt[k][0], mt[k][1])
    return (f"| {name} | **{g('new_right')}** | {g('new_pushed')} | {g('new_asked')} | {pct(mt['nc_right'][0])} / {pct(mt['nc_pushed'][0])} | "
            f"{g('follow_right')} | {g('follow_wrong')} | {g('follow_to_new')} | {g('follow_asked')} | {g('pooled_sent')} | {g('pooled_wrong')} | "
            f"{g('wrong_project')} | {f'{p50:.2f} s' if p50 is not None else '-'} | {f'${cost:.4f}' if cost is not None else '-'} |")


# ---------------------------------------------------------------- latency and cost
def anth_cost(r):
    u = r.get("usage") or {}
    p = PRICE.get(r.get("model") or "claude-sonnet-5-5")
    if not p or "input_tokens" not in u: return 0.0
    return (u["input_tokens"] * p[0] + u.get("cache_read_input_tokens", 0) * p[1] + u.get("cache_creation_input_tokens", 0) * p[2]
            + u["output_tokens"] * p[3]) / 1e6


def jev_cost(r):
    u = r.get("usage") or {}
    return (u.get("input_tokens", 0) + u.get("output_tokens", 0)) * JEV_PER_MTOK / 1e6


def p50(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def weighted_mean(vals, split):
    """Mean over the natural ratio of a {id: value} on decided moments (follow-ups reweighted)."""
    its = items({i: ("ask", ()) for i in vals}, split, {"new", "new_continues", "follow"})
    w = sum(x[2] for x in its)
    return sum(x[2] * vals[x[3]] for x in its) / w if w else None


def logit(p): p = min(max(p, 1e-4), 1 - 1e-4); return math.log(p / (1 - p))
