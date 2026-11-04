#!/usr/bin/env python3
"""Router POC: the long-running process. Standard library only.

  routerd.py            serve .build/router-poc/fjord.sock

The native host sends the page's events (EVENTS.md) as JSON lines and receives commands on the same connection. A debug client
(router.py) sends {"op": …} lines. Events become Seen rows and step the Board in memory, so a read never touches the page.
`Core` has no sockets and no timers of its own: the server feeds it events, calls `tick` at the next deadline, and tests do the same.
"""
import json
import math
import os
import queue
import secrets
import socket
import socketserver
import sys
import threading
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board as boards
import context
import decide
import do
import kwatch
import look
import page
import store
import tell

STATE = decide.STATE
SOCK = os.environ.get("FJORD_SOCK") or os.path.join(STATE, "fjord.sock")
DB = os.environ.get("ROUTER_DB") or os.path.join(STATE, "router.db")
DIALOG_OPEN = "a dialog is open"  # content.js's send step, when a settings dialog is open in the page
DEV_WAIT = 60  # seconds a dev_command op waits for the page's `done`
ACCEPTED_WAIT = 300.0  # how long a message the page took may stay queued behind a coordinator reply
KEEP_DAYS = 3  # chat and message rows older than this are dropped from Seen at start
REPLAY = 200_000  # at most this many of the newest Seen rows are replayed at start
CAP = 500  # facts and claims kept for the next tell
VANISHED = ("the tab reloaded right after the click, and the reloaded page doesn't show the words: the old page likely went before the "
            "server had them (not sent again)")
WENT = ("the page it was handed to went before it said what it did, and no row from you showed after: the words were likely lost with "
        "it, and were never confirmed (not sent again)")
NOTICE_FRESH = 15.0  # seconds: a page notice this recent is why words came back (the page gives up about 10.5 s after a 429 or 5xx)
WAKE_CAP = 30_000  # ms: the longest a page's `wake_me` is waited for
TAKE_WAIT = 2.0  # seconds after a click for the page to take the words; a hidden tab's page timers run at most once a second
RELOAD_LOSS = 3.0  # seconds after a reported click within which a page that goes can take the words with it (lost at ~0.1 s, measured);
# a page that goes later went after its pending row had time to reach the server, so it is waited for as any taken message
VANISH_GRACE = 1.0  # seconds a reloaded page's first rows of the place are given to render the rest, a margin of its own (content.js
# settles a chat SETTLE_GRACE after its fetch): a read marked `settled` can still lack the bottom (`PartialFirstRender`: a later
# `/timeline` fetch of the chat can bring it)
FRESH_AFTER = 2.0  # seconds after the tab arrived on a project that a send still waiting for its settled read opens it `fresh`, once: a
# chat whose rows the page never fetched since the arrival never settles (measured: a visit's one fetch ends ~0.33 s after the open, and
# a send that switches places waits ~1.0 s for its settled read (median), 1.7 s at worst)
RESUME = 600  # seconds: an intent left unfinished by a restart is picked up again only inside this window
RUNS = context.SENDS + do.TOOLS
# A tool run's stages, in order: start (show the place) -> act (sent once; a setting's act reads `before` itself) -> prove (read until it shows)
# -> look (at the deadline, one more read) -> confirmed or failed. Each stage opens the place at most once and reads at most once.
ACTED = ("act", "prove", "look")  # the act is in the page or done: never sent again
PROVING = ("prove", "look")  # the act is done: the run yields the composer to sends


def no_model(*_):
    raise RuntimeError("no model configured")


class Models:
    """The three calls that leave the process, so tests replace them."""
    def __init__(self, jev=no_model, sonnet=no_model, spawn=lambda fn: fn()):
        self.jev, self.sonnet, self.spawn = jev, sonnet, spawn


def trace(way, event):
    """FJORD_TRACE=1: every event with its time, without its words, for measuring and debugging on a live run."""
    if os.environ.get("FJORD_TRACE"):
        size = lambda v: len(v) if isinstance(v, (str, list)) else v
        words = ("draft", "text", "threads", "projects", "goal", "instructions", "repos", "folders", "offered_folders", "before", "name", "repo", "path", "error", "cause")
        short = {k: ([r.get("index") for r in v if isinstance(r, dict)] if k == "rows" and isinstance(v, list) else size(v) if k in words else v)
                 for k, v in event.items() if k != "path"}
        print(f"{time.time():.3f} {way} {json.dumps(short, default=str)}", file=sys.stderr, flush=True)


def carry_on(what, fn, *args):
    """One event or one tick that raises is logged and skipped: the next one still runs, and so do the deadlines."""
    try:
        return fn(*args)
    except Exception as e:
        print(f"{time.time():.3f} {what} failed: {e!r}", file=sys.stderr, flush=True)
        traceback.print_exc()


class Core:
    def __init__(self, db, out, models=None, clock=time.time, wake=lambda: None, uptime=time.monotonic):
        """`out(command)` sends one command down the socket. `wake()` says a deadline was added. `gone()` (set by the watcher) says the
        page went away: the watcher looks at Chrome again. `uptime()` is a clock that stands still while the Mac sleeps (macOS's
        monotonic clock), for a wait that sleep must not use up even with no run to notice the jump."""
        self.db, self.out, self.models, self.clock, self.wake, self.gone = db, out, models or Models(), clock, wake, lambda: None
        self.uptime = uptime
        self.lock = threading.RLock()
        self.runs, self.waiters, self.hosts, self.commands = {}, {}, 0, 0
        self.wakes = set()  # when the page's `wake_me`s are answered with a `wake`: every time asked, rounded up to 50 ms so close ones share one
        # Command ids name this start too: the page keeps and replays its latest `done`s, which a restarted routerd's own c1, c2… must not match.
        self.start_id = secrets.token_hex(3)
        self.last_done = {}  # document (`pages`) -> the newest of this routerd's commands whose `done` arrived from it (`unheard_sends`)
        # read_settings commands whose read arrived and whose run is over: the page is still closing their dialog. Each -> its deadline, at
        # which it is cancelled and let go (`tick`): a dialog that never closes doesn't hold the sends for good.
        self.closing = {}
        self.dev = {}  # dev commands (dev_command) -> the callback waiting for their `done`
        self.cut_old = set()  # commands of an earlier routerd start, waiting in the page, cancelled once
        self.stale_goal = {}  # project → a goal the server refused that the tab still shows (the page shows what was typed)
        self.chains = {}  # intent id -> the ids of the queued tool steps after it, in order
        self.notice = ("", 0.0)  # the page's latest notice and when it came
        self.last_send = {}  # place -> the newest send: words back in the draft belong to it alone
        self.reads = {}  # project -> how many settings reads the page has sent: a tool's read is the one that comes after its mark
        # The read commands whose `done` arrived, its settings handled (live: the `settings` event before it; or replayed): a snapshot
        # repeats the page's last `done`s, and an old read's settings handled again would count as a new read, or undo a goal's mark.
        self.reads_done = {}
        self.linked = 0  # how many commands were sent when a host last connected: the page's `commands` answers for those only
        self.moves = 0  # how many opens a run made to act or look, or taken sends that went back finished: a taken send goes back once per move
        self.back_due = False  # a taken send that went back finished: `advance_all` visits the other taken ones again
        self.lists = 0  # how many complete lists of the projects the page has sent: a create's look is the first after its mark
        # Sends that failed after a click (taken but never confirmed, stuck, VANISHED) -> until when a later row of yours confirms them
        # late: the server may have queued the words behind a coordinator's turn, which shows them only once it ends. The time is on
        # `uptime`, which stands still while the Mac sleeps: a sleep doesn't use up the watch, with or without a run to see the jump. The
        # intent's result keeps its end on the wall clock too (`watch`), so a restart watches it again for the rest of it.
        self.watched = {}
        # A watched send goes back to its place as a taken one does, once per move (`back_to_watched`): id -> `moves` when it last went.
        # The open in flight, if any: {"open", "to", "hold_until", "moving_from"}, which holds the other runs as a taken send's (`going_back`).
        self.watch_back, self.watch_open = {}, None
        # How many times the page was replaced: a `page` with another (`loaded`, `instance`), or a `gone` whose next `page` carries another
        # or none (one with the same pair is the same script back). A click belongs to one of them.
        self.pages = 0
        self.loaded = None  # the latest page's `loaded`
        # The latest page's `instance`: content.js's own run in the document. An extension reload keeps the document (its `loaded`) but
        # injects a fresh script whose `recent` starts empty, so a document is told by (`loaded`, `instance`). An old page sends none:
        # taken as another document every time.
        self.instance = None
        self.regone = False  # a `gone` came and no `page` since: the next one says whether the document was replaced
        # A host linked and no `page` since: a document replaced while none was linked is counted only at the next `page` (its `loaded`),
        # so a snapshot's sends to mark as never run (`replay`) wait for it to say the document is the one they were handed to.
        self.relinked, self.unran = False, []
        self.nopage = False  # a host linked and no event from it since: the page's health is unknown (`connection`)
        self.unwent = []  # runs whose send was dropped at a replay while `relinked`: went, or retried, once the next `page` says (`replay`)
        self.arrivals = 0  # how many times the tab showed another place (`arrive`)
        self.last_seen = None  # (wall clock, uptime) at the last check for a jump (`jump`)
        store.compact(db, clock() - KEEP_DAYS * 86400)
        rows, mark = store.seen(db, last=REPLAY), store.mark(db)
        self.acc = boards.start(mark)
        boards.fold_into(self.acc, [r for r in rows if r["id"] <= mark])
        before = boards.finish(self.acc)
        boards.fold_into(self.acc, [r for r in rows if r["id"] > mark])
        self.acc["health"] = {"connected": False, "signed_in": None, "page_ok": None}
        for p in self.acc["projects"].values():
            p.update(chat=None, draft=None, disabled=None, settings=None, turning=None, turn_state=None)
        for t in self.acc["threads"].values():
            t.update(messages=None, draft=None, disabled=None, turning=None, turn_state=None)  # rows from a past run can't be a baseline: the page sends what it shows on load
        self.chatted, self.last_local, self._board = store.chat_projects(db), None, None
        # Place (chat or thread) -> the keys of every row of it Seen holds, in the order they were last read (`remember`): the latest last.
        # A place with none hasn't been seen with rows: a chat never shrinks, so a full scan of none for one that has some is the page still
        # loading. A send's baseline holds the latest do.KNOWN of them (`do.baselined`): a first render can lack the bottom rows, and an old
        # one the next delta brings must not look new.
        self.known = {}
        for r in rows:
            if r["kind"] in ("chat", "messages") and r["fields"].get("messages"):
                self.remember(r["subject"], r["fields"]["messages"])
        # Places shown since the tab arrived on them whose whole read the page hasn't marked `settled`: a first render can lack the bottom
        # rows, and rows added while Fjord was away (or before a restart, which starts with no place shown) aren't among the stored keys,
        # so one of yours in the next delta would look new. No send is baselined there until a settled whole read comes.
        self.unsettled = set()
        self.arrived = (None, 0.0)  # (project, when) the tab last arrived on a project: a `fresh` open is due FRESH_AFTER past it (`stale`)
        # Place (project, thread) -> the keys of its rows that proved a send: one row proves one send. Rebuilt from the confirmed sends'
        # results (`row`), which persist it.
        self.claimed = {}
        for i in store.intents(db, -1, status="confirmed", columns=store.LEAN):
            if i["tool"] in context.SENDS and (i["result"] or {}).get("row"):
                self.claimed.setdefault((i["project"], i["thread"]), set()).add(i["result"]["row"])
        self.facts = {f["key"]: f for f in tell.facts(before, self.board())}
        self.trim()
        for i in sorted((i for s in ("pending", "paused", "queued") for i in store.intents(db, -1, status=s)), key=lambda i: i["id"]):
            if i["status"] in ("pending", "paused") and i["tool"] in context.SENDS:
                if self.clock() - i["at"] > RESUME or "baseline" in (i["proof"] or {}):
                    # One with a baseline issued a send (it is taken just before the first), whose click may have come with no `done`
                    # heard (routerd went just then): it may yet show the words, so it is watched as a send failed after a click is. A
                    # watch confirms only on a matching row no other send claimed, clicked or not: a replayed ok `done` changes nothing.
                    sent = "baseline" in (i["proof"] or {})
                    store.update_intent(db, self.clock(), i["id"], status="failed", cause="routerd restarted before the words were proved",
                                        **({"result": {**(i["result"] or {}), "watch": self.clock() + ACCEPTED_WAIT}} if sent else {}))
                else:
                    store.update_intent(db, self.clock(), i["id"], status="paused", cause="routerd restarted")
                    self.runs[i["id"]] = {"id": i["id"], "stage": "start", "t0": i["at"], "paused": True, "deadline": None, "ms": {}, "tool": False}
            elif i["status"] in ("pending", "paused") and i["tool"] in do.TOOLS:  # a tool is never acted on twice: what was done is read, not done again
                store.update_intent(db, self.clock(), i["id"], status="failed", cause="routerd restarted before the change was proved")
            elif i["status"] == "queued":  # its earlier step's run is gone
                store.update_intent(db, self.clock(), i["id"], status="refused", cause="routerd restarted before the step before it was confirmed")
        # A send failed after a click is watched again for the rest of its watch (on uptime from now), those the start failed too. Every
        # other failed one keeps only its proof's tail, as a finished send's does. The time it was updated stays: cutting it changes no outcome.
        for i in store.intents(db, -1, status="failed", columns=store.LEAN):
            until = (i["result"] or {}).get("watch")
            if i["tool"] in context.SENDS and isinstance(until, (int, float)) and until > self.clock():
                self.watched[i["id"]] = self.uptime() + until - self.clock()
        for i in store.long_proofs(db, do.KEPT):
            if i["id"] not in self.watched:
                store.update_intent(db, i["updated"], i["id"], proof=do.tail(i["proof"]))
        self.unproved = {i["id"] for i in store.intents(db, -1, status="failed", columns=store.LEAN) if i["tool"] in do.TOOLS and (i["result"] or {}).get("acted") and (i["result"] or {}).get("provable", True)}  # acted, never proved: a later read can confirm
        self.mark_goals()

    def mark_goals(self, project=None):
        """Each project's latest goal that was typed and not proved is marked: the tab, which a restart doesn't reload, may still show it."""
        if project:
            self.stale_goal.pop(project, None)
        for i in store.intents(self.db, -1, tool="set_goal"):
            if "acted" in (i["result"] or {}) and project in (None, i["project"]):
                if i["status"] in ("failed", "refused") and (not i["result"]["acted"] or i["result"].get("provable", True) is False):
                    self.stale_goal[i["project"]] = i
                else:
                    self.stale_goal.pop(i["project"], None)

    # ---- the Board in memory

    def board(self):
        """The Board as of the last event. Folded again only after a step."""
        with self.lock:
            if self._board is None:
                self._board = boards.finish(self.acc)
            return self._board

    def ingest(self, rows):
        """Appends Seen rows, steps the Board, and keeps the facts and claims the rows make for the next tell."""
        if not rows:
            return
        rows = store.add_seen(self.db, self.clock(), rows)
        threads = any(r["kind"] in ("thread", "app") for r in rows)
        before = self.board() if threads else None
        for r in rows:
            boards.step(self.acc, r)
        self._board = None
        if threads:
            self.facts.update({f["key"]: f for f in tell.facts(before, self.board())})
        self.trim()

    def trim(self):
        """The facts and claims waiting for a tell keep only the newest."""
        del self.acc["claims"][:-CAP]
        for key in list(self.facts)[:-CAP]:
            del self.facts[key]

    def claim_rows(self, project, messages):
        """What the project's coordinator said that Fjord hasn't seen. Chat seen for the first time is only a baseline."""
        seen, first = {c for p, c in self.acc["seen_claims"] if p == project}, project not in self.chatted
        return [look.row("coordinator", "claim", project, project=project, thread=None, key=m["key"], text=m["text"], decision=bool(m.get("decision")), baseline=first)
                for m in messages if m.get("from") == "claude" and boards.settled(m) and m.get("text") and m["key"] not in seen]

    # ---- events

    def handle(self, event):
        """One event from the page."""
        trace("up", event)
        with self.lock:
            self.jump(self.clock())
            if self.nopage and event.get("type") not in ("page", "done", "notice", "wake_me"):
                self.ingest([page.row("health", "page", page_ok=True)])  # an event from the content script: there is a page after all
            if event.get("type") not in ("done", "notice", "wake_me"):
                self.nopage = False
            if event.get("type") == "done":
                return self.done(event)
            if event.get("type") == "notice":  # the page's own message, kept to say why a send it gave up on failed
                self.notice = (str(event.get("text") or ""), self.clock())
                return
            if event.get("type") == "commands":
                return self.replay(event)
            if event.get("type") == "wake_me":
                return self.wake_me(event.get("after"))
            if event.get("type") == "page" and event.get("gone") is True:
                # The worker says the adopted page's port dropped (a reload, say): what was sent so far went to that page, so the next
                # page's `commands` answers for it, and one it doesn't list is dropped. Commands sent after this wait in the worker and
                # reach the next page before its snapshot does, so that snapshot lists them.
                self.linked = self.commands
                # A click reported just before went to that page, which may have gone before the server had the words: the next page's
                # rows of the place tell (`advance`: `vanished_at`). `reloaded` is when it went. A click older than RELOAD_LOSS isn't marked:
                # its words had time to reach the server, and a queued message is waited for as usual. A send still in the page when it
                # went keeps when (`gone_at`): if the next page's `commands` doesn't list it, it went with that page (`went`), which may
                # have typed and clicked it just then, so it is `reloaded` from then. One the next page still holds isn't.
                for run in self.runs.values():
                    if run["tool"]:
                        continue
                    if run.get("clicked") and self.clock() - run.get("click_at", float("-inf")) <= RELOAD_LOSS:
                        run["reloaded"] = self.clock()
                    if run["stage"] == "waiting" and self.in_page(run):
                        run["gone_at"] = (self.clock(), run["command"])
                # The page is counted as replaced at the next `page` only if its (`loaded`, `instance`) differs. An extension reload keeps
                # the document but not the script: the new one's `recent` knows nothing of the old one's sends.
                self.regone = True
            project, thread = page.place(event)
            self.arrive((project, thread) if project else None)
            if event.get("type") == "settings" and project:
                self.reads[project] = self.reads.get(project, 0) + 1
            if event.get("type") == "projects" and event.get("complete") is True:
                self.lists += 1
            rows = page.seen_rows(event)
            if event.get("type") == "rows" and rows:
                subject, messages = rows[0]["subject"], rows[0]["fields"]["messages"]
                if event.get("full") is True and event.get("settled") is True:  # the page's whole render of the place
                    self.unsettled.discard(subject)
                    self.read_whole((project, thread if event.get("side") == "thread" else None), event)
                # Its first rows, maybe not all of them yet, also for a place Fjord has seen (rows may have come while it was away). A
                # delta with rows comes only after a whole read (an empty chat's is settled), so it adds rows to a render already known;
                # a turning-only delta (no rows) may come before it, and the Board leaves the place's rows unread for it (`boards.step`).
                elif event.get("full") is True and messages:
                    self.unsettled.add(subject)
                if messages:
                    self.remember(subject, messages)
            if event.get("type") == "rows" and event.get("side") == "project" and project:
                claims = self.claim_rows(project, rows[0]["fields"]["messages"]) if rows else []
                self.ingest(rows + claims)
                if rows and rows[0]["fields"]["messages"]:  # a page shows no rows before its transcript mounts: that isn't having seen the chat
                    self.chatted.add(project)
            else:
                self.ingest(rows)
            loaded = event.get("loaded") if event.get("type") == "page" else None
            instance = event.get("instance") if event.get("type") == "page" else None
            # The same script as the latest page's: an event without `instance` (an old page) is never taken as the same.
            known = (isinstance(loaded, (int, float)) and loaded == self.loaded and instance is not None and instance == self.instance)
            # The first page since the host linked that comes from a document: content.js's always carries `loaded`; the worker's
            # page-less `page_ok: false` (no tab answered) carries none and defers it further. (fake_page sends no `loaded`.)
            if (event.get("type") == "page" and event.get("gone") is not True and self.relinked
                    and (loaded is not None or event.get("page_ok") is not False)):
                same = known and not self.regone
                unran, self.relinked, self.unran = self.unran, False, []
                if same:  # the snapshot came from the document its sends were handed to
                    self.mark_unran(unran)
                self.settle_unwent()
            if event.get("type") == "page" and event.get("gone") is not True and self.regone:  # the first page after a `gone`
                self.regone = False
                if not known:  # no (`loaded`, `instance`) to tell by: taken as another document
                    self.pages += 1
                if isinstance(loaded, (int, float)):
                    self.loaded, self.instance = loaded, instance
            elif isinstance(loaded, (int, float)) and (loaded, instance) != (self.loaded, self.instance):
                # another document or script: a host lost and back may hide a reload, or an extension reload
                self.pages += self.loaded is not None
                self.loaded, self.instance = loaded, instance
            if isinstance(loaded, (int, float)):  # a document loaded after a goal was marked shows the server's goals, not what was typed
                for p, marked in list(self.stale_goal.items()):
                    if loaded / 1000 > (marked.get("updated") or marked["at"]):
                        del self.stale_goal[p]
            if event.get("type") == "settings" and project:
                self.drop_stale_goal(project)  # the tab shows another goal now: the refused one is gone from it
            # The live runs first; the place's sends are judged together (`proved_at`), so a row of a watched send's words is its, not a
            # live run's, and reconcile_sends then confirms it.
            self.advance_all()
            if self.unproved and event.get("type") in ("settings", "projects"):
                self.reconcile(event["type"], project, complete=event.get("complete") is True)
            if self.watched and event.get("type") == "rows" and project:
                self.reconcile_sends((project, thread if event.get("side") == "thread" else None))

    def read_whole(self, place, event):
        """A settled whole read of a place came: a watched send's going back there is over, used (`release_watch`), and a look there
        knows its outcome (`look_read`): the run's next step ends it, the proof placed against this read. Only a read made after the
        look's open (the tab arrived since it went out, or its `done` came first): one from before is the render the look is there to
        refresh. Not one that shows a row of yours still pending, or the coordinator mid-turn: the server may hold your message
        queued, and the row may key moments later, so the look waits on to its end."""
        w = self.watch_open
        # An open for a place the tab already shows moves no tab: the page's own read after the send is the one it answers with.
        if w and w["to"] == place and (self.arrivals > w["open_from"] or not w["open"] or w["shown"]):
            self.release_watch(used=True)
        rows = event.get("rows") if isinstance(event.get("rows"), list) else []
        if event.get("turning") is True or any(isinstance(r, dict) and r.get("from") == "you" and r.get("pending") for r in rows):
            return
        for run in self.runs.values():
            if not run["tool"] and self.look_live(run) and (self.arrivals > run.get("open_from", self.arrivals) or run.get("look_done")
                                                              or (run.get("open") and run.get("open_shown"))):
                intent = store.intent(self.db, run["id"])
                if (intent["project"], intent["thread"]) == place:
                    run["look_read"] = True

    def remember(self, subject, messages):
        """A read's keys go to the end of the place's `known`, in index order: its tail is the rows read last, the latest."""
        keys = self.known.setdefault(subject, {})
        for m in sorted(messages, key=lambda m: m["index"]):
            keys.pop(m["key"], None)
            keys[m["key"]] = None

    def arrive(self, here):
        """The tab shows another place. What the Board held of the places on screen is from a past visit: the page sends it again in full,
        and until a whole read of it is `settled` it is unsettled, seen before or not: rows may have come while the tab was elsewhere,
        and a first render can lack them (the bottom ones). A thread opened or closed in the same project is no arrival on the project:
        the page keeps its chat rendered beside the thread, and content.js keeps the project side's settling too (its arrival is the
        address's path, `told.arrived`), so only the thread is read afresh. The page still sends the project's whole read again; one that
        isn't settled (a remounted transcript) makes it unsettled as any does."""
        if here == self.acc["here"]:
            return
        was, self.acc["here"], self._board = self.acc["here"], here, None
        self.arrivals += 1
        # The tab arrived somewhere after a taken send's open was done: its move is over, wherever it went, so it holds nobody, and the
        # timer (`next_deadline`) keeps no hold for it.
        w = self.watch_open
        if w and not w["open"] and w["moving_from"] is not None and w["moving_from"] != self.arrivals and not shows(self.acc, w["to"]):
            self.release_watch(used=False)  # the tab went elsewhere after its `done` (you moved it): its place wasn't read, it may go again
        for run in self.runs.values():
            if run.get("moving_to") and not run.get("open") and run.get("moving_from") is not None and run["moving_from"] != self.arrivals:
                run["moving_to"] = None
                run.pop("hold_until", None)
        if here:
            if not (was and was[0] == here[0]):
                self.unsettled.add(here[0])
                self.arrived = (here[0], self.clock())
                if here[0] in self.acc["projects"]:
                    self.acc["projects"][here[0]].update(chat=None, draft=None, disabled=None, turning=None, turn_state=None)
            if here[1]:
                self.unsettled.add(here[1])
                if here[1] in self.acc["threads"]:
                    self.acc["threads"][here[1]].update(messages=None, draft=None, disabled=None, turning=None, turn_state=None)

    def ready(self, board, place):
        """The tab shows the place and its rows and composer have arrived since. No rows at all for a chat that had some, or for a thread (it
        always has its opening message), is the page still loading: its composer can mount before its transcript. For a chat routerd
        hasn't seen, the page sends no rows only once its transcript mounted, its rows were fetched and it stayed empty since (content.js's
        `settledEmpty`: the page can mount it before its rows), so that empty baseline doesn't turn its history, rendered later, into news.
        Every place waits, after the tab arrived on it, for a whole read the page marks `settled` (its render done), since a first render
        can lack the bottom rows: the stored keys in the baseline don't cover rows added while the tab was elsewhere."""
        shown = boards.place_of(board, *place)
        rows = boards.rows_of(shown, place[1])
        subject = place[1] or place[0]
        return (shows(board, place) and rows is not None and (bool(rows) or (not place[1] and not self.known.get(place[0])))
                and subject not in self.unsettled and shown.get("draft") is not None)

    def stale(self, board, place):
        """For a project place the tab shows whose whole read hasn't settled since it arrived there: True once FRESH_AFTER has passed
        since that arrival, else the time it will have (a float). None for anything else: a thread (its side settles by the page's flushes,
        not by a fetch), a place not shown, or one settled."""
        project, thread = place
        if thread or project not in self.unsettled or not shows(board, place) or self.arrived[0] != project:
            return None
        due = self.arrived[1] + FRESH_AFTER
        return True if self.clock() >= due else float(due)

    def composes(self, board, project):
        """The tab shows the project and its composer has arrived since: where a tool starts. A tool acts in the settings dialog, not the
        chat, so it waits neither for the chat's rows nor for a settled read of them (`ready`)."""
        return shows(board, (project, None)) and (boards.place_of(board, project, None) or {}).get("draft") is not None

    def jump(self, now):
        """The clock jumped (the Mac slept): a deadline that is long past was not missed, so it moves on by a full wait, and a taken
        message's wait is pushed back with it. A send's watch after it failed after a click is on `uptime`, which a sleep doesn't move."""
        # The jump is seen against the last check too, not only a deadline: a taken run paused across the sleep (no deadline) has its
        # waits pushed back as well, or it would take its look at once when the page is back. The sleep is the wall clock's gap less
        # uptime's, so a long idle stretch while awake isn't one.
        up = self.uptime()
        (wall, was_up), self.last_seen = self.last_seen or (now, up), (now, up)
        gap = (now - wall) - (up - was_up)
        jumped = gap > do.TIMEOUT
        for run in self.runs.values():
            late = now - run["deadline"] if run["deadline"] is not None else 0
            # At least the sleep: a deadline only a little late (a taken send's long wait) has its waits moved by the whole sleep.
            shift = max(late + do.TIMEOUT if late > do.TIMEOUT else 0, gap if jumped else 0)
            if late > do.TIMEOUT:
                run["deadline"] = now + do.TIMEOUT
                if run.get("looking"):
                    run["looking"] = run["deadline"]
            elif shift:  # a sleep shorter than the lateness plus a wait: the deadline and the look's end move on by the sleep too
                for key in ("deadline", "looking"):
                    if run.get(key) is not None:
                        run[key] += shift
            if shift:
                for key in ("accepted", "vanished_at", "reloaded", "turn_seen", "grace", "click_at"):  # `grace`: the app's thread's wait
                    if run.get(key):
                        run[key] += shift
                for key in ("limit", "fresh_at", "hold_until", "relook_by"):  # its attempt's end, when its `fresh` open is due, its open's hold, a lost look's
                    if run.get(key):
                        run[key] += shift
                if run.get("gone_at"):  # when its page went: it becomes `reloaded` if the next page lost it (`went`)
                    run["gone_at"] = (run["gone_at"][0] + shift, run["gone_at"][1])
        if jumped and self.watch_open:  # a watched send's going back holds on across the sleep, as a run's open does
            self.watch_open["hold_until"] += gap
        if jumped and self.arrived[0] is not None:  # the page slept too: FRESH_AFTER for its settling counts from the wake (`stale`)
            self.arrived = (self.arrived[0], self.arrived[1] + gap)
        for id_, due in self.closing.items():  # a dialog's close waited on across the sleep gets its full wait too
            if now - due > do.TIMEOUT:
                self.closing[id_] = now + do.TIMEOUT

    def connection(self, up, current=True):
        """A native host connected or went away. `current`: the one leaving is the one commands go to (the latest linked). An older
        host whose socket closes after a newer one linked takes nothing with it: the commands since went to the newer one."""
        with self.lock:
            self.hosts = max(0, self.hosts + (1 if up else -1))
            if up or current or not self.hosts:
                self.settle_unwent()  # no `page` decided them: taken as gone with the page
            if up:
                self.linked, self.relinked, self.unran = self.commands, True, []
                self.send_wake()  # a wake due while no host was linked was dropped, and the page doesn't ask again: settling is idempotent
            if not up and (current or not self.hosts):  # a cancel lost with the host: a later snapshot listing the old command cancels it again
                self.cut_old.clear()
                if self.watch_open and self.watch_open["open"]:  # lost with the host: it moves no tab, and may go again
                    self.release_watch(used=False)
                for run in self.runs.values():  # a taken send's open lost with the host moves no tab: it holds nobody (`going_back`)
                    if not run["tool"] and self.yielded(run) and run.get("open"):
                        self.lost_open(run)
            if not self.hosts:  # a `done` lost with the host comes back in the page's next `commands`
                # Where the tab is, and what it showed, is unknown until the next host's events: each watched send may go back once more.
                self.watch_back.clear()
                self.watch_open = None
                # A goal the tab shows wrongly stays marked: a host lost isn't the tab reloaded, and the page keeps its copy of the goal.
                self.arrive(None)
                self.gone()
                for p in self.acc["projects"].values():
                    p.update(chat=None, draft=None, disabled=None, turning=None, turn_state=None)
                for t in self.acc["threads"].values():
                    t.update(messages=None, draft=None, disabled=None, turning=None, turn_state=None)
                self._board = None
            # At a link the health kept from before is stale (the page may be gone, and an open sent on it fails if the worker finds no
            # tab): the page can't be read until the worker's first event says whether there is one (`connectHost`), so a tick between
            # the two moves no run on a `page_ok: true` from the host before.
            self.ingest([page.row("health", "page", connected=self.hosts > 0, **({"page_ok": False} if up else {}))])
            self.nopage = up or (self.nopage and self.hosts > 0)
            if not up:
                self.advance_all()

    def connected(self):
        return self.hosts > 0

    def recheck_pauses(self):
        """Why a paused run waits, said again: Chrome may have started (its profile picker showing) since the reason was set."""
        with self.lock:
            why = do.blocked(self.board()["health"])
            for run in list(self.runs.values()):
                if run["paused"] and why:
                    intent = store.intent(self.db, run["id"])
                    if intent and intent["status"] == "paused" and intent["cause"] != why and not intent["cause"].startswith("waiting for the Claude app"):
                        store.update_intent(self.db, self.clock(), run["id"], cause=why)

    def replay(self, event):
        """The page's `commands`, sent with each snapshot: the ids still waiting in it, and the last `done`s it sent. A replayed `done` for
        a run's open or command that is still unanswered is handled now, as the late `done` it is (an ok send's is its click). A run's
        command sent before the host connected, or before the worker said the page was gone, that the page neither lists as waiting nor
        reported done (a reloaded page) is marked `dropped`: it no longer holds the tab (`in_page`). It stays unanswered. A send its run
        waits on reached a page (a send is made only while a host is linked) that may have typed and clicked it before it went: it is
        taken (`went`) and never sent again, at once (a paused one when it comes out of the pause), unless the document it was handed
        to says it never ran: then it is sent again (`went_or_retry`; after a new link, decided at the next `page`). A command an earlier routerd start sent that still waits has no run to answer for it: it is
        cancelled, so an old send can't click."""
        done = event.get("done") if isinstance(event.get("done"), list) else []
        for d in done:
            if isinstance(d, dict) and isinstance(d.get("settings"), dict):  # a read's `settings` event, lost while the port was muted
                self.replayed_settings(d)
            watched_open = self.watch_open and self.watch_open["open"]
            if isinstance(d, dict) and d.get("id") and (d["id"] in self.dev or d["id"] == watched_open or any(self.unheard(r, d["id"]) for r in self.runs.values())):
                self.done(d, replayed=True)
            self.closing.pop(d.get("id"), None) if isinstance(d, dict) else None
            self.typed_nothing(d)
            self.late_done(d)
        if isinstance(event.get("waiting"), list):
            self.closing = {k: v for k, v in self.closing.items() if k in event["waiting"]}  # a read's close the page no longer holds (a reloaded page) blocks nobody
            for old in [w for w in event["waiting"] if isinstance(w, str) and not w.startswith(f"c{self.start_id}.") and w not in self.cut_old]:
                self.cut_old.add(old)
                self.command("cancel", target=old)
            # Fewer than 20 `done`s is all this document has said: a send handed to it that it neither lists as waiting nor reported
            # done never ran, its cancel first, so it is no longer waited on (`unheard_sends`). Only for the document the send was
            # handed to (`send_pages`), which the snapshot may not come from: after a `gone`, or a host linked again (the tab may have
            # reloaded while none was), `pages` is counted at the next `page` that carries `loaded` (not the worker's page-less one), so the
            # marks wait for it to carry the same `loaded`.
            # Only from the script it was handed to (`send_scripts`): a new script's (an extension reload's) `done` list starts empty, and
            # proves nothing of an older one's sends. A snapshot without `instance` (an old page) proves nothing either.
            said = {d.get("id") for d in done if isinstance(d, dict)}
            script = event.get("instance")
            if len(done) < 20 and not self.regone and script is not None:
                unran = [(run["id"], id_) for run in self.runs.values() for id_ in run.get("sends", ())
                         if (self.seq(id_) or self.linked + 1) <= self.linked and id_ not in event["waiting"] and id_ not in said
                         and run.get("send_pages", {}).get(id_) == self.pages and run.get("send_scripts", {}).get(id_) == script]
                # So does a tool's act (the worker failed it, its `done` lost with the port): nothing was done (`tool_unran`).
                unran += [(run["id"], run["command"]) for run in self.runs.values() if run["tool"] and run["stage"] == "act" and run.get("command")
                          and (self.seq(run["command"]) or self.linked + 1) <= self.linked and run["command"] not in event["waiting"]
                          and run["command"] not in said and run.get("command_page") == (self.pages, script)]
                if self.relinked:
                    self.unran = unran
                else:
                    self.mark_unran(unran)
            # A taken send's open (its going back, or its look) sent before the page went that it neither lists nor reported done never
            # ran: the tab won't move for it, so it holds nobody (`going_back`). A look's own deadline still ends it.
            for run in self.runs.values():
                o = run.get("open")
                if (not run["tool"] and self.yielded(run) and o and (self.seq(o) or self.linked + 1) <= self.linked
                        and o not in event["waiting"] and o not in said):
                    self.lost_open(run)
            o = self.watch_open and self.watch_open["open"]  # a watched send's going back that never ran: as a taken send's (`lost_open`)
            if o and (self.seq(o) or self.linked + 1) <= self.linked and o not in event["waiting"] and o not in said:
                self.release_watch(used=False)
            lost = []
            for run in self.runs.values():
                sent = run.get("command") and (self.seq(run["command"]) or self.linked + 1) <= self.linked  # one sent since may not be listed yet
                if run.get("command") in event["waiting"]:  # the next page holds it: it didn't go with the page that went
                    run.pop("gone_at", None)
                if sent and run.get("answered") != run["command"] and run["command"] not in event["waiting"]:
                    if not run["tool"] and run["stage"] == "waiting" and not run["paused"] and run.get("dropped") != run["command"]:
                        lost.append(run)
                    run["dropped"] = run["command"]
            # A dev command sent before the page went (or before the host linked) that it neither lists nor reported done went with it:
            # its caller is told, and the sends it held go on.
            for id_ in [i for i in self.dev if (self.seq(i) or self.linked + 1) <= self.linked and i not in event["waiting"]]:
                self.dev.pop(id_)({"type": "done", "id": id_, "ok": False, "error": "the page went before it answered"})
            for run in lost:
                if run["id"] not in self.runs:
                    continue
                if self.relinked:  # the next `page` says whether the snapshot is of the document the send was handed to
                    run["went_due"] = True
                    self.unwent.append(run["id"])
                else:  # it reached a page (a send is made only while a host is linked), which may have clicked it, unless it never ran
                    self.went_or_retry(run)
        self.advance_all()

    def lost_open(self, run):
        """A taken send's open (its going back, or its look) that never reached a page: the tab won't move for it, so it holds nobody
        (`going_back`). A look's open is sent again, once (`relooked`), with a fresh wait, when it is next advanced with a host linked;
        a second lost one leaves the look to its deadline. A going back may go again (`back`)."""
        run["open"], run["moving_to"], run["look_read"], run["look_done"] = None, None, False, False
        run.pop("hold_until", None)
        if not run.get("looking"):
            run["back"] = None
        elif not run.get("relooked"):  # it is sent again by `relook_by`, when a host is linked by then
            run["looking"], run["relooked"], run["deadline"], run["relook_by"] = None, True, self.clock(), self.clock() + do.TIMEOUT

    def went_or_retry(self, run):
        """A send dropped from the page it was handed to: one that document says never ran (`mark_unran`) is made again, typed again if
        no click was reported; any other went with it (`went`)."""
        run.pop("went_due", None)
        if run["command"] in run.get("unran", ()):
            self.never_ran(run)
        else:
            self.went(run)
        self.safely(run)

    def never_ran(self, run):
        """A send its document says never ran (`mark_unran`): no attempt used. The same attempt goes on (`ignored`), made again with a
        fresh wait of its own."""
        run.pop("gone_at", None)
        run["stage"], run["deadline"], run["ignored"], run["limit"] = "start", None, True, self.clock() + do.TIMEOUT
        store.update_intent(self.db, self.clock(), run["id"], cause=None)

    def settle_unwent(self):
        """The sends `replay` dropped while relinked, decided now that the next `page` came (its never-ran marks made or not)."""
        unwent, self.unwent = self.unwent, []
        for run_id in unwent:
            run = self.runs.get(run_id)
            if run is not None and run.get("went_due"):
                self.went_or_retry(run)

    def mark_unran(self, unran):
        """[(run id, send id)]: sends the document they were handed to says never ran (`replay`)."""
        for run_id, id_ in unran:
            run = self.runs.get(run_id)
            if run and run["tool"]:
                if run["stage"] == "act" and run.get("command") == id_:
                    self.tool_unran(run)
                continue
            if run_id in self.runs:
                self.runs[run_id].setdefault("heard", set()).add(id_)
                self.runs[run_id].setdefault("unran", set()).add(id_)

    def tool_unran(self, run):
        """A tool's act the document it was handed to says never ran (`replay`: the worker failed it, its `done` lost): as an act that
        erred before its one change (`ok: false`, not `committed`), nothing was done, and a goal typed nowhere marks no stale goal."""
        intent = store.intent(self.db, run["id"])
        run["command"] = None
        self.keep(run, acted=False, **({"provable": True} if intent["tool"] == "set_goal" else {}))
        self.finish(run, "failed", "the page never ran the step: it went before it said what it did")

    def replayed_settings(self, d):
        """A replayed read's settings, handled only for a read still unheard (a tool's command or a dev command no `done` answered yet)
        and only once: an old read's settings repeated by each snapshot would bump the reads (a tool's proving read would be this old
        one) and drop a goal's mark. Only what a settings read does is done: no arrival (the event's place is the read's, not the tab's
        now), and the runs advance after the snapshot as a whole."""
        id_ = d.get("id")
        if not isinstance(id_, str) or id_ in self.reads_done or not (id_ in self.dev or any(r["tool"] and self.unheard(r, id_) for r in self.runs.values())):
            return
        self.read_heard(id_)
        event = {**d["settings"], "type": "settings"}
        project = page.place(event)[0]
        if not project:
            return
        self.reads[project] = self.reads.get(project, 0) + 1
        self.ingest(page.seen_rows(event))
        self.drop_stale_goal(project)
        if self.unproved:
            self.reconcile("settings", project)

    def read_heard(self, id_):
        """A read's `done` heard, its settings handled: kept for the newest CAP."""
        self.reads_done[id_] = None
        for old in list(self.reads_done)[:-CAP]:
            del self.reads_done[old]

    def drop_stale_goal(self, project):
        """A settings read that shows another goal than the refused one marked: the tab no longer shows it."""
        if project in self.stale_goal and not do.tool_proved(self.board(), self.stale_goal[project])[0]:
            del self.stale_goal[project]

    def late_done(self, d):
        """A tool's act that an earlier routerd start sent (or that its run was cut off from) and that failed unproved: the page's replayed
        `done` for it says what it did. A 2xx `saved` is the server's answer, so the act is confirmed (a goal's too: provable). A refusal
        before the change (`ok: false`, not `committed`) means nothing was done. `already` is `typed_nothing`'s. Its run is over: this
        changes the intent, never a run."""
        if not (isinstance(d, dict) and isinstance(d.get("id"), str)):
            return
        candidates = set(self.unproved) | {m["id"] for m in self.stale_goal.values()}
        for intent_id in candidates:
            intent = store.intent(self.db, intent_id)
            result = intent["result"] or {}
            if intent_id in self.runs or result.get("act") != d["id"] or not result.get("acted") or d.get("already") is True:
                continue
            goal = intent["tool"] == "set_goal"
            if d.get("ok") and isinstance(d.get("saved"), int) and 200 <= d["saved"] < 300:
                self.unproved.discard(intent_id)
                self.confirm_late(intent, "confirmed by the page's late report of its save", {"provable": True} if goal else None)
                if goal:
                    self.mark_goals(intent["project"])
            elif d.get("ok") is False and not d.get("committed"):
                self.unproved.discard(intent_id)
                store.update_intent(self.db, self.clock(), intent_id, result={**result, "acted": False, **({"provable": True} if goal else {})})
                if goal:
                    self.mark_goals(intent["project"])

    def confirm_late(self, intent, cause, result=None, **columns):
        """A tool that was done but not confirmed is confirmed after all. The steps it stopped are not run now: nobody waits on them any
        more, and they were checked against a board that has moved on. Their cause stops naming a failure that turned out not to be one."""
        store.update_intent(self.db, self.clock(), intent["id"], status="confirmed", cause=cause, result={**(intent["result"] or {}), **(result or {})}, **columns)
        n = (intent["result"] or {}).get("step", 1)
        for i in (intent["result"] or {}).get("stopped") or []:
            if store.intent(self.db, i)["status"] == "refused":
                store.update_intent(self.db, self.clock(), i, cause=f"step {n} ({intent['tool']}) was confirmed later, by a read; this step wasn't run")

    def typed_nothing(self, d):
        """A goal's act an earlier routerd start sent, which the page reports found it already so: nothing was typed, so its goal is no
        longer marked as one the tab may show unsaved (an older mark of that project's still holds)."""
        if not (isinstance(d, dict) and d.get("already") is True and isinstance(d.get("id"), str)):
            return
        for p, marked in list(self.stale_goal.items()):
            if (marked["result"] or {}).get("act") == d["id"]:
                result = {k: v for k, v in marked["result"].items() if k not in ("acted", "provable")}
                store.update_intent(self.db, self.clock(), marked["id"], result=result)
                self.mark_goals(p)

    def local(self, local):
        """One look at the local files. Rows are written only when they differ from the last pass."""
        with self.lock:
            if not local:
                return
            now = self.clock()
            known = [{"id": p["id"], "name": p["name"]} for p in self.board()["projects"].values() if p.get("where") == "cloud"]
            rows = look.local_rows(self.board(), local, known, now)
            key = json.dumps([[r["kind"], r["subject"], r["fields"]] for r in rows], sort_keys=True, default=str)
            if key != self.last_local:
                self.last_local = key
                self.ingest(rows)
                self.advance_all()

    # ---- do

    def next_id(self):
        return f"c{self.start_id}.{self.commands + 1}"

    def command(self, kind, **fields):
        command = {"id": self.next_id(), "kind": kind, **fields}
        self.commands += 1
        trace("down", command)
        self.out(command)
        return command["id"]

    def dev_command(self, kind, reply, **fields):
        """A dev step: sends one page command that belongs to no run and calls `reply` with its `done`. No intent, no proof. Sends and
        tool runs wait while it is in the page (`tool_busy`): it may have a dialog open. With no host linked nothing is
        sent and `reply` says so at once (returns None)."""
        with self.lock:
            if not self.connected():
                return reply({"ok": False, "error": "no host linked"})
            id_ = self.command(kind, **fields)
            self.dev[id_] = reply
            return id_

    def dev_cancel(self, id_):
        """Gives up on a dev command still waiting: the page is told to drop it, and its `done` is no longer waited for. Returns whether it
        was still waiting: false when its `done` already came."""
        with self.lock:
            if self.dev.pop(id_, None):
                self.command("cancel", target=id_)
                self.advance_all()  # the sends that waited for it go on
                return True
            return False

    def ms(self, run):
        return round((self.clock() - run["t0"]) * 1000)

    def start(self, intent, t0):
        """Begins delivering a pending send or tool. Anything else is already done."""
        with self.lock:
            if intent["status"] != "pending" or intent["tool"] not in RUNS:
                return self.settle(intent)
            self.add_run(intent, t0)
            self.advance_all()

    def add_run(self, intent, t0):
        run = {"id": intent["id"], "stage": "start", "t0": t0, "deadline": None, "paused": False, "ms": {"decided": round((self.clock() - t0) * 1000)},
               "tool": intent["tool"] in do.TOOLS}
        if run["tool"]:
            self.goto(run, "start")
        self.runs[intent["id"]] = run

    def yielded(self, run):
        """The run no longer needs the composer: a send the page took, or a tool whose act is done (it may still read to prove it)."""
        return run["stage"] in PROVING if run["tool"] else bool(run.get("taken"))

    def in_page(self, run):
        """The run's last command still waits in the page: not answered, not cancelled, and not missing from a reconnected page's list.
        A cancelled send keeps its `command`, so a click the page made before the cancel still lands as its `done`."""
        return bool(run.get("command")) and run["command"] not in (run.get("answered"), run.get("dropped"))

    def cancel_send(self, run):
        """A send still waiting in the page is cut off. The page sends no `done` for a cancelled send: it is `dropped`, out of the page. It
        stays the run's `command`, and among its `sends`: a click the page made before the cancel arrived still counts when its `done` comes."""
        cancel = self.command("cancel", target=run["command"])
        run["dropped"] = run["command"]
        run.setdefault("cuts", {})[run["command"]] = self.seq(cancel)  # its cancel's place in the order (`unheard_sends`)

    def went(self, run):
        """A send dropped with the page it was handed to (`replay`): that page may have typed and clicked it, and the server may have the
        words, so it is never sent again, not even click-only (the next page may show them in its draft, its saved draft). It is taken:
        its row proves it, or it fails as taken and is watched (`finish`). No page took this click: words back in a draft aren't one
        giving up."""
        self.clicked(run)
        run["taken"], run["click_page"], run["went"] = True, None, True
        # Dropped with a page that went (a reload: `gone`): the next page's settled rows tell, as after a click a reload may have lost
        # (`vanished_at`), so it fails about do.TIMEOUT after the page went. One dropped at a host's reconnect (no `gone`) waits ACCEPTED_WAIT.
        gone_at, command = run.pop("gone_at", None) or (None, None)
        if gone_at is not None and command == run.get("command") and run.get("reloaded") is None:
            run["reloaded"] = gone_at
        store.update_intent(self.db, self.clock(), run["id"], cause="the page it was handed to went before it said what it did")

    def clicked(self, run):
        """The run may have sent the words. A restart watches any send that issued one (its baseline), so this isn't kept."""
        run["clicked"] = True

    def unheard(self, run, id_):
        """A `done` the run still waits for: its open's, its tool command's, or one of the sends it issued that hasn't been heard from."""
        return id_ in (run.get("open"), run.get("command") if run["tool"] else None) or (id_ in run.get("sends", ()) and id_ not in run.get("heard", ()))

    def seq(self, id_):
        """A command's place in this routerd's order, or None for another's (an older routerd's, a page's own)."""
        head, _, n = str(id_ or "").rpartition(".")
        return int(n) if head == f"c{self.start_id}" and n.isdigit() else None

    def unheard_sends(self, run):
        """Sends the run issued that no `done` answered: a cut-off one may still have clicked, its `done` to come. The page runs commands in
        order, so once the `done` of a command after its cancel arrived from the document it was handed to, a cut-off send with none never
        ran: its cancel reached the page first. A later command's `done` alone says nothing: a send waits in the page while the page
        settles, and a dev command or a read may run meanwhile. A send never cut off is unheard until its `done`."""
        cuts, pages = run.get("cuts", {}), run.get("send_pages", {})
        return [id_ for id_ in run.get("sends", ()) if id_ not in run.get("heard", ())
                and not (cuts.get(id_) and id_ in pages and self.last_done.get(pages[id_], 0) > cuts[id_])]

    def acting(self, run):
        """The run has the tab: past its start, or it opened, or a command of its own is in the page. A send cut off (`cancel_send`) is out
        of the page, but isn't acting only when its caller also resets its stage to `start` (a hand-off to the coordinator, the app
        closing, a tool's dialog); one cut off to open its place again is `opening`, which acts."""
        return run["stage"] != "start" or run.get("opened") or (run.get("command") if run["tool"] else self.in_page(run))

    def look_live(self, run):
        """The run's look is under way: its `looking` is set and not passed."""
        return bool(run.get("looking")) and self.clock() < run["looking"]

    def looking_now(self, run):
        """Another run's look is under way (a taken send opened its place to read it once more, `looking` not yet passed): it holds the tab
        against every other run until it ends, at most until `looking`, so the row it waits for can show. A send made meanwhile would move
        the tab away, and the look would fail with the row in a place no longer shown."""
        return any(i != run["id"] and not o["tool"] and self.yielded(o) and self.look_live(o) for i, o in self.runs.items())

    def tab_held(self, run):
        """Another run has the tab: it hasn't yielded and is acting (it has opened, read or sent), or is paused with a command still in the
        page, or its look is under way (`looking_now`). Of two paused runs with commands in the page, the older goes first."""
        mine = self.in_page(run)
        if self.looking_now(run):
            return True
        return any(not self.yielded(o) and ((not o["paused"] and not o.get("lost") and self.acting(o)) or (o["paused"] and self.in_page(o) and not (mine and run["id"] < i)))
                   for i, o in self.runs.items() if i != run["id"])

    def safely(self, run, late=False):
        """One run's step. One that raises ends that run, so its waiter gets an outcome, and the other runs go on."""
        try:
            self.advance(run, late)
        except Exception as e:
            traceback.print_exc()
            if run["id"] in self.runs:
                self.finish(run, "failed", f"routerd error: {e!r}")

    def advance_all(self):
        """One tab, one composer: only the oldest run that hasn't yielded acts. A yielded run waits for its proof and blocks nobody. A run
        added during the pass (a tool step whose earlier step was just confirmed) is the newest, and is advanced in it too. A run coming
        out of a pause waits its turn while another run has the tab: opening its own place would move the tab under it. One that waited
        is visited again once a run finished or yielded in the pass (a newer one that held the tab may have let it go), until none does.
        So is every taken send once one that went back finished, or a run that had the tab let it go (`back_due`): it may go back now.
        Last, a watched send may go back (`back_to_watched`)."""
        acting, passed, held, freed = False, set(), set(), False
        while set(self.runs) - passed or (freed and held) or self.back_due:
            if not set(self.runs) - passed:  # the pass is over and a run let the tab go: the runs that waited for it are visited again
                taken = {i for i, r in self.runs.items() if not r["tool"] and self.yielded(r)} if self.back_due else set()
                passed, held, freed, self.back_due = passed - held - taken, set(), False, False
                acting = any(not self.yielded(r) and not r.get("paused") and not r.get("lost") and not r.get("open_wait") for i, r in self.runs.items() if i in passed)
            for run_id in sorted(set(self.runs) - passed):
                passed.add(run_id)
                run = self.runs.get(run_id)
                if run is None or (acting and not self.yielded(run)):
                    continue
                if run.get("paused") and self.tab_held(run):
                    held.add(run_id)
                    continue
                was = self.yielded(run)
                self.safely(run)
                if run_id in self.runs and (run.pop("waits_tab", False) | bool(run.get("gated") or run.get("retry"))):  # waits for the tab: a pass that frees it comes back
                    held.add(run_id)
                lets_go = run_id not in self.runs or (self.yielded(run) and not was)
                freed = freed or lets_go
                if lets_go and not was:  # a run that had the tab let it go: the taken sends may go back now, before the watched ones
                    self.back_due = True
                # A run whose open was lost or erred (`lost`, `open_wait`) opens again at its deadline: until then it holds nobody back.
                acting = acting or (run_id in self.runs and not self.yielded(run) and not run.get("paused") and not run.get("lost") and not run.get("open_wait"))
        self.back_to_watched()

    def back_to_watched(self):
        """A watched send (failed after a click, `finish`) goes back to its place as a taken one does: the row that confirms it late comes
        only in a `rows` event of that place, and a tab that stays elsewhere would never read it. Once per move during its watch (it last
        went at another `moves`), behind every live run: only while no run acts, is about to, or has an open or a look in the page, and
        every taken send that may go back has (the tab idle, as for a taken send's going back), and no tool or dialog may use the page.
        It only opens the place: an open never types or clicks. Its going back is no move: a taken send whose place it leaves goes back
        to it once it is over (as after a move), and no other watched send goes back for it."""
        if not self.watched or self.watch_open or not self.connected() or do.blocked(self.board()["health"]) or self.tool_busy():
            return
        board = self.board()
        for o in self.runs.values():
            if o["paused"] and not self.in_page(o):
                continue
            if o["tool"] or not self.yielded(o) or self.look_live(o) or o.get("open") or o.get("moving_to"):
                return
            i = store.intent(self.db, o["id"])
            if o.get("back") != self.moves and not shows(board, (i["project"], i["thread"])):  # its own going back comes first
                return
        for intent_id in sorted(self.watched):
            if self.watch_back.get(intent_id) == self.moves:
                continue
            i = store.intent(self.db, intent_id)
            place = (i["project"], i["thread"])
            # Shown with its rows read since the tab arrived: a row of yours comes in its `rows` events. A project shown beside a thread
            # whose own rows weren't read again on arrival isn't: the open reads them.
            if shows(board, place) and boards.rows_of(boards.place_of(board, *place), i["thread"]) is not None:
                continue
            self.watch_back[intent_id] = self.moves
            for o in self.runs.values():  # a taken send whose place the tab leaves for this goes back to it once this is over
                theirs = store.intent(self.db, o["id"])
                if not o["tool"] and shows(board, (theirs["project"], theirs["thread"])):
                    o["back"] = None
            self.watch_open = {"open": self.command("open", project=i["project"], thread=i["thread"]), "to": place, "id": intent_id,
                               "hold_until": self.clock() + do.TIMEOUT, "moving_from": None, "open_from": self.arrivals,
                               "shown": shows(board, place)}
            return self.wake()

    def deadline(self, run):
        run["deadline"] = self.clock() + do.TIMEOUT
        self.wake()

    def taken(self, run, board, place):
        """The page took the words: Send was clicked and the draft is empty now."""
        shown = boards.place_of(board, *place)
        return bool(run.get("clicked") and shows(board, place) and shown is not None and shown.get("draft") is not None and not boards.squash(shown["draft"]))

    def returned(self, board, place, intent):
        """The words are back in the draft after the page took them."""
        shown = boards.place_of(board, *place)
        return shows(board, place) and shown is not None and boards.loose(shown.get("draft")) == boards.loose(intent["words"])

    def release_watch(self, used):
        """A watched send's going back is over. `used`: it counts for this move (a settled whole read of its place came, the page failed
        its open, or its hold ran out); else (superseded, lost with the host or a dropped page, the tab gone elsewhere before the read) it
        may go back again."""
        w, self.watch_open = self.watch_open, None
        if w and not used:
            self.watch_back.pop(w["id"], None)

    def taken_failed(self, run):
        """A taken send's end with no row from you: the cause says what is known of it. It is watched (`finish`)."""
        if run.get("stuck"):  # the draft emptied after a click that had left the words there: a navigation may have dropped them
            return self.finish(run, "failed", "the words stayed in the draft after a click, then the draft emptied with no row from you: "
                                              "the page may not have sent them, and they were never confirmed")
        if run.get("went"):  # dropped with a page that went: no page said it took them
            return self.finish(run, "failed", WENT)
        if run.get("vanished_at") is not None:
            return self.finish(run, "failed", VANISHED)
        return self.finish(run, "failed", "the page took the words but never confirmed them")

    def await_proof(self, run, intent):
        """The page took the words, or shows a row from you: never send again. Wait for the row; at ACCEPTED_WAIT open the place once, so a
        full scan can prove it, then fail. One whose words a reload lost (`vanished_at`) ends do.TIMEOUT after the page went (`reloaded`), or
        VANISH_GRACE after the reloaded page's rows showed it when that is later (a first render may not hold the bottom yet), rather
        than at ACCEPTED_WAIT: it fails then with no look while the tab shows the place (the reloaded page's rows were fetched afresh,
        and its stream delivers a later row of yours), and takes the look's open only when another run moved the tab away. A later row
        of yours still confirms it late (`reconcile_sends`)."""
        now = self.clock()
        run["accepted"] = run.get("accepted") or now
        end = run["accepted"] + ACCEPTED_WAIT
        # Not while the coordinator is mid-turn: the server may hold the words queued behind it, so the reloaded page shows no row yet.
        # Once it ends the queued row gets a full wait to show: `turn_seen` is the last look that saw the turn, or the first after it.
        turning = do.turning(self.board(), intent["proof"])
        if turning or run.get("turn_on"):
            run["turn_seen"] = now
        run["turn_on"] = turning
        early = run.get("vanished_at") is not None and not turning
        if early:
            waits = (run["vanished_at"] + VANISH_GRACE, run["reloaded"] + do.TIMEOUT, (run.get("turn_seen") or 0) + do.TIMEOUT)
            end = min(end, max(waits))
        place = (intent["project"], intent["thread"])
        if now < end:
            if run.get("looking"):  # its end moved on (the look found the coordinator mid-turn): the look is over, it holds nobody
                run["looking"], run["relooked"] = None, False  # a look taken again after this one has its own retry if its open is lost
                if not run.get("open"):  # an open still in the page holds until its `done` (`going_back`)
                    run["moving_to"] = None
                    run.pop("hold_until", None)
            run["deadline"] = end
            # Another run took the tab away before the row came (a tool's read, a send elsewhere): once the tab is idle, go back at once,
            # so the row proves it now rather than at the look. Idle means every other run is a send the page took: a tool, even one
            # whose act is done, may still open its project to read.
            # A paused run with no command in the page (waiting for the Claude app, say) leaves the tab idle too.
            # It goes back once per time a run moved the tab (another send's going back doesn't count, so two never take turns).
            # Only with a host linked: an open sent with none is lost, and would use up the going back.
            # Not while another run is about to act (unpaused, not yielded: queued behind none, it moves the tab anyway): its move lets
            # this one go back after it.
            # Nor while a watched send's going back is in flight (`back_to_watched`): it goes back once that is over.
            if (self.connected() and not shows(self.board(), place) and run.get("back") != self.moves and self.tab_idle(run)
                    and not self.about_to_act(run) and not self.watch_open):
                # Several taken sends going back in one pass supersede each other's opens (the newest wins); the others go back on `back_due`.
                run["back"], run["moving_to"], run["hold_until"] = self.moves, place, now + do.TIMEOUT
                run["open_from"], run["open_shown"] = self.arrivals, shows(self.board(), place)  # an arrival after this, before its `done`, ends the move at the `done`
                run["open"] = self.command("open", project=intent["project"], thread=intent["thread"])
            return self.wake()
        board = self.board()
        lost = WENT if run.get("went") else VANISHED
        if early and shows(board, place) and do.anchored(board, intent["proof"]):  # rows read afresh: no look
            return self.finish(run, "failed", lost)
        if run.get("looking") is None:
            # With the page away (Chrome closed, signed out, no host) no look can be taken: it fails at its bound, watched as any
            # taken send that failed, so a later row of yours still confirms it (`reconcile_sends`), and nobody waits past the bound.
            if do.blocked(self.board()["health"]) or not self.connected():
                if now < run.get("relook_by", 0):  # a look lost with the host is sent again if one links within a wait (`lost_open`)
                    run["deadline"] = run["relook_by"]
                    return self.wake()
                return self.taken_failed(run)
            if not self.tab_idle(run):  # another run is using the tab, or a tool may read
                return self.deadline(run)
            if self.watch_open:  # a watched send's going back is in flight: the look goes once it is over (its read, or its hold)
                run["deadline"] = self.watch_open["hold_until"]
                return self.wake()
            run["looking"], self.moves, run["moving_to"] = now + do.TIMEOUT, self.moves + 1, place
            run["hold_until"], run["open_from"], run["look_read"], run["look_done"] = now + do.TIMEOUT, self.arrivals, False, False
            run["open_shown"] = shows(board, place)
            run["open"] = self.command("open", project=intent["project"], thread=intent["thread"])
            run["deadline"] = run["looking"]
            return self.wake()
        # The look ends at its end, or once its open is done and a settled whole read of the place came after it with no row from you
        # (`look_read`, set in `handle`; the proof was checked against it before this): the outcome is known, and the tab is let go.
        if now >= run["looking"] or (run.get("look_read") and not run.get("open")):
            return self.taken_failed(run)

    def about_to_act(self, run):
        """Another run, not paused and not yielded, will take the tab: it acts now or once the ones ahead of it let go."""
        return any(not o["paused"] and not self.yielded(o) for i, o in self.runs.items() if i != run["id"])

    def going_back(self, run):
        """Another run's open is in the page for a send the page took (its going back, or its look): the tab is about to move there, so
        a run that checks or acts on the place the Board shows now waits for it. The open's `done` can come before the tab says it arrived (normally the arrival's `page`
        comes first; a muted port's replay, or the fake page, sends the `done` first): after an ok one it waits on until the tab arrives somewhere (`arrivals`): that place, or another (you moved the tab).
        Each event advances the runs. It holds at most do.TIMEOUT from the open's sending, then from its `done` (`hold_until`): an open
        the page dropped, or a tab that never arrived, holds nobody for longer (`next_deadline` wakes the runs then)."""
        board = self.board()
        w = self.watch_open
        if w and self.clock() < w["hold_until"]:  # a watched send's going back holds until its place's settled whole read (`handle`)
            return True
        for i, o in self.runs.items():
            if i == run["id"] or o["tool"] or not self.yielded(o) or self.clock() >= o.get("hold_until", float("inf")):
                continue
            to = o.get("moving_to")
            if o.get("open") or (to and o.get("moving_from") == self.arrivals and not shows(board, to)):
                return True
        return False

    def tab_idle(self, run):
        """No other run may move the tab: each is a send the page took, paused with no command in the page, or not acting (queued behind
        the runs that are, it moves nothing until they let the tab go)."""
        return all((self.yielded(o) and not o["tool"] and not self.look_live(o)) or (o["paused"] and not self.in_page(o)) or not self.acting(o)
                   for i, o in self.runs.items() if i != run["id"])

    def advance(self, run, late=False):
        """The next small step for one run, from the Board and the events so far. `late`: its deadline passed."""
        intent = store.intent(self.db, run["id"])
        if intent["status"] in do.DONE:
            self.runs.pop(run["id"], None)
            return
        if run["tool"]:
            return self.advance_tool(run, intent, late)
        if run.get("went_due"):  # its dropped send is decided at the next `page` (`settle_unwent`)
            return
        board = self.board()
        # Nothing reached the thread while no click was reported and nothing was taken: a reply may still go to the coordinator instead.
        gone = do.stranded(board, intent) if intent["thread"] and not run.get("clicked") and not run.get("taken") else None
        if gone and run.get("app"):  # the app is back but the thread isn't yet: it gets one full wait to come back too
            if run.get("grace") is None:
                run["grace"] = run["deadline"] = self.clock() + do.TIMEOUT
                return self.wake()
            if self.clock() < run["grace"]:
                return
        if gone:
            if self.in_page(run):  # a send to the thread may still wait in the page
                self.cancel_send(run)
            # The sends so far went to the dead thread: a click of one reported after this doesn't make the coordinator's send click-only.
            run["app"], run["grace"], run["sends"] = None, None, []
            run["stage"] = "start"  # an open of the thread may be under way: the project is the place now
            intent = self.hand_off(intent, gone)
        refused = do.refusal(board, intent)
        if refused:
            # One the page may have sent (a click reported, taken, or a send not heard from) failed: a later row of yours may still
            # confirm it (`watched`). Only one that surely never reached the server is refused.
            may_have = run.get("clicked") or run.get("taken") or self.unheard_sends(run)
            return self.finish(run, "failed" if may_have else "refused", refused)
        place = (intent["project"], intent["thread"])
        holds = False
        if "baseline" in intent["proof"]:
            holds, cause, key = self.proved_at(place, intent)[run["id"]]
            if holds and not cause:
                return self.finish(run, "confirmed", row=key)
            # A row from you with other words after the baseline (you typed in the chat meanwhile): a run that never clicked and isn't
            # taken has nothing of its own to wait for, so it fails now. One that may have sent keeps the cause and waits for its row: so
            # does one with a cut-off send not heard from, which may have clicked before the cancel reached it. A send still waiting in
            # the page is cancelled by the failure instead (and watched, `finish`).
            cut_off = [i for i in self.unheard_sends(run) if not (i == run.get("command") and self.in_page(run))]
            if holds and not run.get("clicked") and not run.get("taken") and not cut_off:
                return self.finish(run, "failed", cause)
            if holds and intent["cause"] != cause:
                intent = store.update_intent(self.db, self.clock(), run["id"], cause=cause)
            # Each read placed against the baseline anchors Claude's rows after it: a busy chat's window can scroll past
            # the baseline (a coordinator's long turn while your message is queued), and a later read is placed by them.
            anchored = do.anchor(board, intent["proof"]) if not holds else intent["proof"]
            if anchored is not intent["proof"]:
                intent = store.update_intent(self.db, self.clock(), run["id"], proof=anchored)
        if self.taken(run, board, place):
            run["taken"] = True
        # The tab reloaded right after a reported click: whatever the new page shows, the old one may have given the server the words, so
        # the run is taken, sends nothing more (not even click-only) and only waits for its row. Words back in a reloaded page's draft are
        # its saved draft, not the page giving up.
        if run.get("reloaded") and run.get("clicked"):
            run["taken"] = True
        # The page gave up: it puts the words back, so nothing was sent. Only the page that took the click does: a page that replaced it
        # (a reload, maybe while no host was linked) shows its saved draft. A replayed click proves no page: it leaves `click_page` as it
        # was (an earlier live click's, or none).
        elif (run.get("taken") and run["command"] == self.last_send.get(place) and run.get("click_page") == self.pages
              and self.returned(board, place, intent)):
            run["taken"], run["clicked"], run["ignored"], run["accepted"], run["stuck"], late = False, False, False, None, False, True
            text, at = self.notice
            said = f": {text}" if text and self.clock() - at < NOTICE_FRESH else ""
            intent = store.update_intent(self.db, self.clock(), run["id"], cause=f"the page couldn't send it{said}")
        # The tab reloaded after the click, and the new page's rows of the place, read from the server and placed against the baseline,
        # hold no row from you after it: the old page went before the server had the words. Never sent again (the server may yet have
        # them): the look comes sooner, and the failure says why. Only a whole read the page marked `settled` says so: one that isn't
        # can lack the bottom rows, the run's among them.
        if (run.get("reloaded") and not holds and run.get("vanished_at") is None and shows(board, place)
                and (intent["thread"] or intent["project"]) not in self.unsettled and do.anchored(board, intent["proof"])):
            run["vanished_at"] = self.clock()
        if run.get("taken") or holds:  # the page took the words, or shows a row from you. It queues them while the coordinator replies.
            return self.await_proof(run, intent)
        why = (do.app_wait(board, intent) if intent["thread"] else None) or do.blocked(board["health"])
        if why == do.APP_CLOSED:  # the page is up and would click: a send still waiting in it is cut off
            run["app"], run["grace"] = True, None
            if self.in_page(run) and run["stage"] == "waiting":
                self.cancel_send(run)
                run["stage"] = "start"
        if why:
            run["paused"], run["deadline"] = True, None
            return self.mark(intent, "paused", why)
        if run["paused"]:  # a lost open is behind it too: its deadline was dropped with the pause
            run["paused"], run["lost"], late = False, False, False
            run["stage"] = "start" if run["stage"] == "opening" else run["stage"]
            self.mark(intent, "pending", None)
            if run["stage"] == "waiting" and run.get("dropped") == run["command"]:  # its send went with a page that is gone (`replay`)
                if run["command"] in run.get("unran", ()):  # unless that page says it never ran: it is made again, in the same attempt
                    self.never_ran(run)
                    late = True
                elif self.relinked and (run["id"], run["command"]) in self.unran:  # the next `page` says if it was that page
                    run["went_due"] = True
                    self.unwent.append(run["id"])
                    return
                else:  # taken now: the run's checks are made again, out of the pause (a row may prove it), and the taken one waits for its proof
                    self.went(run)
                    return self.advance(run)
            if run["stage"] == "waiting":
                self.deadline(run)
        if run.get("lost"):  # its open was superseded by another run's: it opens again at its deadline, not against that run
            if not late:
                return
            run["lost"] = False
        held = (run.get("held") and not self.tool_busy()) or (run.get("retry") and not self.tab_held(run))
        if run["stage"] == "waiting" and not late and not held:
            return
        run["held"] = run["retry"] = False
        run["gated"] = self.tool_busy()
        if run["gated"]:  # a tool's dialog may be open in the page: nothing is typed or opened until it ends, which advances this run at once
            if self.in_page(run) and run["stage"] == "waiting":
                run["ignored"] = True  # not tried: the same attempt goes on (a click reported already made it so)
                self.cancel_send(run)
                run["stage"] = "start"
            elif run["stage"] == "waiting":  # its retry is due (TAKE_WAIT, a deadline) with nothing in the page: the gate's end makes it
                run["held"] = True
            elif run["stage"] == "opening":  # its open would move the tab under the dialog: it opens again, with a full wait, once it ends
                if run.get("open"):
                    self.command("cancel", target=run["open"])
                    if run["open"] == run.get("fresh_open"):  # the fresh open never ran: the next open may ask for it again
                        run["fresh"] = False
                    run["open"] = None
                run["stage"] = "start"
            return self.deadline(run)  # only a wake-up: at it the run is gated again, or goes on
        if run["stage"] == "opening" and late:  # the tab showing the place with its whole read never settled is another failure
            unsettled = shows(board, place) and (intent["thread"] or intent["project"]) in self.unsettled
            return self.finish(run, "failed", intent["cause"] or ("the page never settled on that place" if unsettled else "the page never showed that place"))
        # A taken send's open will move the tab (`going_back`): the place the Board shows is about to change. Its `done` advances this run.
        # So does another taken send's look under way: it holds the tab until its end (`looking_now`), which advances this run.
        if (run["stage"] != "waiting" or late or held) and (self.going_back(run) or self.looking_now(run)):
            run["waits_tab"] = True  # a pass in which the look ends, or the open is done, comes back to it (`advance_all`)
            return self.deadline(run) if run["deadline"] is None else None
        # A send held by a dialog goes on only to a place still ready: the tool may have moved the tab.
        if (run["stage"] != "waiting" or late or held) and not self.ready(board, place):
            # A project shown but never settled since the tab arrived on it, FRESH_AFTER on: the page may never have fetched its rows
            # this visit (a script injected into a long-lived tab, a re-open served from the page's cache), so the open asks the page
            # to make it (`fresh`: content.js leaves for `/code` and comes back, when it has seen no fetch since the arrival).
            # Once a run: one that still never settles fails at its deadline as before.
            stale = None if run.get("fresh") else self.stale(board, place)
            if run["stage"] != "opening" or stale is True:
                if self.in_page(run):  # its send may still wait in the page, and would click behind the next one
                    self.cancel_send(run)
                fresh = {"fresh": True} if stale is True else {}
                run["fresh"] = run.get("fresh") or stale is True
                if run["stage"] != "opening":
                    self.moves += 1
                self.deadline(run)  # a fresh open gets its own full wait too
                run["stage"], run["open"] = "opening", self.command("open", project=intent["project"], thread=intent["thread"], **fresh)
                if fresh:
                    run["fresh_open"] = run["open"]
            if isinstance(stale, float):  # not due yet (a time, not True): a timer comes back to it (`next_deadline`, `tick`)
                run["fresh_at"] = stale
                self.wake()
            return
        run["fresh_at"] = None  # the place settled first: no `fresh` open is due
        proof = do.baselined(board, intent["proof"], self.known.get(intent["thread"] or intent["project"], ()))
        if proof is not intent["proof"]:
            intent = store.update_intent(self.db, self.clock(), run["id"], proof=proof)
            if not intent["thread"]:  # Fjord has seen this chat: what comes after its send is news, even if it was empty
                self.chatted.add(intent["project"])
        if run.get("clicked") and self.returned(board, place, intent):  # a reported click left the words in the draft
            run["stuck"] = True
        # A click the page reported but ignored is clicked again within the same attempt: that attempt's deadline stays the limit. A new
        # attempt is a send with no click reported, or a retry after the deadline or after the page erred.
        again = run.get("ignored") and self.clock() < run.get("limit", 0)
        if not again:
            if intent["attempts"] > do.RETRIES:
                return self.finish(run, "failed", intent["cause"] or "the words never showed up")
            intent = store.update_intent(self.db, self.clock(), run["id"], status="pending", attempts=intent["attempts"] + 1, cause=None)
            run["limit"] = self.clock() + do.TIMEOUT
        side = "thread" if intent["thread"] else "project"
        # After a reported click the page may still take the words late: the retry only clicks words already in the draft, and any later
        # empty draft counts as taken, so the words are never typed twice. The page refuses a send while the tab shows another place.
        run["stage"], run["ignored"], clicks = "waiting", False, {"click_only": True} if run.get("clicked") else {}
        # `intent`: whose send it is. The page treats a send that finds the draft empty right after a click of the same intent's words there as
        # a retry that crossed that click's `done`: it never types (another intent's same words, sent after the first was proved, do).
        run.pop("gone_at", None)  # kept for the send in the page when it went, not this one
        run["command"] = self.last_send[place] = self.command("send", side=side, text=intent["words"], project=intent["project"], thread=intent["thread"], intent=run["id"], **clicks)
        run.setdefault("sends", []).append(run["command"])  # every send the run issued: a click of an older one, reported late, still counts
        run.setdefault("send_pages", {})[run["command"]] = self.pages  # the document it was handed to (`replay`)
        run.setdefault("send_scripts", {})[run["command"]] = self.instance  # and the script in it
        run["deadline"] = run["limit"]
        self.wake()

    # ---- tools: the tab acts once, then reads the settings (or lists the projects) to prove it

    def keep(self, run, **result):
        """Adds to what the intent's result holds: `before` and `acted`."""
        intent = store.intent(self.db, run["id"])
        return store.update_intent(self.db, self.clock(), run["id"], result={**(intent["result"] or {}), **result})

    def issue(self, run, kind, **fields):
        run["command"] = self.command(kind, **fields)
        run["command_page"] = (self.pages, self.instance)  # the document and script it is handed to (`replay`)
        self.deadline(run)

    def goto(self, run, stage):
        """The run moves to its next stage. What the last stage sent, opened, read or cut off is behind it."""
        run.update(stage=stage, command=None, opened=False, mark=None, cut=False, open_wait=False, open_error=False)  # an erred open is the last stage's

    def reach(self, run, project, there=False):
        """`there`: the tab shows the place. Until it does, the place is opened, once per stage. The projects page counts as shown once
        its open is done, since nothing else says so."""
        if project is None:
            there = run["opened"] and not run["command"]
        if not there and not run["opened"] and not run["command"] and not run.get("open_wait"):  # `open_wait`: an erred open's deadline
            run["opened"], self.moves = True, self.moves + 1
            self.issue(run, "open", project=project, thread=None)
            run["reach_open"] = run["command"]  # its `done` is an open's (`tool_done`)
        return there

    def read(self, run, intent):
        """One read of the project's settings. The one that counts is the first to arrive after this."""
        run["mark"] = self.reads.get(intent["project"], 0)
        self.issue(run, "read_settings", project=intent["project"])

    def has_read(self, run, intent):
        """The stage's read has arrived."""
        return run["mark"] is not None and self.reads.get(intent["project"], 0) > run["mark"]

    def tab_free(self, run):
        """Reading shares the tab with the sends: it waits while another run is acting, or another tool's command is in the page (tool
        commands have no side: two reads, or a read and an act, would replace or disturb each other). A run that hasn't begun (at `start`,
        nothing sent, nothing opened) isn't acting, as in `tab_held`: a send that arrived meanwhile must not hold the read it waits behind."""
        return not self.tool_busy(run) and not self.going_back(run) and not self.looking_now(run) and not any(not self.yielded(o) and not o["paused"] and self.acting(o) for i, o in self.runs.items() if i != run["id"])

    def tool_busy(self, run=None):
        """A tool has the page's dialog open or may open it: a command of its own is in the page, or it opened its project to read and
        hasn't read yet (its open's `done` comes before the tab says it arrived: a run that yielded, in `prove`, may still be reading); or
        a dev command is in the page (it may have the settings dialog open). Words typed meanwhile could land in the dialog's fields:
        sends wait for it to end, and for a finished read still closing the dialog too. `run`: a tool asking about the others, which
        doesn't wait for a close (its own open closes a dialog left open)."""
        return (run is None and bool(self.closing)) or bool(self.dev) or any(
            o["tool"] and (self.in_page(o) or (o["stage"] in PROVING and o["opened"] and o["mark"] is None)) for o in self.runs.values() if o is not run)

    def advance_tool(self, run, intent, late):
        """A tool run: the tab shows the place, then the act is sent once. A setting's act reads what it changes first (kept as `before`), and
        the server's answer to its save proves it; with no answer, or for a create, a later read proves it. Once the act is sent it is never
        sent again: with no proof there is one more look, then `failed`."""
        board, project = self.board(), intent["project"]
        # Only a read after the act proves it, and never a goal's: the dialog shows the tab's copy of it, which may be what was typed.
        if run["stage"] in ACTED and intent["tool"] != "set_goal" and (not project or self.reads.get(project, 0) > run["acted"]):
            holds, cause = do.tool_proved(board, intent)
            if cause:
                return self.finish(run, "failed", cause)
            if holds:
                return self.finish(run, "confirmed", **({"project": do.created(board, intent["proof"])[0]} if not project else {}))
            if run["stage"] == "prove" and run.get("unsaved"):  # the page saw no save, and a read taken after the act lacks it: it didn't take
                return self.finish(run, "failed", run["act_error"])
        why = do.blocked(board["health"])
        if why:
            run["paused"], run["deadline"] = True, None
            return self.mark(intent, "paused", why)
        if run["paused"]:
            run["paused"], late = False, False
            self.mark(intent, "pending", None)
            if run["stage"] in ACTED:  # the act is in the page, or done: only the wait goes on
                self.deadline(run)
            else:
                if run["command"]:
                    self.command("cancel", target=run["command"])
                self.goto(run, "start")
        if late:
            return self.tool_late(run, intent)
        self.step_tool(run, intent)

    def step_tool(self, run, intent):
        """What the run's stage does next, from the Board and the events so far."""
        board, project, stage, create = self.board(), intent["project"], run["stage"], intent["tool"] == "create_project"
        if stage == "start" and self.tool_busy(run):  # another run's proving read is in the page: an open or act now would close its dialog under it
            return
        if stage == "start" and (self.going_back(run) or self.looking_now(run)):  # a taken send's open will move the tab, or its look
            run["waits_tab"] = True  # holds it (`looking_now`): its `done`, or the look's end in the same pass, advances this run
            return
        if stage == "start" and create:  # the projects page is where the New project dialog is
            taken = do.name_taken(board, intent["args"]["name"])
            if taken:
                return self.finish(run, "refused", taken)
            if self.reach(run, None):
                self.act(run, intent)
        elif stage == "start":  # a setting's act opens the settings fresh itself and reads what it changes before changing it
            if self.reach(run, project, self.composes(board, project)):
                self.act(run, intent)
        elif stage == "prove" and not create:  # a create's proof is a projects list, which comes by itself
            if run["mark"] is None:
                self.prove_read(run, intent)
        elif stage == "look" and create:  # the second look is the projects page itself: its open's `done` may come before its list
            if not self.tab_free(run):
                return self.deadline(run)
            if run["mark"] is None:
                run["mark"] = self.lists
            if self.reach(run, None) and self.lists > run["mark"]:
                self.finish(run, "failed", self.not_confirmed(run))
        elif stage == "look":
            if run["mark"] is None:
                self.prove_read(run, intent)
            elif self.has_read(run, intent):
                self.finish(run, "failed", self.not_confirmed(run))

    def prove_read(self, run, intent):
        """A read that proves the act. A send that went on while this run waited may have moved the tab: it goes back to the project first."""
        if not self.tab_free(run):
            return self.deadline(run)  # the deadline is the wake-up: at it the run takes its look, or reads now if the tab is free
        if self.reach(run, intent["project"], shows(self.board(), (intent["project"], None))):
            self.read(run, intent)

    def act(self, run, intent):
        """The one act. From here the run is past `act`: it is proved or failed, never sent again. A setting's act may find it already so
        and change nothing; until it says so, it counts as done."""
        kind, fields = do.act_command(intent)
        store.update_intent(self.db, self.clock(), run["id"], status="pending", attempts=1, cause=None)
        # A goal is proved by its save's answer alone. `act`: the command's id, so that a `done` a later start replays is known as its.
        self.keep(run, acted=True, act=self.next_id(), **({"provable": False} if intent["tool"] == "set_goal" else {}))
        self.goto(run, "act")
        run["acted"] = self.reads.get(intent["project"], 0)  # the reads the page had sent before the act: the one before it is old
        self.issue(run, kind, **fields)

    def tool_late(self, run, intent):
        """The deadline passed. A page step that is still waiting is cut off: it knows what it lacked and says so in its `done`. In `prove`
        the run takes its one more look; any other stage, or a second deadline, ends the run."""
        stage = run["stage"]
        if stage != "start" and self.in_page(run) and not run["cut"]:
            run["cut"] = True
            self.command("cancel", target=run["command"])
            return self.deadline(run)
        if run.get("open_wait"):  # its open erred (`tool_done`): it opens again now, once more
            run["open_wait"] = False
            self.deadline(run)
            return self.step_tool(run, intent)
        if stage == "prove":
            self.goto(run, "look")
            return self.step_tool(run, intent)
        if stage == "look" and run["mark"] is None and not run["opened"]:  # another run held the tab: the look hasn't been taken yet
            return self.step_tool(run, intent)
        if stage == "act" and intent["tool"] == "set_goal":  # its save got no answer: no read can prove it, now or later
            self.stale_goal[intent["project"]] = self.keep(run, provable=False)
            return self.finish(run, "failed", "the page never finished the step")
        self.finish(run, "failed", {"start": self.unstarted(intent), "act": "the page never finished the step"}.get(stage) or self.not_confirmed(run))

    def unstarted(self, intent):
        """Why a tool never started (`composes`; a tool waits for no settled chat): the tab never showed the place, or never its composer,
        or another tool's command held the page."""
        board, project = self.board(), intent["project"]
        if project is None or not shows(board, (project, None)):
            return "the page never showed that place"
        if not self.composes(board, project):
            return "the page showed that place but never its composer"
        return "another tool's step held the page"

    def not_confirmed(self, run):
        """An act that erred after it committed says its error too."""
        return f"{do.NOT_CONFIRMED}: {run['act_error']}" if run.get("act_error") else do.NOT_CONFIRMED

    def tool_done(self, run, event):
        """The page's report of a tool step. A setting's act reports what its fresh open read (`before`), then either that it was already
        so (`already`: nothing done) or the server's answer to its save (`saved`, the HTTP status), which proves it. An act that errs
        before it committed is the answer; one that errs after (`committed`: no answer to the save, a dialog stuck closing) may have
        taken, so it is proved by a read, its error kept for the cause, except a goal, which no read can prove. A refusal (`refused`) is
        the page not offering what was asked."""
        error = str(event.get("error") or "the page reported a failure")
        stage, run["command"] = run["stage"], None
        intent = store.intent(self.db, run["id"])
        if event.get("id") == run.get("reach_open"):  # its open's: as a send's open, a page error opens again at the deadline, a second fails it
            run["reach_open"] = None
            if event.get("ok"):
                run["open_error"] = False
            elif error != "superseded" and stage != "prove":  # a proving open's error waits for the deadline's look, as before
                if run.get("open_error"):
                    return self.finish(run, "failed", error)
                run["open_error"], run["opened"], run["open_wait"] = True, False, True
                return self.deadline(run)
        setting = stage == "act" and intent["tool"] != "create_project"
        before = self.read_before(run, intent, event) if setting and "before" in event else None
        if event.get("ok"):
            if setting and event.get("already") is True:
                return self.already(run, intent, before)
            if stage == "act":
                run["ms"].setdefault("clicked", self.ms(run))
            if setting and isinstance(event.get("saved"), int) and 200 <= event["saved"] < 300:  # the server took it: nothing to read
                if intent["tool"] == "set_goal":
                    self.keep(run, provable=True)
                    self.stale_goal.pop(intent["project"], None)  # the tab shows the goal the server has
                return self.finish(run, "confirmed")
            if setting:  # done, but no answer to its save was reported: as an act that committed with none
                return self.unanswered(run, intent, "the page reported no answer to the save")
            if stage == "act":  # a create: a later list of the projects proves it
                self.goto(run, "prove")
                self.deadline(run)
            return
        if error == "superseded" and stage != "act":  # another run moved the tab or read: this one opens and reads again
            run.update(opened=False, mark=None)
            return
        if stage == "prove" and run["cut"]:  # routerd cut it off at the deadline: this is its report, and the look follows at once
            self.goto(run, "look")
            return self.step_tool(run, intent)
        if stage == "prove":  # a proving open or read that broke on its own: the deadline's look decides
            return self.deadline(run)
        if stage == "act" and event.get("committed") and not event.get("refused"):
            run["ms"].setdefault("clicked", self.ms(run))
            # A folder or repository pressed with no save seen by the page's short wait: the fresh read that follows answers, not the look.
            run["unsaved"] = bool(event.get("unsaved")) and intent["tool"] in ("add_repo", "preapprove_folder")
            return self.unanswered(run, intent, error)
        if stage == "act" and not event.get("committed"):  # the page step erred before its one change: nothing was done
            intent = self.keep(run, acted=False, **({"provable": True} if intent["tool"] == "set_goal" else {}))
        if stage == "act" and not event.get("committed") and intent["tool"] == "set_goal":  # the tab may show the goal the server refused
            self.stale_goal[intent["project"]] = intent
        if event.get("refused"):
            path = (intent["args"] or {}).get("path")
            missing = intent["tool"] == "preapprove_folder" and error.startswith("no folder option")  # its list was there and lacked it
            return self.finish(run, "refused", f"connect {path} in the Claude app first" if missing else error)
        self.finish(run, "failed", f"{do.NOT_CONFIRMED}: {error}" if stage == "look" else error)

    def read_before(self, run, intent, event):
        """What the act's own open read, kept as `before`. A goal is the tab's copy: one the tab shows that differs from a goal marked as
        refused means the marked one is gone from it."""
        before, goal = do.before(event["before"], intent), intent["tool"] == "set_goal"
        self.keep(run, before=before, **({"before_is": "the tab's copy, maybe older"} if goal else {}))
        marked = self.stale_goal.get(intent["project"])
        if goal and marked and isinstance(before, str) and not do.shows(marked["proof"], before):
            del self.stale_goal[intent["project"]]
        return before

    def already(self, run, intent, before):
        """The act found it already so and changed nothing: it was never acted on. A goal is said as the tab knows it (an unchanged field
        saves nothing, so it can't be written again); one the server refused, which the tab still shows (it shows what was typed), is not so."""
        result = {k: v for k, v in (store.intent(self.db, run["id"])["result"] or {}).items() if k not in ("acted", "provable")}
        store.update_intent(self.db, self.clock(), run["id"], result=result)
        if not do.shows(intent["proof"], before):  # what the page read says otherwise: nothing was done, and nothing is known
            return self.finish(run, "failed", "the page said it was already so, but what it read differs")
        if intent["tool"] != "set_goal":
            return self.finish(run, "confirmed", "it was already so")
        if intent["project"] in self.stale_goal:
            unknown = (self.stale_goal[intent["project"]]["result"] or {}).get("provable", True) is False
            return self.finish(run, "refused", "Fjord can't tell whether the server took this goal: reload the tab first" if unknown
                               else "the server refused this goal earlier and Fjord's tab still shows it: reload the tab first")
        self.finish(run, "confirmed", "it was already so, as far as Fjord's tab knows")

    def unanswered(self, run, intent, error):
        """The act committed its change but no answer to its save came. The proving read and the look decide, except for a goal: the
        dialog shows the goal as the tab last knew it (the typed one, even if the server refused it), so only the answer to its save
        proves a goal, and without it no read can, now or later."""
        if intent["tool"] == "set_goal":
            intent = self.keep(run, provable=False)
            self.stale_goal[intent["project"]] = intent  # the tab shows the typed goal whether or not the server has it
            return self.finish(run, "failed", f"{do.NOT_CONFIRMED}: {error}")
        self.goto(run, "prove")
        run["act_error"] = error
        store.update_intent(self.db, self.clock(), run["id"], cause=error)
        self.deadline(run)

    def reconcile(self, kind, project, complete=False):
        """A tool that was done but not confirmed is confirmed by a later read that shows it (a later list of projects, for a create). A full
        list without the name, seen ACCEPTED_WAIT after the create, says it never took (the server refused it): its name is free again.
        Sooner, the server may only be slow, and freeing the name would let a second create make a duplicate."""
        board = self.board()
        for intent_id in list(self.unproved):
            intent = store.intent(self.db, intent_id)
            if (intent["tool"] == "create_project") != (kind == "projects") or (kind == "settings" and intent["project"] != project):
                continue
            holds, cause = do.tool_proved(board, intent)
            if not holds and complete and intent["tool"] == "create_project" and self.clock() - intent["at"] >= ACCEPTED_WAIT:
                self.unproved.discard(intent_id)
                store.update_intent(self.db, self.clock(), intent_id, result={**(intent["result"] or {}), "acted": False})
                continue
            if holds and not cause:
                self.unproved.discard(intent_id)
                found = {"project": do.created(board, intent["proof"])[0]} if intent["tool"] == "create_project" else {}
                self.confirm_late(intent, "confirmed by a later read", **found)

    def reconcile_sends(self, place):
        """A send failed after a click (taken but never confirmed, stuck, VANISHED; `finish`) is confirmed late by a later read of its place
        (project, thread: a rows event of that side) that proves it, for ACCEPTED_WAIT of uptime after its failure: the server may have
        had the words all along, queued behind a coordinator's turn.
        Its proof (baseline and anchors) is kept, and moves forward as a run's does. Only words that match prove it: another row of yours
        is someone else's message, and a row that proved another send (a live run of the same words claims it first) is that send's.
        Its watch over, its proof keeps only the tail any finished send's does (`do.tail`)."""
        self.unwatch()
        board = self.board()
        proved = self.proved_at(place)
        for intent_id in list(self.watched):
            intent = store.intent(self.db, intent_id)
            if (intent["project"], intent["thread"]) != place or intent_id not in proved:
                continue
            holds, cause, key = proved[intent_id]
            if holds and not cause:
                del self.watched[intent_id]
                self.claimed.setdefault(place, set()).add(key)
                self.confirm_late(intent, "confirmed late, by a later read that showed the words after it was failed", {"row": key},
                                  proof=do.tail(intent["proof"]))
                continue
            anchored = do.anchor(board, intent["proof"])
            if anchored is not intent["proof"]:
                store.update_intent(self.db, self.clock(), intent_id, proof=anchored)

    def proofs_at(self, place, current=None):
        """[(id, proof)] of the sends of a place that a row of yours may prove, judged together (`do.proved_all`): the live runs that
        sent (a baseline), first, so a row of the same words goes to a live run before a send failed earlier, then the watched ones.
        `current`: a run's intent as `advance` holds it."""
        live, watched = [], []
        for run_id in sorted(self.runs):
            if self.runs[run_id]["tool"]:
                continue
            i = current if current and current["id"] == run_id else store.intent(self.db, run_id)
            if (i["project"], i["thread"]) == place and i["status"] not in do.DONE and "baseline" in (i["proof"] or {}):
                live.append((run_id, i["proof"]))
        for intent_id in sorted(self.watched):
            i = store.intent(self.db, intent_id)
            if intent_id not in self.runs and (i["project"], i["thread"]) == place and i["status"] == "failed" and "baseline" in (i["proof"] or {}):
                watched.append((intent_id, i["proof"]))
        return live + watched

    def proved_at(self, place, current=None):
        """{id: (done, cause, key)} for each send of the place `proofs_at` lists."""
        return do.proved_all(self.board(), self.proofs_at(place, current), self.claimed.get(place, ()))

    def unwatch(self):
        """The watches that are over (past their uptime, or the intent no longer failed) end, each proof cut to its tail: at each tick
        (`next_deadline` gives the earliest end) and before a read is reconciled, so an expired proof isn't kept until a later read."""
        now = self.uptime()
        for intent_id, until in list(self.watched.items()):
            intent = store.intent(self.db, intent_id)
            if now >= until or intent["status"] != "failed":  # at its end: a tick then must not find it due again
                del self.watched[intent_id]
                self.watch_back.pop(intent_id, None)
                store.update_intent(self.db, intent["updated"], intent_id, proof=do.tail(intent["proof"]))  # cutting it changes no outcome

    def hand_off(self, intent, t):
        """A reply to a stranded thread goes to its project's coordinator instead: one ordinary project send, with the same proof, that asks
        for a new thread continuing it. `continues` ties the new thread to the old one. Nothing is sent into the dead thread."""
        words, args = do.handoff(t, intent["words"])
        proof = {"kind": "latest_you", "project": t["project"], "thread": None, "words": words}
        changed = {**intent, "args": args}
        return store.update_intent(self.db, self.clock(), intent["id"], tool="send_to_project", words=words, project=t["project"], thread=None,
                                   args=args, proof=proof, result={**(intent["result"] or {}), "warning": do.warning(self.board(), changed)})

    def mark(self, intent, status, cause):
        """Status and cause change only when they differ. A paused intent answers whoever waits: it goes on by itself when the page is back."""
        if (intent["status"], intent["cause"]) != (status, cause):
            intent = store.update_intent(self.db, self.clock(), intent["id"], status=status, cause=cause)
            if status == "paused":
                self.settle(intent)

    def done(self, event, replayed=False):
        """The page's report of a command: what it did, not whether it worked. A failed step is tried again at once. `replayed`: from a
        `commands` snapshot, for a click made some time before (when isn't known): it is a click, but not a fresh one."""
        error = str(event.get("error") or "the page reported a failure")
        self.closing.pop(event.get("id"), None)
        # Kept for the document `pages` counts, which a `done` after a `gone` or a host linked again may not come from (`pages` is
        # counted at the next `page`): a new document's `done` then says nothing of the old one's cut-off sends (`unheard_sends`).
        if not (self.regone or self.relinked):
            self.last_done[self.pages] = max(self.last_done.get(self.pages, 0), self.seq(event.get("id")) or 0)
        if isinstance(event.get("settings"), dict) and isinstance(event.get("id"), str):  # a live read's: its `settings` event came first
            self.read_heard(event["id"])
        if event.get("id") in self.dev:
            self.dev.pop(event["id"])(event)  # a dev command belongs to no run
            return self.advance_all()  # the sends that waited for it go on
        w = self.watch_open
        if w and w["open"] and event.get("id") == w["open"]:  # a watched send's going back (`back_to_watched`)
            if event.get("ok"):  # it holds on until a settled whole read of the place (`handle`), at most do.TIMEOUT more
                w["open"], w["moving_from"], w["hold_until"] = None, self.arrivals, self.clock() + do.TIMEOUT
                board = self.board()
                if w["shown"] and shows(board, w["to"]) and (w["to"][1] or w["to"][0]) not in self.unsettled \
                        and boards.rows_of(boards.place_of(board, *w["to"]), w["to"][1]) is not None:  # shown and read already: no read is due
                    self.release_watch(used=True)
            else:  # superseded by another open (it may go again), or failed (it goes after the next move)
                self.release_watch(used=event.get("error") != "superseded")
        for run in list(self.runs.values()):
            if run["tool"]:
                if event.get("id") == run.get("command"):
                    self.tool_done(run, event)
                continue
            if event.get("id") == run.get("open") and (event.get("ok") or (run.get("accepted") and not run.get("looking"))):
                run["open"] = None  # no longer waiting in the page. A taken send's going back is only a help: it goes back after the next move
                if event.get("ok"):  # an open that worked: a later error is the first in a row again
                    run["open_error"] = False
                    run["look_done"] = bool(run.get("looking"))  # a settled read after this answers its look (`read_whole`)
                    run["moving_from"] = self.arrivals  # the tab says it arrived after this `done` (`going_back`)
                    if (run.get("moving_to") and self.arrivals > run.get("open_from", self.arrivals)
                            and shows(self.board(), run["moving_to"])):
                        # The tab arrived at the open's place since it went out (its `page` came before this `done`): the move is over.
                        # An arrival elsewhere proves nothing: a reloaded page's own arrival can come after the open went out, before
                        # that page runs it.
                        run["moving_to"] = None
                        run.pop("hold_until", None)
                    elif run.get("moving_to"):
                        run["hold_until"] = self.clock() + do.TIMEOUT
                else:
                    run["moving_to"] = None
            elif event.get("id") == run.get("open"):
                # Another open replaced it (`superseded`), or the page failed it (no tab to be had, say): the run lost the tab, and opens
                # again at its deadline, as background.js says routerd does. A second error in a row fails it with that error.
                if error != "superseded" and run.get("open_error"):
                    run["open"] = None
                    self.finish(run, "failed", error)
                    continue
                run["open"], run["open_error"], run["moving_to"] = None, error != "superseded", None
                run.pop("hold_until", None)
                if run.get("looking"):  # as a lost one (`lost_open`): looked again once, with a fresh wait; else left to its deadline
                    run["look_read"] = run["look_done"] = False
                    if not run.get("relooked"):
                        run["looking"], run["relooked"] = None, True
                        self.deadline(run)
                    else:
                        run["deadline"] = run["looking"]
                        self.wake()
                else:
                    run["stage"], run["lost"] = "start", True
                    self.deadline(run)
            elif event.get("id") in run.get("sends", ()) and event["id"] not in run.setdefault("heard", set()):
                run["heard"].add(event["id"])  # a replay that says it again is not heard twice
                # The run's answer is its latest send's, unless that was cut off. An older send's, or a cut-off one's, counts only as a click:
                # it was replaced or cancelled, so its error says nothing of the run.
                current = event["id"] == run["command"] and event["id"] != run.get("dropped")
                if current:
                    run["answered"] = run["command"]  # no longer waiting in the page
                if event.get("ok"):
                    run["ms"].setdefault("clicked", self.ms(run))
                    self.clicked(run)
                    run["ignored"] = True  # ignored until the draft says otherwise
                    # The latest click: a page that goes within RELOAD_LOSS of it may lose the words. A replayed one's time and page
                    # aren't known: no reload is taken for its loss, nor words back in a draft for its page giving up.
                    if not replayed:
                        run["click_at"], run["click_page"] = self.clock(), self.pages
                    # A click the page takes empties the draft within 65 ms (every one measured). One it ignored (a hidden tab's page
                    # still finishing the last send) leaves the words there: it is tried again after TAKE_WAIT, not at the deadline.
                    # Only while the run waits on a send: a cut-off one's late click while it opens again keeps the open's own deadline.
                    if run["stage"] == "waiting" and not replayed:
                        run["deadline"] = min(run["deadline"] or float("inf"), self.clock() + TAKE_WAIT)
                        self.wake()
                elif current and error == DIALOG_OPEN:  # (an older or cut-off send's error says nothing of the run)
                    # A dialog the page holds open (a tool's, or one routerd doesn't know of): the same attempt goes on, and the send is made
                    # again when the tools end, else at its deadline. It never burns an attempt, nor is retried at once against the dialog.
                    store.update_intent(self.db, self.clock(), run["id"], cause=error)
                    run["ignored"], run["held"] = True, self.tool_busy()
                elif current:
                    store.update_intent(self.db, self.clock(), run["id"], cause=error)
                    if error != "superseded" and self.tab_held(run):  # another run has the tab: the retry waits for it, at most the deadline
                        run["retry"] = True  # the pass that frees the tab makes it (`advance`, `advance_all`)
                        self.deadline(run)
                    elif error != "superseded":  # not a failure of this command: the next attempt needn't wait for the deadline
                        run["deadline"] = None
                        self.safely(run, late=True)
        self.advance_all()

    def wake_me(self, after):
        """The page asks to be woken after `after` ms: a hidden tab's own timers are throttled, a message is not. Each time asked is kept,
        so a later request isn't lost behind an earlier one; one wake answers every time that has passed. Anything that isn't a number of
        ms is ignored."""
        if isinstance(after, bool) or not isinstance(after, (int, float)) or not math.isfinite(after):
            return
        due = math.ceil((self.clock() + min(max(after, 0), WAKE_CAP) / 1000) * 20) / 20  # up: a wake never comes before its time
        if due not in self.wakes:
            self.wakes.add(due)
            self.wake()

    def tick(self, now=None):
        """Called when a deadline passes. A run that got no row from you in time takes its next attempt."""
        with self.lock:
            now = self.clock() if now is None else now
            self.jump(now)
            if any(due <= now for due in self.wakes):
                self.wakes = {due for due in self.wakes if due > now}
                if self.connected():  # with no host the wake is dropped: the host that links next is sent one at once (`connection`)
                    self.send_wake()
            # A finished read still closing its dialog at its deadline is let go and cancelled: the sends it held go on, and meet the page's
            # own dialog guard if the dialog is still open (they end within their attempts); the next tool's open closes a dialog left open.
            for id_ in [i for i, due in self.closing.items() if due <= now]:
                del self.closing[id_]
                self.command("cancel", target=id_)
            self.unwatch()
            if self.watch_open and self.watch_open["hold_until"] <= now:  # an open the page dropped, a tab that never arrived or settled
                self.release_watch(used=True)  # used: a place that never settles isn't opened again and again in one move
            for run in list(self.runs.values()):
                if (run.get("fresh_at") or float("inf")) <= now:  # its `fresh` open is due: the pass below sends it (`advance`)
                    run["fresh_at"] = None
                if run["deadline"] is not None and run["deadline"] <= now:
                    if run.get("paused") and self.tab_held(run):  # as in advance_all: it waits its turn, and the pass that frees the tab advances it
                        run["deadline"] = None  # a past deadline kept would wake the timers again at once
                        continue
                    run["deadline"] = None
                    self.safely(run, late=True)
            self.advance_all()

    def send_wake(self):
        command = {"kind": "wake"}  # no id and not counted: the page answers nothing, and it is no command waiting in the page
        trace("down", command)
        self.out(command)

    def next_deadline(self):
        with self.lock:
            # A watch's end is on uptime: it is given on the wall clock as the time left from now (a sleep only makes the tick early).
            watches = [self.clock() + max(0.0, until - self.uptime()) for until in self.watched.values()]
            holds = [r["hold_until"] for r in self.runs.values() if (r.get("open") or r.get("moving_to")) and r.get("hold_until", 0) > self.clock()]
            if self.watch_open and self.watch_open["hold_until"] > self.clock():
                holds.append(self.watch_open["hold_until"])
            holds += [r["looking"] for r in self.runs.values() if r.get("looking") and r["looking"] > self.clock()]  # a look's end frees the tab
            return min([r["deadline"] for r in self.runs.values() if r["deadline"] is not None] + holds + [r["fresh_at"] for r in self.runs.values() if r.get("fresh_at")]
                       + list(self.wakes) + list(self.closing.values()) + watches, default=None)

    def finish(self, run, status, cause=None, row=None, **changes):
        """`row`: the key of the row that proved a send. It is kept in the intent's result and claimed for its place: it proves no other."""
        self.runs.pop(run["id"], None)
        # A send still waiting in the page must not click later, whatever the outcome (a confirmed run's retry may wait too). A tool's
        # command is cut off only on a failure: a confirming read's own `done` closes its dialog.
        waiting = not run["tool"] and self.in_page(run)
        # A read whose settings already arrived is only closing its dialog: it is left to close, since a cancel now would stop that close
        # (the page would report the cut-off as the read's first and only `done`, leaving the dialog open). Sends wait for it until its
        # `done`, a `commands` that no longer lists it, or its deadline, when it is cancelled after all (`tick`).
        reading = run["tool"] and run.get("mark") is not None and run.get("command") and self.reads.get(store.intent(self.db, run["id"])["project"], 0) > run["mark"]
        if reading:
            self.closing[run["command"]] = self.clock() + do.TIMEOUT
            self.wake()
        elif run.get("command") and run["command"] != run.get("dropped") and (status in ("failed", "refused") or waiting):
            self.command("cancel", target=run["command"])
        if not run["tool"] and run.get("open"):  # its open (a look, say) still waits in the page: it must not move the tab later
            self.command("cancel", target=run["open"])
        if status == "confirmed":
            run["ms"]["proved"] = self.ms(run)
        intent = store.intent(self.db, run["id"])
        result = {**(intent["result"] or {}), "ms": run["ms"], **({"row": row} if row else {})}
        if row:
            self.claimed.setdefault((intent["project"], intent["thread"]), set()).add(row)
        # A finished send's proof is read again only when it failed after a click (taken but never confirmed, stuck, VANISHED): the
        # server may yet show the words (`reconcile_sends`). Any other keeps a short tail of its baseline and anchors (`do.tail`), so the
        # intents table doesn't grow by hundreds of keys a send. A watched one is cut to it when its watch ends.
        proof = intent["proof"] or {}
        # A send failed while still in the page (`waiting`) is watched too: the page may click it before the cancel reaches it. So is
        # one with any send not heard from: a cut-off one may have clicked before its cancel arrived.
        may_have = run.get("clicked") or run.get("taken") or waiting or (not run["tool"] and self.unheard_sends(run))
        watch = not run["tool"] and status == "failed" and bool(may_have) and "baseline" in proof
        if "baseline" in proof and not watch:
            changes["proof"] = do.tail(proof)
        if watch:  # its end on the wall clock, for a restart (`__init__`)
            result["watch"] = self.clock() + ACCEPTED_WAIT
        intent = store.update_intent(self.db, self.clock(), run["id"], status=status, cause=cause, result=result, **changes)
        if status == "failed" and result.get("acted") and result.get("provable", True):
            self.unproved.add(intent["id"])
        if watch:  # a later row of yours still confirms it (`reconcile_sends`)
            self.watched[intent["id"]] = self.uptime() + ACCEPTED_WAIT
            self.wake()  # its end is a deadline: the tick then cuts its proof (`unwatch`)
        if run.get("back") is not None:  # it took the tab back to its place: another taken send may go back once more (`await_proof`)
            self.moves, self.back_due = self.moves + 1, True
        self.follow(intent)
        self.settle(intent)

    def follow(self, intent):
        """The tool steps queued after one that is over. When it is confirmed the next is checked and started, and whoever waits on this
        step waits on the next; otherwise every later step is refused, naming it."""
        queued = self.chains.pop(intent["id"], None)
        if not queued:
            return
        if intent["status"] != "confirmed":
            for i in queued:
                store.update_intent(self.db, self.clock(), i, status="refused", cause=decide.after(intent))
            store.update_intent(self.db, self.clock(), intent["id"], result={**(intent["result"] or {}), "stopped": queued})  # a late confirmation says so on them
            return
        step = decide.start_step(self.db, self.board(), self.clock(), store.intent(self.db, queued[0]), self.unproved)
        self.waiters[step["id"]] = self.waiters.pop(intent["id"], [])
        if queued[1:]:
            self.chains[step["id"]] = queued[1:]
        if step["status"] == "pending":  # the pass that finished this step advances it
            return self.add_run(step, self.clock())
        if step["status"] == "refused":  # so are the rest. A grant (`awaiting`) keeps them queued until `confirm` runs it.
            self.follow(step)
        self.settle(step)

    def settle(self, intent):
        for fn in self.waiters.pop(intent["id"], []):
            fn(intent)

    # ---- say

    def say(self, message, project=None, thread=None, reply=lambda event: None, finished=lambda intent: None):
        """Decide and start doing. `reply` gets the decision as soon as there is one; `finished` the intent once it is done."""
        t0 = self.clock()
        with self.lock:
            board, notes, past = self.board(), store.notes(self.db), store.intents(self.db, 30)
        if project or thread:
            with self.lock:
                return self.begin(decide.explicit(self.db, board, message, self.clock(), project, thread), t0, reply, finished, {"by": "explicit"})
        text, digest = context.build(board, notes, past, self.clock())
        log = {}
        try:
            state, questions = decide.jev_request(board, past, message, self.clock())
            log["jev"] = self.models.jev(state, questions)
            sure = decide.jev_pick(board, log["jev"])
        except Exception as e:
            log["jev"], sure = {"error": str(e)}, None
        if "error" not in log["jev"] and decide.jev_silent(log["jev"]):
            with self.lock:
                intent = store.add_intent(self.db, self.clock(), "answer_here", message, status="answered", cause="", context_hash=digest,
                                          output={**log, "by": "jev"}, dup=False)[0]
                return self.begin(intent, t0, reply, finished)
        if sure:
            with self.lock:
                intent = decide.send_intent(self.db, self.clock(), message, sure["id"], None, context_hash=digest, output={**log, "by": "jev"})
                return self.begin(intent, t0, reply, finished)
        reply({"event": "thinking", "jev": log["jev"]})
        self.models.spawn(lambda: self.sonnet(message, board, text, digest, log, t0, reply, finished))

    def sonnet(self, message, board, text, digest, log, t0, reply, finished):
        try:
            out, seconds, cost = self.models.sonnet(decide.ROLE, f"{text}\n\nMessage:\n<message>{message}</message>", decide.SCHEMA)
            out = {**out, "seconds": round(seconds, 1), "usd": round(cost, 4)}
            with self.lock:
                first, *later = decide.from_model(self.db, board, message, self.clock(), out, digest, log, self.unproved)
        except Exception as e:  # the call, or an answer that isn't what the schema says: the waiter still gets an outcome
            with self.lock:
                intent = store.add_intent(self.db, self.clock(), "send_to_project", message, status="failed", cause=f"the model call failed: {e}",
                                          context_hash=digest, output=log)[0]
                return self.begin(intent, t0, reply, finished)
        with self.lock:
            self.begin(first, t0, reply, finished, later=later)

    def begin(self, intent, t0, reply, finished, log=None, later=()):
        """Replies with the decision and starts it. `later`: the tool steps after this one, shown in the decision as `steps` so the owner
        sees them all at once; each starts when the one before it is confirmed."""
        if log and not intent["output"]:
            intent = store.update_intent(self.db, self.clock(), intent["id"], output=log)
        gone = do.stranded(self.board(), intent) if intent["thread"] and intent["status"] == "pending" else None
        if gone:
            intent = self.hand_off(intent, gone)
        warning = do.warning(self.board(), intent)
        if warning:
            intent = store.update_intent(self.db, self.clock(), intent["id"], result={**(intent["result"] or {}), "warning": warning})
        reply({"event": "decision", "intent": intent, "warning": warning, **({"steps": [intent, *later]} if later else {})})
        queued = [i["id"] for i in later if i["status"] == "queued"]
        if queued:
            self.chains[intent["id"]] = queued
        if intent["status"] in do.DONE or intent["status"] == "awaiting":  # a permission grant waits for `confirm`
            return finished(intent)
        self.waiters.setdefault(intent["id"], []).append(finished)
        if intent["id"] not in self.runs:
            self.start(intent, t0)

    def tool(self, tool, /, reply=lambda event: None, finished=lambda intent: None, **args):
        """One of the Router's tools by name, as an explicit project send is: no model. `preapprove_folder` is `awaiting` until `confirm`."""
        t0 = self.clock()
        with self.lock:
            return self.begin(decide.tool_intent(self.db, self.board(), self.clock(), tool, args, unproved=self.unproved), t0, reply, finished, {"by": "explicit"})

    def confirm(self, intent_id, finished=lambda intent: None):
        """The owner confirms a permission grant. Until then nothing was done."""
        with self.lock:
            intent = store.intent(self.db, intent_id)
            if not intent or intent["status"] != "awaiting":  # whoever asked still gets an outcome: the run's, or the intent as it is
                if intent and intent["id"] in self.runs:
                    self.waiters.setdefault(intent_id, []).append(finished)
                else:
                    finished(intent or {"id": intent_id, "error": f"no intent {intent_id}"})
                return intent
            intent = store.update_intent(self.db, self.clock(), intent_id, status="pending", result={**(intent["result"] or {}), "confirmed": self.clock()})
            self.waiters.setdefault(intent_id, []).append(finished)
            self.start(intent, self.clock())
            return store.intent(self.db, intent_id)

    def correct(self, intent_id, project):
        """The owner says a message belonged to another project. Kept on the intent."""
        with self.lock:
            return store.update_intent(self.db, self.clock(), intent_id, correction={"project": project, "at": self.clock()})

    def note(self, topic, text):
        with self.lock:
            store.set_note(self.db, self.clock(), topic, text)
            return store.add_intent(self.db, self.clock(), "update_notes", text, args={"topic": topic, "text": text}, status="confirmed", dup=False)[0]

    # ---- tell

    def tell(self):
        """The brief: facts since the last tell that you weren't told. Records what was told."""
        with self.lock:
            now = self.clock()
            known, board = store.told(self.db), self.board()
            found = list(self.facts.values())
            found += [f for f in tell.standing(board) if f["key"] in known and f["key"] not in self.facts]
            # Whether a thread's state is live is as of now, not as of when the fact was found: the tab may have moved since.
            found = [{**f, "as_of": board["threads"][f["thread"]]["as_of"]} if f.get("thread") in board["threads"] else f for f in found]
            found = [f for f in found if tell.holds(f, board)]  # a thread stranded and back, or an app closed and open again, before the tell
            say, quiet = tell.plan(found, known, self.acc["claims"], now)
            for f in say + quiet:
                store.set_told(self.db, now, f["key"], f["project"], f["kind"], f["detail"], f["text"])
            store.mark(self.db, store.last_seen_id(self.db))
            self.facts = {}
            self.acc["claims"].clear()
            self._board = None
            return [f["text"] for f in say]


def shows(board, place):
    """Whether the tab shows the place. A project shows with or without a thread open beside it: arriving on a project, the page
    reopens the thread last shown there, and the project's chat and composer are still there."""
    here = board["here"]
    return here == place or (place[1] is None and here is not None and here[0] == place[0])


# ---- the local files

def watch(core, arm=kwatch.Watch, read=look.read_local, watched=look.watched):
    """One look at the local files per burst of changes: armed before the pass, so what changes during it is one more pass. The page
    going away wakes it too (a byte down `gone`): from then on Chrome's exit, or its folder while it isn't running, is watched."""
    gone, said = os.pipe()
    os.set_blocking(gone, False)
    os.set_blocking(said, False)

    def wake():
        try:
            os.write(said, b"x")
        except BlockingIOError:  # the pipe is full: the watcher is woken already
            pass
    core.gone = wake
    while True:
        try:
            while os.read(gone, 64):  # emptied before arming: a byte written after this wakes the watcher at once
                pass
        except BlockingIOError:
            pass
        watcher = arm(*watched(chrome=not core.connected()), [gone])
        try:
            core.local(read())
            core.recheck_pauses()
        except Exception as e:
            print(f"look: {e}", file=sys.stderr, flush=True)
        watcher.wait()
        watcher.close()


# ---- the socket

def link(core, hosts, write_lock, stream):
    """A native host's first event: its stream joins the hosts and the commands sent so far are the ones its page's `commands` answers
    for. Both under core.lock (taken before write_lock, as command() does before send()): a command sent between them would be counted
    as answered for, and its absence from the snapshot read as dropped."""
    with core.lock:
        with write_lock:
            hosts.append(stream)
        core.connection(True)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(sock=SOCK, db_path=DB, models=None):
    os.makedirs(os.path.dirname(sock), exist_ok=True)
    if os.path.exists(sock):
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(sock)
            sys.exit("routerd is already running")
        except OSError:
            os.unlink(sock)
        finally:
            probe.close()
    hosts, write_lock, wake = [], threading.Lock(), threading.Event()

    def send(command):
        with write_lock:
            if not hosts:  # nothing to carry it: loud, so a command that goes nowhere isn't taken for one the page ignored
                print(f"{time.time():.3f} no host linked: dropped {command.get('kind')} {command.get('id')}", file=sys.stderr, flush=True)
            for w in hosts[-1:]:
                try:
                    w.write((json.dumps(command, ensure_ascii=False) + "\n").encode())
                    w.flush()
                except OSError:
                    pass

    def spawn(fn):
        threading.Thread(target=fn, daemon=True).start()

    core = Core(store.connect(db_path), send, models or Models(decide.ask_jev, decide.claude_model, spawn), wake=wake.set)

    def timers():
        """Sleeps until the next deadline, or until one is added. Nothing here polls."""
        while True:
            due = core.next_deadline()
            wake.wait(None if due is None else max(0.0, due - core.clock()))
            wake.clear()
            carry_on("tick", core.tick)

    class Handler(socketserver.StreamRequestHandler):
        def reply(self, body):
            with write_lock:
                self.wfile.write((json.dumps(body, ensure_ascii=False, default=str) + "\n").encode())
                self.wfile.flush()

        def handle(self):
            host = False
            try:
                for line in self.rfile:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(message, dict):
                        continue
                    if "type" in message:
                        if not host:
                            host = True
                            link(core, hosts, write_lock, self.wfile)
                        carry_on("event", core.handle, message)
                    elif "op" in message:
                        self.op(message)
            except OSError:
                pass
            finally:
                if host:
                    with write_lock:
                        current = bool(hosts) and hosts[-1] is self.wfile  # commands go to the latest host (`send`)
                        hosts.remove(self.wfile)
                    core.connection(False, current=current)

        def stream(self, begin):
            """Replies as `begin` makes them, up to the outcome."""
            lines = queue.Queue()
            begin(lines.put, lambda i: lines.put({"event": "outcome", "intent": i}))
            while True:
                line = lines.get()
                self.reply(line)
                if line["event"] == "outcome":
                    break

        def op(self, m):
            kind = m["op"]
            if kind == "say":
                self.stream(lambda reply, finished: core.say(m.get("message", ""), m.get("project"), m.get("thread"), reply, finished))
            elif kind == "tool":
                self.stream(lambda reply, finished: core.tool(m.get("tool", ""), reply, finished, **(m.get("args") or {})))
            elif kind == "confirm":
                self.stream(lambda reply, finished: core.confirm(m["id"], finished))
            elif kind == "board":
                self.reply({"board": core.board(), "now": core.clock()})
            elif kind == "tell":
                self.reply({"tell": core.tell()})
            elif kind == "notes" and m.get("topic"):
                self.reply({"intent": core.note(m["topic"], m.get("text", ""))})
            elif kind == "notes":
                self.reply({"notes": store.notes(core.db)})
            elif kind == "log":
                self.reply({"intents": store.intents(core.db, 100, columns=store.BRIEF)})  # no proofs: a send's holds its baseline's keys
            elif kind == "correct":
                self.reply({"intent": core.correct(m["id"], m["project"])})
            elif kind == "dev_command" and m.get("kind"):  # a dev step: one page command (remove_folder…), answered with its `done` (at once with no host)
                answers = queue.Queue()
                fields = {k: v for k, v in m.items() if k not in ("op", "kind", "id")}  # the id is routerd's
                id_ = core.dev_command(m["kind"], answers.put, **fields)
                try:
                    self.reply(answers.get(timeout=DEV_WAIT))
                except queue.Empty:
                    if not core.dev_cancel(id_):  # its done came just as the wait ended
                        return self.reply(answers.get_nowait())
                    self.reply({"type": "done", "id": id_, "ok": False, "error": f"the page didn't answer in {DEV_WAIT} s"})
            elif kind in ("reload_extension", "reload_tab"):  # dev steps: the extension reloads itself (edited scripts), or the tab
                with core.lock:  # loads afresh at the projects page. Checked under the lock: a host that leaves meanwhile can't drop it unsaid
                    up = core.connected()
                    if up:
                        core.command(kind)
                self.reply({"ok": True} if up else {"ok": False, "error": "no host linked"})
            else:
                self.reply({"error": f"unknown op {kind}"})

    old = os.umask(0o177)
    try:
        server = Server(sock, Handler)
    finally:
        os.umask(old)
    for fn in (timers, lambda: watch(core)):
        threading.Thread(target=fn, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        os.unlink(sock)


if __name__ == "__main__":
    serve()
