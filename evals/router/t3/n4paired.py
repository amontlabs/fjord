"""N4: paired day-bootstrap of (variant − baseline) under each one's CV bars, on (new right + follow right) / 2 and each rate."""
import json, random, sys, collections
import n3common as C, n3bars as NB, n4score as N4

S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))


def per_id(v, t):
    rows = N4.prepare(v, M, G, S)
    if N4.ONLY: rows = [r for r in rows if r[5] in N4.ONLY]
    dec, _ = NB.cv([r[:4] for r in rows], t)
    return {r[5]: (r[0], r[1], r[2], dec[n]) for n, r in enumerate(rows)}


def rates(xs):
    acc = collections.defaultdict(lambda: [0.0, 0.0])
    for day, k, w, o in xs:
        acc[k][0] += w; acc[k][1] += w * (o == "right")
    nr = acc["new"][1] / acc["new"][0] if acc["new"][0] else 0; fr = acc["follow"][1] / acc["follow"][0] if acc["follow"][0] else 0
    return nr, fr, (nr + fr) / 2


a, base = sys.argv[1], sys.argv[2]
if len(sys.argv) > 3: N4.ONLY = set(N4.load_rows(sys.argv[3], "dev"))
for t in (0.01, 0.02):
    A, Bv = per_id(a, t), per_id(base, t)
    ids = sorted(set(A) & set(Bv)); days = sorted({A[i][0] for i in ids})
    byd = collections.defaultdict(list)
    for i in ids: byd[A[i][0]].append(i)
    def diff(sel):
        ra = rates([A[i] for i in sel]); rb = rates([Bv[i] for i in sel]); return [x - y for x, y in zip(ra, rb)]
    d0 = diff(ids); rng = random.Random(5); bs = []
    for _ in range(1000):
        sel = [i for d in (rng.choice(days) for _ in days) for i in byd[d]]; bs.append(diff(sel))
    ci = [sorted(b[j] for b in bs) for j in range(3)]
    print(f"{a} − {base} at {t:.0%} (n={len(ids)}): " + ", ".join(f"{nm} {100*d0[j]:+.1f} ({100*ci[j][25]:+.0f}…{100*ci[j][974]:+.0f})" for j, nm in enumerate(("new right", "follow right", "mean"))))
