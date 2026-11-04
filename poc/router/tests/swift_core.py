"""SwiftCore: routerd.Core's constructor and methods, served by `Fjord --courier-test --db <path>` over JSON lines
(docs/design/router-swift-port.md, "The conformance bridge" and "Protocol"). support.py puts it in place of routerd.Core when
FJORD_CORE=swift. `FJORD_SWIFT_BIN` names another executable that speaks the protocol (tests/fake_bridge.py).

This module imports nothing of the POC but `store`, so the bridge process can share its `plain`."""
import atexit
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
import weakref

import store

TIMEOUT = 15  # seconds of silence from the bridge before a request fails
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
TMP = tempfile.mkdtemp(prefix="router-swift-")
atexit.register(shutil.rmtree, TMP, True)

# What mock.patch changes today: each is sent as a `set_constant` before the request that follows the change.
CONSTANTS = {"KEPT": ("do", "KEPT"), "DEV_WAIT": ("routerd", "DEV_WAIT")}
# The internals `call` runs, and which of them leave the state as it was (the cached `state` stays).
CALLS = {"advance_all", "safely", "cancel_send", "finish", "command", "remember", "recheck_pauses", "goto", "advance", "start", "done", "wake_me"}
READS = {"acting", "yielded", "in_page", "tab_held", "tab_idle", "tool_busy", "next_id", "ready", "stale", "unheard_sends"}
READ_OPS = {"state", "next_deadline", "pure"}


def plain(value):
    """Python's value as the JSON the Swift side writes: sets and tuples are arrays, keys are strings, a run is its id."""
    if isinstance(value, RunDict):
        value._fresh()
        ref = {"$run": dict.__getitem__(value, "id")}
        return ref if value.core._live(value) else {**ref, "fields": plain(dict(dict.items(value)))}  # a run that ended is sent as it was
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, (set, frozenset)):
        return sorted((plain(v) for v in value), key=json.dumps)
    return value


def executable():
    path = os.environ.get("FJORD_SWIFT_BIN") or os.path.join(ROOT, ".build", "debug", "Fjord")
    return [sys.executable, path] if path.endswith(".py") else [path]


class Process:
    """One bridge process. `request` writes a line and hands back every line up to the reply with the request's id."""
    def __init__(self, db_path):
        self.proc = subprocess.Popen([*executable(), "--courier-test", "--db", db_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.n, self.buffer, self.last = 0, b"", None
        weakref.finalize(self, Process.close, self.proc)

    def readline(self):
        """One line from the bridge, or a RuntimeError naming the last request after TIMEOUT seconds of silence: nothing can hang."""
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            # poll, not select: unittest keeps every test's core alive to the end, so descriptors pass select's 1024 limit
            poller = select.poll()
            poller.register(fd, select.POLLIN)
            if not poller.poll(TIMEOUT * 1000):
                raise RuntimeError(f"the bridge was silent for {TIMEOUT} s after {self.last}")
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError(f"the bridge ended after {self.last}")
            self.buffer += chunk
        text, _, self.buffer = self.buffer.partition(b"\n")
        return text.decode()

    @staticmethod
    def close(proc):
        try:
            proc.stdin.close()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        finally:
            proc.stdout.close()

    def request(self, fields, on_line):
        body = plain(fields)  # first: a stale run in it makes a request of its own
        self.n += 1
        line = json.dumps({"id": self.n, **body}, ensure_ascii=False)
        self.last = line if len(line) < 400 else line[:400] + "…"
        try:
            self.proc.stdin.write(line.encode() + b"\n")
            self.proc.stdin.flush()
        except OSError as e:
            raise RuntimeError(f"the bridge is gone ({e}) at {self.last}")
        failure = None
        while True:
            m = json.loads(self.readline())
            if m.get("id") == self.n:
                if failure:
                    raise failure
                if "error" in m:
                    raise RuntimeError(m["error"])
                return m.get("result")
            try:
                on_line(m)
            except Exception as e:  # the lines after it are still read: the next request starts clean
                failure = failure or e


class RunDict(dict):
    """A run as the state dump has it. The test holds it like Python's live run dict: a read finds the state after every op since (a
    run that ended keeps its last fields), and writing a field is a test-only `set_run`."""
    def __init__(self, core, *a, **k):
        super().__init__(*a, **k)
        self.core = core

    def _fresh(self):
        if self.core._cache is None and self.core._live(self):
            self.core._state()

    def __setitem__(self, field, value):
        self.core._write("set_run", run=self["id"], field=field, value=value)
        super().__setitem__(field, value)

    def update(self, *a, **k):
        for field, value in dict(*a, **k).items():
            self[field] = value


def _reader(name):
    def read(self, *a, **k):
        self._fresh()
        return getattr(dict, name)(self, *a, **k)
    read.__name__ = name
    return read


for _name in ("__getitem__", "get", "__contains__", "__iter__", "__len__", "keys", "values", "items", "__eq__", "__ne__", "copy", "__repr__"):
    setattr(RunDict, _name, _reader(_name))


class SwiftCore:
    def __init__(self, db, out, models=None, clock=time.time, wake=lambda: None, uptime=time.monotonic):
        """`db` is a connection (its file is the bridge's) or a path. `models` and `wake` are kept and never used: the engine calls no model,
        and the timer is the test's (`tick`)."""
        self.db = store.connect(db) if isinstance(db, str) else db
        self.out, self.models, self.clock, self.wake, self.uptime = out, models, clock, wake, uptime
        path = self.db.execute("pragma database_list").fetchone()[2]
        if not path:
            raise ValueError("a SwiftCore needs a database file: support.memory_db() makes one under the switch")
        self._finish_hook, self._hooking = None, False
        self._cache, self._callbacks, self._runs, self._sent, self._changes = None, {}, {}, self._constants(), self.db.total_changes
        self._cb, self._gone = 0, {}
        self._process = Process(path)
        self._raw("start", constants=self._sent)

    def __setattr__(self, name, value):
        if name == "finish":  # the fuzz harness wraps the core's `finish` to time it: the proxy calls it back for each run that ended
            return object.__setattr__(self, "_finish_hook", value)
        object.__setattr__(self, name, value)

    # ---- the wire

    @staticmethod
    def _constants():
        import do
        import routerd
        return {"KEPT": do.KEPT, "DEV_WAIT": routerd.DEV_WAIT}

    def _send(self, op, **fields):
        """One request. Patched constants and Python's own writes to the file go ahead of it (the bridge reads what it caches again)."""
        now = self._constants()
        for name, value in now.items():
            if self._sent[name] != value:
                self._sent[name] = value
                self._raw("set_constant", name=name, value=value)
        if self.db.total_changes != self._changes:
            fields["db"], self._changes = True, self.db.total_changes
        return self._raw(op, **fields)

    def _raw(self, op, **fields):
        return self._process.request({"op": op, "t": self.clock(), "up": self.uptime(), **fields}, self._line)

    def _line(self, m):
        if "out" in m:
            self.out(m["out"])
        elif "reply" in m:
            self._callbacks[m["reply"]][0](m["event"])
        elif "finished" in m:
            self._callbacks.pop(m["finished"])[1](m["intent"])
        else:
            raise RuntimeError(f"unknown line from the bridge: {m}")

    def _op(self, op, **fields):
        """A request that may change the core: the cached state is dropped."""
        self._cache = None
        try:
            return self._send(op, **fields)
        finally:
            self._cache = None  # (a run among the fields was refreshed for the request: that state is from before it)
            self._ended()

    def _write(self, op, **fields):
        return self._op(op, **fields)

    def _callback(self, reply, finished):
        self._cb += 1
        self._callbacks[self._cb] = (reply, finished)
        return self._cb

    def _ended(self):
        if self._finish_hook and not self._hooking:
            before = set(self._runs)
            self._state()
            self._hooking = True
            try:
                for id_ in sorted(before - set(self._runs)):
                    self._finish_hook(self._gone[id_], None)
            finally:
                self._hooking = False

    def _live(self, run):
        return self._runs.get(dict.__getitem__(run, "id")) is run

    def _state(self):
        if self._cache is None:
            s = self._send("state")
            self._gone = dict(self._runs)
            for key, fields in s["ended"].items():  # a run that ended keeps its final fields
                if int(key) in self._runs:
                    dict.clear(self._runs[int(key)])
                    dict.update(self._runs[int(key)], self._fields(fields))
            for id_ in list(self._runs):
                if str(id_) not in s["runs"]:
                    del self._runs[id_]
            for key, fields in s["runs"].items():
                run = self._runs.setdefault(int(key), RunDict(self))
                dict.clear(run)
                dict.update(run, self._fields(fields))
            places = {tuple(p) if isinstance(p, list) else p for p in s["unsettled"]}
            wo = s["watch_open"] and {**s["watch_open"], "to": tuple(s["watch_open"]["to"])}
            self._cache = {**s, "runs": self._runs, "watch_open": wo, "watched": {int(k): v for k, v in s["watched"].items()},
                           "watch_back": {int(k): v for k, v in s["watch_back"].items()}, "unproved": set(s["unproved"]),
                           "unsettled": places, "arrived": tuple(s["arrived"]), "known": {k: dict.fromkeys(v) for k, v in s["known"].items()},
                           "dev": dict.fromkeys(s["dev"], True), "claimed": {(p, t): set(rows) for p, t, rows in s["claimed"]}}
        return self._cache

    @staticmethod
    def _fields(fields):
        return {k: tuple(v) if k in ("moving_to", "back") and isinstance(v, list) else set(v) if k == "heard" and isinstance(v, list) else v
                for k, v in fields.items()}

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        if name in ("runs", "watched", "watch_open", "watch_back", "moves", "unproved", "stale_goal", "unsettled", "arrived", "pages", "linked",
                    "commands", "known", "dev", "closing", "relinked", "claimed"):
            return self._state()[name]
        if name in CALLS or name in READS:
            return lambda *args, **kwargs: self._call(name, args, kwargs)
        raise AttributeError(f"SwiftCore has no {name}")

    def _call(self, name, args, kwargs):
        if name in READS:
            return self._send("call", name=name, args=list(args), kwargs=kwargs)
        return self._op("call", name=name, args=list(args), kwargs=kwargs)

    # ---- Core's methods

    def board(self):
        return self._state()["board"]

    def handle(self, event):
        return self._op("handle", event=event)

    def connection(self, up, current=True):
        return self._op("connection", host=up, current=current)

    def local(self, local):
        return self._op("local", local=local)

    def say(self, message, project=None, thread=None, reply=lambda event: None, finished=lambda intent: None):
        return self._op("say", message=message, project=project, thread=thread, cb=self._callback(reply, finished))

    def tool(self, tool, /, reply=lambda event: None, finished=lambda intent: None, **args):
        return self._op("tool", name=tool, args=args, cb=self._callback(reply, finished))

    def confirm(self, intent_id, finished=lambda intent: None):
        return self._op("confirm", intent=intent_id, cb=self._callback(lambda event: None, finished))

    def correct(self, intent_id, project):
        return self._op("correct", intent=intent_id, project=project)

    def note(self, topic, text):
        return self._op("note", topic=topic, text=text)

    def tell(self):
        return self._op("tell")

    def tick(self, now=None):
        return self._op("tick", **({} if now is None else {"now": now}))

    def next_deadline(self):
        return self._send("next_deadline")

    def dev_command(self, kind, reply, **fields):
        return self._op("dev_command", kind=kind, fields=fields, cb=self._callback(reply, lambda intent: None))

    def dev_cancel(self, id_):
        return self._op("dev_cancel", target=id_)

    def finish(self, run, status, cause=None, row=None, **changes):
        if self._hooking:  # the harness's wrapper calling on: the run is already over
            return None
        return self._call("finish", (run, status, cause, row), changes)


# ---- pure functions

# What the wire flattens, rebuilt for the tests: results Python returns as tuples, and as sets.
TUPLES = {"do.proved", "do.tool_args", "do.handoff", "tell.plan"}
PURE = {"board": ("fold", "proof_holds", "ends_shortly", "starts_with", "merge_rows", "loose", "new_rows", "assign", "start", "step", "fold_into", "finish"),
        "do": ("proved", "proved_all", "anchor", "baselined", "turning", "tool_args", "handoff"),
        "page": ("seen_rows",),
        "tell": ("facts", "plan")}


class Acc(dict):
    """A board fold state as a handle, {"acc": n}: it lives in the bridge. Writing a field (the tests set `here`) is `board.acc_set`."""
    def __setitem__(self, field, value):
        pure("board.acc_set", self, field, value)


def rebuild(fn, result):
    if fn == "board.start" or fn in ("board.step", "board.fold_into"):
        return Acc(result)
    if fn == "board.assign":
        return {i: key for i, key in result}
    if fn == "do.proved_all":
        return {i: tuple(v) for i, v in result}
    if fn in ("board.finish", "board.fold"):
        if result["here"] is not None:
            result["here"] = tuple(result["here"])
        return result
    return tuple(result) if fn in TUPLES else result


def pure(fn, *args, **kwargs):  # kwargs is an object on the wire; `claimed=` is the one tests pass
    if not _pure:
        db = os.path.join(TMP, "pure.db")
        store.connect(db).close()
        _pure.append(Process(db))
    result = _pure[0].request({"op": "pure", "t": 0, "up": 0, "fn": fn, "args": list(args), "kwargs": kwargs}, lambda m: None)
    return rebuild(fn, result)


_pure = []


def install_pure():
    """Under the switch the pure test files' calls to board, do, page and tell go through `pure`, with their imports unchanged."""
    import board
    import do
    import page
    import tell
    modules = {"board": board, "do": do, "page": page, "tell": tell}

    def route(module, name):
        def call(*args, **kwargs):
            return pure(f"{module}.{name}", *args, **kwargs)
        call.__name__ = name
        return call
    for module, names in PURE.items():
        for name in names:
            setattr(modules[module], name, route(module, name))
