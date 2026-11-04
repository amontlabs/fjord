"""The test double for the page: an in-memory world that speaks events (EVENTS.md) and obeys commands, with the failures the Router must survive.

No sockets and no timers. `Core(db, page.receive)` gets its commands in `inbox`; `pump(core)` plays them and feeds the events back.
Rows have keys: `cmsg_<n>` once the server has them, `cmsg_pending_<n>` for your message not yet delivered and `provisional:<n>` for a
reply being written. Sending follows content.js's steps: a draft of other words is cleared, a settling page (Send enabled with an
empty draft) is waited out, then the words are typed and Send is clicked once (a click on an enabled Send after typing always takes).
A send that isn't click-only and finds the draft empty within ATTEMPT of a click of the same intent's words on that side, in that place, fails
as a click-only one does (a retry that crossed the click's `done`). A newer send on the same side replaces the one still waiting, and a newer open the open still waiting (`slow_opens`: an open waits until
`settle()`, as one waits for its place's composer); `cancel` drops it. A thread holds its opening message, from you. During a `turn` the composer has no Send until typed in.
A send names its place and is refused ("not on that place") while the tab shows another, before typing; `click_only` never types: it
clicks words already in the draft, else fails. An open of the projects page reports `done` before its list, as the real page can.
Streaming rows are sent when they start and once settled, as content.js does, not as each snapshot. Each `connect` (a snapshot) first
sends `commands`: the ids still waiting and the last 20 `done`s, as content.js does, so a `done` lost with the host is said again.
`reload` is the tab reloading under a linked host: the worker's `page` with `gone: true`, then the new document's `commands` and scan;
your pending messages are kept pending, keyed (the server had them) or lost with the old page.
A newer send supersedes the waiting one before anything else; the dialog guard stops only clearing and typing (words already in the
draft are clicked), as content.js's modal check does.

A folder row can carry a note (`notes`, `row_text`) that no read, `before` or match includes. A removal confirms or not at the page (some folders
are removed at the item press, with no confirmation): either way it reports `removed` and `saved`; `save="neither"` is the page doing
neither a save nor a confirmation (an error after the short wait, `committed: true, unsaved: true`).
The tool commands (create_project, set_field, add_repo, preapprove_folder, remove_folder, read_settings) act once and report `done`, as content.js does.
A place in `mounting` isn't known to show its rows yet: its transcript hasn't mounted, or its container (`transcript-sizer`) has but
its rows' fetch hasn't ended since, or it hasn't stayed empty after (content.js's `settledEmpty`: the page can mount it before its rows). Its load sends no `rows` at all,
not even an empty whole scan, until `mount()` sends what it shows (its rows rendering, or the flush that finds it still empty). A place in
`rendering` sends whole reads that aren't `settled`, each one owed again, until `render()` sends it settled; one in `unfetched` does so
until an `open` with `fresh` while it shows (a project open: its project, any thread beside it) takes the tab to `/code` (the page that
starts a new task, whose sidebar list is never `complete`) and back (content.js's `openStep`). A `wake` is played at once when the host connects (content.js settles its waiting steps).
A setting's act reports `before` (what its fresh open read) and stops with `already` when it is so; else it changes it and reports the
save's answer, `saved: 200`. `save`: the server "refused" it (an error, nothing committed; the tab still shows a goal as typed), left
it "unanswered" (an error with `committed: true`; here the change took), or the pick saved "nothing" (the step says so at once, as
content.js does after its short wait, with `committed: true, unsaved: true`; "nothing_took": the save came later and took; "hang": an older
page that waits and says so only when it is cut off). `takes=False`: a create is
reported but nothing changes; a setting gets no answer and nothing changes. `lags`: the change shows only after `land()` (a setting's
save got no answer). A repository or folder the page doesn't offer is refused at once (the repository search has answered here; a
folder's list is read at once), as are several exact matches. A step cut off (`cancel`) says what it lacked and its `before`, as the real one does.
"""
ATTEMPT = 20  # seconds: content.js's ATTEMPT, routerd's do.TIMEOUT
TOOLS = ("create_project", "set_field", "add_repo", "preapprove_folder", "remove_folder", "read_settings")


class FakePage:
    def __init__(self):
        self.signed_in, self.page_ok = True, True
        self.window = 50  # the page holds only the latest rows
        self.settles = False  # after a click the page stays settling (empty draft, Send enabled) until `settle()`
        self.holds = False  # a message you send shows as pending until `deliver()`, as when the coordinator is replying
        self.swallow = False  # a click empties the draft, but the message never shows
        self.composerless = False  # no composer (a reload under way) until `settle()`: sends wait
        self.slow_opens = False  # an open waits until `settle()`, as one waits for its place's composer
        # The server's answer to a setting's save: "ok", "refused", "unanswered", "nothing" (no save was made), "nothing_took" (the save
        # came after the short wait and took), "hang" (an older page that waits until cut off), or "neither" (a removal neither saved nor confirmed).
        self.save = "ok"
        self.mounting = set()  # (project, thread) places whose transcript hasn't mounted: no rows are sent for them until `mount()`
        # (project, thread) places whose render isn't done: their whole reads say `settled: false` and stay owed, and `render()` sends the
        # owed one again, settled, as content.js's next scan does (a flush, or the grace's wake)
        self.rendering, self.owed = set(), set()
        # Project places whose chat the page hasn't fetched since the tab arrived (a script injected into a long-lived tab, a re-open served
        # from the page's cache): their whole reads say `settled: false` until an `open` with `fresh` while they show, which leaves for
        # `/code` and comes back, as content.js does, and that arrival fetches them
        self.unfetched = set()
        self.bounces = 0  # `fresh` opens that went to `/code` and back
        self.turning_told = {}  # (project, thread) -> the `turning` last sent for the place
        self.sent = {}  # key -> the last streaming snapshot sent, so only the start and the settled row go out
        self.clicks, self.keys = 0, 0
        self.clock = lambda: 0.0  # the page's time, for how recent a click is (support.world gives it the core's clock)
        self.last_click = {}  # side -> (place, intent, words, when): a send of that intent that finds the draft empty right after it is a crossed retry
        self.waiting = []  # commands waiting for the page, as steps do
        self.wakes = 0  # `wake` commands received
        self.recent = []  # the last 20 `done`s sent, said again in `commands`
        self.instance = "i1"  # the content script's run in this document (`instance`, on `page` and `commands`): new on a reload or a re-injection
        self.instances = 1
        self.projects = {}
        self.inbox, self.outbox, self.calls = [], [], []
        self.at = None  # (project, thread) the tab shows, or None on the projects page or `/code`
        self.takes, self.lags = True, False
        self.repos, self.connected = [], []  # the repositories the add list offers, and the folders this Mac has connected
        self.notes = {}  # folder path -> the note its row carries beside it ("Approuvé pour Remote Control uniquement sur cet ordinateur.")
        self.later, self.hanging, self.created = [], {}, 0  # changes waiting for `land()`, steps waiting (id -> what they lack, and whether that is a refusal), projects made
        self.slow_reads = False  # a read_settings waits in the page, its dialog open, until `release()` (cancelled, it says what it lacked)
        self.slow_close = False  # a read_settings sends the settings at once, but its `done` waits for `release()`: the dialog is still closing
        self.chosen = []  # options the list marks chosen though the settings don't list them: never pressed, the step reports `already`
        self.left_open = False  # a step that broke after its pick leaves the settings dialog open until the next tool command closes it
        self.reads_done = {}  # command id -> the settings a read_settings read, for its `done`
        self.dialogs = {}  # command id -> (command, "read"|"close"): the tool commands whose settings dialog is open in the page
        self.acted = []  # the setting commands that went on to change something: not already so

    def add_project(self, pid, name):
        self.projects[pid] = {"name": name, "threads": {}, "chat": [], "draft": "", "settling": False, "turn": False,
                              "settings": {"goal": "", "instructions": "", "repos": [], "folders": []}}

    def add_thread(self, pid, tid, title, state="idle", session=None, needs=None, text=""):
        self.projects[pid]["threads"][tid] = {"title": title, "state": state, "needs": needs, "text": text,
                                              "session": session, "messages": [], "draft": "", "settling": False, "turn": False}
        self.projects[pid]["threads"][tid]["messages"].append({"key": f"{tid}_opening", "from": "you", "text": title, "index": 0, "decision": False,
                                                                "streaming": False, "pending": False})  # a thread starts with its opening message

    def _place(self, pid, thread):
        return self.projects[pid]["threads"][thread] if thread else self.projects[pid]

    def _rows(self, pid, thread):
        return self._place(pid, thread)["messages" if thread else "chat"]

    def _stamp(self, event, pid=None, thread=None):
        pid, thread = (pid, thread) if pid else (self.at or (None, None))
        return {**event, "path": f"/code/project/{pid}" if pid else "/code", "thread": thread}

    def _thread_event(self, pid):
        return {"type": "threads", "threads": [{"thread": tid, **{k: t[k] for k in ("title", "state", "needs", "text", "session")}}
                                                 for tid, t in self.projects[pid]["threads"].items()]}

    def set_thread(self, pid, tid, **fields):
        """A thread changed on the page: its row in the project's list is sent."""
        self.projects[pid]["threads"][tid].update(fields)
        self.outbox.append(self._stamp(self._thread_event(pid), pid))

    def key(self, pending=False):
        self.keys += 1
        return f"cmsg_pending_{self.keys}" if pending else f"cmsg_{self.keys}"

    def post(self, pid, who, text, thread=None, decision=False, streaming=False, pending=False, key=None):
        rows = self._rows(pid, thread)
        row = {"key": key or ("provisional:%d" % (self.keys + 1) if pending and who == "claude" else self.key(pending)), "from": who, "text": text,
               "index": len(rows), "decision": decision, "streaming": streaming, "pending": pending}
        rows.append(row)
        self._show(pid, thread, [row])
        return row

    def _composer(self, place, side):
        """Send is missing during a turn until something is typed, enabled while the page settles, else disabled."""
        disabled = False if place["draft"] or place["settling"] else None if place["turn"] else True
        return self._stamp({"type": "composer", "side": side, "draft": place["draft"], "disabled": disabled})

    def _turning(self, pid, thread):
        """Whether the place's bottom Claude row (by index, pending included) is streaming, as content.js's `turningNow`: a row with no
        words, no decision card, not streaming and never sent while streaming is skipped, as content.js's `rowsNow` leaves it out."""
        claude = [r for r in self._rows(pid, thread) if r["from"] == "claude"
                  and (r["text"] or r["decision"] or r["streaming"] or r["key"] in self.sent)]
        return bool(claude) and max(claude, key=lambda r: r["index"])["streaming"]

    def _show(self, pid, thread, rows):
        rows = [r for r in rows if not r["streaming"] or self.sent.get(r["key"]) != (r["index"], r["from"], r["decision"])]
        for r in rows:
            if r["streaming"]:
                self.sent[r["key"]] = (r["index"], r["from"], r["decision"])
        turning = self._turning(pid, thread)
        told = self.turning_told.get((pid, thread))
        turned = told != turning  # alone (no rows) only when it changed, as content.js does
        # Alone, as content.js: only once the whole read isn't owed, and never a first `false`.
        alone = turned and (pid, thread) not in self.owed and (turning or told is not None)
        if (rows or alone) and self.at is not None and self.at[0] == pid and (thread is None or self.at[1] == thread):  # a project's rows show beside an open thread
            self.turning_told[(pid, thread)] = turning
            self.outbox.append(self._stamp({"type": "rows", "side": "thread" if thread else "project", "rows": [dict(r) for r in rows], "full": False,
                                            "turning": turning}))  # every rows event says it, as content.js

    def finish(self, pid, row, thread=None):
        """A reply being written is done: it has its real key."""
        row.update(key=self.key(), streaming=False, pending=False)
        self._show(pid, thread, [row])

    def deliver(self, pid, thread=None):
        """The coordinator's turn ends: your pending messages are delivered, after whatever was said, and renumbered to the end."""
        rows = self._rows(pid, thread)
        late = [r for r in rows if r["pending"]]
        rows[:] = [r for r in rows if not r["pending"]] + late
        for n, r in enumerate(rows):
            r["index"] = n
        for r in late:
            r.update(key=self.key(), pending=False)
        self._show(pid, thread, late)

    def renumber(self, pid, drop, thread=None):
        """A reload: the page now holds fewer rows, numbered again from 0. Follow with `load`."""
        rows = self._rows(pid, thread)
        del rows[:drop]
        for n, r in enumerate(rows):
            r["index"] = n

    def load(self, pid, thread=None):
        """Navigating: the tab sends what is on screen."""
        self.at = (pid, thread)
        side = "thread" if thread else "project"
        place = self._place(pid, thread)
        rows = [] if (pid, thread) in self.mounting else [self.whole(pid, thread)]  # no transcript yet: no rows, not even none
        return [self._stamp({"type": "page", "signed_in": self.signed_in, "page_ok": self.page_ok, "instance": self.instance}),
                self._stamp({"type": "projects", "projects": [{"id": p, "name": v["name"]} for p, v in self.projects.items()]}),
                self._stamp(self._thread_event(pid)), *rows, self._composer(place, side)]

    def whole(self, pid, thread=None):
        """The whole read of a place's rows, as on load: its render is done (`settled`), unless the place is `rendering`, when the read
        stays owed until `render()`. A read on a place that had settled counts the same way (any whole read sets the owed mark)."""
        settled = (pid, thread) not in self.rendering and (pid, thread) not in self.unfetched
        (self.owed.discard if settled else self.owed.add)((pid, thread))
        self.turning_told[(pid, thread)] = turning = self._turning(pid, thread)  # every whole read says it
        return self._stamp({"type": "rows", "side": "thread" if thread else "project", "rows": [dict(r) for r in self._rows(pid, thread)[-self.window:]], "full": True,
                            "settled": settled, "turning": turning})

    def render(self, pid, thread=None):
        """The place's render is done: its owed whole read is sent again, settled, if the tab shows it."""
        self.rendering.discard((pid, thread))
        if (pid, thread) in self.owed and self.at == (pid, thread):
            self.outbox.append(self.whole(pid, thread))

    def mount(self, pid, thread=None):
        """The place's transcript mounts: what it shows is sent whole, if the tab shows it."""
        self.mounting.discard((pid, thread))
        if self.at == (pid, thread):
            self.outbox.append(self.whole(pid, thread))

    def connect(self, core):
        """Fjord's host connects and the tab shows each project in turn, ending on the first."""
        core.connection(True)
        for wake in [c for c in self.inbox if c["kind"] == "wake"]:  # the host's wake is played at once, before the snapshot
            self.inbox.remove(wake)
            self.run(wake)
        core.handle(self._stamp({"type": "commands", "waiting": [c["id"] for c in self.waiting] + list(self.hanging), "done": list(self.recent), "instance": self.instance}))
        for pid in reversed(list(self.projects)):
            for event in self.load(pid):
                core.handle(event)

    def reload(self, core, pid, pending=None):
        """The tab reloads with the host still linked: the worker says the page is gone (stamped with no place, as the worker's own
        events are), and the new document, which knows nothing of the old one's commands, `done`s or clicks, shows `pid` (None: the
        projects page, as the dev `reload_tab` does) once it answers the worker's snapshot (`commands` first: content.js sends nothing on a
        new port before its snapshot).
        `pending`: what became of your messages the old page showed as pending: "keyed" (the server had them: the new page shows them
        with their key) or "lost" (the old page went before the server had them); None leaves them pending."""
        self.waiting, self.hanging, self.recent, self.last_click, self.dialogs = [], {}, [], {}, {}
        self._new_instance()
        for p in self.projects.values():
            for place in (p, *p["threads"].values()):
                rows = place["messages" if "messages" in place else "chat"]
                if pending == "lost":
                    rows[:] = [r for r in rows if not (r["pending"] and r["from"] == "you")]
                for n, r in enumerate(rows):
                    r["index"] = n
                    if pending == "keyed" and r["pending"] and r["from"] == "you":
                        r.update(key=self.key(), pending=False)
        core.handle({"type": "page", "signed_in": None, "page_ok": False, "gone": True, "path": None, "thread": None})
        if pid is None:
            self.at = None
            where = {"path": "/code/projects/browse", "thread": None}
            events = [{"type": "page", "signed_in": self.signed_in, "page_ok": self.page_ok, "instance": self.instance, **where},
                      {"type": "projects", "projects": [{"id": p, "name": v["name"]} for p, v in self.projects.items()], "complete": True, **where}]
        else:
            events = self.load(pid)
        core.handle(self._stamp({"type": "commands", "waiting": [], "done": [], "instance": self.instance}))
        for event in events:
            core.handle(event)

    def _new_instance(self):
        self.instances += 1
        self.instance = f"i{self.instances}"

    def reinject(self, core):
        """The extension reloads: the document stays (its rows, its clicks' effects), a fresh content script replaces the old one, whose
        waiting steps and `recent` go with it, and the worker restarts, so the host links again. The new script says what the page shows,
        `commands` first (empty: it has said nothing yet), with a new `instance`."""
        self.waiting, self.hanging, self.recent, self.last_click, self.dialogs = [], {}, [], {}, {}
        self._new_instance()
        core.connection(False)
        core.connection(True)
        core.handle(self._stamp({"type": "commands", "waiting": [], "done": [], "instance": self.instance}))
        for event in (self.load(*self.at) if self.at else [self._stamp({"type": "page", "signed_in": self.signed_in, "page_ok": self.page_ok, "instance": self.instance})]):
            core.handle(event)

    def receive(self, command):
        self.inbox.append(command)

    def pump(self, core):
        """Plays commands and events until nothing is left."""
        while self.inbox or self.outbox:
            events = self.outbox[:]
            self.outbox.clear()
            if self.inbox:
                events += self.run(self.inbox.pop(0))
            for event in events:
                core.handle(event)

    def land(self):
        """The changes that were slow to show now show."""
        later, self.later = self.later, []
        for change in later:
            self.outbox += change()

    def settle(self):
        """The page settles: Send is disabled again, and the commands that waited run."""
        self.composerless = self.slow_opens = False
        for pid, p in self.projects.items():
            for place in (p, *p["threads"].values()):
                place["settling"] = False
        waiting, self.waiting = self.waiting, []
        for command in waiting:
            self.outbox += self.run(command)

    def run(self, command):
        if command["kind"] == "wake":  # content.js settles its waiting steps and sends nothing: no id, no `done`, not a call
            self.wakes += 1
            return []
        events = self.step(command)
        self.recent = (self.recent + [e for e in events if e.get("type") == "done"])[-20:]
        return events

    def step(self, command):
        keys = ("side", "text") if command["kind"] == "send" else ("project", "thread", "side", "text")
        self.calls.append((command["kind"], *[command.get(k) for k in keys if k in command]))
        done = {"type": "done", "id": command["id"], "ok": True, "error": None}
        if command["kind"] == "open":
            events = []
            for old in [c for c in self.waiting if c["kind"] == "open"]:  # a newer open replaces the waiting one, as a newer send does
                self.waiting.remove(old)
                events.append(self._stamp({"type": "done", "id": old["id"], "ok": False, "error": "superseded"}))
            if self.slow_opens:
                self.waiting.append(command)
                return events
            if self.signed_in and self.page_ok and command["project"] is None:  # the projects page lists them all
                self.at = None
                where = {"path": "/code/projects/browse", "thread": None}
                return events + [{**done, **where}, {"type": "page", "signed_in": True, "page_ok": True, "instance": self.instance, **where},
                        {"type": "projects", "projects": [{"id": p, "name": v["name"]} for p, v in self.projects.items()], "complete": True, **where}]
            # A project open's place shows whenever its project does, a thread open beside it or not (content.js's `openStep`).
            place = (command["project"], command["thread"])
            shows = self.at is not None and (self.at[0] == command["project"] if command["thread"] is None else self.at == place)
            if self.signed_in and self.page_ok and command.get("fresh") and shows and place in self.unfetched:
                # shown, never fetched: away to the page that starts a new task (no project list: never a `complete` one) and back,
                # which fetches it
                self.unfetched.discard(place)
                self.bounces += 1
                self.at = None
                where = {"path": "/code", "thread": None}
                events += [{"type": "page", "signed_in": True, "page_ok": True, "instance": self.instance, **where},
                           {"type": "projects", "projects": [{"id": p, "name": v["name"]} for p, v in self.projects.items()], "complete": False, **where}]
            if self.signed_in and self.page_ok and shows and self.at not in (None, place):  # the project shown, a thread beside it: left open, a full scan
                pid = self.at[0]
                return events + [self._stamp(done), *self.load(*self.at), self.whole(pid), self._composer(self._place(pid, None), "project")]
            if self.signed_in and self.page_ok:
                return events + [self._stamp(done, command["project"], command["thread"]), *self.load(command["project"], command["thread"])]
            return events + [{**done, "ok": False, "error": "the page can't be read"}]
        if command["kind"] == "cancel":
            self.dialogs.pop(command["target"], None); self.reads_done.pop(command["target"], None)
            self.waiting = [c for c in self.waiting if c["id"] != command["target"]]
            lacked, more = self.hanging.pop(command["target"], (None, {}))
            return [{"type": "done", "id": command["target"], "ok": False, "error": lacked, "path": "/code", "thread": None, **more}] if lacked else []
        if command["kind"] in TOOLS:
            return self.tool(command)
        events = []
        for old in [c for c in self.waiting if c["kind"] == "send" and c["side"] == command["side"]]:  # a newer send on the same side replaces the waiting one, before it runs
            self.waiting.remove(old)
            events.append(self._stamp({"type": "done", "id": old["id"], "ok": False, "error": "superseded"}))
        # content.js's second guard, on clearing and typing only (words typed under a modal could land in its fields): words already in
        # the draft are clicked.
        dialog = lambda: [self._stamp({**done, "ok": False, "error": "a dialog is open"})] if self.dialogs or self.left_open else None
        # A project send needs only its project (the page may show a thread beside it); a thread send needs its thread.
        if self.at is None or self.at[0] != command.get("project") or (command["side"] == "thread" and self.at[1] != command.get("thread")):
            return events + [self._stamp({**done, "ok": False, "error": "not on that place"})]
        pid, thread = self.at[0], (self.at[1] if command["side"] == "thread" else None)
        place = self._place(pid, thread)
        side = "thread" if thread else "project"
        composer = lambda: self._composer(place, side)
        if self.composerless:
            self.waiting.append(command)
            return events
        words = " ".join(command["text"].split())
        # A send that isn't click-only and finds the draft empty right after this side clicked the same words there is a retry that crossed
        # that click's `done` (content.js's `lastClick`): it never types either.
        click = self.last_click.get(command["side"])
        crossed = not place["draft"] and click is not None and command.get("intent") is not None and click[:3] == ((pid, thread), command.get("intent"), words) and self.clock() - click[3] < ATTEMPT
        if (command.get("click_only") or crossed) and " ".join(place["draft"].split()) != words:  # never types
            return events + [self._stamp({**done, "ok": False, "error": "the words aren't in the draft"})]
        if " ".join(place["draft"].split()) not in ("", words):  # a. other words: cleared
            if dialog():
                return events + dialog()
            place["draft"] = ""
            events.append(composer())
        if not place["draft"]:
            if place["settling"]:  # b. settling: a click now would do nothing
                self.waiting.append(command)
                return events
            if dialog():
                return events + dialog()
            place["draft"] = command["text"]  # c. typed (during a turn Send appears now)
            events.append(composer())
        self.clicks += 1
        self.last_click[command["side"]] = ((pid, thread), command.get("intent"), " ".join(place["draft"].split()), self.clock())
        words = place["draft"]
        place["draft"], place["settling"] = "", self.settles
        if not self.swallow:
            self.post(pid, "you", words, thread, pending=self.holds)
        return events + [self._stamp(done), composer()] + self.outbox_take()

    def row_text(self, path):
        """A folder row's whole text: the path, then its note if it has one. A read names the folder by the element titled with the full
        path (`rowPath`), so the note is no part of what is read, and an act finds the row by that path alone."""
        return f"{path} {self.notes[path]}" if path in self.notes else path

    def tool(self, command):
        kind, project = command["kind"], command.get("project")
        where = {"path": f"/code/project/{project}" if project else "/code/projects/browse", "thread": None}
        done = {"type": "done", "id": command["id"], "ok": True, "error": None, **where}
        if (self.at is None or self.at[0] != project) if project else self.at is not None:  # a thread may be open beside the project: same pathname
            return [{**done, "ok": False, "error": "not on that project" if project else "not on the projects page"}]
        settings = self.projects[project]["settings"] if project else None
        self.left_open = False  # every tool step closes a dialog left open before it opens its own
        if kind == "read_settings" and self.slow_reads:
            self.dialogs[command["id"]] = (command, "read")
            self.hanging[command["id"]] = ("the settings never came back from the server", {})
            return []
        if kind == "read_settings":
            read = {"type": "settings", "project": project, **{k: list(v) if isinstance(v, list) else v for k, v in settings.items()},
                    "offered_folders": None, **where}
            self.reads_done[command["id"]] = read  # its `done` carries the read too, as content.js's does (the replay repeats it)
            if self.slow_close:
                self.dialogs[command["id"]] = (command, "close")
                self.hanging[command["id"]] = ("the settings dialog stayed open", {})
                return [read]
            return [read, {**done, "settings": self.reads_done.pop(command["id"])}]
        if kind == "remove_folder":  # dev only: the folder's row menu, then the folders endpoint's answer
            folders = settings["folders"]
            done = {**done, "before": list(folders)}
            if command["path"] not in folders:
                return [{**done, "ok": False, "refused": True, "error": f"no folder {command['path']}; has: {', '.join(folders) or 'none'}"}]
            if self.save == "refused":
                return [{**done, "ok": False, "error": "the server refused the folder removal (HTTP 400)"}]
            if self.save == "neither":  # the item was pressed and the page neither saved nor asked to confirm
                return [{**done, "ok": False, "committed": True, "unsaved": True, "error": "neither a save nor a confirmation followed the removal"}]
            if self.save in ("nothing", "hang"):
                return [{**done, "ok": False, "committed": True, "unsaved": True, "error": "the page saved nothing after the removal was chosen"}]
            folders.remove(command["path"])
            return [{**done, "removed": True, "saved": 200}]
        if kind == "create_project":
            def change():
                self.created += 1
                pid = f"chan_new{self.created}"
                self.add_project(pid, command["name"])
                self.projects[pid]["settings"]["goal"] = command.get("goal") or ""
                return self.load(pid)
            if not self.takes:
                return [done]
            if self.lags:
                self.later.append(lambda: change() or [])
                return [done]
            return [done, *change()]
        return self.setting(command, settings, done)

    def setting(self, command, settings, done):
        """A setting's act, as content.js does it: a fresh open reads what it changes (`before`), stops if it is already so, else changes it
        and waits for the server's answer to the save (`saved`)."""
        kind, goal = command["kind"], command.get("field") == "goal"
        key = command["field"] if kind == "set_field" else "repos" if kind == "add_repo" else "folders"
        before = list(settings[key]) if isinstance(settings[key], list) else settings[key]
        done = {**done, "before": before}
        if kind == "set_field":
            what, already = ("goal" if goal else "instructions"), settings[key] == command["text"]
            change = lambda: settings.__setitem__(key, command["text"])
        else:
            what, offered, wanted = ("repository", self.repos, command["repo"]) if kind == "add_repo" else ("folder", self.connected, command["path"])
            already, change = wanted in settings[key] or wanted in self.chosen, lambda: settings[key].append(wanted)
        if already:
            return [{**done, "already": True}]
        self.acted.append(kind)
        name = "repo" if kind == "add_repo" else "folder"
        if kind != "set_field" and offered.count(wanted) > 1:
            return [{**done, "ok": False, "refused": True, "error": f"{offered.count(wanted)} {name} options match {wanted}"}]
        if kind != "set_field" and wanted not in offered:  # the search has answered, or the folder list was read at once: none matching is final
            return [{**done, "ok": False, "refused": True, "error": f"no {name} option {wanted}; offered: {', '.join(offered) or 'none'}"}]
        if self.save in ("nothing", "nothing_took"):  # pressed, and no save request was seen by the short wait: the step says so at once
            if self.save == "nothing_took":  # the save came later than the wait and took
                change()
            self.left_open = True
            return [{**done, "ok": False, "committed": True, "unsaved": True, "error": (
                "the page saved nothing after the repository was chosen" if kind == "add_repo" else
                "the page saved nothing after the folder was chosen")}]
        if self.save == "hang":  # an older page: it waits for a save that never comes, and says so when it is cut off
            self.hanging[command["id"]] = ("the page saved nothing after the repository was chosen" if kind == "add_repo" else
                                           "the page saved nothing after the folder was chosen"), \
                {"refused": False, "committed": True, "before": before}
            return []
        unanswered = {**done, "ok": False, "error": f"no answer from the server to the {what} (network)", "committed": True}
        if self.save == "refused":  # nothing changed on the server; the tab shows a goal as typed, as the real page does
            if goal:
                change()
            return [{**done, "ok": False, "error": f"the server refused the {what} (HTTP 400)"}]
        if self.save == "unanswered":  # the change took, but its save got no answer
            change()
            return [unanswered]
        if not self.takes:  # no answer, and nothing changed
            return [unanswered]
        if self.lags:  # no answer, and the change shows only later
            self.later.append(lambda: change() or [])
            return [unanswered]
        change()
        return [{**done, "saved": 200}]

    def release(self):
        """The dialogs close: a held read reads and reports, a closing one reports `done`."""
        dialogs, self.dialogs = self.dialogs, {}
        slow, self.slow_reads, close, self.slow_close = self.slow_reads, False, self.slow_close, False
        for id_, (command, how) in dialogs.items():
            self.hanging.pop(id_, None)
            where = {"path": f"/code/project/{command['project']}", "thread": None}
            read = {"settings": self.reads_done.pop(id_)} if id_ in self.reads_done else {}
            self.outbox += self.tool(command) if how == "read" else [{"type": "done", "id": id_, "ok": True, "error": None, **where, **read}]
        self.slow_reads, self.slow_close = slow, close

    def outbox_take(self):
        events, self.outbox = self.outbox, []
        return events


def demo():
    page = FakePage()
    page.add_project("chan_a", "alpha")
    page.add_project("chan_b", "beta")
    page.add_thread("chan_a", "cmsg_1", "Alpha first task", state="working", session="cse_1")
    page.add_thread("chan_a", "cmsg_2", "Alpha second task", state="idle", session="cse_2")
    page.add_thread("chan_b", "cmsg_3", "Beta task", state="needs_you", needs="a choice")
    return page
