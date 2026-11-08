"""N4: where the clean-gold follow-up thread sits in the built context (D live, C archive, E top-6 hits, shipped candidates).
Weighted to the dev population. No model calls; prints aggregates only."""
import json, collections
import n3common as C, n3score as SC, n4ctx as N

S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))
acc = collections.Counter(); W = 0.0
for i in sorted(S["ids"]):
    if i not in G or SC.klass(G[i]["places"]) != "follow": continue
    m = M[i]; w = S["weight"][i]; W += w
    gk = {p[1] for p in G[i]["places"] if p[0] == "thread"}
    sel, b = N.live_threads(m); live = {t.key for t in sel}
    arch = N.archive_keys(m)
    _, idx = N.retrieval_block(m, live, arch, [t.key for t in b.threads])
    _, hits = idx.search(N.B.redact(m["message"]))
    e = {h[1] for h in hits}
    shown = {t.key for t in b.candidates()}
    full = {t.key for t in sel if t.running} | {t.key for t in sorted(sel, key=lambda t: t.minutesIdle)[:N.FULL_N]}
    for name, s in (("shipped candidates", shown), ("D live", live), ("D full digest", full), ("C archive", set(arch)), ("E hits", e),
                    ("D or C", live | set(arch)), ("D, C or E", live | set(arch) | e)):
        if gk & s: acc[name] += w
for k, v in acc.items(): print(f"{k}: {v / W:.1%}")
