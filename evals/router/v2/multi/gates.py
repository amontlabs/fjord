"""Exploratory (dev only): how often Jev's compound gates notice a message meant for several places, and what else could
(REPORT.md, "the gates' recall"). Never reads the sealed split.

python3 -m v2.multi.gates probe            # per multi dev case: Jev's shipped answers (cached), the ship form's and
                                           # Haiku-decides' (noask2) results → v2/data/multi/gates_probe.jsonl
python3 -m v2.multi.gates probe-single     # the same signals on every everyday submit of the v2 dev episodes
python3 -m v2.multi.gates reword [name…]   # each reworded gate (REWORDS), in a Jev call of its own, on both
python3 -m v2.multi.gates everyday [name…] # …and on the real moments and Router-style messages outside the dev episodes
python3 -m v2.multi.gates everyday-ship    # the shipped call's gates and pick on those
python3 -m v2.multi.run multi ship3+ap70 --split dev; python3 -m v2.multi.run single ship3+ap70
python3 -m v2.multi.gates report ship3+ap70 …   # against the ship form → v2/data/multi/gates_report.json
Data files hold message text and stay under v2/data (gitignored); nothing here prints it."""
import json
import sys

from . import candidates, common as C, score

RUNS = score.RUNS


def reading(cand, state, message, context):
    """The shipped Jev request's answers on this message (a cache hit), as run.reading reads them."""
    from v2.run import adapter
    router = cand.pipeline.router
    formats, _, legacy_run = router._load()[:3]
    event = {"id": "mp", "kind": "submit", "message": message,
             "context": {k: v for k, v in context.items() if k != "tags"}}
    built, questions, keymap = formats.build(router.format_name, adapter.to_case(state, event),
                                             shuffle_seed=router.option_seed)
    answer = router._ask(built, questions)[0]
    return legacy_run.reading({"id": "mp", "keymap": keymap, "answers": answer["answers"]})


def titles(cand, state, message, context):
    """The sessions' names as Jev's route options give them."""
    from v2.run import adapter
    router = cand.pipeline.router
    formats = router._load()[0]
    event = {"id": "mp", "kind": "submit", "message": message,
             "context": {k: v for k, v in context.items() if k != "tags"}}
    _, questions, _ = formats.build(router.format_name, adapter.to_case(state, event), shuffle_seed=router.option_seed)
    return [k for k, v in questions["route"]["criteria"].items() if isinstance(v, dict)
            and v.get("kind") == "Claude Code session"]


def signals(r):
    g = r.get("gates", {})
    d = r.get("dests", {})
    ranked = sorted(((k, v) for k, v in d.items() if k != "unclear"), key=lambda x: -x[1])
    sess = sorted((v for k, v in d.items() if str(k).startswith("session") or str(k).startswith("new")), reverse=True)
    return {"g1": g.get("gate_compound", 0), "g2": g.get("gate_compound2", 0), "you": g.get("gate_you", 0),
            "setting": g.get("gate_setting", 0), "question": g.get("gate_question", 0),
            "p_compound": d.get("compound", 0), "p_unclear": d.get("unclear", 0),
            "top": ranked[0][0] if ranked else None, "p_top": ranked[0][1] if ranked else 0,
            "p_second": ranked[1][1] if len(ranked) > 1 else 0,
            "sess2": sess[1] if len(sess) > 1 else 0, "p_fjord": d.get("change_fjord", 0) + d.get("question", 0)}


def probe():
    cand = candidates.Ship3()
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "dev"]
    outs = {n: {o["id"]: o for o in C.jsonl(RUNS / f"multi_dev_{n}.jsonl")} for n in ("ship3", "noask2", "pipeline")}
    rows = []
    for c in cases:
        structural = bool(c["context"].get("tags")) or bool(c["context"].get("replyTo"))
        r = reading(cand, c["state"], c["message"], c["context"])
        row = {"id": c["id"], "group": c["group"], "multi": c["gold"]["multi"], "message": c["message"],
               "places": titles(cand, c["state"], c["message"], c["context"]), "source": c["provenance"]["source"],
               "kind": c["provenance"].get("kind"), "structural": structural, **signals(r)}
        for n, o in outs.items():
            s = score.case_score(c, o[c["id"]])
            row[n] = {"all_right": s["all_right"], "wrong_send": s["wrong_send"], "path": o[c["id"]].get("path")}
        rows.append(row)
    C.write_jsonl(C.DATA / "gates_probe.jsonl", rows)
    print(len(rows), "cases")


# Reworded gates, each asked alone in its own Jev call on the message (the shipped call's state), so the shipped call's
# answers don't move. `places`: the sessions' names, as the route's options give them.
REWORDS = {
    "addr": ("Does `message` give instructions to two or more different sessions, each picked out by what it works on "
             "(\"the CI one: …\", \"in the X session …\", \"tell the Y one to …\", \"for the Z one: …\")? Several "
             "points or steps for one session is no.", False),
    "split": ("Should `message` be split, with different parts sent to different places (two or more sessions, or Fjord "
              "itself and a session), so that each place gets only what is meant for it? A message with several points "
              "for one session is no.", False),
    "agents": ("Does `message` speak to two or more different agents in turn, or to Fjord itself and to an agent? "
               "Telling one agent about another session (\"the CI one is done, rebase on it\") is no.", False),
    "addr-places": ("Does `message` give instructions to two or more of `places`, each picked out by what it works on "
                    "(\"the CI one: …\", \"in the X session …\", \"tell the Y one to …\")? Several points or steps "
                    "for one session is no.", True),
}


def ask_reworded(router, name, message, places):
    question, with_places = REWORDS[name]
    instructions = {"question": question}
    if with_places:
        instructions["places"] = "; ".join(places)
    answer = router._ask({"message": message}, {"gate": {"type": "noul", "instructions": instructions}})[0]
    return float(answer["answers"]["gate"]["noul"])


def reword(names):
    """Each reworded gate's p on the multi dev messages and every everyday submit."""
    from concurrent.futures import ThreadPoolExecutor
    router = candidates.Ship3().pipeline.router
    for path in ("gates_probe.jsonl", "gates_probe_single.jsonl"):
        rows = C.jsonl(C.DATA / path)
        for name in names:
            with ThreadPoolExecutor(4) as pool:
                ps = list(pool.map(lambda r: ask_reworded(router, name, r["message"], r["places"]), rows))
            for r, p in zip(rows, ps):
                r.setdefault("reworded", {})[name] = p
            print(path, name, "done", flush=True)
        C.write_jsonl(C.DATA / path, rows)


def everyday_extra(names):
    """The reworded gates on everyday messages outside the dev episodes: the 611 real moments of evals/router/real (those
    whose words aren't a dev submit) and the 332 Router-style messages written on those real boards. Message-only gates:
    only the message and the board's session names go in."""
    import ast
    from concurrent.futures import ThreadPoolExecutor
    router = candidates.Ship3().pipeline.router
    dev = {r["message"] for r in C.jsonl(C.DATA / "gates_probe_single.jsonl")}
    rows = []
    for src, files in (("real", ["real.jsonl"]), ("routerstyle", ["routerstyle_0.jsonl", "routerstyle_1.jsonl"])):
        for f in files:
            for r in C.jsonl(C.ROUTER / "real" / "data" / f):
                board = r["board"] if isinstance(r["board"], dict) else ast.literal_eval(r["board"])
                if r["message"] in dev:
                    continue
                rows.append({"id": r["id"], "source": src, "message": r["message"],
                             "places": [s["title"] for s in board["sessions"]]})
    for name in names:
        with ThreadPoolExecutor(4) as pool:
            ps = list(pool.map(lambda r: ask_reworded(router, name, r["message"], r["places"]), rows))
        for r, p in zip(rows, ps):
            r.setdefault("reworded", {})[name] = p
    C.write_jsonl(C.DATA / "gates_probe_everyday.jsonl", rows)
    print(len(rows), "messages")


def fused_top(router, reading, case):
    """The shipped policy's pick (sent) or the fused ranking's first (asked), as RouterSystem.decide gives `top`."""
    _, _, _, policy, lexical, fusion, final3 = router._load()
    if not getattr(policy, "needs_case", False):
        fusion._CASES = {case["id"]: case}
    kind, what = policy(reading, case) if getattr(policy, "needs_case", False) else policy(reading)
    if kind != "ask":
        return what
    fs = lexical.features(reading, case)
    if not fs:
        return None
    weights, confidence = final3.fitted()
    return fusion.confidence(reading, case, fs, weights, confidence)[0]


def everyday_ship():
    """The shipped request's gates and route on the same everyday messages (the combo-o format, as the dev replay)."""
    router = candidates.Ship3().pipeline.router
    formats, _, legacy_run = router._load()[:3]
    cases = {}
    for f in ("real.jsonl", "routerstyle_0.jsonl", "routerstyle_1.jsonl"):
        for r in C.jsonl(C.ROUTER / "real" / "data" / f):
            cases[r["id"]] = r
    rows = C.jsonl(C.DATA / "gates_probe_everyday.jsonl")

    def one(row):
        case = cases[row["id"]]
        built, questions, keymap = formats.build(router.format_name, case, shuffle_seed=router.option_seed)
        answer = router._ask(built, questions)[0]
        r = legacy_run.reading({"id": row["id"], "keymap": keymap, "answers": answer["answers"]})
        return {**signals(r), "fused_top": fused_top(router, r, case)}
    sigs = [one(row) for row in rows]  # the shipped policy keeps module state (fusion._CASES): one at a time
    for row, sig in zip(rows, sigs):
        row["gold"] = cases[row["id"]]["gold"]
        row.update(sig)
    C.write_jsonl(C.DATA / "gates_probe_everyday.jsonl", rows)
    print(len(rows), "messages;", router.new_calls, "new Jev calls")


IN_CALL = "combo-o+addressed"


def addressed_question(names):
    question, _ = REWORDS["addr-places"]
    return {"type": "noul", "instructions": {"question": question, "places": "; ".join(names)}}


def _install_in_call(router):
    """The shipped format with the addr-places gate (`gate_addressed`) asked in the same call."""
    formats = router._load()[0]
    if IN_CALL in formats.FORMATS:
        return
    base = formats.FORMATS["combo-o"]

    def build(case, rng=None):
        state, q, keymap = base(case, rng)
        names = [k for k, v in q["route"]["criteria"].items() if isinstance(v, dict)
                 and v.get("kind") == "Claude Code session"]
        return state, {**q, "gate_addressed": addressed_question(names)}, keymap
    formats.FORMATS[IN_CALL] = build


class Ship3Plus(candidates.Ship3):
    """The ship form with more reasons to ask the divider, `spec` joined by "-":
    - `pcNN`: Jev's route gives `compound` at least NN/100 (the shipped request; no new call);
    - `apNN` / `aNN` / `splitNN`: the reworded gate addr-places / addr / split at least NN/100 (one more Jev call on the
      message alone);
    - `gtNN`: the gates' second bar at NN/100 instead of 0.5 (gate_compound ≥ 0.75 as shipped);
    - `inNN`: addr-places asked inside the shipped call (`gate_addressed`) at least NN/100: every answer of that call
      may move, so the whole decision is the new call's."""
    REWORD = {"ap": "addr-places", "a": "addr", "split": "split", "agents": "agents"}

    def __init__(self, spec):
        super().__init__()
        self.rules = []
        for item in spec.split("-"):
            key = item.rstrip("0123456789")
            self.rules.append((key, int(item[len(key):]) / 100))
        if any(key == "in" for key, _ in self.rules):
            router = self.pipeline.router
            _install_in_call(router)
            router.format_name = IN_CALL

    def fires(self, state, message, context, g1, g2):
        for key, bar in self.rules:
            if key == "gt" and g1 >= 0.75 and g2 >= bar:
                return True
            if key == "in" and reading(self, state, message, context)["gates"].get("gate_addressed", 0) >= bar:
                return True
            if key == "pc" and reading(self, state, message, context)["dests"].get("compound", 0) >= bar:
                return True
            if key in self.REWORD:
                router = self.pipeline.router
                if ask_reworded(router, self.REWORD[key], message, titles(self, state, message, context)) >= bar:
                    return True
        return False


def report(names):
    """Each Ship3Plus run against the ship form: everyday extra wrong sends per 100 submits (v2 dev episodes, all and
    real moments; paired group bootstrap), look-multi wrong sends per 100, several places fully right (paired)."""
    from v2.run import compare
    from v2.run.score import load_results
    out = {"single": {}, "multi": {}}
    base = load_results(RUNS / "single_ship3.jsonl")
    real = lambda rs: [r for r in rs if r.get("provenance", {}).get("source") == "real-moment"]  # noqa: E731
    pct = lambda x: None if x is None else round(100 * x, 1)  # noqa: E731
    for v in names:
        c = load_results(RUNS / f"single_{v}.jsonl")
        for name, (x, y) in {"all": (base, c), "real": (real(base), real(c))}.items():
            nat = compare.compare(x, y, bootstrap=2000)["natural"]
            out["single"].setdefault(v, {})[name] = {
                "extra_wrong_per_100": pct(nat["delta"]["wrong_all"]),
                "ci95": [pct(nat["ci95"]["wrong_all"]["low"]), pct(nat["ci95"]["wrong_all"]["high"])],
                "wrong_per_100_ship": pct(nat["baseline"]["wrong_all"]), "wrong_per_100": pct(nat["candidate"]["wrong_all"]),
                "loss_delta": round(nat["delta"]["loss_per_submit"], 3),
                "loss_ci95": [round(nat["ci95"]["loss_per_submit"]["low"], 3),
                              round(nat["ci95"]["loss_per_submit"]["high"], 3)]}
    all_names = ("ship3",) + tuple(names)
    cases = [c for c in C.jsonl(C.DATA / "cases.jsonl") if c["split"] == "dev"]
    outs = {n: {o["id"]: o for o in C.jsonl(RUNS / f"multi_dev_{n}.jsonl")} for n in all_names}
    rows = {n: [score.case_score(c, outs[n][c["id"]]) for c in cases] for n in all_names}
    slices = {"look-multi, written": lambda r: not r["multi"] and r["source"] == "written",
              "look-multi, real": lambda r: not r["multi"] and r["source"] == "real",
              "several places": lambda r: r["multi"]}
    for label, pred in slices.items():
        sub = {n: [r for r in rows[n] if pred(r)] for n in all_names}
        rep = score.summarize(sub, all_names, 2000)
        metric = "all_right" if label == "several places" else "wrong_send"
        table = {"n": rep["ship3"]["n"], "groups": rep["ship3"]["groups"]}
        for n in all_names:
            table[n] = {"value": pct(rep[n][metric]), "ci95": [pct(x) for x in rep[n]["ci95"][metric]]}
            if n != "ship3":
                if f"ship3 - {n}" in rep["paired"]:
                    d = rep["paired"][f"ship3 - {n}"][metric]["ci95"]
                    table[n]["vs_ship"] = [pct(-d[1]), pct(-d[0])]
                else:
                    d = rep["paired"][f"{n} - ship3"][metric]["ci95"]
                    table[n]["vs_ship"] = [pct(d[0]), pct(d[1])]
        out["multi"][label] = {"metric": metric, **table}
    (C.DATA / "gates_report.json").write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))


class _Recording(candidates.Ship3):
    """The ship form, unchanged, noting Jev's signals on every message it reads."""
    def __init__(self, sink):
        super().__init__()
        self.sink = sink

    def route(self, state, message, context):
        out = super().route(state, message, context)
        if not out["path"].startswith("ship3-tags") and out["path"] != "ship3-chip":
            r = reading(self, state, message, context)
            self.sink.append({"message_hash": C.hashlib.sha256(message.encode()).hexdigest()[:16],
                              "message": message, "places": titles(self, state, message, context),
                              "path": out["path"], "parts": len(out["parts"]), **signals(r)})
        return out


def probe_single():
    """Every everyday submit's signals, replaying the v2 dev episodes with the ship form (cached: no new calls)."""
    from v2.run import episodes
    from . import run
    episodes._SKIPPED_CARDS = run._PerThread()
    eps = episodes.load_episodes(C.ROUTER / "v2" / "data" / "episodes" / "dev" / "episodes.jsonl")
    out = []
    for ep in eps:
        sink = []
        cand = _Recording(sink)
        res = episodes.play_episode(ep, run.AsRouter("ship3", cand))
        for row in sink:
            out.append({"episode": ep["id"], "group": ep.get("group"),
                        "real": ep.get("provenance", {}).get("source") == "real-moment", **row})
    C.write_jsonl(C.DATA / "gates_probe_single.jsonl", out)
    print(len(out), "submits read by Jev;", cand.pipeline.router.new_calls, "new Jev calls in the last episode")


if __name__ == "__main__":
    if sys.argv[1] == "report":
        report(sys.argv[2:])
    elif sys.argv[1] == "everyday-ship":
        everyday_ship()
    elif sys.argv[1] == "everyday":
        everyday_extra(sys.argv[2:] or list(REWORDS))
    elif sys.argv[1] == "reword":
        reword(sys.argv[2:] or list(REWORDS))
    else:
        {"probe": probe, "probe-single": probe_single}[sys.argv[1]]()
