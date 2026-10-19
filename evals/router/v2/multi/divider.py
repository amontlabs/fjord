"""Exploratory (dev only): divider prompt revisions in the ship form (ship3 = live prompts, ship3-v2, ship3-v3) against
each other and B as shipped.

- several places (multi dev, gold two places or more): share fully right;
- look-multi (multi dev, gold one place), written and real: wrong sends per 100;
- parts with added words, over every part sent (multi dev);
- everyday messages where the gates fire (single-place episodes): wrong sends among those submits.
Intervals: 2,000 bootstrap replicates over groups, paired against the live prompt.

python3 -m v2.multi.divider ship3 ship3-v2 ship3-v3  →  v2/data/multi/divider_report.json"""
import argparse
import json
import random

from . import common as C, score

HAIKU_PATHS = ("ship3-split", "ship3-one", "ship3-one-ask", "ship3-failed")


def pct(x):
    return None if x is None else round(100 * x, 1)


def boot_paired(rows, names, value, reps=2000, seed=11):
    """Mean of value(row) per name, its 95% CI, and the CI of each name minus the first, resampling groups."""
    groups = sorted({r["group"] for r in rows[names[0]]})
    by = {n: {} for n in names}
    for n in names:
        for r in rows[n]:
            by[n].setdefault(r["group"], []).append(value(r))
    rng = random.Random(seed)
    draws = {n: [] for n in names}
    for _ in range(reps):
        pick = [rng.choice(groups) for _ in groups]
        for n in names:
            vals = [x for g in pick for x in by[n].get(g, [])]
            draws[n].append(sum(vals) / len(vals) if vals else 0.0)

    def ci(xs):
        xs = sorted(xs)
        return [pct(xs[int(0.025 * len(xs))]), pct(xs[int(0.975 * len(xs)) - 1])]
    out = {}
    for n in names:
        vals = [value(r) for r in rows[n]]
        out[n] = {"value": pct(sum(vals) / len(vals)) if vals else None, "ci95": ci(draws[n])}
        if n != names[0]:
            out[n]["vs_" + names[0]] = ci([b - a for a, b in zip(draws[names[0]], draws[n])])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("variants", nargs="+")
    a = ap.parse_args()
    names = ["pipeline"] + a.variants
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "dev"]
    outs = {n: {o["id"]: o for o in C.jsonl(score.RUNS / f"multi_dev_{n}.jsonl")} for n in names}
    rows = {n: [score.case_score(c, outs[n][c["id"]]) for c in cases] for n in names}
    report = {"n_cases": len(cases)}
    multi = {n: [r for r in rows[n] if r["multi"]] for n in names}
    report["several_places_fully_right"] = {"n": len(multi[names[0]]),
                                            **boot_paired(multi, a.variants, lambda r: r["all_right"])}
    report["several_places_fully_right"]["pipeline"] = pct(sum(r["all_right"] for r in multi["pipeline"]) / len(multi["pipeline"]))
    for label, pred in (("look_multi_written", lambda r: not r["multi"] and r["source"] == "written"),
                        ("look_multi_real", lambda r: not r["multi"] and r["source"] == "real")):
        sub = {n: [r for r in rows[n] if pred(r)] for n in names}
        report[label + "_wrong_per_100"] = {"n": len(sub[names[0]]), **boot_paired(sub, a.variants,
                                                                                   lambda r: r["wrong_send"])}
        report[label + "_wrong_per_100"]["pipeline"] = pct(sum(r["wrong_send"] for r in sub["pipeline"]) / len(sub["pipeline"]))
    added = {}
    for n in a.variants:
        parts = [(c["message"], p["text"]) for c in cases for p in outs[n][c["id"]]["parts"]]
        extra = [score.aligned(m, t)[1] for m, t in parts]
        split_parts = [(c["message"], p["text"]) for c in cases if len(outs[n][c["id"]]["parts"]) >= 2
                       and outs[n][c["id"]]["path"].endswith("split") for p in outs[n][c["id"]]["parts"]]
        sx = [score.aligned(m, t)[1] for m, t in split_parts]
        added[n] = {"parts": len(parts), "with_added_words": pct(sum(e > 0 for e in extra) / len(extra)),
                    "split_parts": len(split_parts), "split_with_added_words": pct(sum(e > 0 for e in sx) / len(sx)),
                    "added_words_per_split_part": round(sum(sx) / len(sx), 2)}
    report["added_words"] = added
    # Everyday messages where the gates fire: the submits on which any variant made its Haiku call.
    from v2.run.score import load_results
    single = {n: load_results(score.RUNS / f"single_{n}.jsonl") for n in names}
    gated = set()
    for n in a.variants:
        for res in single[n]:
            for ev in res["events"]:
                if ev["kind"] == "submit" and ev.get("cand_path") in HAIKU_PATHS:
                    gated.add((res["id"], ev["id"]))
    everyday = {}
    for n in names:
        evs = {(res["id"], ev["id"]): ev for res in single[n] for ev in res["events"] if ev["kind"] == "submit"}
        hit = [evs[k] for k in gated if k in evs]
        everyday[n] = {"submits": len(hit), "wrong": sum(bool(e.get("wrong")) for e in hit),
                       "asks": sum(e.get("decision") == "ask" for e in hit)}
    report["everyday_gated"] = everyday
    (C.DATA / "divider_report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
