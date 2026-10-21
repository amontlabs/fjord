"""Explorer `life`: a one-line whole-life summary on each session's option (2026-10-21).

UniiChat (github.com/VictorTaelin/UniiChat) keeps a chat as a binary tree of one-line summaries; its root says what the
whole conversation has been about. Round 2 measured richer *recent* context per option (first ask, last 2 paragraphs:
noise); this asks whether a line about the session's whole life helps Jev name where a real message goes, beside the
shipped options ("now", "the user last told it").

The line is written by Haiku (`claude -p`) from the session's turns before the moment: every earlier turn's message and
answer, clipped, and the current turn's message only (its answer may not exist yet). Keyed by session and turn, so a
session's line is shared by every case that sees it at that turn. Written directly from the turns rather than built up
a tree, so it is at least as good as a tree's root would be.

  python3 -m explore.life derive         →  real/data/life.json   (session@turn → line)
  python3 -m explore.life bench          runs combo-o and combo-life on style and real; scores both with the shipped
                                         weights, and each with weights refit on its own runs (realA + styleA)"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

from explore import combo
from explore.context import TOKEN

HERE = pathlib.Path(__file__).resolve().parent.parent
LIFE_PATH = HERE / "real" / "data" / "life.json"
FIELD = "what it has been about overall"
MAX_CHARS = 300

PROMPT = f"""Below is a Claude Code session's conversation so far: the user's messages and the session's answers, \
clipped, oldest first. Write ONE line, at most {MAX_CHARS} characters, saying what this session has been about over its \
whole life: its goal and the main threads of work, in plain words. No preamble, no quotes, just the line.

<conversation>
{{conv}}
</conversation>"""


# ---------------------------------------------------------------- derivation

def _clip(t, n):
    t = " ".join((t or "").split())
    return t if len(t) <= n else t[:n] + "…"


def conversation(turns, i):
    """Turns before i with their answers, turn i's message alone; a long session keeps its first 4 turns and last 40."""
    rows = []
    for k, t in enumerate(turns[:i + 1]):
        rows.append(f"User: {_clip(t['you'], 400)}")
        if k < i and t.get("said"):
            rows.append(f"Session: {_clip(t['said'], 400)}")
    if len(rows) > 88:
        rows = rows[:8] + ["[… earlier turns left out …]"] + rows[-80:]
    return "\n".join(rows)


def jobs():
    """{session@turn: conversation} for every session on every real board (style boards reuse real ones)."""
    sys.path.insert(0, str(HERE / "real"))
    import boards as rb
    sessions = rb.load()
    by = {}
    for s in sessions:
        by.setdefault(s["id"][:8], []).append(s)
    out, per_case = {}, {}
    for line in open(HERE / "real" / "data" / "real.jsonl"):
        c = json.loads(line)
        t0 = rb.ts(c["at"])
        gold = c["gold"]["to"][0]
        keys = {}
        for s in c["board"]["sessions"]:
            now = t0 - 1e-3 if s["id"] == gold else t0
            cands = [x for x in by.get(s["id"], []) if x["title"][:80] == s["title"] or len(by[s["id"]]) == 1]
            for x in cands:
                st = rb.state_at(x, now)
                if st:
                    i = x["turns"].index(st["turn"])
                    k = f"{s['id']}@{i}"
                    out.setdefault(k, TOKEN.sub("[redacted]", conversation(x["turns"], i)))
                    keys[s["id"]] = k
                    break
        per_case[c["id"]] = keys
    return out, per_case


def haiku(prompt, max_chars=MAX_CHARS, tries=2):
    """One line from Haiku via `claude -p` from a temp cwd (no tools, no settings, no session kept); None on failure."""
    for _ in range(tries):
        try:
            with tempfile.TemporaryDirectory() as d:
                r = subprocess.run(["claude", "-p", "--model", "haiku", "--system-prompt", "You summarize conversations in one line.",
                                    "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"],
                                   input=prompt, capture_output=True, text=True, cwd=d, timeout=180)
        except subprocess.TimeoutExpired:
            continue
        line = " ".join(r.stdout.split())
        if r.returncode == 0 and line:
            return line[:max_chars]
    return None


def write_line(conv):
    return haiku(PROMPT.format(conv=conv))


def derive(workers=6):
    todo, per_case = jobs()
    have = json.loads(LIFE_PATH.read_text()) if LIFE_PATH.exists() else {}
    lines = have.get("lines", {})
    missing = [k for k in todo if not lines.get(k)]
    print(f"{len(todo)} session@turn, {len(missing)} to write", flush=True)
    done = 0
    with ThreadPoolExecutor(workers) as ex:
        for k, line in zip(missing, ex.map(lambda k: write_line(todo[k]), missing)):
            lines[k] = line
            done += 1
            if done % 50 == 0:
                LIFE_PATH.write_text(json.dumps({"lines": lines, "cases": per_case}, ensure_ascii=False))
                print(done, flush=True)
    LIFE_PATH.write_text(json.dumps({"lines": lines, "cases": per_case}, ensure_ascii=False))
    print("failed:", sum(1 for k in todo if not lines.get(k)))


# ---------------------------------------------------------------- format

_life = None


def life_of(case):
    """{session id: line} as the case's board saw each session; style cases borrow their real board's."""
    global _life
    if _life is None:
        _life = json.loads(LIFE_PATH.read_text()) if LIFE_PATH.exists() else {"lines": {}, "cases": {}}
    keys = _life["cases"].get(case["id"])
    if keys is None:
        keys = _style_keys(case)
    return {sid: _life["lines"].get(k) for sid, k in keys.items() if _life["lines"].get(k)}


_fp = None


def _style_keys(case):
    global _fp
    if _fp is None:
        _fp = {}
        for line in open(HERE / "real" / "data" / "real.jsonl"):
            c = json.loads(line)
            _fp[frozenset((s["id"], s["idle_min"]) for s in c["board"]["sessions"])] = c["id"]
    rid = _fp.get(frozenset((s["id"], s.get("idle_min")) for s in case["board"]["sessions"]))
    return _life["cases"].get(rid, {}) if rid else {}


def combo_life(case, rng=None):
    state, q, keymap = combo.combo(case, rng)
    life = life_of(case)
    crit = q["route"]["criteria"]
    for name, c in crit.items():
        line = life.get(keymap.get(name))
        if line and isinstance(c, dict) and c.get("kind") == "Claude Code session":
            c[FIELD] = line
    return state, q, keymap


FORMATS = {"combo-life": combo_life}


# ---------------------------------------------------------------- bench

def bench(sets=("style", "real"), score_sets=("realA", "realB", "real", "styleB")):
    os.environ["JEV_ORDERED"] = "1"
    import bench as B
    import formats
    import jev
    import run
    from explore import cal, final3
    from explore import fusion as Fu
    from explore import lexical as L
    from v2.run.episodes import _shipped_weights
    jev.ordered = True
    formats.FORMATS.update(combo.FORMATS)
    formats.FORMATS.update(cal.FORMATS)
    formats.FORMATS.update(FORMATS)
    for fmt in ("combo-o", "combo-life"):
        for s in sets:
            if not (HERE / "runs" / f"{fmt}@{s}.jsonl").exists():
                rows = run.run(fmt, B.load_set(s), 1)
                run.save(f"{fmt}@{s}", rows)
                toks = [r["tokens"] for r in rows if r.get("tokens")]
                print(f"ran {fmt}@{s}: {len(rows)} rows, mean input tokens {sum(toks) / max(len(toks), 1):.0f}", flush=True)
    L.install()
    L.STATE["fields"] = True
    Fu.case_features = final3.case_features
    shipped = _shipped_weights()
    for fmt in ("combo-o", "combo-life"):
        for label, wv in (("shipped weights", shipped), ("refit", None)):
            if wv is None:  # final3.fitted, on realA + styleA (the written sets are no longer in the repo)
                w, v = L.fitted(fmt, L.FEATS_FIELDS, Fu.CASE_FEATURES, train=("realA", "styleA"))
                wv = ({k: round(float(x), 2) for k, x in w.items()}, {k: round(float(x), 2) for k, x in v.items()})
            pol = final3.make(*wv)
            print(f"== {fmt}  (final3, {label})")
            for s in score_sets:
                cases = B.load_set(s)
                whole = {"realA": "real", "realB": "real", "styleA": "style", "styleB": "style"}.get(s, s)
                ids = {c["id"] for c in cases}
                rows = [r for r in run.load(f"{fmt}@{whole}") if r["id"] in ids]
                print("  " + B.line(s, B.score(cases, rows, pol)), flush=True)


if __name__ == "__main__":
    {"derive": derive, "bench": bench}[sys.argv[1]]()
