"""RouteFusion's parity fixture (Tests/FjordTests/Fixtures/router-fusion-parity.json) decided again with the weights and
rules Fjord carries now, on the inputs it holds (Jev's answers and the board facts of the 360 written cases, scrubbed).
The written sets that made it (parity.py) are no longer in the repo; their inputs are all a decision needs.

python3 -m explore.v2_new.parity            check: how many cases the port decides as the fixture says
python3 -m explore.v2_new.parity --write    rewrite the fixture's `sure` and `top` with the port's decision

The port is explore/v2_new/traffic.py's decide (RouteFusion.decide, RouterTools.verdict) on v2/build/traffic.py's
features (RouteFusion.features); with Swift's tables as they are, it decides every case as the fixture did.
"""
import argparse
import json
import pathlib
import sys

sys.dont_write_bytecode = True

from explore.v2_new import traffic as T
from v2.build import traffic as X

FIXTURE = pathlib.Path(__file__).resolve().parents[4] / "Tests" / "FjordTests" / "Fixtures" / "router-fusion-parity.json"


def moment(c):
    sessions = list(c["idle"])
    inputs = {"options": [{"target": "session:" + s, "session": s} for s in sessions],
              "route": c["route"], "reply": c["reply"], "next": c["next"], "gates": c["gates"], "lexical": c["lexical"],
              "latest": c["latest"], "running": c["running"], "idle": c["idle"], "lastTold": c["lastTold"]}
    facts = {k: c[k] for k in ("latest", "running", "idle", "lastTold")}
    # As the Swift test has it: every card check counts, its session offered or not.
    facts.update(targetOf={s: "session:" + s for s in list(sessions) + list(c["reply"])}, message=c["message"],
                 leaves=c["leaves"])
    return {"frozen": {"options": inputs["options"], "fs": X.features(inputs, c["message"]), "facts": facts,
                       "signals": {k: inputs[k] for k in ("route", "reply", "next", "gates", "lexical")}}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--gate", type=float, default=T.OLD_HOURS, help="hours after which a session's recency features are dropped (Swift's oldHours)")
    a = ap.parse_args()
    cases = json.loads(FIXTURE.read_text())
    differ = 0
    for c in cases:
        kind, target, _ = T.decide(moment(c), gate=a.gate)
        sure, top = kind == "send", target if kind == "send" else None
        if (sure, top) != (c["sure"], c["top"]):
            differ += 1
        c["sure"], c["top"] = sure, top
    print(f"{len(cases) - differ}/{len(cases)} decided as the fixture says")
    if a.write:
        FIXTURE.write_text(json.dumps(cases, ensure_ascii=False, indent=0))


if __name__ == "__main__":
    main()
