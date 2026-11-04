"""A Python stand-in for `Fjord --courier-test --db <path>`: routerd.Core behind the JSON-lines protocol of docs/design/router-swift-port.md
("Protocol"). `FJORD_SWIFT_BIN=<this file>` makes SwiftCore (swift_core.py) talk to it, so the proxy is proved faithful before the Swift
core exists. It is as strict as the Swift side must be: no model is available (a `say` with no project or thread is an error), only
whitelisted internals are callable, and everything it says is plain JSON.

Usage: fake_bridge.py --courier-test --db <path>"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import board
import do
import page
import routerd
import store
import tell
from swift_core import plain

CONSTANTS = {"KEPT": (do, "KEPT"), "DEV_WAIT": (routerd, "DEV_WAIT")}
CALLS = {"advance_all", "safely", "acting", "yielded", "in_page", "tab_held", "tab_idle", "cancel_send", "finish", "command", "next_id",
         "remember", "recheck_pauses", "ready", "stale", "goto", "advance", "start", "tool_busy", "unheard_sends", "done", "wake_me"}
PURE = {"board": board, "do": do, "page": page, "tell": tell}
PLACE_ARGS = {"ready": 1, "stale": 1}  # the argument that is a (project, thread) place: JSON has it as a list


class Bridge:
    def __init__(self, db_path, write):
        self.db_path, self.write, self.core, self.t, self.up = db_path, write, None, 0.0, 0.0
        self.held = {}  # the runs as the last `state` had them: one that has since ended is reported with its final fields

    def line(self, **fields):
        self.write(json.dumps(plain(fields), ensure_ascii=False))

    def callback(self, kind, cb):
        return lambda value: self.line(**{kind: cb, "event" if kind == "reply" else "intent": value})

    def run_of(self, value):
        if isinstance(value, dict) and "$run" in value:
            return self.core.runs.get(value["$run"]) or value.get("fields")
        return value

    def request(self, m):
        op = m["op"]
        self.t, self.up = m["t"], m["up"]
        if m.get("db") and self.core:  # Python wrote to the file since the last request: whatever the core caches from it is read again
            self.core.chatted = store.chat_projects(self.core.db)
        c = self.core
        if op == "start":
            for name, value in (m.get("constants") or {}).items():
                setattr(*CONSTANTS[name], value)
            self.core = routerd.Core(store.connect(self.db_path), lambda command: self.line(out=command), routerd.Models(),
                                     clock=lambda: self.t, uptime=lambda: self.up)
            return None
        if op == "set_constant":
            module, name = CONSTANTS[m["name"]]
            setattr(module, name, m["value"])
            return None
        if op == "pure":
            return PURE_RESULT(m["fn"], m.get("args", []), m.get("kwargs") or {})
        if op == "handle":
            return c.handle(m["event"])
        if op == "connection":
            return c.connection(m["host"], m.get("current", True))
        if op == "local":
            return c.local(m["local"])
        if op == "say":
            if not m.get("project") and not m.get("thread"):
                raise ValueError("no model here: say needs a project or a thread")
            return c.say(m["message"], m.get("project"), m.get("thread"), self.callback("reply", m["cb"]), self.callback("finished", m["cb"]))
        if op == "tool":
            return c.tool(m["name"], reply=self.callback("reply", m["cb"]), finished=self.callback("finished", m["cb"]), **m["args"])
        if op == "confirm":
            return c.confirm(m["intent"], self.callback("finished", m["cb"]))
        if op == "correct":
            return c.correct(m["intent"], m["project"])
        if op == "note":
            return c.note(m["topic"], m["text"])
        if op == "tell":
            return c.tell()
        if op == "tick":
            return c.tick(m.get("now"))
        if op == "next_deadline":
            return c.next_deadline()
        if op == "dev_command":
            return c.dev_command(m["kind"], self.callback("reply", m["cb"]), **m["fields"])
        if op == "dev_cancel":
            return c.dev_cancel(m["target"])
        if op == "set_run":
            c.runs[m["run"]][m["field"]] = m["value"]
            return None
        if op == "call":
            name = m["name"]
            if name not in CALLS:
                raise ValueError(f"call {name} is not whitelisted")
            args = [self.run_of(a) for a in m.get("args", [])]
            if name in PLACE_ARGS:
                args[0], args[PLACE_ARGS[name]] = c.board(), tuple(args[PLACE_ARGS[name]])
            return getattr(c, name)(*args, **{k: self.run_of(v) for k, v in (m.get("kwargs") or {}).items()})
        if op == "state":
            return self.state()
        raise ValueError(f"unknown op {op}")

    def state(self):
        c = self.core
        ended = {i: r for i, r in self.held.items() if i not in c.runs}
        self.held = dict(c.runs)
        return {"runs": c.runs, "ended": ended, "watched": c.watched, "watch_open": c.watch_open, "watch_back": c.watch_back, "moves": c.moves,
                "unproved": c.unproved, "stale_goal": c.stale_goal, "unsettled": c.unsettled, "arrived": c.arrived, "pages": c.pages,
                "linked": c.linked, "commands": c.commands, "known": {k: list(v) for k, v in c.known.items()}, "dev": list(c.dev),
                "closing": c.closing, "relinked": c.relinked,
                "claimed": [[p, t, sorted(rows)] for (p, t), rows in c.claimed.items()], "board": c.board()}


ACCS = {}  # board fold states by handle: {"acc": n}


def pure_args(fn, args):
    """What the wire flattens is rebuilt for the POC's functions: a proofs list is [(id, proof)], a place is a tuple."""
    if fn in ("do.proved_all", "board.assign"):
        args = [args[0], [tuple(p) for p in args[1]], *args[2:]]
    if fn in ("do.proved", "do.proved_all", "board.assign", "board.proof_holds") and len(args) > 2 and args[-1] is not None:
        args[-1] = set(args[-1])
    return args


def PURE_RESULT(fn, args, kwargs):
    """Results in the shapes the Swift side sends: sets are sorted lists, tuples are lists, `board.assign` is [[id, key], …],
    `do.proved` is [done, cause, key], `do.proved_all` is [[id, [done, cause, key]], …] in proof order, `tell.plan` is [say, quiet]."""
    if fn == "board.start":
        ACCS[len(ACCS) + 1] = board.start(*args)
        return {"acc": len(ACCS)}
    if fn in ("board.step", "board.fold_into", "board.finish", "board.acc_set"):
        acc = ACCS[args[0]["acc"]]
        if fn == "board.step":
            board.step(acc, args[1])
        elif fn == "board.fold_into":
            board.fold_into(acc, args[1])
        elif fn == "board.acc_set":
            acc[args[1]] = tuple(args[2]) if args[1] == "here" and args[2] is not None else args[2]
            return None
        else:
            return board.finish(acc)
        return args[0]
    claimed = kwargs.get("claimed")
    if claimed is not None:
        kwargs = {**kwargs, "claimed": set(claimed)}
    module, _, name = fn.partition(".")
    args = pure_args(fn, list(args))
    result = PURE[module].__dict__[name](*args, **kwargs)
    if fn == "board.assign":
        return [[i, k] for i, k in result.items()]
    if fn == "do.proved_all":
        return [[i, list(v)] for i, v in result.items()]
    return result


def main(argv):
    db_path = argv[argv.index("--db") + 1]
    out = sys.stdout
    bridge = Bridge(db_path, lambda s: out.write(s + "\n"))
    for text in sys.stdin:
        m = json.loads(text)
        try:
            result = bridge.request(m)
            bridge.line(id=m["id"], result=result)
        except Exception as e:  # the Swift side replies `error` too, and goes on
            bridge.line(id=m["id"], error=f"{type(e).__name__}: {e}")
        out.flush()


if __name__ == "__main__":
    main(sys.argv)
