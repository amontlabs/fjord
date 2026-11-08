"""N4: top-1 answers whatever the bars (bar-free, steadier than the 1% CV fit), weighted, clean gold, with day-bootstrap CIs."""
import json, sys
import n3common as C, n3score as SC, n4score as N4

S = C.load_sample(); M = C.moments(); G = json.load(open(C.DATA / "n3_gold.json"))


def top(v, a, b):
    if v.startswith("n3:"): return SC.tup(SC.guess(a, b))
    rs = N4.resolver(v, b)
    if a.get("action") == "answer_here": return ("answer",)
    k = rs(a.get("session"))
    if k and a.get("action") in ("follow_up", "ask"): return ("thread", k)
    p = b.project_named(a.get("project") or "")
    return ("new", p) if p else ("ask",)


for v in sys.argv[1:]:
    R = N4.load_rows(v, "dev")
    rs = []
    for i, r in R.items():
        if i not in G: continue
        b = C.make_board(M[i]); d = top(v, r["answer"] or {}, b)
        rs.append((M[i]["day"], G[i]["places"], SC.outcome(M[i], G[i]["places"], d), S["weight"][i]))
    cells = []
    for name, kl in (("new", "new"), ("follow", "follow")):
        f = lambda o: o == "right"
        cells.append(f"{name} right {SC.pct(SC.rate(rs, kl, f), SC.boot(rs, kl, f))}")
    f = lambda o: o.startswith("pushed"); cells.append(f"new pushed {SC.pct(SC.rate(rs, 'new', f))}")
    f = lambda o: o.startswith("wrong_thread"); cells.append(f"follow wrong thread {SC.pct(SC.rate(rs, 'follow', f))}")
    f = lambda o: o.startswith("to_new"); cells.append(f"follow to new {SC.pct(SC.rate(rs, 'follow', f))}")
    print(f"| {v} (n={len(rs)}) | " + " | ".join(cells) + " |")
