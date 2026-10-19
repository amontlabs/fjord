"""The multi-place test split, read only here, only as aggregates.

Runs the named candidates on every test case, keeps their outputs in v2/data/multi/sealed/ (nobody reads those per
case), prints the slice tables of score.py (means, intervals, paired differences: no case text, no per-case rows) and
appends the run to v2/data/multi/ledger.jsonl with the code's hash. Freeze the candidates on dev first: each read of
test is one entry in the ledger.

python3 -m v2.multi.seal haiku pipeline [sonnet]"""
import argparse
import datetime
import hashlib
import json

from . import common as C, run, score

SEALED = C.DATA / "sealed"


def code_hash():
    h = hashlib.sha256()
    for f in sorted(C.HERE.glob("*.py")):
        h.update(f.read_bytes())
    return h.hexdigest()[:16]


def strip(report):
    """Aggregates only: drop anything that isn't a number, an interval or a nested table of those."""
    if isinstance(report, dict):
        return {k: strip(v) for k, v in report.items()}
    if isinstance(report, list):
        return [strip(v) for v in report] if all(isinstance(v, (int, float, type(None))) for v in report) else None
    return report if isinstance(report, (int, float, bool, type(None))) else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("candidates", nargs="+", choices=["haiku", "pipeline", "sonnet"])
    a = ap.parse_args()
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "test"]
    outs = {}
    for name in a.candidates:
        out = run.multi(name, "test", allow_test=True)
        C.write_jsonl(SEALED / f"multi_test_{name}.jsonl", out)
        outs[name] = {o["id"]: o for o in out}
    report, _ = score.slices(cases, outs, a.candidates)
    report = strip(report)
    entry = {"at": datetime.datetime.now().isoformat(timespec="seconds"), "candidates": a.candidates,
             "code": code_hash(), "cases": len(cases)}
    with (C.DATA / "ledger.jsonl").open("a") as f:
        f.write(json.dumps(entry) + "\n")
    (C.DATA / "test_report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
