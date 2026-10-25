"""Better text evidence (explorer: lexical).

BM25 between the message and each board session's recent text, as Lookout can read it at send time: for real moments
the session's transcript before the moment (turns still running count by what the user told it, not what it will say),
for written cases the board's own text. Variants: window (last N turns, user / assistant side, decayed by age), field
weights (title, last assistant message, the user's last instruction), IDF over the board or over every session,
light stemming.

python3 -m explore.lexical probe            top1 / stand-out precision of each variant on real follow-ups
python3 -m explore.lexical fit FORMAT       fuse3 refit with this module's features; every set
python3 bench.py FORMAT --policy explore.lexical:NAME"""
import collections
import functools
import json
import math
import pathlib
import re
import sys
import unicodedata

HERE = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(HERE))
import veto  # noqa: E402
from real.entities import ts  # noqa: E402

# ---------------------------------------------------------------- text

FR_STOP = {"les", "des", "une", "est", "pas", "que", "qui", "pour", "dans", "sur", "avec", "mais", "fait", "faire",
           "tout", "plus", "bien", "aussi", "comme", "cette", "ces", "son", "ses", "elle", "nous", "vous", "ils",
           "leur", "sont", "ont", "été", "etre", "être", "par", "donc", "alors", "oui", "non", "quoi"}
EN_STOP = {"what", "when", "where", "which", "while", "will", "with", "would", "this", "those", "was", "were", "you",
           "your", "yes", "why", "who", "very", "want", "use", "using", "used", "way", "well", "too", "only", "more",
           "most", "much", "same", "other", "each", "both", "after", "before", "again", "still", "even", "being",
           "been", "because", "doing", "done", "don", "doesn", "didn", "isn", "it's", "i'm", "they", "their", "think",
           "know", "see", "look", "go", "going", "sure", "right", "good", "work", "works", "thing", "things"}
STOP = set(veto.COMMON) | EN_STOP | FR_STOP


def fold(text):
    return "".join(ch for ch in unicodedata.normalize("NFD", text) if unicodedata.category(ch) != "Mn")


def stem(w):
    """A light English/French suffix strip (plurals, -ing, -ed, -ly, -ation), enough to meet "notification(s)",
    "notify" stays itself. NaturalLanguage's lemmatizer would be the Swift counterpart."""
    for suf in ("ations", "ation", "ings", "ing", "edly", "ies", "ied", "ers", "er", "ed", "ly", "es", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 4:
            w = w[: -len(suf)]
            if suf in ("ies", "ied"):
                w += "y"
            break
    return w


def toks(text, stemming=True, minlen=3):
    out = []
    for w in re.findall(r"[^\W_]+", fold((text or "").lower())):
        if len(w) < minlen or w in STOP or w.isdigit() and len(w) < 4:
            continue
        out.append(stem(w) if stemming else w)
    return out


# ---------------------------------------------------------------- what Lookout can read per session

@functools.lru_cache(maxsize=1)
def corpus():
    out = {}
    for line in open(HERE / "real" / "data" / "corpus.jsonl"):
        s = json.loads(line)
        out[s["id"][:8]] = s
    return out


@functools.lru_cache(maxsize=None)
def _turns(sid):
    src = corpus().get(sid)
    if not src:
        return None
    return [(ts(t["at"]), ts(t["end"]) if t.get("end") else float("inf"), t["you"], t["said"]) for t in src["turns"]]


@functools.lru_cache(maxsize=200000)
def _toks(text, stemming):
    return tuple(toks(text, stemming))


def past_turns(case, sid):
    """[(you, said)] before the moment, oldest first; a turn still running at the moment has no `said` yet."""
    turns = _turns(sid)
    if turns is None or "at" not in case:
        return None
    now = ts(case["at"])
    out = []
    for at, end, you, said in turns:
        if at >= now:
            break
        out.append((you, said if end <= now else ""))
    return out


def board_fields(case, s, layout="flat"):
    """Written cases: what the board shows about a session, split like a transcript.
    flat: what the user told it, then one turn saying cards + summary + activity;
    turns: the last turn is (what the user last told it, its cards), the one before (earlier messages, summary and
    activity), as a transcript's last turn and its past would be."""
    b = case["board"]
    if layout == "turns":
        you = [h["you"] for h in sorted(b.get("history", []), key=lambda h: -h["ago_min"]) if h["to"] == s["id"]]
        cards = " ".join(c["text"] for c in b.get("cards", []) if c["session"] == s["id"])
        older = " ".join(x for x in (s.get("summary", ""), s.get("activity", "")) if x)
        return [(" ".join(you[:-1]), older), (you[-1] if you else "", cards)]
    said = [s.get("summary", ""), s.get("activity", "")] + [c["text"] for c in b.get("cards", []) if c["session"] == s["id"]]
    you = [h["you"] for h in sorted(b.get("history", []), key=lambda h: -h["ago_min"]) if h["to"] == s["id"]]
    return [(y, "") for y in you] + [("", " ".join(x for x in said if x))]


@functools.lru_cache(maxsize=None)
def _corpus_df(stemming):
    """Document frequency over every session in the corpus (title + all turns): IDF as a long-running Lookout would
    have it from the sessions it has seen."""
    df = collections.Counter()
    for s in corpus().values():
        text = s["title"] + " " + " ".join(t["you"] + " " + t["said"] for t in s["turns"])
        df.update(set(toks(text, stemming)))
    return df, len(corpus())


DEFAULT = dict(n=2, w_you=1.0, w_said=1.0, w_title=1.0, w_last_said=0.0, w_last_you=0.0, decay=1.0, idf="board",
               stemming=True, k1=1.2, b=0.75, said_chars=None, skip_last=False, board="flat")


def session_tf(case, s, cfg):
    """Weighted term counts for one session and its weighted length."""
    turns = past_turns(case, s["id"])
    if turns is None:
        turns = board_fields(case, s, cfg["board"])
    if cfg["skip_last"]:
        turns = turns[:-1]
    turns = turns[-cfg["n"]:] if cfg["n"] else turns
    tf = collections.Counter()
    st = cfg["stemming"]
    for w in _toks(s["title"], st):
        tf[w] += cfg["w_title"]
    k = len(turns)
    for i, (you, said) in enumerate(turns):
        age = k - 1 - i                     # 0 = the latest turn
        a = cfg["decay"] ** age
        if cfg["said_chars"]:
            said = said[-cfg["said_chars"]:]
        for w in _toks(you, st):
            tf[w] += a * (cfg["w_you"] + (cfg["w_last_you"] if age == 0 else 0))
        for w in _toks(said, st):
            tf[w] += a * (cfg["w_said"] + (cfg["w_last_said"] if age == 0 else 0))
    return tf


def scores(case, cfg=None, **kw):
    """{session id: BM25 score} over the board's sessions."""
    cfg = {**DEFAULT, **(cfg or {}), **kw}
    q = set(toks(case["message"], cfg["stemming"]))
    sess = case["board"]["sessions"]
    if not q or not sess:
        return {s["id"]: 0.0 for s in sess}
    docs = {s["id"]: session_tf(case, s, cfg) for s in sess}
    lens = {d: sum(tf.values()) for d, tf in docs.items()}
    avg = sum(lens.values()) / len(docs) or 1
    if cfg["idf"] == "corpus":
        df, n = _corpus_df(cfg["stemming"])
    else:
        df, n = collections.Counter(w for tf in docs.values() for w in tf if w in q), len(docs)
    out = {}
    for d, tf in docs.items():
        sc = 0.0
        for w in q:
            f = tf.get(w, 0)
            if f:
                idf = math.log(1 + (n - df.get(w, 0) + 0.5) / (df.get(w, 0) + 0.5))
                sc += idf * f * (cfg["k1"] + 1) / (f + cfg["k1"] * (1 - cfg["b"] + cfg["b"] * lens[d] / avg))
        out[d] = sc
    return out


# ---------------------------------------------------------------- probe

def probe_one(cases, cfg):
    t = collections.Counter()
    for c in cases:
        gold = set(c["gold"]["to"])
        if not gold & {s["id"] for s in c["board"]["sessions"]}:
            continue
        sc = scores(c, cfg)
        ranked = sorted(sc.items(), key=lambda x: -x[1])
        t["n"] += 1
        if not ranked or ranked[0][1] <= 0:
            continue
        t["any"] += 1
        uniq = len(ranked) < 2 or ranked[0][1] > ranked[1][1]
        t["top1"] += uniq and ranked[0][0] in gold
        t["mrr"] += next((1 / (i + 1) for i, (d, _) in enumerate(ranked) if d in gold and _ > 0), 0)
        r2 = ranked[1][1] if len(ranked) > 1 else 0
        if ranked[0][1] >= 2 * r2:
            t["out"] += 1
            t["outok"] += ranked[0][0] in gold
    n = max(t["n"], 1)
    return (f"n={t['n']} words={100 * t['any'] / n:.0f}% top1={100 * t['top1'] / n:.1f}% mrr={t['mrr'] / n:.3f} "
            f"stands-out {100 * t['out'] / n:.0f}% right {100 * t['outok'] / max(t['out'], 1):.0f}%")


VARIANTS = {
    "fuse3 (n=2 board idf, no stem)": dict(stemming=False),
    "n=2": {},
    "n=1": dict(n=1),
    "n=3": dict(n=3),
    "n=6": dict(n=6),
    "n=all": dict(n=0),
    "n=6 decay .5": dict(n=6, decay=0.5),
    "n=all decay .5": dict(n=0, decay=0.5),
    "n=all decay .3": dict(n=0, decay=0.3),
    "you only n=2": dict(w_said=0),
    "said only n=2": dict(w_you=0),
    "you only n=6": dict(n=6, w_said=0),
    "no title": dict(w_title=0),
    "title x3": dict(w_title=3),
    "last said +2": dict(w_last_said=2),
    "last you +2": dict(w_last_you=2),
    "last said tail 600": dict(said_chars=600),
    "corpus idf": dict(idf="corpus"),
    "corpus idf n=6 decay .5": dict(idf="corpus", n=6, decay=0.5),
    "k1=2 b=.3": dict(k1=2.0, b=0.3),
    "b=0": dict(b=0.0),
}


def probe(sets=("realA", "realB", "synth", "styleA", "heldout")):
    import bench
    data = {s: bench.load_set(s) for s in sets}
    for name, cfg in VARIANTS.items():
        print(f"{name:32} " + " | ".join(f"{s} {probe_one(data[s], cfg)}" for s in sets if s.startswith("real")))
    for name in ("fuse3 (n=2 board idf, no stem)", "n=2", "corpus idf"):
        print(f"{name:32} " + " | ".join(f"{s} {probe_one(data[s], VARIANTS[name])}" for s in sets if not s.startswith("real")))


# ---------------------------------------------------------------- fusion (fuse3 with this module's evidence)

from explore import fuse3 as _F3  # noqa: E402  (patches fusion.features with fuse2's + bm; we patch over it)
from explore import fusion as Fu  # noqa: E402

LEX = dict(n=0, decay=0.5, b=0.3)        # every turn, each older turn weighing half the next; mild length norm
_cache = {}


def lex(case, cfg=None):
    cfg = cfg or LEX
    key = (case["id"], json.dumps(cfg, sort_keys=True))
    if key not in _cache:
        _cache[key] = scores(case, cfg)
    return _cache[key]


STATE = {"cfg": LEX}


def features(r, case):
    out = _F3._base(r, case)
    sc = lex(case, STATE["cfg"])
    ranked = sorted(sc.items(), key=lambda x: -x[1])
    top = ranked[0][1] if ranked else 0
    second = ranked[1][1] if len(ranked) > 1 else 0
    for d, f in out.items():
        if f.get("sess"):
            x = sc.get(d, 0)
            f["bm"] = x / top if top else 0
            f["bmtop"] = int(bool(ranked) and ranked[0][0] == d and top > 0 and second <= 0.5 * top)
            f["lbm"] = math.log1p(x)
            f["bm1"] = int(bool(ranked) and ranked[0][0] == d and top > 0 and top > second)
            f["bmz"] = int(top > 0 and x == 0)              # the message shares nothing with it while others do
    if STATE.get("fields"):
        for name, fcfg in FIELDS.items():
            fsc = lex(case, fcfg)
            m = max(fsc.values(), default=0)
            for d, f in out.items():
                if f.get("sess"):
                    f[name] = fsc.get(d, 0) / m if m else 0
    if STATE.get("old_hours") is not None:
        old_out(out, case, STATE["old_hours"])
    return out


RECENCY = ("fin0", "fin1", "fin2", "told0", "told10", "fin0u", "fin1u", "told0u", "nxt")


def old_out(fs, case, hours):
    """RouteFusion.oldHours: a finished session (not running, not waiting on you) idle `hours` or more has none of the
    features that make the latest sessions likely."""
    board = {s["id"]: s for s in case["board"]["sessions"]}
    waiting = {c["session"] for c in case["board"].get("cards", []) if c.get("kind") in ("question", "plan", "asks", "approval", "permission")}
    for d, f in fs.items():
        s = board.get(d)
        if not f.get("sess") or not s or s.get("running") or s.get("waits_on_you") or d in waiting:
            continue
        if (s.get("idle_min") or 0) >= hours * 60:
            for k in RECENCY:
                f.pop(k, None)


FIELDS = {"f_said": dict(n=1, w_you=0, w_title=0, b=0.3, board="turns"),
          "f_you": dict(n=1, w_said=0, w_title=0, b=0.3, board="turns"),
          "f_old": dict(n=0, decay=0.5, skip_last=True, w_title=0, b=0.3, board="turns"),
          "f_title": dict(n=1, w_you=0, w_said=0, b=0.3, board="turns")}


_case_features = Fu.case_features


def case_features(r, case, fs, P):
    cf = _case_features(r, case, fs, P)
    top = max(P.items(), key=lambda x: x[1])[0]
    f = fs[top]
    cf["top_bm1"] = f.get("bm1", 0)
    cf["top_bm"] = f.get("bm", 0)
    cf["top_bmz"] = f.get("bmz", 0)
    others = [g.get("bm", 0) for d, g in fs.items() if d != top and g.get("sess")]
    best_other = max(others, default=0)
    # lexical margin: how much more the pick shares with the message than any other session (0 when not a session)
    cf["bmgap"] = (f.get("bm", 0) - best_other) if f.get("sess") else 0
    # a near tie: another session shares as much (≥ 0.6 of the best) with the message as the pick
    cf["bmtie"] = int(bool(f.get("sess")) and f.get("bm", 0) > 0 and best_other >= 0.6)
    # a new session or an intent picked while one session clearly shares the message's words
    cf["bmelse"] = int(not f.get("sess") and best_other >= 1.0 and sum(1 for o in others if o >= 0.5) == 1)
    return cf


def install():
    """Point fusion at this module's features. Not done at import: formats.py imports every explorer module, and other
    explorers' fusions must keep their own."""
    Fu.features = features
    Fu.case_features = case_features
    Fu._patch_reading()


CF = Fu.CASE_FEATURES + ["top_bm1", "top_bm", "top_bmz"]
CF_GAP = Fu.CASE_FEATURES + ["bmgap", "bmtie"]
BASE = _F3.FEATS                                    # fuse2's + bm, bmtop


def fitted(fmt, feats, cfeats, train=("realA", "synth", "styleA")):
    w = Fu.fit(Fu.dataset(fmt, list(train)), feats=feats)
    ev = Fu.load_eval(fmt, list(train))
    v = Fu.fit_conf([x for s in ev for x in ev[s]], w, feats=cfeats)
    return w, v


def make_guarded(w, v, b1=0.5, b2=0.9, min_words=3, veto=None, c1=None):
    """fuse3's guarded decision on this module's features; `veto(fs, dest, case, path)` turns a send into an ask."""
    from explore import combo
    rules = combo.make_policy()

    def pol(r, case):
        fs = features(r, case)
        if not fs:
            return ("ask", [])
        k, d = rules(r)
        P = Fu.probs(fs, w)
        ask = ("ask", sorted(P, key=lambda x: -P[x])[:3])
        top, p = Fu.confidence(r, case, fs, w, v)
        if k == "send" and P.get(d, 0) >= b1 and (c1 is None or (top == d and p >= c1)):
            pol.path = "rules"
            return ask if veto and veto(fs, d, case, "rules") else ("send", d)
        if p >= b2 and len(case["message"].split()) >= min_words and top not in Fu.INTENTS:
            pol.path = "conf"
            return ask if veto and veto(fs, top, case, "conf") else ("send", top)
        return ask
    pol.needs_case = True
    return pol


SETS = ("synth", "styleB", "realA", "realB", "heldout")


def table(fmt, pol, sets=SETS, short=True):
    import bench
    import run
    out = []
    for s in sets:
        cases = bench.load_set(s)
        ids = {c["id"] for c in cases}
        whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
        rows = [r for r in run.load(f"{fmt}@{whole}") if r["id"] in ids and r["order"] == 0]
        t = bench.score(cases, rows, pol)
        out.append(f"{s} {100 * t['right'] / t['n']:.1f}/{100 * t['wrong'] / t['n']:.1f}" if short else bench.line(s, t))
    return ("  ".join(out)) if short else "\n".join(out)


def sweep(fmt, configs, bars=((0.5, 0.9),)):
    install()
    for name, (cfg, feats, cfeats) in configs.items():
        STATE["cfg"] = cfg
        w, v = fitted(fmt, feats, cfeats)
        if "-w" in sys.argv:
            print({k: round(float(x), 2) for k, x in w.items()})
            print({k: round(float(x), 2) for k, x in v.items()})
        for bar in bars:
            b1, b2 = bar[:2]
            c1 = bar[2] if len(bar) > 2 else None
            print(f"{name:28} b1={b1} b2={b2} c1={c1}  " + table(fmt, make_guarded(w, v, b1, b2, c1=c1)), flush=True)


def main_fit(fmt):
    old = dict(n=2, stemming=False)
    configs = {
        "fuse3 feats, old lex": (old, BASE, Fu.CASE_FEATURES),
        "fuse3 feats, LEX": (LEX, BASE, Fu.CASE_FEATURES),
        "+lbm": (LEX, BASE + ["lbm"], Fu.CASE_FEATURES),
        "+bm1": (LEX, BASE + ["bm1"], Fu.CASE_FEATURES),
        "+bmz": (LEX, BASE + ["bmz"], Fu.CASE_FEATURES),
        "+lbm+bmz, conf+bm": (LEX, BASE + ["lbm", "bmz"], CF),
        "LEX, conf+bm": (LEX, BASE, CF),
        "LEX, conf+gap": (LEX, BASE, CF_GAP),
        "LEX, conf+gap+else": (LEX, BASE, CF_GAP + ["bmelse"]),
        "old lex, conf+gap": (old, BASE, CF_GAP),
    }
    if "-q" in sys.argv:
        configs = {k: configs[k] for k in list(configs)[-3:]}
    if "-f" in sys.argv:
        STATE["fields"] = True
        nobm = [f for f in BASE if f not in ("bm", "bmtop")]
        configs = {"fields only": (LEX, nobm + list(FIELDS), Fu.CASE_FEATURES)}
        if "-a" in sys.argv:
            for f in FIELDS:
                configs[f"fields - {f}"] = (LEX, nobm + [x for x in FIELDS if x != f], Fu.CASE_FEATURES)
            configs["fields, conf+gap"] = (LEX, nobm + list(FIELDS), CF_GAP)
        else:
            configs["LEX + fields"] = (LEX, BASE + list(FIELDS), Fu.CASE_FEATURES)
        bars = [(0.5, 0.9), (0.5, 0.85, 0.7)]
        if "-g" in sys.argv:
            configs = {"fields only": configs["fields only"]}
            bars = [(b1, b2, c1) for b1 in (0.5,) for b2 in (0.85, 0.88, 0.9) for c1 in (None, 0.6, 0.7, 0.75, 0.8)]
        sweep(fmt, configs, bars=bars)
        return
    if "-c" in sys.argv:
        configs = {k: configs[k] for k in ("fuse3 feats, old lex", "fuse3 feats, LEX", "LEX, conf+gap")}
        sweep(fmt, configs, bars=[(0.5, 0.9)] + [(0.5, b2, c1) for b2 in (0.85, 0.9) for c1 in (0.5, 0.6, 0.7, 0.8)])
        return
    sweep(fmt, configs, bars=((0.5, 0.85), (0.5, 0.9)))


def diag(fmt, sets=("realA", "realB", "synth", "styleA", "heldout")):
    """On the moments the guarded policy asks: how often would agreement between the fused top, BM25's top and Jev's
    top have been right?"""
    import bench
    import run
    install()
    w, v = fitted(fmt, BASE, Fu.CASE_FEATURES)
    pol = make_guarded(w, v)
    for s in sets:
        cases = {c["id"]: c for c in bench.load_set(s)}
        whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
        t = collections.Counter()
        for row in run.load(f"{fmt}@{whole}"):
            if row["id"] not in cases or row["order"]:
                continue
            c = cases[row["id"]]
            r = run.reading(row)
            gold = set(c["gold"]["to"])
            if pol(r, c)[0] == "send":
                continue
            t["asked"] += 1
            fs = features(r, c)
            P = Fu.probs(fs, w)
            top = max(P, key=P.get)
            rk = sorted(lex(c).items(), key=lambda x: -x[1])
            bt = rk[0][0] if rk and rk[0][1] > 0 else None
            st = bool(bt) and (len(rk) < 2 or rk[1][1] <= 0.5 * rk[0][1])
            jt = max(((dd, p) for dd, p in r["dests"].items() if dd != "unclear"), key=lambda x: x[1])[0]
            t["clear"] += not (c["gold"].get("ask_ok") or not gold)
            t["fused ok"] += top in gold
            for name, cond, pick in (("f=bm", top == bt, top), ("f=bm st", top == bt and st, top),
                                     ("f=bm=j", top == bt == jt, top), ("f=bm=j st", top == bt == jt and st, top),
                                     ("bm st", st, bt), ("f=j", top == jt, top)):
                if cond:
                    t[name] += 1
                    t[name + " ok"] += pick in gold
        print(s, " ".join(f"{k}={x}" for k, x in t.items()))


# ---------------------------------------------------------------- the winner

FEATS_FIELDS = [f for f in _F3.FEATS if f not in ("bm", "bmtop")] + list(FIELDS)
_POL = {}


def best_policy(fmt="combo-o", c1=0.6, b2=0.9):
    """fuse2's features + BM25 per field (f_said, f_you, f_old, f_title) instead of fuse3's single bm, fitted on realA
    + synth + styleA; decided like fuse3's guarded, except that the rules' send also needs the calibrated sureness of
    the same destination to reach c1."""
    install()
    STATE["fields"] = True
    w, v = fitted(fmt, FEATS_FIELDS, Fu.CASE_FEATURES)
    return make_guarded(w, v, 0.5, b2, c1=c1), w, v


def __getattr__(name):
    spec = {"best": dict(c1=0.6), "fields_guarded": dict(c1=None), "best70": dict(c1=0.7)}
    if name in spec:
        if name not in _POL:
            _POL[name] = best_policy(**spec[name])[0]
        return _POL[name]
    raise AttributeError(name)


# ---------------------------------------------------------------- formats: "next message?" for lexical candidates too

def lex_next(case, rng=None, k=2, rel=0.5):
    """combo (one call), plus the same "is `message` your next message in this conversation?" yes/no for up to `k`
    sessions BM25 ranks highest (score ≥ `rel` of the best) that are not already among the 3 latest finished. What
    reaches Jev is board text (the session's card and what the user last told it), as combo sends."""
    from explore import combo
    from explore import recency as R
    state, q, keymap = combo.combo(case, rng)
    board = case["board"]
    asked = {key[len("gate_next_"):] for key in q if key.startswith("gate_next_")}
    sc = lex(case)
    top = max(sc.values(), default=0)
    byid = {s["id"]: s for s in board["sessions"]}
    extra = [d for d, x in sorted(sc.items(), key=lambda x: -x[1]) if top and x >= rel * top and d not in asked][:k]
    for d in extra:
        s = byid[d]
        conv = []
        h = R.last_told(board, s)
        if h:
            conv.append({"user": h["you"][:300]})
        said = R.last_said(board, s)
        if said:
            conv.append({"session": said[:400]})
        if conv:
            q[f"gate_next_{d}"] = {"type": "noul", "instructions": {"question": R.NEXT_QUESTIONS["next"],
                                                                      "conversation": conv}}
    return state, q, keymap


FORMATS = {"lex-next": lex_next}


def coverage(sets=("realA", "realB", "synth", "styleA", "heldout")):
    """Where the gold session sits: among the 3 latest finished (combo asks "next?" there), or else among BM25's top 2."""
    import bench
    from explore import recency as R
    for s in sets:
        t = collections.Counter()
        for c in bench.load_set(s):
            gold = set(c["gold"]["to"])
            ids = {x["id"] for x in c["board"]["sessions"]}
            if not gold & ids:
                continue
            t["n"] += 1
            lat = [x["id"] for x in R.finished_by_recency(c["board"])[:3]]
            rk = [d for d, x in sorted(lex(c).items(), key=lambda x: -x[1]) if x > 0]
            run_ = [x["id"] for x in c["board"]["sessions"] if x.get("running")]
            if gold & set(lat):
                t["latest3"] += 1
            elif gold & set(run_):
                t["running"] += 1
                t["running, bm top2"] += bool(gold & set(rk[:2]))
            else:
                t["older"] += 1
                t["older, bm top1"] += bool(gold & set(rk[:1]))
                t["older, bm top2"] += bool(gold & set(rk[:2]))
            extra = [d for d in rk[:2] if d not in lat]
            t["extra asks"] += len(extra)
        print(s, dict(t))


def within_latest(fmt, sets=("realA", "realB", "styleA"), k=3, nxt_prefix="gate_next_"):
    """Among the k latest finished sessions, when gold is one of them: how often each signal's argmax is it."""
    import bench
    import run
    from explore import recency as R
    install()
    for s in sets:
        cases = {c["id"]: c for c in bench.load_set(s)}
        whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
        t = collections.Counter()
        for row in run.load(f"{fmt}@{whole}"):
            if row["id"] not in cases or row["order"]:
                continue
            c = cases[row["id"]]
            gold = set(c["gold"]["to"])
            lat = [x["id"] for x in R.finished_by_recency(c["board"])[:k]]
            if k == 0:      # every session asked "next?" in this run
                lat = [key[len(nxt_prefix):] for key in row["answers"] if key.startswith(nxt_prefix)]
            if not gold & set(lat) or len(lat) < 2:
                continue
            r = run.reading(row)
            g = r.get("gates") or {}
            sc = lex(c)
            t["n"] += 1
            sig = {"fin0": {d: -i for i, d in enumerate(lat)},
                   "jev": {d: r["dests"].get(d, 0) for d in lat},
                   "nxt": {d: g.get(nxt_prefix + d, -1) for d in lat},
                   "bm": {d: sc.get(d, 0) for d in lat}}
            sig["nxt+bm"] = {d: sig["nxt"][d] + 0.3 * (sc.get(d, 0) / max(max(sig["bm"].values()), 1e-9)) for d in lat}
            for name, m in sig.items():
                best = max(m.values())
                tops = [d for d in lat if m[d] == best]
                t[name] += len(tops) == 1 and tops[0] in gold
        print(s, t["n"], " ".join(f"{k}={100 * x / t['n']:.0f}%" for k, x in t.items() if k != "n"))


def sends(fmt, sets=("realA",), feats=None, cfeats=None):
    """Each send of the guarded policy: right or wrong, with the lexical evidence for the pick and for gold."""
    import bench
    import run
    install()
    w, v = fitted(fmt, feats or BASE, cfeats or Fu.CASE_FEATURES)
    pol = make_guarded(w, v)
    for s in sets:
        cases = {c["id"]: c for c in bench.load_set(s)}
        whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
        t = collections.Counter()
        for row in run.load(f"{fmt}@{whole}"):
            if row["id"] not in cases or row["order"]:
                continue
            c = cases[row["id"]]
            r = run.reading(row)
            k, d = pol(r, c)
            if k != "send":
                continue
            gold = c["gold"]["to"]
            fs = features(r, c)
            f = fs.get(d, {})
            ok = d in gold
            key = ("ok " if ok else "WRONG ") + pol.path
            for b in ("bm", "bm1", "bmz"):
                t[f"{key} {b}"] += f.get(b, 0)
            t[key] += 1
            t[f"{key} nowords"] += not toks(c["message"])
            if not ok and "-v" in sys.argv:
                g = gold[0] if gold else None
                print(f"  {c['id']:16} {c['gold'].get('label')} pick={d[:10]} {({k_: round(x, 2) for k_, x in f.items() if x})} gold={str(g)[:10]} "
                      f"{({k_: round(x, 2) for k_, x in fs.get(g, {}).items() if x})} :: {len(c['message'])}ch")
        print(s, {k_: round(x, 1) for k_, x in t.items()})


if __name__ == "__main__" and len(sys.argv) > 1:
    if sys.argv[1] == "sends":
        sends(sys.argv[2], sys.argv[3].split(","))
    if sys.argv[1] == "latest":
        within_latest(sys.argv[2], sets=("realA", "realB", "synth", "styleA", "heldout"), k=int(sys.argv[3]) if len(sys.argv) > 3 else 3)
    if sys.argv[1] == "coverage":
        coverage()
    if sys.argv[1] == "diag":
        diag(sys.argv[2])
    if sys.argv[1] == "probe":
        probe()
    if sys.argv[1] == "fit":
        main_fit(sys.argv[2])
