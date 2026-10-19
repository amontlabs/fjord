"""What the divider is given, as the benchmark measured it, for Fjord's tests to check RouterDivider against.

python3 -m v2.multi.parity  (from evals/router)  →  Tests/FjordTests/Fixtures/router-divider-parity.json

Runs `candidates.model_route` (A, B's divider and Ship3's one call) on fixed synthetic boards with `common.options` and
`common.claude` replaced: no model is called and no real board or message is read. The fixture holds, per case, the
request (message, places, cards, composer context), and what the benchmark built from it: the system instructions, the
schema, the prompt, the card lines and the composer lines. RouterDividerTests builds the same request in Swift and asserts
the same bytes (the schema as parsed JSON).

One deliberate difference: in the tags mode the note names the places by key (S1, fjord-change), not by target
(session:<id>), which a model can't match to the places it is shown."""
import json
import pathlib

from . import candidates as K
from . import common as C

OUT = C.ROUTER.parents[1] / "Tests" / "FjordTests" / "Fixtures" / "router-divider-parity.json"

SESSION = {"kind": "Claude Code session", "project": "app"}
PLACES = [
    ("S1", "session:ci", json.dumps({"title": "CI watcher", **SESSION, "now": "working: rerunning the build"}, ensure_ascii=False)),
    ("S2", "session:docs", json.dumps({"title": "Docs \"writer\"", **SESSION, "now": "finished 4 min ago: added the intro",
                                       "the user last told it": "add the page (2 min ago)"}, ensure_ascii=False)),
    ("new:app", "new:app", json.dumps({"kind": "new session", "project": "app"}, ensure_ascii=False)),
    ("fjord-change", "change_fjord", "Fjord itself: Change how Fjord behaves: its settings, notifications, inbox categories, rules or groups"),
    ("fjord-question", "question", "Fjord itself: A question to the Router about the board: which sessions are working, done or waiting"),
]
CARDS = [
    {"id": "ci#t2", "session": "ci", "kind": "question", "text": "Use \\ or /? Mind the \"é\" in the path, then pick."},
    {"id": "docs#t5", "session": "docs", "kind": "finished", "text": "Added the intro; the page is left."},
    {"id": "gone#t1", "session": "gone", "kind": "stuck", "text": "A card whose session is not on the board."},
]

# (name, mode, fixed targets, message, cards on the board, composer context)
CASES = [
    ("gates-plain", "gates", [], "rerun the build, and tell docs to add the page", CARDS, {}),
    ("gates-no-cards", "gates", [], "turn off the notification sounds and ask the CI one what it picked", [], {}),
    ("gates-composer", "gates", [], "yes. and docs should add the page\nthen {\"quote\": 'x'} and \\n stay as typed\n\tÀ la carte",
     CARDS, {"replyTo": "ci#t2",
             "tags": [{"tag": "@Docs \"writer\"", "target": "session:docs", "place": "session:docs"}],
             "pills": ["app"], "pinned": "session:docs", "notTo": "change_fjord"}),
    ("tags-sessions", "tags", ["session:ci", "session:docs"], "ask @CI watcher to rerun the build, or @Docs \"writer\" to add the page", CARDS,
     {"tags": [{"tag": "@CI watcher", "target": "session:ci", "place": "session:ci"},
               {"tag": "@Docs \"writer\"", "target": "session:docs", "place": "session:docs"}]}),
    ("tags-chip-and-fjord", "tags", ["change_fjord", "session:docs", "new:app"],
     "mute notifications for an hour or tell @Docs \"writer\" about it, in @app", CARDS,
     {"replyTo": "docs#t5", "tags": [{"tag": "@Docs \"writer\"", "target": "session:docs", "place": "session:docs"}],
      "pills": ["app"], "notTo": "session:ci"}),
]


def case(name, mode, fixed, message, cards, context):
    C.options = lambda state, message, context=None: PLACES
    calls = []
    C.claude = lambda model, system, prompt, schema=None, tag="claude", timeout=180: (
        calls.append((system, prompt, schema)) or {"out": {"parts": [], "sure": False, "alternatives": []}, "error": None})
    state = {"cards": cards}
    key_by_target = {t: k for k, t, _ in PLACES}
    note = None
    if mode == "tags":
        keys = list(dict.fromkeys(key_by_target[t] for t in fixed))
        note = f"The user's pills fix the places: divide the message among exactly these places ({', '.join(keys)})."
    K.model_route("fake", state, message, context, note=note, fixed=fixed or None, waits=mode == "gates")
    system, prompt, schema = calls[0]
    keys_by_target = key_by_target
    return {
        "name": name,
        "mode": mode,
        "fixed": fixed,
        "message": message,
        "places": [{"key": k, "target": t, "description": d, "session": t[len("session:"):] if t.startswith("session:") else None}
                   for k, t, d in PLACES],
        "board": cards,
        "composer": context,
        "cards": [K._card_line(state, c, keys_by_target) for c in cards if "session:" + c["session"] in keys_by_target][:20],
        "context": K.context_lines(state, context, keys_by_target),
        "keys": schema["properties"]["alternatives"]["items"]["enum"],
        "system": system,
        "schema": schema,
        "prompt": prompt,
    }


def main():
    out = {"system": {"tags": K.ROUTER_SYSTEM, "gates": K.ROUTER_SYSTEM + K.WAITS_RULE},
           "cases": [case(*c) for c in CASES]}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(len(out["cases"]), "cases →", OUT)


if __name__ == "__main__":
    main()
