"""Track 5 launch eval: 40 settings-aside drafts + 10 near-misses, through the shipped schema (launch, launch_words) and launchRole
via `claude -p` Sonnet, on a small synthetic board (evals/router/w2/launch_drafts.py). Output: evals/router/w2/out/launch_<tag>.json (no real data).

  python3 launch_eval.py run [--tag base] [--workers 4] [--prompt-file extra_role.txt] [--schema-variant NAME]
  python3 launch_eval.py score [--tag base]

Scored per draft: model/effort/runtime/interaction exactly as named (and nothing else set), launch_words an exact accepted span that is a
substring of the draft, nothing taken for near-misses (launch == {} and launch_words == ""), and the message never rewritten (the app only
ever uses launch_words to cut it out, so a non-substring is a rewrite)."""
import json, pathlib, sys, concurrent.futures as cf
HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "t3"))
import w2run as W
from launch_drafts import DRAFTS

OUT = HERE / "out"; OUT.mkdir(exist_ok=True)

BOARD = """## Projects
- webapp | purpose: the customer dashboard (React, Vite)
- api | purpose: the backend REST api and its workers
- notes-cli | purpose: a small command line tool for notes
- infra | purpose: docker, ci and deploys

## Live threads (creation order)
### t-a1f0 | webapp | Settings page layout
state: finished, last activity Wed 11-11 17:20 · you last wrote here Wed 11-11 17:02 · created Tue 11-10 09:30 · you opened it Wed 11-11 17:25, after its reply
card: deliverable: rebuild the settings page in two columns · status: delivered · left: nothing
### t-b2c9 | api | Retry logic for webhooks
state: running (a message would interrupt it) · you last wrote here Wed 11-11 18:40 · created Wed 11-11 18:10
card: deliverable: add exponential backoff to webhook delivery · status: in_progress · left: tests for the backoff
### t-c3d4 | infra | Slow CI build
state: finished, last activity Wed 11-11 12:05 · you last wrote here Wed 11-11 11:50 · created Wed 11-11 11:40
card: deliverable: find why CI takes 14 minutes · status: delivered · left: the owner decides on caching

## Project facts
- webapp: 14 threads started in all, the newest at Tue 11-10 09:30
- api: 22 threads started in all, the newest at Wed 11-11 18:10
- notes-cli: 5 threads started in all, the newest at Mon 11-02 10:00
- infra: 9 threads started in all, the newest at Wed 11-11 11:40"""
NOW = "## Now\nThu 11-12 10:15 Paris.\nYour last message anywhere: Wed 11-11 18:40.\nSince then: no thread finished a reply.\nRunning now: t-b2c9."
EXTRA = ""


def system():
    return W.N.ROLE_CTX + W.launch_role() + EXTRA


def ask(d, schema):
    user = BOARD + "\n\n## Threads whose text shares words with the message (a lexical match, not a ranking)\n- no thread shares a word with the message\n- words of the message no thread mentions: none\n\n" \
        + NOW + f"\n\nMessage:\n<message>{d['draft']}</message>"
    a, o, sec = W.claude(system(), user, schema)
    return a, o.get("total_cost_usd") or 0, sec


def run(tag, workers):
    schema = W.schema_launch()
    def one(i):
        try: a, c, s = ask(DRAFTS[i], schema); return i, a, c, s
        except Exception as e: return i, {"error": str(e)[:200]}, 0, 0  # noqa: BLE001
    with cf.ThreadPoolExecutor(workers) as ex: res = sorted(ex.map(one, range(len(DRAFTS))))
    json.dump([{"i": i, "answer": a, "cost": c, "sec": s} for i, a, c, s in res], open(OUT / f"launch_{tag}.json", "w"))
    print(tag, len(res), f"cost ${sum(r[2] for r in res):.2f}")


MODEL_EFFORTS = {m[0]: m[3] for m in W.MODELS}


def checked(la):
    """RouterLaunchCatalog.checked: an effort the named model doesn't take is dropped (Haiku takes none; Sonnet has no xhigh)."""
    out = dict(la); m = out.get("model") or "claude-opus-5-5"
    if "effort" in out and out["effort"] not in MODEL_EFFORTS.get(m, []): del out["effort"]
    return out


def residue(draft, words):
    """What taking `words` leaves behind: empty or unbalanced brackets, a doubled/dangling comma or dash."""
    import re
    rest = (draft[:draft.rfind(words)] + draft[draft.rfind(words) + len(words):]).strip()
    return bool(re.search(r"\(\s*\)|\[\s*\]|^[\s,;:.-]+\S|[(\[]\s*$|^\s*[)\]]|\s[,;]\s|\(\s+[^)]*$|^[^(]*\)", rest)) or rest.count("(") != rest.count(")")


def score(tag):
    R = {r["i"]: r for r in json.load(open(OUT / f"launch_{tag}.json"))}
    rows, fails = [], []
    for i, d in enumerate(DRAFTS):
        a = R[i]["answer"]; la = checked(a.get("launch") or {}); lw = a.get("launch_words") or ""
        r = dict(i=i, kind=d["kind"], action=a.get("action"))
        r["words_in_draft"] = lw == "" or lw in d["draft"]
        if d["kind"] == "aside":
            r["settings_ok"] = la == d["want"]
            r["settings_missing"] = {k: v for k, v in d["want"].items() if la.get(k) != v}
            r["settings_extra"] = {k: v for k, v in la.items() if k not in d["want"]}
            strip = lambda x: x.strip("() ").strip()
            r["words_exact"] = lw == d["words"] or lw in d["accept"]
            r["words_ok"] = r["words_exact"] or (lw != "" and strip(lw) == strip(d["words"]))   # same words, brackets in or out
            r["bracket_residue"] = lw != "" and r["words_in_draft"] and residue(d["draft"], lw)
            r["ok"] = r["settings_ok"] and r["words_ok"] and r["words_in_draft"]
        else:
            r["taken"] = bool(la) or bool(lw)
            r["ok"] = not r["taken"]
        if not r["ok"]: fails.append((i, d, la, lw))
        rows.append(r)
    A = [r for r in rows if r["kind"] == "aside"]; Nn = [r for r in rows if r["kind"] == "near"]
    f = lambda xs, k: f"{sum(1 for x in xs if x[k])}/{len(xs)}"
    print(f"{tag}: asides all-right {f(A,'ok')} · settings exact {f(A,'settings_ok')} · words right (brackets in or out) {f(A,'words_ok')} · "
          f"words exact incl. brackets {f(A,'words_exact')} · cut leaves residue {f(A,'bracket_residue')} · "
          f"extra setting set {sum(1 for r in A if r['settings_extra'])} · near-misses clean {sum(r['ok'] for r in Nn)}/{len(Nn)} · "
          f"words not in draft (rewrite) {sum(1 for r in rows if not r['words_in_draft'])}/{len(rows)} · "
          f"asides with a model launched on a non-new action {sum(1 for r in A if r['action']!='new_work')}")
    for i, d, la, lw in fails: print(f"  FAIL #{i} [{d['kind']}] {d['draft']!r}\n    want {d['want']} words {d['words']!r}\n    got  {la} words {lw!r}")
    json.dump(rows, open(OUT / f"launch_{tag}_scored.json", "w"))


if __name__ == "__main__":
    a = sys.argv[1:]; tag = a[a.index("--tag") + 1] if "--tag" in a else "base"
    if "--prompt-file" in a: EXTRA = "\n" + open(a[a.index("--prompt-file") + 1]).read().strip()
    if a[0] == "run": run(tag, int(a[a.index("--workers") + 1]) if "--workers" in a else 4)
    else: score(tag)
