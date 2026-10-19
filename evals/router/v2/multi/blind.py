"""A blind sample for you to check by hand: ~40 dev cases (never test), each with three divisions in a random order:
the labellers' gold, Haiku's (A) and the pipeline's (B). You tick the ones you'd accept and note what you'd change; the
key stays in a separate file until you're done.

python3 -m v2.multi.blind make [--n 40]   →  v2/data/multi/blind/blind.md, key.json
python3 -m v2.multi.blind read            →  agreement of your ticks with the gold, and how each candidate fared"""
import argparse
import json
import random
import re

from . import common as C
from .candidates import board_prompt

OUT = C.DATA / "blind"


def gold_division(case):
    parts = {}
    for text, u in zip(case["units"], case["gold"]["units"]):
        for p in u["for"]:
            parts.setdefault(p, []).append(text)
        for p in u["may"]:
            if p in case["gold"]["allowed"]:
                parts.setdefault(p, []).append("[" + text.strip() + "]")
    return {p: " ".join(t.strip() for t in ts) for p, ts in parts.items() if p in case["gold"]["allowed"]}


def division(out):
    d = {p["place"]: p["text"] for p in out.get("parts", [])}
    return d, bool(out.get("sure"))


def names(case):
    opts, _ = board_prompt(case["state"], case["message"], case["context"])
    out = {}
    for key, target, desc in opts:
        place = C.place_of(target)
        if place == "fjord":
            out[place] = "Fjord itself"
        elif target.startswith("new:"):
            out[place] = "a new session in " + target[4:]
        else:
            d = json.loads(desc)
            out[place] = f"“{d.get('title')}” ({d.get('project')})"
    return out


def make(n, seed):
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "dev"]
    outs = {k: {o["id"]: o for o in C.jsonl(C.DATA / "runs" / f"multi_dev_{k}.jsonl")} for k in ("haiku", "pipeline")}
    cases = [c for c in cases if all(c["id"] in outs[k] for k in outs)]
    rng = random.Random(seed)
    by_kind = {}
    for c in cases:
        by_kind.setdefault(c["provenance"].get("kind") or "real", []).append(c)
    for v in by_kind.values():
        rng.shuffle(v)
    picked = []
    while len(picked) < n and any(by_kind.values()):
        for k in sorted(by_kind):
            if by_kind[k] and len(picked) < n:
                picked.append(by_kind[k].pop())
    lines = ["# Router multi-place benchmark: blind check", "",
             "For each message, three divisions say what each place would receive. Tick every division you'd accept "
             "as sent (right places, each getting what it should, in your words). Words in [brackets] may go or not. "
             "\"(would ask first)\" means nothing is sent before you confirm. Add a note when none is right.", ""]
    key = {}
    for i, c in enumerate(picked, 1):
        nm = names(c)
        divs = [("gold", gold_division(c), True), ("haiku", *division(outs["haiku"][c["id"]])),
                ("pipeline", *division(outs["pipeline"][c["id"]]))]
        rng.shuffle(divs)
        key[str(i)] = {"id": c["id"], "order": [d[0] for d in divs]}
        lines += [f"## {i}", ""]
        ctx = []
        if c["context"].get("replyTo"):
            card = next((x for x in c["state"]["cards"] if x["id"] == c["context"]["replyTo"]), None)
            if card:
                ctx.append(f"reply chip on {nm.get('session:' + card['session'], '?')}: “{card.get('text', '')[:160]}”")
        for t in c["context"].get("tags") or []:
            ctx.append(f"{t['tag']} = {nm.get(t['place'], t['place'])}")
        if ctx:
            lines.append("Context: " + "; ".join(ctx))
        lines += ["", "> " + c["message"].replace("\n", "\n> "), ""]
        for j, (_, d, sure) in enumerate(divs, 1):
            lines.append(f"**Division {j}**" + ("" if sure else " (would ask first)"))
            if not d:
                lines.append("- nothing sent: asks you where it goes")
            for p, text in d.items():
                lines.append(f"- to {nm.get(p, p)}: {json.dumps(text, ensure_ascii=False)}")
            lines.append("")
        lines += ["- [ ] 1 is right", "- [ ] 2 is right", "- [ ] 3 is right", "", "Note: ", "", "---", ""]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "blind.md").write_text("\n".join(lines))
    (OUT / "key.json").write_text(json.dumps(key, indent=1))
    print(len(picked), "cases →", OUT / "blind.md")


def read():
    text = (OUT / "blind.md").read_text()
    key = json.loads((OUT / "key.json").read_text())
    tally = {"gold": [0, 0], "haiku": [0, 0], "pipeline": [0, 0]}
    for block in re.split(r"\n## ", text)[1:]:
        num = block.split("\n", 1)[0].strip()
        ticks = {int(m.group(2)): m.group(1).lower() == "x" for m in re.finditer(r"- \[( |x|X)\] (\d) is right", block)}
        if num not in key:
            continue
        for j, who in enumerate(key[num]["order"], 1):
            tally[who][0] += ticks.get(j, False)
            tally[who][1] += 1
    for who, (ok, n) in tally.items():
        print(f"{who}: you accepted {ok}/{n}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["make", "read"])
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--seed", type=int, default=5)
    a = ap.parse_args()
    make(a.n, a.seed) if a.action == "make" else read()


if __name__ == "__main__":
    main()
