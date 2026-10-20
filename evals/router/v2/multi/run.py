"""Run a candidate on a slice and save what it did.

- `single`: the v2 dev episodes (one place each), replayed through v2/run/episodes.play_episode with the candidate as
  the Router, so the click-loss, branches and corrections are the existing benchmark's. A sure answer with several
  parts is a `compound` send (right only where the gold is compound); an unsure one asks with its places.
- `multi`: the multi-place cases of one split (dev here; test only through seal.py), one route per case.

python3 -m v2.multi.run single haiku|pipeline|sonnet [--limit N]
python3 -m v2.multi.run multi haiku|pipeline|sonnet --split dev
Outputs under v2/data/multi/runs/ (gitignored)."""
import argparse
import json
from concurrent.futures import ThreadPoolExecutor

from . import candidates, common as C

RUNS = C.DATA / "runs"


class _PerThread:
    """episodes._SKIPPED_CARDS as one dict per thread, so episodes can replay in parallel."""
    def __init__(self):
        import threading
        self._local = threading.local()

    def _d(self):
        if not hasattr(self._local, "d"):
            self._local.d = {}
        return self._local.d

    def clear(self):
        self._d().clear()

    def setdefault(self, *a):
        return self._d().setdefault(*a)

    def get(self, *a):
        return self._d().get(*a)


class AsRouter:
    """A candidate in the v2 replay's RouterSystem shape (decide, name)."""
    def __init__(self, name, candidate):
        self.name, self.candidate = name, candidate

    def decide(self, state, event):
        r = self.candidate.route(state, event["message"], event.get("context", {}))
        parts = r["parts"]
        ranked = [{"target": t, "score": 0.0} for t in r["options"]]
        extra = {"parts": parts, "latency": r.get("latency"), "cost": r.get("cost"), "calls": r.get("calls"),
                 "cand_path": r.get("path"), "error": r.get("error"), "path": "candidate"}
        if r["sure"] and len(parts) == 1:
            return {"decision": "send", "target": parts[0]["target"], "top": parts[0]["target"], "ranked": ranked, **extra}
        if r["sure"] and len(parts) > 1:
            return {"decision": "send", "target": "compound", "top": "compound", "ranked": ranked, **extra}
        return {"decision": "ask", "target": None, "top": ranked[0]["target"] if ranked else None, "ranked": ranked,
                **extra}


def single(name, limit=None, workers=4):
    from v2.run import episodes
    episodes._SKIPPED_CARDS = _PerThread()
    eps = episodes.load_episodes(C.ROUTER / "v2" / "data" / "episodes" / "dev" / "episodes.jsonl")[:limit]
    cand = candidates.make(name)
    if name in ("pipeline", "hybrid", "hybrid-lazy") or name.startswith("noask") or name.startswith("ship3"):
        workers = 1  # the shipped policy keeps module state per call (fusion._CASES): one at a time

    def play(ep):
        return episodes.play_episode(ep, AsRouter(name, cand))
    with ThreadPoolExecutor(workers) as pool:
        results = []
        for n, res in enumerate(pool.map(play, eps), 1):
            res.pop("final_state", None)
            results.append(res)
            if n % 50 == 0:
                print(f"{n}/{len(eps)}", flush=True)
    C.write_jsonl(RUNS / f"single_{name}.jsonl", results)
    print(len(results), "episodes")


def multi(name, split, workers=4, allow_test=False):
    if split == "test" and not allow_test:
        raise SystemExit("the test split is read only through v2.multi.seal")
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == split]
    if name in ("pipeline", "hybrid", "hybrid-lazy") or name.startswith("noask") or name.startswith("ship3"):
        cand, workers = candidates.make(name), 1
    else:
        cand = candidates.make(name)

    def go(c):
        r = cand.route(c["state"], c["message"], c["context"])
        return {"id": c["id"], **r}
    with ThreadPoolExecutor(workers) as pool:
        out = list(pool.map(go, cases))
    return out


_KNOWN = ("haiku", "pipeline", "sonnet", "hybrid", "hybrid-lazy", "noask1", "noask2", "noask3", "ship3", "ship3-v2",
          "ship3-v3", "ship3-v4", "ship3-v5")


def _known(name):
    if name not in _KNOWN:
        raise argparse.ArgumentTypeError(f"unknown candidate {name}")
    return name


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("slice", choices=["single", "multi"])
    ap.add_argument("candidate", type=lambda n: n if n.startswith("ship3+") else _known(n))
    ap.add_argument("--split", default="dev", choices=["dev"])
    ap.add_argument("--limit", type=int)
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    if a.slice == "single":
        single(a.candidate, a.limit, a.workers)
    else:
        out = multi(a.candidate, a.split, a.workers)
        C.write_jsonl(RUNS / f"multi_{a.split}_{a.candidate}.jsonl", out)
        print(len(out), "cases")


if __name__ == "__main__":
    main()
