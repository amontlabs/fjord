"""N1: one purpose sentence per project from 12 of its thread titles on dev days (E3's method), -> data/purposes.json."""
import collections, json, pathlib, random, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from calls import anthropic
from moments import DATA, History, day_of

H = json.load(open(DATA / "history.json"))
hist = History(H, {})
M = [json.loads(l) for l in open(DATA / "moments.jsonl")]
dev_days = {m["day"] for m in M if m["split"] == "dev"}
by = collections.defaultdict(list)
for t in hist.listed:
    if t["msgs"] and day_of(t["msgs"][0]["at"]) in dev_days: by[hist.projects[t["project"]]].append(t["title"])
out = {}
for p in sorted(hist.projects.values()):
    titles = by.get(p, [])
    titles = random.Random(1).sample(titles, min(12, len(titles)))
    if not titles: continue
    r = anthropic("Write one plain sentence (at most 25 words) saying what this software project is about, from its thread titles. Reply with the sentence only.",
                  f"Project: {p}\nThread titles:\n" + "\n".join(f"- {t}" for t in titles), thinking={"type": "between_tools"}, max_tokens=200, tag="purpose")
    out[p] = " ".join((r["answer"] or "").split())
json.dump(out, open(DATA / "purposes.json", "w"), indent=1)
print(len(out), "purposes")
