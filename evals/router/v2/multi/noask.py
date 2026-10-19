"""Exploratory (dev only): the no-ask mixes (candidates.NoAsk 1–3) against B as shipped, every division scored as sent.

- everyday single-place messages: extra wrong sends per 100 submits vs B (v2 dev episodes, all and real moments),
  paired group bootstrap;
- look-multi messages (gold: one place), written and real: wrong sends per 100;
- messages meant for several places: share fully right.

python3 -m v2.multi.noask  →  a table on stdout and v2/data/multi/noask_report.json"""
import json

from . import common as C, score

VARIANTS = ("noask1", "noask2", "noask3", "ship3")


def pct(x):
    return None if x is None else round(100 * x, 1)


def main():
    from v2.run import compare
    from v2.run.score import load_results
    out = {"single": {}, "multi": {}}
    b = load_results(score.RUNS / "single_pipeline.jsonl")
    real = lambda rs: [r for r in rs if r.get("provenance", {}).get("source") == "real-moment"]  # noqa: E731
    for v in VARIANTS:
        c = load_results(score.RUNS / f"single_{v}.jsonl")
        for name, (x, y) in {"all": (b, c), "real": (real(b), real(c))}.items():
            cmp = compare.compare(x, y, bootstrap=2000)
            nat = cmp["natural"]
            out["single"].setdefault(v, {})[name] = {
                "extra_wrong_per_100": pct(nat["delta"]["wrong_all"]),
                "ci95": [pct(nat["ci95"]["wrong_all"]["low"]), pct(nat["ci95"]["wrong_all"]["high"])],
                "wrong_per_100_B": pct(nat["baseline"]["wrong_all"]), "wrong_per_100": pct(nat["candidate"]["wrong_all"]),
                "loss_delta": round(nat["delta"]["loss_per_submit"], 2),
                "loss_ci95": [round(nat["ci95"]["loss_per_submit"]["low"], 2),
                              round(nat["ci95"]["loss_per_submit"]["high"], 2)]}
    names = ("pipeline",) + VARIANTS
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "dev"]
    outs = {n: {o["id"]: o for o in C.jsonl(score.RUNS / f"multi_dev_{n}.jsonl")} for n in names}
    rows = {n: [score.case_score(c, outs[n][c["id"]]) for c in cases] for n in names}
    slices = {"look-multi, written": lambda r: not r["multi"] and r["source"] == "written",
              "look-multi, real": lambda r: not r["multi"] and r["source"] == "real",
              "several places": lambda r: r["multi"]}
    for label, pred in slices.items():
        sub = {n: [r for r in rows[n] if pred(r)] for n in names}
        rep = score.summarize(sub, names, 2000)
        metric = "all_right" if label == "several places" else "wrong_send"
        table = {"n": rep["pipeline"]["n"], "groups": rep["pipeline"]["groups"]}
        for n in names:
            table[n] = {"value": pct(rep[n][metric]), "ci95": [pct(x) for x in rep[n]["ci95"][metric]]}
            if n != "pipeline":
                # score.boot names a pair by alphabetical order: "<later> - <earlier>".
                if f"pipeline - {n}" in rep["paired"]:
                    d = rep["paired"][f"pipeline - {n}"][metric]["ci95"]
                    table[n]["vs_B"] = [pct(-d[1]), pct(-d[0])]
                else:
                    d = rep["paired"][f"{n} - pipeline"][metric]["ci95"]
                    table[n]["vs_B"] = [pct(d[0]), pct(d[1])]
        out["multi"][label] = {"metric": metric, **table}
    (C.DATA / "noask_report.json").write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
