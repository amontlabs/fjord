"""Explorer `lifetree`: the production way to write a session's whole-life line, and the controls (2026-10-21).

explore/life.py wrote the line straight from the raw transcript, with the user's own past phrasing: not what Fjord would
ship. Production keeps a tree of one-line summaries per session (UniiChat's idea):
  leaf  = one Haiku line per finished turn, written from that turn alone (the user's message + the session's answer)
  root  = one Haiku line rewritten from ALL the session's leaves for the turns finished before the moment, oldest first
The current, unfinished turn contributes no leaf. Leaves are cached by session@turn, roots by session@turn-count.

Formats (all on top of combo-o, field FIELD, ≤ 300 chars):
  combo-root      the root
  combo-recent    the latest finished turn's leaf only (token-matched recent-only control)
  combo-shuffled  roots permuted among the session options of the same board (derangement, seed per case)

  python3 -m explore.lifetree derive      leaves, then roots  →  real/data/tree_leaves.json, tree_roots.json
  python3 -m explore.lifetree bench       run the formats, score
  python3 -m explore.lifetree report      the paired table (bootstrap CIs)"""
import json
import os
import pathlib
import random
import sys
from concurrent.futures import ThreadPoolExecutor

from explore import combo
from explore.life import FIELD, MAX_CHARS, HERE, _clip, haiku

DATA = HERE / "real" / "data"
LEAVES = DATA / "tree_leaves.json"
ROOTS = DATA / "tree_roots.json"
PLAN = DATA / "tree_plan.json"

LEAF_PROMPT = f"""Below is one exchange from a Claude Code session: what the user asked and how the session answered, \
clipped. Write ONE line, at most 160 characters, saying what this exchange was about and what came of it, in plain \
words. No preamble, no quotes, just the line.

<exchange>
{{conv}}
</exchange>"""

ROOT_PROMPT = f"""Below are one-line summaries of the turns of a Claude Code session so far, oldest first. Write ONE \
line, at most {MAX_CHARS} characters, saying what this session has been about over its whole life: its goal and the \
main threads of work, in plain words. No preamble, no quotes, just the line.

<turns>
{{conv}}
</turns>"""


def _redact(t):
    sys.path.insert(0, str(HERE / "real"))
    import boards as rb
    return rb.redact(t)


# ---------------------------------------------------------------- plan: what each case sees

def plan():
    """{leaves: {sid@t: {you, said}}, roots: {sid@n: [leaf keys]}, cases: {case id: {board sid: [sid@n, last leaf key]}}}.
    A turn is finished at a moment when it ended by then; for the gold session the moment is just before the message."""
    if PLAN.exists():
        return json.loads(PLAN.read_text())
    sys.path.insert(0, str(HERE / "real"))
    import boards as rb
    sessions = rb.load()
    by = {}
    for s in sessions:
        by.setdefault(s["id"][:8], []).append(s)
    leaves, roots, cases = {}, {}, {}
    for line in open(DATA / "real.jsonl"):
        c = json.loads(line)
        t0 = rb.ts(c["at"])
        gold = c["gold"]["to"][0]
        out = {}
        for s in c["board"]["sessions"]:
            now = t0 - 1e-3 if s["id"] == gold else t0
            cands = [x for x in by.get(s["id"], []) if x["title"][:80] == s["title"] or len(by[s["id"]]) == 1]
            for x in cands:
                st = rb.state_at(x, now)
                if not st:
                    continue
                done = [i for i, t in enumerate(x["turns"]) if t["t0"] < now and t["t1"] <= now]
                if not done:
                    break
                keys = []
                for i in done:
                    k = f"{x['id']}@{i}"
                    leaves.setdefault(k, {"you": x["turns"][i]["you"], "said": x["turns"][i]["said"]})
                    keys.append(k)
                rk = f"{x['id']}@n{len(done)}"
                roots.setdefault(rk, keys)
                out[s["id"]] = [rk, keys[-1]]
                break
        cases[c["id"]] = out
    p = {"leaves": leaves, "roots": roots, "cases": cases}
    PLAN.write_text(json.dumps(p, ensure_ascii=False))
    return p


# ---------------------------------------------------------------- derivation

def leaf_input(l):
    said = " ".join((l["said"] or "").split())
    said = said if len(said) <= 900 else "…" + said[-900:]  # the end of an answer holds its outcome
    return f"User: {_clip(_redact(l['you']), 500)}\nSession: {said or '(no text answer)'}"


def root_input(lines):
    lines = [f"- {x}" for x in lines]
    if len(lines) > 88:
        lines = lines[:8] + ["[… earlier turns left out …]"] + lines[-80:]
    return "\n".join(lines)


def _run(todo, fn, path, cache, workers):
    missing = [k for k in todo if not cache.get(k)]
    print(f"{len(todo)} total, {len(missing)} to write -> {path.name}", flush=True)
    done = 0
    with ThreadPoolExecutor(workers) as ex:
        for k, line in zip(missing, ex.map(fn, missing)):
            if line:
                cache[k] = line
            done += 1
            if done % 100 == 0:
                path.write_text(json.dumps(cache, ensure_ascii=False))
                print(done, flush=True)
    path.write_text(json.dumps(cache, ensure_ascii=False))
    print("failed:", sum(1 for k in todo if not cache.get(k)), flush=True)


def derive(workers=8):
    p = plan()
    leaves = json.loads(LEAVES.read_text()) if LEAVES.exists() else {}
    _run(list(p["leaves"]), lambda k: haiku(LEAF_PROMPT.format(conv=leaf_input(p["leaves"][k])), 160), LEAVES, leaves, workers)
    roots = json.loads(ROOTS.read_text()) if ROOTS.exists() else {}
    ok = lambda ks: [leaves[k] for k in ks if leaves.get(k)]
    todo = [k for k in p["roots"] if ok(p["roots"][k])]
    _run(todo, lambda k: haiku(ROOT_PROMPT.format(conv=root_input(ok(p["roots"][k]))), MAX_CHARS), ROOTS, roots, workers)


# ---------------------------------------------------------------- formats

_cache = {}


def _data():
    if not _cache:
        p = plan()
        _cache.update(p=p, leaves=json.loads(LEAVES.read_text()), roots=json.loads(ROOTS.read_text()))
        fp = {}
        for line in open(DATA / "real.jsonl"):
            c = json.loads(line)
            fp.setdefault(frozenset((s["id"], s["idle_min"]) for s in c["board"]["sessions"]), []).append(c)
        _cache["fp"] = fp
    return _cache


def real_id(case):
    """The real moment a case's board is: itself, or (a style case) the one whose board it reuses."""
    d = _data()
    if case["id"] in d["p"]["cases"]:
        return case["id"]
    reals = d["fp"].get(frozenset((s["id"], s.get("idle_min")) for s in case["board"]["sessions"]), [])
    same = [c for c in reals if set(c["gold"]["to"]) & set(case["gold"]["to"])]
    return (same or reals)[0]["id"] if reals else None


def lines_of(case, kind):
    """{board session id: line}"""
    d = _data()
    out = {}
    for sid, (rk, lk) in d["p"]["cases"].get(real_id(case), {}).items():
        line = d["roots"].get(rk) if kind in ("root", "shuffled") else d["leaves"].get(lk)
        if line:
            out[sid] = line
    if kind == "shuffled":
        ids = sorted(out)
        if len(ids) > 1:
            rng = random.Random(f"shuffle:{case['id']}")
            while True:  # a derangement: no line stays with its own session
                perm = ids[:]
                rng.shuffle(perm)
                if all(a != b for a, b in zip(ids, perm)):
                    break
            out = {a: out[b] for a, b in zip(ids, perm)}
    return out


def make(kind):
    def fmt(case, rng=None):
        state, q, keymap = combo.combo(case, rng)
        lines = lines_of(case, kind)
        for name, c in q["route"]["criteria"].items():
            line = lines.get(keymap.get(name))
            if line and isinstance(c, dict) and c.get("kind") == "Claude Code session":
                c[FIELD] = line[:MAX_CHARS]
        return state, q, keymap
    return fmt


FORMATS = {"combo-root": make("root"), "combo-recent": make("recent"), "combo-shuffled": make("shuffled")}

# ---------------------------------------------------------------- bench

ALL = ("combo-o", "combo-life", "combo-root", "combo-recent", "combo-shuffled")
RES = DATA / "tree_results.json"


def _setup():
    os.environ["JEV_ORDERED"] = "1"
    import bench as B
    import formats
    import jev
    import run
    from explore import cal, final3
    from explore import fusion as Fu
    from explore import lexical as L
    from explore import life
    from v2.run.episodes import _shipped_weights
    jev.ordered = True
    formats.FORMATS.update(combo.FORMATS)
    formats.FORMATS.update(cal.FORMATS)
    formats.FORMATS.update(life.FORMATS)
    formats.FORMATS.update(FORMATS)
    return B, run, final3, Fu, L, _shipped_weights


def bench(fmts=ALL):
    """Run each format on style and real (resumable: a finished runs/ file is kept), then score."""
    B, run, final3, Fu, L, shipped = _setup()
    for fmt in fmts:
        for s in ("style", "real"):
            if not (HERE / "runs" / f"{fmt}@{s}.jsonl").exists():
                rows = run.run(fmt, B.load_set(s), 1)
                run.save(f"{fmt}@{s}", rows)
                toks = [r["tokens"] for r in rows if r.get("tokens")]
                print(f"ran {fmt}@{s}: {len(rows)} rows, mean input tokens {sum(toks) / max(len(toks), 1):.0f}", flush=True)
    L.install()
    L.STATE["fields"] = True
    Fu.case_features = final3.case_features
    out = {}
    for fmt in fmts:
        for label in ("shipped", "refit"):
            if label == "shipped":
                wv = shipped()
            else:
                w, v = L.fitted(fmt, L.FEATS_FIELDS, Fu.CASE_FEATURES, train=("realA", "styleA"))
                wv = ({k: round(float(x), 2) for k, x in w.items()}, {k: round(float(x), 2) for k, x in v.items()})
            pol = final3.make(*wv)
            for s in ("realA", "realB", "real", "styleA", "styleB"):
                cases = B.load_set(s)
                whole = "real" if s.startswith("real") else "style"
                ids = {c["id"] for c in cases}
                rows = [r for r in run.load(f"{fmt}@{whole}") if r["id"] in ids]
                by = {c["id"]: c for c in cases}
                per = {}
                for row in rows:
                    t = B.score([by[row["id"]]], [row], pol)
                    per[row["id"]] = {k: int(t[k]) for k in ("top1", "right", "wrong", "wrong_session", "ask", "needless")}
                    per[row["id"]]["tok"] = row.get("tokens") or 0
                    per[row["id"]]["grp"] = by[row["id"]]["gold"]["to"][0] if by[row["id"]]["gold"]["to"] else row["id"]
                out[f"{fmt}|{label}|{s}"] = per
    RES.write_text(json.dumps(out))
    print("saved", RES)


def report():
    import numpy as np
    res = json.loads(RES.read_text())
    rng = np.random.default_rng(7)
    KEYS = ("top1", "right", "wrong", "wrong_session", "needless")

    def boot(a, b, k):
        """Mean difference b - a in points, session-grouped bootstrap 95% CI, gained/lost counts."""
        ids = sorted(a)
        groups = {}
        for i in ids:
            groups.setdefault(a[i]["grp"], []).append(b[i][k] - a[i][k])
        gs = [np.array(v) for v in groups.values()]
        tot = np.array([v.sum() for v in gs])
        cnt = np.array([len(v) for v in gs])
        bs = []
        for _ in range(2000):
            ix = rng.integers(0, len(gs), len(gs))
            bs.append(100 * tot[ix].sum() / cnt[ix].sum())
        d = [b[i][k] - a[i][k] for i in ids]
        return 100 * np.mean(d), np.percentile(bs, 2.5), np.percentile(bs, 97.5), sum(x > 0 for x in d), sum(x < 0 for x in d)

    for label in ("refit", "shipped"):
        for s in ("real", "realB", "styleB", "styleA"):
            print(f"\n### {label} weights, {s} (n={len(res[f'combo-o|{label}|{s}'])})")
            print("| format | top-1 | right | wrong | wrong to a session | needless asks | input tokens |")
            print("|---|---|---|---|---|---|---|")
            base = res[f"combo-o|{label}|{s}"]
            for fmt in ALL:
                r = res[f"{fmt}|{label}|{s}"]
                n = len(r)
                m = lambda k: 100 * sum(x[k] for x in r.values()) / n
                tok = [x["tok"] for x in r.values() if x["tok"]]
                print(f"| {fmt} | {m('top1'):.1f} | {m('right'):.1f} | {m('wrong'):.1f} | {m('wrong_session'):.1f} | "
                      f"{m('needless'):.1f} | {sum(tok) / max(len(tok), 1):.0f} |")
            for fmt in ALL[1:]:
                r = res[f"{fmt}|{label}|{s}"]
                parts = []
                for k in KEYS[:2] + ("wrong", "needless"):
                    d, lo, hi, g, l = boot(base, r, k)
                    parts.append(f"{k} {d:+.1f} [{lo:+.1f}, {hi:+.1f}] ({g}+/{l}-)")
                print(f"  {fmt} vs combo-o: " + "; ".join(parts))


if __name__ == "__main__":
    {"derive": derive, "bench": bench, "report": report}[sys.argv[1]]()
