"""N3 finalists on the sealed test subsample: bars fitted on all of dev, applied once to test (unweighted within class)."""
import json, sys
import n3common as C
import n3bars as B

def test_moments():
    out = {}
    for l in open(C.DATA / "n3_moments_test.jsonl"):
        m = json.loads(l); out[m["id"]] = m
    return out

S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))
MT = test_moments(); GT = json.load(open(C.DATA / "n3_gold_test_sub.json"))
ST = {"weight": {i: 1.0 for i in GT}}
for v in sys.argv[1:]:
    dev = B.prepare(v, M, G, S)
    tst = B.prepare(v, MT, GT, ST, split="test")
    for t in (0.01, 0.02):
        bars = B.fit(dev, t)
        s = B.stats(tst, bars); d = B.stats(dev, bars)
        print(v, f"target {t:.0%} bars {bars} n_test {len(tst)}")
        print("  test:", {k: f"{x:.1%}" for k, x in s.items()})
        print("  dev :", {k: f"{x:.1%}" for k, x in d.items()})
