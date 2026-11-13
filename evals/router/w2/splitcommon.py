"""The shipped split additions, ported from the Swift source verbatim (DeciderContext.split, DeciderContext.schema's `sends`,
RouterProjectDecider.splitParts), shared by the 300-moment run (t3/splitrun.py) and the drafts eval (w2/split_eval.py)."""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evals/router/t3"))
import n4ctx as N  # noqa: E402

BARS = dict(idle=0.90, running=0.90, new=0.70, pnew=0.70)


def split_text():
    """`DeciderContext.split`, read from the Swift source so the eval runs what ships."""
    src = (ROOT / "Sources/Fjord/DeciderContext.swift").read_text()
    m = re.search(r'static let split = """\n(.*?)\n\s*"""', src, re.S)
    return "\n".join(l[8:] if l.startswith(" " * 8) else l.strip() for l in m.group(1).split("\n"))


def system():
    return N.ROLE_CTX + split_text()


def schema():
    """`DeciderContext.schema` (N4b's with `sends` last), read from the Swift source."""
    src = (ROOT / "Sources/Fjord/DeciderContext.swift").read_text()
    m = re.search(r'static let schema = #"(.*?)"#', src, re.S)
    s = json.loads(m.group(1))
    assert s["required"][:-1] == N.SCHEMA["required"], "the Swift schema drifted from N4b's"
    return s


def words(text):
    """`RouterProjectDecider.words`: lowercased letters and digits, an apostrophe kept inside a word."""
    out, run = set(), ""
    for ch in text.lower():
        if ch.isalnum() or (ch in "'’" and run): run += "'" if ch == "’" else ch
        elif run: out.add(run.strip("'")); run = ""
    if run: out.add(run.strip("'"))
    out.discard("")
    return out


def parts(answer, message, place, running):
    """`splitParts`: the model's sends as [(places, sure, words, confidence)], or [] (no split). `place(to)` -> ("thread", key) |
    ("new", project) | None; `running(key)` -> bool."""
    sends = (answer or {}).get("sends") or []
    if len(sends) < 2: return []
    owned = words(message); out = []
    for s in sends:
        w = (s.get("words") or "").strip(); first = place(s.get("to") or "")
        if not first or not w: return []
        if not words(w) <= owned: return []
        bar = (BARS["running"] if running(first[1]) else BARS["idle"]) if first[0] == "thread" else BARS["new"]
        conf = s.get("confidence") or 0; sure = conf >= bar; places = [first]
        if not sure:
            for alt in s.get("alternatives") or []:
                p = place(alt)
                if p and p not in places: places.append(p)
            places = places[:3]
        out.append((places, sure, w, conf))
    firsts = [p[0][0] for p in out]
    if len(set(firsts)) != len(firsts): return []
    return out
