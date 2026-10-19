"""Score the multi-place slice, and the words of the single-place slice, with intervals clustered by group.

Multi-place, per case (gold from label.py):
- places right: the candidate's places S satisfy required ⊆ S ⊆ allowed (exact when the labellers agreed).
- text right, per gold place it reached: no required unit missing, no unit meant only for other places. A unit is read
  as present in a part by aligning the part's words to the message's (difflib, in order): missing when under 75% of
  its words are found (all of a one-word unit), foreign when 50% or more of a unit of two words or more is found.
- added words: a part with any word not aligned to the message.
- all right: places right and every text right.
- loss (clicks): send when sure, preview when not. Sure: 25 per place it shouldn't have sent to, 4 per place it missed
  (you send that part yourself), 4 per reached place whose text is wrong (you fix it). Unsure: 1 to look, plus 4 per
  defect, since nothing went out. `loss_preview` previews every division of two places or more as well.
Single-place: the v2 replay's own scores (v2/run/score.py), and, for each right send, whether the words sent are the
message as typed (pills and asides aside).

python3 -m v2.multi.score multi dev haiku pipeline [sonnet]
python3 -m v2.multi.score single haiku pipeline [sonnet]"""
import argparse
import difflib
import json
import random
import statistics

from . import common as C

RUNS = C.DATA / "runs"


def aligned(message, text):
    """Message word indices matched by the text's words, in order; and the text's words left unmatched."""
    m, t = C.norm_words(message), C.norm_words(text)
    sm = difflib.SequenceMatcher(a=m, b=t, autojunk=False)
    hit, used = set(), set()
    for block in sm.get_matching_blocks():
        for k in range(block.size):
            hit.add(block.a + k)
            used.add(block.b + k)
    return hit, len(t) - len(used), m


def unit_spans(message, units):
    """Word index ranges of each unit within the message's words."""
    spans, start = [], 0
    for u in units:
        n = len(C.norm_words(u))
        spans.append(range(start, start + n))
        start += n
    return spans


def case_score(case, out):
    g = case["gold"]
    parts = {p["place"]: p["text"] for p in out.get("parts", [])}
    S = set(parts)
    required, allowed = set(g["required"]), set(g["allowed"])
    places_right = required <= S <= allowed
    spans = unit_spans(case["message"], case["units"])
    text_rows = []
    added_parts = 0
    for place, text in parts.items():
        hit, added, words = aligned(case["message"], text)
        added_parts += added > 0
        if place not in allowed:
            continue
        missing = foreign = 0
        for span, u in zip(spans, g["units"]):
            if not span:
                continue
            cov = sum(i in hit for i in span) / len(span)
            if place in u["for"] and cov < (1.0 if len(span) == 1 else 0.75):
                missing += 1
            if place not in u["for"] and place not in u["may"] and len(span) >= 2 and cov >= 0.5:
                foreign += 1
        text_rows.append({"place": place, "required": place in required, "missing": missing, "foreign": foreign,
                          "added": added, "right": missing == 0 and foreign == 0})
    texts_right = all(r["right"] for r in text_rows)
    wrong_places = len(S - allowed)
    missed = len(required - S)
    text_defects = sum(not r["right"] for r in text_rows)
    sure = bool(out.get("sure")) and bool(parts)
    if sure:
        loss = 25 * wrong_places + 4 * missed + 4 * text_defects
    else:
        loss = 1 + 4 * (wrong_places + missed + text_defects)
    previewed = not sure or len(S) >= 2
    loss_preview = (1 + 4 * (wrong_places + missed + text_defects)) if previewed else loss
    return {"id": case["id"], "group": case["group"], "multi": g["multi"], "agreed": g["agreed"],
            "kind": case["provenance"].get("kind") or ("real-" + case["provenance"].get("flag", "")),
            "source": case["provenance"]["source"], "writer": case["provenance"]["writer"],
            "places_right": places_right, "texts_right": texts_right, "all_right": places_right and texts_right,
            "sure": sure, "wrong_send": sure and wrong_places > 0, "missed": missed,
            "text_rows": text_rows, "parts": len(parts), "added_parts": added_parts,
            "loss": loss, "loss_preview": loss_preview,
            "latency": out.get("latency") or 0.0, "cost": out.get("cost") or 0.0}


METRICS = ("all_right", "places_right", "texts_right", "wrong_send", "sure", "loss", "loss_preview", "latency", "cost")


def mean(rows, key):
    vals = [float(r[key]) for r in rows]
    return sum(vals) / len(vals) if vals else None


def part_rates(rows):
    tr = [t for r in rows for t in r["text_rows"] if t["required"]]
    parts = sum(r["parts"] for r in rows)
    return {"text_right_per_place": sum(t["right"] for t in tr) / len(tr) if tr else None,
            "parts_with_added_words": sum(r["added_parts"] for r in rows) / parts if parts else None,
            "text_missing_per_place": sum(t["missing"] > 0 for t in tr) / len(tr) if tr else None,
            "text_foreign_per_place": sum(t["foreign"] > 0 for t in tr) / len(tr) if tr else None}


def boot(rows_by_cand, names, reps=2000, seed=7):
    """Cluster bootstrap over groups: per-candidate 95% intervals and paired differences (second − first...)."""
    groups = sorted({r["group"] for r in rows_by_cand[names[0]]})
    by_group = {n: {} for n in names}
    for n in names:
        for r in rows_by_cand[n]:
            by_group[n].setdefault(r["group"], []).append(r)
    rng = random.Random(seed)
    draws = {n: {m: [] for m in METRICS} for n in names}
    diffs = {(a, b): {m: [] for m in METRICS} for a in names for b in names if a < b}
    for _ in range(reps):
        pick = [rng.choice(groups) for _ in groups]
        vals = {}
        for n in names:
            rows = [r for g in pick for r in by_group[n].get(g, [])]
            vals[n] = {m: mean(rows, m) for m in METRICS}
            for m in METRICS:
                draws[n][m].append(vals[n][m])
        for (a, b), d in diffs.items():
            for m in METRICS:
                d[m].append(vals[b][m] - vals[a][m])

    def ci(xs):
        xs = sorted(x for x in xs if x is not None)
        return [xs[int(0.025 * len(xs))], xs[int(0.975 * len(xs)) - 1]] if xs else None
    return ({n: {m: ci(v) for m, v in d.items()} for n, d in draws.items()},
            {f"{b} - {a}": {m: {"ci95": ci(v), "p_gt0": sum(x > 0 for x in v if x is not None) / len(v)}
                            for m, v in d.items()} for (a, b), d in diffs.items()})


def summarize(rows_by_cand, names, reps=2000):
    out = {}
    for n in names:
        rows = rows_by_cand[n]
        out[n] = {"n": len(rows), "groups": len({r["group"] for r in rows}),
                  **{m: mean(rows, m) for m in METRICS}, **part_rates(rows),
                  "latency_p50": statistics.median([r["latency"] for r in rows]) if rows else None,
                  "latency_p95": sorted(r["latency"] for r in rows)[int(0.95 * (len(rows) - 1))] if rows else None}
    if reps and all(rows_by_cand[n] for n in names):
        cis, diffs = boot(rows_by_cand, names, reps)
        for n in names:
            out[n]["ci95"] = cis[n]
        out["paired"] = diffs
    return out


def slices(cases, outs, names):
    """Overall, multi vs single-looking, agreed-only, real vs written, by kind and by writer."""
    rows = {n: [case_score(c, outs[n][c["id"]]) for c in cases if c["id"] in outs[n]] for n in names}
    ids = set.intersection(*[{r["id"] for r in rows[n]} for n in names])
    rows = {n: [r for r in rows[n] if r["id"] in ids] for n in names}

    def sub(pred, reps=2000):
        return summarize({n: [r for r in rows[n] if pred(r)] for n in names}, names, reps)
    report = {"all": sub(lambda r: True), "multi": sub(lambda r: r["multi"]),
              "looks_multi_single": sub(lambda r: not r["multi"]), "agreed": sub(lambda r: r["agreed"]),
              "real": sub(lambda r: r["source"] == "real", 1000), "written": sub(lambda r: r["source"] == "written", 0),
              "by_kind": {k: sub(lambda r, k=k: r["kind"] == k, 0) for k in sorted({r["kind"] for r in rows[names[0]]})},
              "by_writer": {w: sub(lambda r, w=w: r["writer"] == w, 0) for w in sorted({r["writer"] for r in rows[names[0]]})}}
    return report, rows


# ---------------------------------------------------------------- single-place slice

def single_words(results):
    """On right sends: is what was sent the message as typed (minus pills and asides)? Haiku's parts carry text;
    the pipeline sends the edit by rule."""
    from v2.run import rules
    right = reworded = trimmed = added = 0
    for res in results:
        for ev in res["events"]:
            if ev.get("kind") != "submit" or ev.get("decision") == "ask" or ev.get("wrong"):
                continue
            parts = ev.get("parts")
            if not parts or len(parts) != 1:
                continue
            right += 1
            whole = rules.edit(ev["message"], (ev.get("context") or {}).get("pills", []))
            hit, extra, words = aligned(whole, parts[0]["text"])
            cov = len(hit) / len(words) if words else 1.0
            trimmed += cov < 0.95
            added += extra > 0
            reworded += cov < 0.95 or extra > 0
    return {"right_sends_checked": right, "words_changed": reworded / right if right else None,
            "dropped_over_5pct": trimmed / right if right else None, "added_words": added / right if right else None}


def single_costs(results):
    lat, cost, n = [], 0.0, 0
    for res in results:
        for ev in res["events"]:
            if ev.get("kind") == "submit":
                n += 1
                lat.append(ev.get("latency") or 0.0)
                cost += ev.get("cost") or 0.0
    lat.sort()
    return {"submits": n, "latency_p50": lat[len(lat) // 2] if lat else None,
            "latency_p95": lat[int(0.95 * (len(lat) - 1))] if lat else None,
            "cost_per_message": cost / n if n else None}


def single(names, reps=2000):
    from v2.run import compare, score
    res = {n: score.load_results(RUNS / f"single_{n}.jsonl") for n in names}
    ids = set.intersection(*[{r["id"] for r in res[n]} for n in names])
    res = {n: [r for r in res[n] if r["id"] in ids] for n in names}
    out = {}
    for n in names:
        ev = score.evaluate(res[n], bootstrap=reps)
        out[n] = {"natural": ev["natural"], "real_only": ev["real_only"], "counts": ev["counts"],
                  "by_family": ev["by_family"], "words": single_words(res[n]), "costs": single_costs(res[n])}
    out["paired"] = {}
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            out["paired"][f"{b} - {a}"] = compare.compare(res[a], res[b], bootstrap=reps)
            real_a = [r for r in res[a] if r.get("provenance", {}).get("source") == "real-moment"]
            real_b = [r for r in res[b] if r.get("provenance", {}).get("source") == "real-moment"]
            out["paired"][f"{b} - {a} (real moments)"] = compare.compare(real_a, real_b, bootstrap=reps)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("slice", choices=["multi", "single"])
    ap.add_argument("rest", nargs="+")
    ap.add_argument("--bootstrap", type=int, default=2000)
    a = ap.parse_args()
    if a.slice == "multi":
        split, names = a.rest[0], a.rest[1:]
        if split != "dev":
            raise SystemExit("test is scored only by v2.multi.seal")
        cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == split]
        outs = {n: {o["id"]: o for o in C.jsonl(RUNS / f"multi_{split}_{n}.jsonl")} for n in names}
        report, _ = slices(cases, outs, names)
    else:
        report = single(a.rest, a.bootstrap)
    print(json.dumps(report, indent=1, default=str))


if __name__ == "__main__":
    main()
