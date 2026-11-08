"""N1: run the current deciders on the moments.

  python3 run.py jev      Jev's fused path (one call per moment, every moment) -> data/res_jev.jsonl
  python3 run.py sonnet   Sonnet as the app calls it, on the Sonnet set           -> data/res_sonnet.jsonl

The Sonnet set: every first message (new work, fork starts) and a seeded 30% sample of follow-ups; score.py reweights the
follow-ups so pooled numbers keep the natural ratio. 4 calls in flight. Prints counts and cost, never text."""
import concurrent.futures as cf
import json
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import board as B  # noqa: E402
from calls import anthropic, jev_ask  # noqa: E402

DATA = pathlib.Path(__file__).parent / "data"
FOLLOW_SHARE = 0.30
PURPOSES = json.load(open(DATA / "purposes.json"))


def load_moments():
    return [json.loads(l) for l in open(DATA / "moments.jsonl")]


def make_board(m):
    return B.Board(projects=m["board"]["projects"], threads=[B.Thread(**t) for t in m["board"]["threads"]], purposes=PURPOSES)


def sonnet_set(M):
    rng = random.Random(11)
    return [m for m in M if m["cls"] != "follow" or rng.random() < FOLLOW_SHARE]


def run_jev(m):
    b = make_board(m)
    req = B.jev_request(m["message"], b)
    state, questions = req[0], req[1]
    a = jev_ask(state, questions)
    r = B.jev_result(a["answers"], req, m["message"])
    return {"id": m["id"], "rows": r["rows"][:6], "send": r["send"], "abstain": r["abstain"], "fjord": r["fjord"],
            "running_mass": r["running_mass"], "jev_top": r["jev_top"], "model": a.get("model"), "sec": a.get("_latency"),
            "usage": a.get("usage")}


def run_sonnet(m):
    b = make_board(m)
    r = anthropic(B.ROLE, B.sonnet_prompt(m["message"], b), B.SCHEMA, model=B.SONNET_MODEL, max_tokens=B.MAX_TOKENS, tag="n1")
    a = r["answer"] or {}
    return {"id": m["id"], "answer": {k: a.get(k) for k in ("action", "project", "session", "confidence", "project_confidence", "alternatives")},
            "decision": B.sonnet_decision(a, b) if a else ("ask", []), "guess": B.sonnet_guess(a, b) if a else ("none",),
            "sec": r["sec"], "usage": r["usage"], "stop": r["stop"]}


def main(which):
    M = load_moments()
    todo, fn = (M, run_jev) if which == "jev" else (sonnet_set(M), run_sonnet)
    path = DATA / f"res_{which}.jsonl"
    done = {json.loads(l)["id"] for l in open(path)} if path.exists() else set()
    fails = 0
    with cf.ThreadPoolExecutor(4) as ex, open(path, "a") as f:
        futs = {ex.submit(fn, m): m["id"] for m in todo if m["id"] not in done}
        for fu in cf.as_completed(futs):
            try: r = fu.result()
            except Exception as e:  # noqa: BLE001
                fails += 1; print("fail", type(e).__name__, str(e)[:120], file=sys.stderr); continue
            f.write(json.dumps(r) + "\n"); f.flush()
    rows = [json.loads(l) for l in open(path)]
    if which == "sonnet":
        u = [r["usage"] for r in rows]
        cost = sum(x["input_tokens"] * 2 + x.get("cache_read_input_tokens", 0) * 0.2 + x.get("cache_creation_input_tokens", 0) * 2.5
                   + x["output_tokens"] * 10 for x in u) / 1e6
        print(which, len(rows), "fails", fails, f"cost ${cost:.2f}", "cut off", sum(r["stop"] == "max_tokens" for r in rows))
    else:
        print(which, len(rows), "fails", fails, "models", {r["model"] for r in rows})


if __name__ == "__main__":
    main(sys.argv[1])
