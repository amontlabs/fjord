"""Seeded random disturbances against Core + FakePage (from the review's harness), checking the end-to-end invariants: no doubled rows,
no confirmed send without its row, no run left stuck, the field holding the newest confirmed tool's text, no failed send whose row
shows by the end while its watch had time to see it, and no confirm slower than SLOW once Fjord could see the row.

Harness artifacts, excluded explicitly where each is handled:
- a reload with `pending=None` while no turn is under way leaves your rows pending in the new page, which a real server never does
  (it shows them keyed, or the old page lost them): a send pending at such a reload isn't held to the failed-but-row check;
- `FakePage.release()` restores `slow_reads`/`slow_close` after releasing, so a quiesce would keep reads slow for good: it clears them;
- the host down: nothing can be read with no host, so a failed send whose watch had no host for most of it isn't held to the
  failed-but-row check, and the time with no host doesn't count toward a slow confirm;
- the harness's own moves of the tab (a reload landing elsewhere, a host's connect showing each project) are the owner's, not a run's.

The product's documented limits, excluded too (EVENTS.md: a taken or watched send goes back once per run's move, two taken sends never
take turns at the tab, a look holds the tab until it ends):
- a failed send is held to the failed-but-row check only when its watch had time: its row came before it failed (its going back after
  the failure reads it), or a run moved the tab after the row came and while it was still watched. A row that comes after its last
  going back, with no move since, is read only if you show its place yourself;
- a confirm is timed from when Fjord could see the row: it showed while the tab showed its place, or a run moved the tab after the row
  came (and after the harness's own last move); less do.TIMEOUT for each other taken send's look that began meanwhile. A send whose row
  could first be seen while another taken send's place was on screen isn't timed: one of the two waits for its look."""
import contextlib
import io
import random
import unittest

import support
import fake_page
import do
import routerd
import store

PLACES = [("chan_a", None), ("chan_b", None), ("chan_a", "cmsg_2")]
BASE = ["say", "say", "say", "tick", "tick", "later", "drop", "reload", "reinject", "swallow", "holds", "deliver",
        "settles", "settle", "sleep", "tool", "composerless", "turn", "finish_turn"]
MORE = ["rendering", "render", "unfetched", "mounting", "mount", "slow_reads", "release", "save", "slow_close", "tool", "tool"]
REVIEWED = [20, 46, 147, 174, 395, 545, 9, 271]  # the reviews' failing seeds, same generator (271: a taken send kept from the tab, `back_due`)
SEEDS = list(range(300)) + REVIEWED
MORE_SEEDS = list(range(150)) + REVIEWED
SLOW = 25  # seconds from a row showing in the page to its send confirmed


class Harness:
    def __init__(self, seed, more=False):
        self.r, self.more = random.Random(seed), more
        self.page = fake_page.demo()
        self.up, self.n, self.log = True, 0, []
        self.sent, self.fin, self.delivered, self.rowat, self.tools = {}, {}, {}, {}, {}
        self.down = []  # [start, end] uptime spans with no host
        self.artifact = set()  # sends pending at a `pending=None` reload with no turn under way
        self.turnrow = None
        self.order = 0  # finishes and deliveries, in the order they happened (several share an uptime)
        self.fin_order, self.delivered_order, self.delivered_moves, self.watch_moves = {}, {}, {}, {}
        self.ready, self.looks = {}, {}  # send -> when Fjord could see its row; (run, look) -> when the look began
        self.owner_mark = 0  # `moves` at the harness's own last move of the tab
        self.rowat_moves = {}  # send -> `moves` when its row showed in the page
        self.contended = {}  # send -> another taken send's place was on screen when its row could first be seen
        clock = support.Clock()
        self.core = routerd.Core(support.memory_db(), self.out, routerd.Models(), clock=clock, uptime=clock.uptime)
        self.page.clock = self.core.clock
        self.page.connect(self.core)
        self.pump()
        finish = self.core.finish

        def finished(run, status, *a, **k):
            self.fin[run["id"]] = self.core.uptime()
            self.order += 1
            self.fin_order[run["id"]] = self.order
            return finish(run, status, *a, **k)
        self.core.finish = finished
        deliver = self.page.deliver

        def delivered(pid, thread=None):
            for r in self.page._rows(pid, thread):
                if r["pending"]:
                    self.order += 1
                    self.delivered[r["text"]] = self.core.uptime()
                    self.delivered_order[r["text"]], self.delivered_moves[r["text"]] = self.order, self.core.moves
            if self.turnrow:  # the turn being written isn't delivered with them
                self.turnrow[2]["pending"] = False
            out = deliver(pid, thread)
            if self.turnrow:
                self.turnrow[2]["pending"] = True
            return out
        self.page.deliver = delivered

    def out(self, command):
        if self.up:
            self.page.receive(command)

    def pump(self):
        if not self.up:  # the page lives on with no host: it runs what it holds, and its events go nowhere
            while self.page.inbox:
                self.page.run(self.page.inbox.pop(0))
            self.page.outbox.clear()
            return
        self.page.pump(self.core)

    def set_up(self, up):
        self.up = up
        if up:
            self.down[-1][1] = self.core.uptime()
            self.owner_mark = self.core.moves
            self.page.connect(self.core)
        else:
            self.down.append([self.core.uptime(), None])
            self.core.connection(False)

    def say(self):
        pid, th = self.r.choice(PLACES)
        self.n += 1
        words = f"message number {self.n} about item {self.n * 7}"
        self.core.say(words, project=pid, thread=th)
        self.sent[store.intents(self.core.db, 1)[-1]["id"]] = (words, (pid, th))

    def reload(self, pid, pending):
        if pending is None and self.turnrow is None:  # artifact: rows left pending with no turn to hold them
            for iid, (words, place) in self.sent.items():
                if any(r["pending"] and r["text"] == words for r in self.page._rows(*place)):
                    self.artifact.add(iid)
        if pending == "keyed":  # the new page shows your pending rows keyed: they are delivered now
            for place in PLACES:
                for r in self.page._rows(*place):
                    if r["pending"] and r["from"] == "you":
                        self.order += 1
                        self.delivered[r["text"]] = self.core.uptime()
                        self.delivered_order[r["text"]], self.delivered_moves[r["text"]] = self.order, self.core.moves
        self.owner_mark = self.core.moves
        self.page.reload(self.core, pid, pending=pending)

    def step(self):
        p, c, r = self.page, self.core, self.r
        k = r.choice(BASE + (MORE if self.more else []))
        self.log.append(f"{c.clock.t - support.NOW:.1f} {k}")
        if k == "say":
            self.say()
        elif k == "tick":
            d = c.next_deadline()
            if d is not None and d > c.clock.t:
                c.clock.t = d
            c.tick()
        elif k == "later":
            support.later(c, r.choice([0.5, 1, 2.5, 5])); c.tick()
        elif k == "drop":
            self.set_up(not self.up)
        elif k == "reload" and self.up:
            self.reload(r.choice(["chan_a", "chan_b", None]), r.choice([None, "keyed", "lost"]))
        elif k == "reinject" and self.up:
            p.reinject(c)
        elif k in ("swallow", "holds"):
            setattr(p, k, not getattr(p, k))
        elif k == "deliver":
            for pl in PLACES:
                p.deliver(*pl)
        elif k == "settles":
            p.settles = True
        elif k == "settle":
            p.settles = False
            p.settle()
        elif k == "composerless":
            p.composerless = True
        elif k == "sleep":
            support.sleep(c, 3600); c.tick()
        elif k == "tool":
            self.n += 1
            self.tools[f"rules {self.n}"] = None
            c.tool("set_instructions", project="chan_b", text=f"rules {self.n}")
        elif k in ("rendering", "unfetched", "mounting"):
            getattr(p, k).add(r.choice(PLACES))
        elif k == "render":
            for pl in list(p.rendering):
                p.render(*pl)
        elif k == "mount":
            for pl in list(p.mounting):
                p.mount(*pl)
        elif k in ("slow_reads", "slow_close"):
            setattr(p, k, True)
        elif k == "release":
            p.release()
        elif k == "save":
            p.save = r.choice(["ok", "ok", "refused", "unanswered", "hang"])
        elif k == "turn":
            pid, th = r.choice(PLACES)
            if self.turnrow is None:
                self.turnrow = (pid, th, p.post(pid, "claude", "", th, streaming=True, pending=True))
        elif k == "finish_turn" and self.turnrow:
            pid, th, row = self.turnrow
            row["text"] = "done reply"
            p.finish(pid, row, th)
            self.turnrow = None
        self.pump()
        self.seen_rows()

    def seen_rows(self):
        for iid in self.core.watched:
            self.watch_moves[iid] = self.core.moves
        for iid, (words, place) in self.sent.items():
            if iid not in self.rowat and any(r["from"] == "you" and r["text"] == words and not r["pending"] for r in self.page._rows(*place)):
                self.rowat[iid], self.rowat_moves[iid] = self.core.uptime(), self.core.moves
        at = self.page.at
        for iid, (words, (pid, th)) in self.sent.items():
            shown = self.up and at is not None and at[0] == pid and (th is None or at[1] == th)
            if iid in self.rowat and iid not in self.ready and (shown or self.core.moves > max(self.owner_mark, self.rowat_moves[iid])):
                self.ready[iid] = self.core.uptime()
                # Another taken send's place on screen: two taken sends can't both show theirs, and they never take turns (each goes
                # back once per run's move), so this one may wait for its look by design.
                self.contended[iid] = not shown and any(
                    o is not None and not o["tool"] and o.get("taken") and other != iid and self.page.at is not None
                    and self.page.at[0] == self.sent.get(other, (None, (None,)))[1][0] for other, o in self.core.runs.items())
        for iid, run in self.core.runs.items():
            if run.get("looking"):
                self.looks.setdefault((iid, run["looking"]), self.core.uptime())

    def quiesce(self):
        p, c = self.page, self.core
        p.swallow = p.holds = p.settles = False
        p.save = "ok"
        for pl in list(p.rendering):
            p.render(*pl)
        for pl in list(p.mounting):
            p.mount(*pl)
        p.release()
        p.slow_reads = p.slow_close = False  # artifact: release() puts them back
        if self.turnrow:
            pid, th, row = self.turnrow
            row["text"] = "done reply"
            p.finish(pid, row, th)
            self.turnrow = None
        p.settle()
        if not self.up:
            self.set_up(True)
        for pl in PLACES:
            p.deliver(*pl)
        self.pump()
        for _ in range(400):
            if not c.runs and not c.watched:
                break
            d = c.next_deadline()
            c.clock.t = max(c.clock.t + 0.05, d if d is not None else c.clock.t + 1)
            c.tick()
            self.pump()
            self.seen_rows()

    def down_for(self, start, end):
        """How long the host was down between two uptimes."""
        return sum(max(0.0, min(end, e if e is not None else end) - max(start, s)) for s, e in self.down)

    def check(self):
        bad, c = [], self.core
        if c.runs:
            bad.append(f"stuck runs: {list(c.runs)}")
        for iid, (words, place) in self.sent.items():
            i = store.intent(c.db, iid)
            rows = [r for r in self.page._rows(*place) if r["from"] == "you" and r["text"] == words]
            real = [r for r in rows if not r["pending"]]
            if len(rows) > 1:
                bad.append(f"doubled {iid} {words!r}: {len(rows)} rows")
            if i["status"] == "confirmed" and not real:
                bad.append(f"confirmed without row {iid} {words!r}")
            if i["status"] == "refused" and real:
                bad.append(f"refused but row exists {iid} {words!r} cause={i['cause']!r}")
            if i["status"] != "failed" or not real or iid in self.artifact or iid not in self.fin:
                continue
            watch = (self.fin[iid], self.fin[iid] + routerd.ACCEPTED_WAIT)
            late = words in self.delivered and self.delivered[words] >= watch[1] - 1  # its row came after its watch: no time
            # The product's limit (see the top): it goes back once per run's move, so a row after its last going back may go unread.
            had_time = words not in self.delivered or (self.delivered_order[words] < self.fin_order[iid]
                                                       or self.delivered_moves[words] < self.watch_moves.get(iid, -1))
            if not late and had_time and self.down_for(*watch) <= routerd.ACCEPTED_WAIT / 2:  # had time (the limit), and a host most of it
                bad.append(f"failed but row exists {iid} {words!r} cause={i['cause']!r}")
        for iid, t in self.ready.items():
            if store.intent(c.db, iid)["status"] != "confirmed" or iid not in self.fin or self.contended.get(iid):
                continue
            looks = sum(1 for (run, _), at in self.looks.items() if run != iid and t <= at <= self.fin[iid])
            took = self.fin[iid] - t - self.down_for(t, self.fin[iid]) - looks * do.TIMEOUT
            if took > SLOW:
                bad.append(f"slow confirm {iid}: row at {t - support.NOW:.1f}, confirmed at {self.fin[iid] - support.NOW:.1f}")
        tools = [i for i in store.intents(c.db, 500) if i["tool"] == "set_instructions"]
        has = self.page.projects["chan_b"]["settings"]["instructions"]
        for i in tools:
            if i["status"] in ("pending", "paused"):
                bad.append(f"tool stuck {i['id']}")
        # The newest confirmed tool's text is the field's, unless a newer one may have acted (failed unproved: either may be there).
        confirmed = [i for i in tools if i["status"] == "confirmed"]
        if confirmed:
            last = max(confirmed, key=lambda i: i["id"])
            text = (last["args"] or {}).get("text")
            newer = [i for i in tools if i["id"] > last["id"] and (i["result"] or {}).get("acted")]
            if not newer and has != text:
                bad.append(f"tool confirmed but not set {last['id']} {text!r} has {has!r}")
        return bad


def run(seed, more=False, steps=25):
    h = Harness(seed, more)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        for _ in range(steps):
            h.step()
        h.quiesce()
    return h, h.check()


class Fuzz(unittest.TestCase):
    def sweep(self, seeds, more):
        failures = {}
        for seed in seeds:
            h, bad = run(seed, more)
            if bad:
                failures[seed] = bad[:3] + ["  " + "; ".join(h.log)]
        self.assertEqual(failures, {})

    def test_random_disturbances_keep_the_invariants(self):
        self.sweep(SEEDS, more=False)

    def test_random_disturbances_with_renders_mounts_and_dialogs_keep_the_invariants(self):
        self.sweep(MORE_SEEDS, more=True)


if __name__ == "__main__":
    unittest.main()
