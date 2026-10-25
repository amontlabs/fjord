"""The route question's focus with its last sentence reworded. It told Jev to "start a new session only when the message
asks for one or no existing session does that work"; now it asks him to tell a new task from more of a session's own
work. Measured as `combo-o` with this sentence (now combo-o itself: formats.ROUTE_INSTRUCTIONS_V2, RouterRoute.swift).

python3 -m explore.v2_new.focus traffic      your Router traffic's requests (sent with the old sentence) asked again with
                                             the new one (18 calls), decided with Swift's fusion as it is
"""
import copy
import json
import sys

sys.dont_write_bytecode = True

SHIPPED_LAST = "Start a new session only when the message asks for one or no existing session does that work."
NEWTASK_LAST = ("A message that starts a task none of the sessions has been doing goes to a new session in its project, "
                "even when that project has sessions; one that continues, corrects or answers a session's own work goes "
                "to that session.")


def reworded(questions):
    q = copy.deepcopy(questions)
    focus = q["route"]["instructions"]["focus"]
    if SHIPPED_LAST not in focus:
        raise ValueError("the route focus doesn't end as shipped")
    q["route"]["instructions"]["focus"] = focus.replace(SHIPPED_LAST, NEWTASK_LAST)
    return q


def newtask(built):
    state, q, keymap = built
    return state, reworded(q), keymap


def traffic(since="2026-10-15"):
    import jev
    from explore.v2_new import traffic as T
    from v2.build import traffic as X
    jev.ordered = True
    rows = [json.loads(l) for l in open(T.DATA)]
    rows = [r for r in rows if r["at"] >= since and r["frozen"] and r["gold"]["intended"] and r["frozen"].get("request")]
    out = []
    for r in rows:
        req = json.loads(r["frozen"]["request"])
        q = req["questions"]
        # Traces before the rename say "Lookout"; the sentence itself is the same.
        q = reworded(q)
        answer = jev.ask(req["state"], q)["answers"]
        names = {o["name"]: o["target"] for o in r["frozen"]["options"]}
        for k in ("unclear", "question", "compound", "change_fjord", "change_lookout"):
            names.setdefault(k, "change_fjord" if k == "change_lookout" else k)
        probs = (answer.get("route") or {}).get("probabilities") or {}
        route = {}
        for name, p in probs.items():
            t = names.get(name)
            if t:
                route[t] = route.get(t, 0) + p
        # The other questions keep the trace's answers: only the route's wording changed.
        old = r["frozen"]["signals"]
        inputs = {"options": r["frozen"]["options"], "route": route, "reply": old["reply"], "next": old["next"],
                  "gates": old["gates"], "lexical": old["lexical"], **{k: r["frozen"]["facts"].get(k)
                                                                      for k in ("latest", "running", "idle", "lastTold")}}
        fz = {**r["frozen"], "fs": X.features(inputs, r["message"]),
              "signals": {**old, "route": route}}
        out.append({**r, "frozen": fz})
    return out


def main():
    from explore.v2_new import traffic as T
    if sys.argv[1:] != ["traffic"]:
        print(__doc__)
        return
    rows = traffic()
    before = [json.loads(l) for l in open(T.DATA)]
    before = {r["id"]: r for r in before}
    print("| routing | gold | before: Jev top / decision | newtask: Jev top / decision |\n|---|---|---|---|")
    c = {"b": [0, 0, 0, 0], "a": [0, 0, 0, 0]}
    for r in rows:
        g = r["gold"]["intended"]
        cells = []
        for tag, rr in (("b", before[r["id"]]), ("a", r)):
            route = rr["frozen"]["signals"]["route"]
            jtop = max((t for t in route if t != "unclear"), key=route.get)
            kind, t, P = T.decide(rr, gate=T.OLD_HOURS)
            top = max(P, key=P.get)
            c[tag][0] += T.same(top, g)
            c[tag][1] += kind == "send" and T.same(t, g)
            c[tag][2] += kind == "send" and not T.same(t, g)
            c[tag][3] += g.startswith("new:") and bool(top) and top.startswith("new:")
            cells.append(f"{jtop[:18]} {route[jtop]:.2f} / {kind} {'ok' if T.same(top, g) else 'x'}")
        print(f"| {r['at'][:16]} | {g[:18]} | {cells[0]} | {cells[1]} |")
    for tag, name in (("b", "before"), ("a", "newtask")):
        print(f"{name}: pick right {c[tag][0]}/{len(rows)}, sent right {c[tag][1]}, sent wrong {c[tag][2]}, "
              f"gold new picked new {c[tag][3]}")


if __name__ == "__main__":
    main()
