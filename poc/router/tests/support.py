import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import fake_page
import routerd
import store

NOW = 1_000_000.0

# FJORD_CORE=swift runs these tests against the Swift core: routerd.Core is SwiftCore (swift_core.py), which speaks to
# `Fjord --courier-test`, and the pure board, do, page and tell functions the tests call go through the same binary. See run_swift.sh.
SWIFT = os.environ.get("FJORD_CORE") == "swift"
if SWIFT:
    import swift_core
    routerd.Core = swift_core.SwiftCore
    swift_core.install_pure()


def python_only(reason):
    """Skips a test (or a class) under FJORD_CORE=swift. Every use names why the Swift core can't take it: `grep -rn python_only tests`."""
    return unittest.skip(f"python_only: {reason}") if SWIFT else (lambda test: test)


class Clock:
    """The wall clock, and `uptime`, which stands still while the Mac sleeps (`sleep`)."""
    def __init__(self):
        self.t, self.slept = NOW, 0.0

    def __call__(self):
        return self.t

    def uptime(self):
        return self.t - self.slept


class Spy:
    """A model that records its calls. With no answer it must not be called."""
    def __init__(self, *answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, *args):
        self.calls.append(args)
        if not self.answers:
            raise AssertionError("a model was called")
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, Exception):
            raise answer
        return answer


def memory_db():
    """A fresh database. Under the switch the bridge opens the same file, so it is a temp file."""
    return store.connect(tempfile.mkstemp(suffix=".db", dir=swift_core.TMP)[1] if SWIFT else ":memory:")


def world(models=None, db=None, page=None, session=True):
    """A core on the demo page, connected, with the tab showing every project in turn. No model is available unless given."""
    page = page or fake_page.demo()
    if not session:
        for p in page.projects.values():
            for t in p["threads"].values():
                t["session"] = None
    clock = Clock()
    core = routerd.Core(db or memory_db(), page.receive, models or routerd.Models(), clock=clock, uptime=clock.uptime)
    page.clock = core.clock
    page.connect(core)
    return core, page


def local_info(cli="c1", folder="/tmp/alpha", **more):
    return {"folder": folder, "title": "t", "detail": "d", "needs": None, "cli": cli, "purpose": "", "result": None, "active": NOW - 7200,
            "category": None, "interrupted": False, "child": False, **more}


def later(core, seconds=1):
    core.clock.t += seconds


def sleep(core, seconds):
    """The Mac sleeps: the wall clock jumps, uptime doesn't."""
    core.clock.t += seconds
    core.clock.slept += seconds


def run_out(core, page, intent_id, steps=20):
    """Each deadline of the run is let pass in turn, until it ends."""
    for _ in range(steps):
        run = core.runs.get(intent_id)
        if run is None:
            return
        core.clock.t = run["deadline"] if run["deadline"] is not None else core.clock.t + 1
        core.tick()
        page.pump(core)


def armed(core):
    """The runs that have begun (acting, yielded or gated) and aren't paused but have no deadline: none should, or nothing wakes them."""
    return [i for i, r in core.runs.items() if not r["paused"] and r["deadline"] is None and (core.acting(r) or core.yielded(r) or r.get("gated"))]
