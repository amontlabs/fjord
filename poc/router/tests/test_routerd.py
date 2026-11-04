import json
import os
import shutil
import time
import tempfile
import threading
import unittest
import unittest.mock

import support
from support import NOW
import do
import fake_page
import kwatch
import look
import routerd
import store


class Restart(unittest.TestCase):
    def test_a_restart_rebuilds_the_board_from_seen_without_old_rows_or_health(self):
        core, page = support.world()
        page.post("chan_a", "claude", "hello")
        page.pump(core)
        again = routerd.Core(core.db, page.receive, clock=support.Clock())
        self.assertEqual(sorted(again.board()["threads"]), ["cmsg_1", "cmsg_2", "cmsg_3"])
        self.assertIsNone(again.board()["projects"]["chan_a"]["chat"])
        self.assertIs(again.board()["health"]["connected"], False)

    def test_an_intent_that_may_have_been_sent_is_not_resumed(self):
        core, page = support.world()
        page.swallow = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        again = routerd.Core(core.db, page.receive, clock=support.Clock())
        i = store.intents(core.db, 1)[-1]
        self.assertEqual((i["status"], i["cause"]), ("failed", "routerd restarted before the words were proved"))
        self.assertEqual(again.runs, {})

    def test_a_restart_finds_unfinished_intents_behind_the_latest_hundred(self):
        core, page = support.world()
        proof = {"kind": "latest_you", "project": "chan_a", "thread": None, "words": "w", "baseline": []}
        old, _ = store.add_intent(core.db, NOW, "send_to_project", "w", "chan_a", None, proof=proof, status="pending")
        acted, _ = store.add_intent(core.db, NOW, "set_goal", "g", "chan_a", None, proof={"field": "goal", "equals": "g"}, status="failed",
                                    result={"acted": True}, args={"project": "chan_a", "text": "g"})
        for n in range(150):
            store.add_intent(core.db, NOW, "answer_here", f"m{n}", status="answered", dup=False)
            store.add_intent(core.db, NOW, "set_goal", f"x{n}", status="failed", dup=False)
        again = routerd.Core(core.db, page.receive, clock=support.Clock())
        self.assertEqual(store.intent(core.db, old["id"])["status"], "failed")
        self.assertIn(acted["id"], again.unproved)

    def test_a_paused_intent_that_never_sent_resumes_when_the_page_is_back(self):
        core, page = support.world()
        core.connection(False)
        core.say("plain test words", project="chan_a")
        again = routerd.Core(core.db, page.receive, clock=core.clock)
        page.connect(again)
        page.pump(again)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")


class Events(unittest.TestCase):
    def test_every_event_is_a_seen_row_and_a_read_writes_nothing(self):
        core, page = support.world()
        before = store.last_seen_id(core.db)
        for _ in range(3):
            core.board()
        self.assertEqual(store.last_seen_id(core.db), before)
        page.set_thread("chan_a", "cmsg_1", state="idle")
        page.pump(core)
        self.assertGreater(store.last_seen_id(core.db), before)

    @support.python_only("tests routerd's lock, link, carry_on or trace: process glue (CourierHostTests)")
    def test_a_command_sent_while_a_host_links_is_not_one_its_replay_answers_for(self):
        core, _ = support.world()
        hosts, sent, connection = [], [], core.connection

        def racing(up):  # another thread sends a command between the host's joining and the count of what its page answers for
            def send():
                with core.lock:  # as every command is sent
                    sent.append(core.command("cancel", target="c0.0"))
            other = threading.Thread(target=send)
            other.start()
            other.join(0.05)
            connection(up)
            threads.append(other)
        core.connection, threads = racing, []
        routerd.link(core, hosts, threading.Lock(), object())
        threads[0].join()
        self.assertGreater(int(sent[0].rsplit(".", 1)[1]), core.linked)

    def test_a_command_an_earlier_start_left_waiting_in_the_page_is_cancelled_once(self):
        core, page = support.world()
        sent = []
        core.out = sent.append
        mine = core.command("open")
        sent.clear()
        for _ in range(2):  # the page lists them with each snapshot
            core.handle({"type": "commands", "waiting": ["cdead00.4", mine], "done": []})
        self.assertEqual([(c["kind"], c.get("target")) for c in sent], [("cancel", "cdead00.4")])

    def test_a_cancel_lost_with_the_host_is_sent_again(self):
        core, page = support.world()
        sent = []
        core.out = sent.append
        core.handle({"type": "commands", "waiting": ["cdead00.4"], "done": []})
        core.connection(False)  # the cancel went down with the host: the page still holds the old command
        core.connection(True)
        core.handle({"type": "commands", "waiting": ["cdead00.4"], "done": []})
        self.assertEqual([(c["kind"], c.get("target")) for c in sent if c["kind"] != "wake"], [("cancel", "cdead00.4")] * 2)

    def test_a_disconnect_makes_the_board_unreadable_for_do_but_keeps_the_threads(self):
        core, page = support.world()
        core.connection(False)
        self.assertIs(core.board()["health"]["connected"], False)
        self.assertIn("cmsg_1", core.board()["threads"])

    def test_a_deadline_exists_only_while_a_send_waits(self):
        core, page = support.world()
        page.settles = True
        core.say("first words", project="chan_a")
        page.pump(core)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        self.assertEqual(core.next_deadline(), NOW + do.TIMEOUT)

    def test_a_load_with_no_rows_yet_does_not_turn_old_history_into_news(self):
        core, page = support.world()
        rows = [{"key": f"cmsg_{i}", "index": i, "from": "claude", "text": f"old message {i}", "decision": False, "pending": False, "streaming": False} for i in range(5)]
        event = lambda rows: {"type": "rows", "side": "project", "rows": rows, "full": True, "path": "/code/project/chan_b", "thread": None}
        core.handle(event([]))
        core.handle(event(rows))
        self.assertEqual([f for f in core.tell() if "old message" in str(f)], [])

    def test_malformed_events_make_no_rows_and_raise_nothing(self):
        core, page = support.world()
        before = core.board()
        for event in ({"type": "threads", "threads": 5}, {"type": "projects", "projects": 5}, {"type": "threads", "threads": [{"thread": {"a": 1}}, 3]},
                      {"type": "projects", "projects": [{"id": 5}, {"id": ["chan_x"]}], "complete": True}, {"type": "rows", "side": "thread", "rows": 5, "thread": ["x"]},
                      {"type": "settings", "project": "chan_a", "repos": 5, "goal": 3}, {"type": "composer", "side": "project", "draft": 5}):
            core.handle({"path": "/code/project/chan_a", "thread": None, **event})
        self.assertEqual(sorted(core.board()["threads"]), sorted(before["threads"]))
        self.assertIn("chan_a", core.board()["projects"])

    @support.python_only("tests routerd's lock, link, carry_on or trace: process glue (CourierHostTests)")
    def test_an_event_or_tick_that_raises_is_logged_and_the_next_one_runs(self):
        import contextlib
        import io

        def boom():
            raise KeyError("x")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(routerd.carry_on("tick", boom))
        self.assertIn("tick failed: KeyError('x')", err.getvalue())
        self.assertEqual(routerd.carry_on("tick", lambda: 3), 3)

    @support.python_only("tests routerd's lock, link, carry_on or trace: process glue (CourierHostTests)")
    def test_the_trace_leaves_out_the_settings_words(self):
        import contextlib
        import io
        import os
        err, os.environ["FJORD_TRACE"] = io.StringIO(), "1"
        try:
            with contextlib.redirect_stderr(err):
                routerd.trace("up", {"type": "settings", "goal": "secret goal", "instructions": "secret rules", "repos": ["acme/secret"], "folders": ["~/secret"], "rows": 5})
                routerd.trace("down", {"kind": "add_repo", "repo": "acme/secret", "path": "~/secret", "error": "no secret", "cause": "secret"})
                routerd.trace("up", {"type": "done", "id": "c1", "ok": True, "before": "secret rules", "saved": 200})
        finally:
            del os.environ["FJORD_TRACE"]
        self.assertNotIn("secret", err.getvalue())
        self.assertIn('"goal": 11', err.getvalue())

    def test_a_correction_is_logged(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        page.pump(core)
        i = store.intents(core.db, 1)[-1]
        core.correct(i["id"], "beta")
        self.assertEqual(store.intent(core.db, i["id"])["correction"]["project"], "beta")


class Sending(unittest.TestCase):
    def sent(self):
        """A core with one send to chan_a waiting, and the one command it gave."""
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        self.assertEqual([c["kind"] for c in page.inbox], ["send"])
        return core, page, next(iter(core.runs.values()))

    def test_an_empty_project_is_ready_once_its_empty_rows_arrive(self):
        core, page = support.world()
        page.add_project("chan_c", "gamma")
        for event in page.load("chan_c"):
            if event["type"] != "rows":
                core.handle(event)
        self.assertIsNone(core.board()["projects"]["chan_c"]["chat"])
        core.handle(next(e for e in page.load("chan_c") if e["type"] == "rows"))
        self.assertEqual(core.board()["projects"]["chan_c"]["chat"], [])
        core.say("plain test words", project="chan_c")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_click_then_an_empty_draft_is_the_page_taking_the_words_whatever_the_order(self):
        for done_first in (True, False):
            core, page, run = self.sent()
            composer = page._stamp({"type": "composer", "side": "project", "draft": "plain test words", "disabled": False})
            empty = {**composer, "draft": ""}
            done = page._stamp({"type": "done", "id": run["command"], "ok": True, "error": None})
            core.handle(composer)
            for event in ([done, empty] if done_first else [empty, done]):
                self.assertNotIn("taken", run)
                core.handle(event)
            self.assertTrue(run["taken"])
            self.assertEqual(len(page.inbox), 1)

    def test_an_empty_draft_alone_is_not_the_page_taking_the_words(self):
        core, page, run = self.sent()
        core.handle(page._stamp({"type": "composer", "side": "project", "draft": "", "disabled": False}))
        self.assertNotIn("taken", run)


class CrossedClicks(unittest.TestCase):
    """The page clicks a send just as routerd cuts it off or replaces it: the click's `done` crosses the cancel or the retry."""
    def setUp(self):
        self.core, self.page = support.world()
        self.core.say("plain test words", project="chan_a")
        self.first = self.page.inbox.pop()  # it waits in the page, never played
        self.run = next(iter(self.core.runs.values()))

    def sends(self):
        return [c for c in self.page.inbox if c["kind"] == "send"]

    def clicked(self, id_):
        """The words typed into the draft, then the click's `done` with them still there (a click the page ignored): not taken."""
        self.core.handle(self.page._stamp({"type": "composer", "side": "project", "draft": "plain test words", "disabled": False}))
        self.core.handle(self.page._stamp({"type": "done", "id": id_, "ok": True, "error": None}))

    def cut_for_a_tool(self):
        """A dev step is in the page at the send's deadline: the send is cancelled while the tool may have a dialog open."""
        dev = self.core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/x")
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        self.assertIn(self.first["id"], [c.get("target") for c in self.page.inbox if c["kind"] == "cancel"])
        return dev

    def test_a_click_that_crosses_a_tools_cut_off_counts_and_the_next_attempt_only_clicks(self):
        dev = self.cut_for_a_tool()
        self.clicked(self.first["id"])
        self.assertTrue(self.run.get("clicked"))
        self.core.handle(self.page._stamp({"type": "done", "id": dev, "ok": True, "error": None}))  # the tool ends: the run goes on
        self.assertEqual([c.get("click_only") for c in self.sends()], [True])

    def test_a_click_that_crosses_the_deadlines_retry_counts_and_the_next_retry_only_clicks(self):
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        self.assertEqual([c.get("click_only") for c in self.sends()], [None])  # no click reported yet: the retry may type
        self.page.inbox.clear()
        self.clicked(self.first["id"])  # the first send's click, reported after the retry went down
        self.assertTrue(self.run.get("clicked"))
        support.later(self.core, routerd.TAKE_WAIT)
        self.core.tick()
        self.assertEqual([c.get("click_only") for c in self.sends()], [True])

    def test_a_replayed_click_of_a_send_cut_off_for_a_tool_counts(self):
        self.cut_for_a_tool()
        self.core.connection(False)
        self.core.connection(True)
        self.core.handle(self.page._stamp({"type": "commands", "waiting": [], "done": [{"type": "done", "id": self.first["id"], "ok": True, "error": None}]}))
        self.assertTrue(self.run.get("clicked"))

    def test_a_retry_that_crosses_the_clicks_done_never_types_the_words_again(self):
        support.later(self.core, do.TIMEOUT)
        self.core.tick()  # no click heard yet: the retry isn't click-only
        retry = self.sends()[0]
        self.assertIsNone(retry.get("click_only"))
        self.page.inbox.remove(retry)
        for command in (self.first, retry):  # the page clicks the first, and its done goes up ahead of the retry's
            for event in self.page.run(command):
                self.core.handle(event)
        self.assertEqual([d["error"] for d in self.page.recent], [None, "the words aren't in the draft"])
        self.page.pump(self.core)
        self.assertEqual((self.page.clicks, store.intent(self.core.db, self.run["id"])["status"]), (1, "confirmed"))

    def test_another_intents_same_words_after_a_click_are_typed(self):
        self.page.inbox.append(self.first)
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, self.run["id"])["status"], "confirmed")
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.assertEqual((self.page.clicks, store.intents(self.core.db, 1)[-1]["status"]), (2, "confirmed"))

    def test_an_older_sends_error_is_not_the_runs_answer(self):
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        attempts = store.intent(self.core.db, self.run["id"])["attempts"]
        self.page.inbox.clear()
        self.core.handle(self.page._stamp({"type": "done", "id": self.first["id"], "ok": False, "error": "superseded"}))
        self.core.handle(self.page._stamp({"type": "done", "id": self.first["id"], "ok": False, "error": "not on that place"}))
        self.assertEqual((self.sends(), store.intent(self.core.db, self.run["id"])["attempts"]), ([], attempts))


class Reload(unittest.TestCase):
    """The tab reloads while the host stays linked: the worker says the page is gone, and the new page knows nothing of what was sent."""
    def setUp(self):
        self.core, self.page = support.world()
        self.core.say("plain test words", project="chan_a")
        self.lost = self.page.inbox.pop()  # it went to the page that reloaded, never played
        self.run = next(iter(self.core.runs.values()))

    def sends(self):
        return [c for c in self.page.inbox if c["kind"] == "send"]

    def test_a_send_lost_with_a_reloaded_page_is_dropped_and_never_made_again(self):
        """The page it went to may have typed and clicked it before it reloaded: it is taken, and waits for its row."""
        self.page.reload(self.core, "chan_a")
        self.assertEqual((self.run["dropped"], self.run["taken"], self.sends()), (self.lost["id"], True, []))
        self.page.pump(self.core)
        intent = store.intent(self.core.db, self.run["id"])
        self.assertEqual((intent["status"], intent["attempts"], self.page.clicks), ("pending", 1, 0))

    def test_one_lost_with_a_reloaded_page_that_had_sent_it_is_proved_by_its_row(self):
        self.page.run(self.lost)  # the old page typed and clicked it, and its `done` went with it
        self.page.reload(self.core, "chan_a", pending="keyed")
        self.page.pump(self.core)
        intent = store.intent(self.core.db, self.run["id"])
        self.assertEqual((intent["status"], self.page.clicks), ("confirmed", 1))

    def test_a_command_sent_after_the_page_went_is_one_the_next_snapshot_lists(self):
        self.core.handle(self.page._stamp({"type": "page", "signed_in": None, "page_ok": False, "gone": True}))
        self.assertEqual(self.core.linked, self.core.commands)
        later = self.core.command("cancel", target="c0.0")  # queued in the worker, handed to the next page before its snapshot
        self.assertGreater(int(later.rsplit(".", 1)[1]), self.core.linked)

    def test_a_send_lost_while_the_new_page_is_signed_out_is_not_made_again_once_signed_in(self):
        self.page.signed_in = False
        self.page.reload(self.core, "chan_a")
        self.assertEqual((self.run["dropped"], self.run["paused"], self.sends()), (self.lost["id"], True, []))
        self.page.signed_in = True
        for event in self.page.load("chan_a"):
            self.core.handle(event)
        self.page.pump(self.core)
        self.assertEqual((self.run["taken"], self.sends(), store.intent(self.core.db, self.run["id"])["status"]), (True, [], "pending"))


class ReloadAfterClick(unittest.TestCase):
    """The live trace: Send clicked, the draft emptied, the message showed only as pending, and the tab reloaded (the dev `reload_tab`,
    to the projects page) before any row proved it. routerd goes back to the place, and the new page's rows say whether the server had it."""
    def setUp(self):
        self.page = fake_page.demo()
        self.page.projects["chan_a"]["chat"].append({"key": "cmsg_old", "from": "you", "text": "plain test words", "index": 0, "decision": False,
                                                     "streaming": False, "pending": False})  # the same words, long ago
        for n in range(80):  # more than a baseline holds: the oldest rows' keys aren't in it
            self.page.projects["chan_a"]["chat"].append({"key": f"cmsg_h{n}", "from": "claude", "text": f"old {n}", "index": n + 1,
                                                         "decision": False, "streaming": False, "pending": False})
        self.core, self.page = support.world(page=self.page)
        self.page.window = 12  # the page renders only the latest rows
        self.page.holds = True
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.intent = store.intents(self.core.db, 1)[-1]
        self.run = self.core.runs[self.intent["id"]]
        self.page.holds = False

    def typed(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def status(self):
        return store.intent(self.core.db, self.intent["id"])["status"]

    def older_rows_scroll_in(self):
        """The new page renders older history: a delta of rows before the window, the old row of the same words among them."""
        rows = self.page._rows("chan_a", None)
        self.core.handle(self.page._stamp({"type": "rows", "side": "project", "full": False, "rows": [dict(r) for r in rows[:10]]}))

    def test_the_click_was_taken_and_only_pending(self):
        self.assertEqual((self.status(), self.page.clicks, bool(self.run.get("taken"))), ("pending", 1, True))

    def test_a_message_the_server_had_is_proved_by_the_reloaded_rows_once(self):
        self.page.reload(self.core, None, pending="keyed")
        self.page.pump(self.core)  # routerd goes back to the place: its full scan holds the message with its key
        self.assertEqual((self.status(), self.page.clicks, len(self.typed())), ("confirmed", 1, 1))

    def test_a_message_the_reload_lost_fails_soon_and_is_never_sent_again(self):
        self.page.reload(self.core, None, pending="lost")
        self.page.pump(self.core)
        self.older_rows_scroll_in()  # old history entering the window is no proof, though an old row has the same words
        self.assertEqual(self.status(), "pending")
        for _ in range(3):
            support.later(self.core, do.TIMEOUT + 1)
            self.core.tick()
            self.page.pump(self.core)
        intent = store.intent(self.core.db, self.intent["id"])
        self.assertEqual(intent["status"], "failed")
        self.assertIn("the tab reloaded right after the click", intent["cause"])
        self.assertLess(self.core.clock.t - support.NOW, routerd.ACCEPTED_WAIT)  # not the 300 s wait for a queued message
        self.assertEqual((self.page.clicks, len(self.typed())), (1, 1))  # typed once, clicked once: no retry of any kind

    def test_a_message_the_reload_lost_fails_a_wait_after_the_reload_with_no_second_look(self):
        """Live, two waits (43-46 s): the look's open took another full wait though the reloaded page's rows had just been read."""
        self.page.reload(self.core, None, pending="lost")
        self.page.pump(self.core)
        for _ in range(4):
            if self.intent["id"] not in self.core.runs:
                break
            self.core.clock.t = self.run["deadline"]
            self.core.tick()
            self.page.pump(self.core)
        self.assertEqual(self.status(), "failed")
        self.assertLessEqual(self.core.clock.t - support.NOW, do.TIMEOUT + 1)
        self.assertEqual((self.page.clicks, len(self.typed())), (1, 1))

    def test_a_reload_long_after_the_click_waits_for_the_queued_message(self):
        """The coordinator replied for two minutes, then the tab reloaded: the message was long with the server, queued behind the turn."""
        support.later(self.core, 120)
        self.core.tick()
        self.page.pump(self.core)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        for _ in range(2):
            support.later(self.core, do.TIMEOUT + 1)
            self.core.tick()
            self.page.pump(self.core)
        self.assertEqual((self.status(), self.run.get("reloaded"), self.run.get("vanished_at")), ("pending", None, None))
        self.page.deliver("chan_a")  # the turn ends: the queued message shows with its key
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.page.clicks), ("confirmed", 1))

    def test_reloaded_rows_that_hold_none_of_the_baseline_say_nothing(self):
        self.page.reload(self.core, None, pending="lost")
        rows = self.page._rows("chan_a", None)
        self.page.whole = lambda pid, thread=None: self.page._stamp({"type": "rows", "side": "project", "full": True, "rows": [dict(r) for r in rows[:10]]})
        self.page.pump(self.core)  # the new page shows only older history, the old row of the same words in it: no proof, no early look
        support.later(self.core, 3 * do.TIMEOUT)
        self.core.tick()
        self.assertEqual((self.status(), self.run.get("vanished_at"), self.page.clicks), ("pending", None, 1))
        del self.page.whole
        self.page.post("chan_a", "you", "plain test words")  # it reached the server after all
        self.core.handle(self.page.whole("chan_a"))  # the bottom of the chat, placed by the baseline's keys, proves it
        self.page.pump(self.core)
        self.assertEqual((self.status(), len(self.typed())), ("confirmed", 1))

    def test_a_lost_message_the_server_shows_late_is_still_confirmed(self):
        self.page.reload(self.core, None, pending="lost")
        self.page.pump(self.core)
        self.page.post("chan_a", "you", "plain test words")  # it reached the server after all, after the new page's read
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.page.clicks, len(self.typed())), ("confirmed", 1, 1))

    def test_a_reload_onto_the_place_itself_proves_it_too(self):
        self.page.reload(self.core, "chan_a", pending="keyed")
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.page.clicks, len(self.typed())), ("confirmed", 1, 1))


class ReloadRightAfterAClick(unittest.TestCase):
    """The click was reported, but the page went before its draft was seen empty, and the reloaded page put the words back in the draft
    (its saved draft): the old page may have given the server the words, so nothing is clicked again."""
    def setUp(self):
        self.core, self.page = support.world()
        self.core.say("plain test words", project="chan_a")
        send = self.page.inbox.pop()
        self.page.swallow = True  # the old page went before the server had them
        typed, done = [e for e in self.page.run(send) if e["type"] in ("composer", "done")][:2]  # the draft emptied after: never heard
        self.core.handle(typed)
        self.core.handle(done)
        self.intent = store.intents(self.core.db, 1)[-1]
        self.run = self.core.runs[self.intent["id"]]
        self.page.swallow = False
        self.page.projects["chan_a"]["draft"] = "plain test words"

    def sends(self):
        return [c for c in self.page.inbox if c["kind"] == "send"]

    def finish(self):
        for _ in range(4):
            if self.intent["id"] not in self.core.runs:
                break
            self.core.clock.t = self.run["deadline"]
            self.core.tick()
            self.page.pump(self.core)
        intent = store.intent(self.core.db, self.intent["id"])
        self.assertEqual((intent["status"], intent["cause"], self.page.clicks), ("failed", routerd.VANISHED, 1))
        self.assertLessEqual(self.core.clock.t - support.NOW, do.TIMEOUT + 1)

    def test_the_words_back_in_the_reloaded_draft_are_not_clicked_again(self):
        self.assertEqual((self.run.get("clicked"), self.run.get("taken")), (True, None))
        self.page.reload(self.core, "chan_a", pending="lost")
        self.assertEqual(self.sends(), [])  # not even click-only
        self.page.pump(self.core)
        self.finish()

    def test_a_reloaded_run_paused_by_a_signed_out_page_waits_only_for_its_row_once_signed_in(self):
        self.page.signed_in = False
        self.page.reload(self.core, "chan_a", pending="lost")
        support.later(self.core, 5)
        self.page.signed_in = True
        for event in self.page.load("chan_a"):
            self.core.handle(event)
        self.assertEqual(self.sends(), [])
        self.page.pump(self.core)
        self.finish()


class Anchors(unittest.TestCase):
    """A busy chat: the coordinator's turn writes more rows than the page's window holds while your message is queued behind it, so a
    full scan holds none of the baseline's keys. The rows read after the baseline place it instead."""
    def setUp(self):
        page = fake_page.demo()
        for n in range(20):
            page.projects["chan_a"]["chat"].append({"key": f"cmsg_h{n}", "from": "claude", "text": f"old {n}", "index": n, "decision": False,
                                                    "streaming": False, "pending": False})
        self.core, self.page = support.world(page=page)
        self.page.window = 12
        self.page.holds = True
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.intent = store.intents(self.core.db, 1)[-1]
        for n in range(15):
            self.page.post("chan_a", "claude", f"step {n}")
        self.page.pump(self.core)

    def status(self):
        return store.intent(self.core.db, self.intent["id"])["status"]

    def test_a_window_scrolled_past_the_baseline_still_proves_the_message(self):
        self.core.handle(self.page.whole("chan_a"))  # the look's open, or the tab coming back: only the latest steps
        self.page.pump(self.core)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.page.clicks), ("confirmed", 1))

    def test_it_is_proved_before_the_wait_for_a_queued_message_ends(self):
        self.core.handle(self.page.whole("chan_a"))
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.core.clock.t), ("confirmed", support.NOW))

    def test_the_anchors_are_rows_not_from_you_after_the_baseline(self):
        proof = store.intent(self.core.db, self.intent["id"])["proof"]
        steps = [r["key"] for r in self.page.projects["chan_a"]["chat"] if r["text"].startswith("step")]
        self.assertEqual(proof.get("anchors"), steps)  # your pending row never reaches the Board


class AnchorOrder(unittest.TestCase):
    """Where a read is cut: after the last baseline key it holds, else after the earliest anchor. Your row, queued while Claude's rows
    were written and anchored, can take its key before them."""
    def row(self, key, who="claude"):
        return {"key": key, "from": who, "text": "hi there" if who == "you" else "x", "streaming": False}

    def board(self, *rows):
        return {"projects": {"chan_a": {"chat": [{**r, "index": n} for n, r in enumerate(rows)]}}, "threads": {}}

    def proof(self, **more):
        return {"project": "chan_a", "thread": None, "words": "hi there", "baseline": ["b1", "b2"], **more}

    def test_a_row_anchored_after_your_pending_row_doesnt_hide_it(self):
        proof = do.anchor(self.board(self.row("b1"), self.row("b2"), self.row("k3")), self.proof())
        self.assertEqual(proof["anchors"], ["k3"])
        self.assertEqual(do.proved(self.board(self.row("b1"), self.row("b2"), self.row("you", "you"), self.row("k3")), proof), (True, None, "you"))

    def test_with_no_baseline_key_the_earliest_anchor_places_the_read(self):
        proof = self.proof(anchors=["k3", "k4"])
        self.assertEqual(do.proved(self.board(self.row("k3"), self.row("you", "you"), self.row("k4")), proof), (True, None, "you"))

    def test_rows_before_the_earliest_anchor_are_not_new(self):
        proof = self.proof(anchors=["k3", "k4"])
        self.assertEqual(do.proved(self.board(self.row("old", "you"), self.row("k3"), self.row("k4")), proof), (False, None, None))

    def test_a_baseline_key_wins_over_the_anchors(self):
        proof = self.proof(anchors=["k3"])
        self.assertEqual(do.proved(self.board(self.row("b2"), self.row("k3"), self.row("you", "you")), proof), (True, None, "you"))
        self.assertEqual(do.proved(self.board(self.row("k3"), self.row("b2"), self.row("x")), proof), (False, None, None))

    def test_only_claudes_rows_are_anchored(self):
        proof = do.anchor(self.board(self.row("b2"), self.row("u3", "unknown"), self.row("k4")), self.proof())
        self.assertEqual(proof["anchors"], ["k4"])  # a row read as unknown may later be yours


class VanishedLate(unittest.TestCase):
    """A reload 2 s after the click, the message already with the server and queued behind the coordinator's turn: the reloaded page
    shows it only once the turn ends, after the run failed as VANISHED."""
    def setUp(self):
        page = fake_page.demo()
        for n in range(3):
            page.projects["chan_a"]["chat"].append({"key": f"cmsg_h{n}", "from": "claude", "text": f"old {n}", "index": n, "decision": False,
                                                    "streaming": False, "pending": False})
        self.core, self.page = support.world(page=page)
        self.page.holds = True
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.intent = store.intents(self.core.db, 1)[-1]
        self.run = self.core.runs[self.intent["id"]]

    def status(self):
        i = store.intent(self.core.db, self.intent["id"])
        return i["status"], i["cause"]

    def run_out(self):
        for _ in range(4):
            if self.intent["id"] not in self.core.runs:
                break
            self.core.clock.t = self.run["deadline"]
            self.core.tick()
            self.page.pump(self.core)
        self.assertEqual(self.status(), ("failed", routerd.VANISHED))

    def test_a_queued_message_shown_after_the_failure_is_confirmed_late(self):
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        self.run_out()
        support.later(self.core, 60)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        status, cause = self.status()
        self.assertEqual(status, "confirmed")
        self.assertIn("confirmed late", cause)
        self.assertEqual(self.page.clicks, 1)

    def test_it_is_watched_only_for_the_wait_of_a_queued_message(self):
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        self.run_out()
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.core.watched), (("failed", routerd.VANISHED), {}))

    def test_a_partial_first_render_then_the_bottom_confirms_it(self):
        """The reloaded page showed the projects page; the place's rows came well after the wait, first without the bottom."""
        self.page.reload(self.core, None, pending="keyed")
        self.page.inbox.clear()  # the run's way back to its place is never played: the place shows later, by itself
        support.later(self.core, do.TIMEOUT + 5)
        self.page.at = ("chan_a", None)
        rows = self.page._rows("chan_a", None)
        for event in self.page.load("chan_a"):
            if event["type"] == "rows":  # the first render: the older rows, not yet the bottom
                event = {**event, "rows": [dict(r) for r in rows[:-1]]}
            self.core.handle(event)
        self.assertEqual(self.status()[0], "pending")
        self.core.handle(self.page._stamp({"type": "rows", "side": "project", "full": False, "rows": [dict(rows[-1])]}))
        self.assertEqual(self.status(), ("confirmed", None))

    def test_an_unsettled_reloaded_read_is_no_sign_the_words_vanished(self):
        """The reloaded page's first read of the place isn't settled and lacks the bottom: past VANISH_GRACE it still says nothing, and
        the settled read that holds the row proves the send in its own run."""
        rows = self.page._rows("chan_a", None)
        self.page.whole = lambda pid, thread=None: self.page._stamp({"type": "rows", "side": "project", "full": True, "settled": False,
                                                                     "rows": [dict(r) for r in rows[:-1]]})
        self.page.rendering.add(("chan_a", None))
        self.page.owed.add(("chan_a", None))
        self.page.reload(self.core, "chan_a", pending="keyed")
        self.page.pump(self.core)
        support.later(self.core, do.TIMEOUT + 5)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual((self.status()[0], self.run.get("vanished_at")), ("pending", None))
        del self.page.whole
        self.page.render("chan_a")
        self.page.pump(self.core)
        self.assertEqual((self.status(), self.page.clicks), (("confirmed", None), 1))


    def test_a_sleep_does_not_use_up_the_watch(self):
        """No run is left to see the clock jump: the watch is on uptime, which stands still while the Mac sleeps."""
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        self.run_out()
        support.sleep(self.core, 3 * 3600)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual(self.status()[0], "confirmed")


class OneRowOneSend(unittest.TestCase):
    """A send failed as VANISHED is watched for a late row of yours, and a new send of the same words to the same place starts meanwhile:
    one row proves one send, and the live one claims it first."""
    def setUp(self):
        VanishedLate.setUp(self)

    status = VanishedLate.status
    run_out = VanishedLate.run_out

    def again(self):
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def test_one_row_confirms_only_the_new_send(self):
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending="lost")  # the old page went before the server had the words
        self.page.pump(self.core)
        self.run_out()
        self.page.holds = False
        b = self.again()
        self.assertEqual(b["status"], "confirmed")
        self.assertEqual(self.status(), ("failed", routerd.VANISHED))
        self.assertIn(self.intent["id"], self.core.watched)  # still watched: its words may yet show
        mine = [r["key"] for r in self.page.projects["chan_a"]["chat"] if r["from"] == "you"]
        self.assertEqual((b["result"]["row"], self.core.claimed[("chan_a", None)]), (mine[-1], {mine[-1]}))

    def test_two_rows_confirm_both(self):
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)  # the server had them, queued behind the coordinator's turn
        self.page.pump(self.core)
        self.run_out()
        b = self.again()  # queued too
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        a, b = store.intent(self.core.db, self.intent["id"]), store.intent(self.core.db, b["id"])
        self.assertEqual((a["status"], b["status"]), ("confirmed", "confirmed"))
        self.assertNotEqual(a["result"]["row"], b["result"]["row"])

    def test_the_claims_survive_a_restart(self):
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        a = store.intent(self.core.db, self.intent["id"])
        again = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        self.assertEqual((a["status"], again.claimed), ("confirmed", {("chan_a", None): {a["result"]["row"]}}))


class PartialFirstRender(unittest.TestCase):
    """The tab opens the place, and the page's first render lacks the bottom rows: an old row of yours with the same words, brought by the
    next delta, is no proof."""
    def old(self, page, pid):
        for n in range(3):
            page.projects[pid]["chat"].append({"key": f"cmsg_h{n}", "from": "claude", "text": f"old {n}", "index": n, "decision": False,
                                               "streaming": False, "pending": False})
        page.projects[pid]["chat"].append({"key": "cmsg_bottom", "from": "you", "text": "continue", "index": 3, "decision": False,
                                           "streaming": False, "pending": False})

    def first_render(self, core, page, settled):
        """Plays the run's open, with a whole read that lacks the bottom row."""
        opened = [c for c in page.inbox if c["kind"] == "open"]
        self.assertEqual(len(opened), 1)
        page.inbox.remove(opened[0])
        for event in page.run(opened[0]):
            if event["type"] == "rows":
                event = {**event, "rows": event["rows"][:-1], "settled": settled}
            core.handle(event)

    def bottom(self, core, page, pid):
        core.handle(page._stamp({"type": "rows", "side": "project", "full": False, "rows": [dict(page.projects[pid]["chat"][-1])]}))

    def test_a_chat_fjord_has_seen_is_baselined_with_its_stored_rows(self):
        page = fake_page.demo()
        self.old(page, "chan_a")
        core, page = support.world(page=page)
        for event in page.load("chan_b"):  # the tab moves away: chan_a's rows are read afresh on the way back
            core.handle(event)
        core.say("continue", project="chan_a")
        self.first_render(core, page, settled=True)  # settled, yet without the bottom: the stored keys fill the baseline in
        self.assertEqual([c["kind"] for c in page.inbox], ["send"])  # no added wait
        self.bottom(core, page, "chan_a")
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual(intent["status"], "pending")
        self.assertIn("cmsg_bottom", intent["proof"]["baseline"])
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], page.clicks), ("confirmed", 1))
        self.assertNotEqual(intent["result"]["row"], "cmsg_bottom")

    def test_a_chat_with_no_stored_rows_waits_for_a_settled_read(self):
        page = fake_page.demo()
        page.add_project("chan_c", "gamma")
        self.old(page, "chan_c")
        page.mounting.add(("chan_c", None))  # never shown with rows: Fjord stores none of it
        core, page = support.world(page=page)
        page.mounting.clear()
        core.say("continue", project="chan_c")
        self.first_render(core, page, settled=False)
        self.bottom(core, page, "chan_c")
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], "baseline" in intent["proof"], [c["kind"] for c in page.inbox]), ("pending", False, []))
        core.handle(page.whole("chan_c"))  # the page's render is done
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], page.clicks), ("confirmed", 1))
        self.assertIn("cmsg_bottom", intent["proof"]["baseline"])

    def away(self, page, pid):
        """A row of yours is added while the tab is elsewhere: Fjord never read it."""
        rows = page.projects[pid]["chat"]
        rows.append({"key": "cmsg_away", "from": "you", "text": "continue", "index": len(rows), "decision": False, "streaming": False, "pending": False})

    def check_waits_for_a_settled_read(self, core, page):
        core.say("continue", project="chan_a")
        self.first_render(core, page, settled=False)  # without the row added while away
        self.bottom(core, page, "chan_a")  # the next delta brings it: an old row, no proof
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], "baseline" in intent["proof"], [c["kind"] for c in page.inbox]), ("pending", False, []))
        core.handle(page.whole("chan_a"))
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], page.clicks), ("confirmed", 1))
        self.assertNotEqual(intent["result"]["row"], "cmsg_away")

    def test_a_seen_chat_with_a_row_added_while_away_waits_for_a_settled_read(self):
        page = fake_page.demo()
        self.old(page, "chan_a")
        core, page = support.world(page=page)
        for event in page.load("chan_b"):
            core.handle(event)
        self.away(page, "chan_a")
        self.check_waits_for_a_settled_read(core, page)

    def test_after_a_restart_a_seen_chat_waits_for_a_settled_read(self):
        """A restart starts with no place shown: the first place the tab shows is arrived on, and unsettled until its render is done."""
        page = fake_page.demo()
        self.old(page, "chan_a")
        core, page = support.world(page=page)
        self.away(page, "chan_a")
        again = routerd.Core(core.db, page.receive, clock=core.clock, uptime=core.clock.uptime)
        self.assertIn("cmsg_bottom", again.known["chan_a"])
        again.connection(True)
        page.inbox.clear()  # the host's wake
        for event in page.load("chan_b"):
            again.handle(event)
        self.check_waits_for_a_settled_read(again, page)

    def test_a_place_that_never_settles_fails_as_such(self):
        page = fake_page.demo()
        self.old(page, "chan_a")
        core, page = support.world(page=page)
        for event in page.load("chan_b"):
            core.handle(event)
        core.say("continue", project="chan_a")
        self.first_render(core, page, settled=False)
        intent = store.intents(core.db, 1)[-1]
        core.clock.t = core.runs[intent["id"]]["deadline"]
        core.tick()
        intent = store.intent(core.db, intent["id"])
        self.assertEqual((intent["status"], intent["cause"], page.clicks), ("failed", "the page never settled on that place", 0))

    def test_an_unsettled_read_of_a_settled_place_waits_for_the_owed_settled_one(self):
        """A snapshot (or a forced scan) of a place that had settled isn't settled itself: the place is unsettled again, the page owes the
        settled read, and its next scan sends it."""
        core, page = support.world()
        page.post("chan_a", "claude", "hello")
        page.pump(core)
        self.assertEqual((page.at, "chan_a" in core.unsettled), (("chan_a", None), False))
        page.rendering.add(("chan_a", None))
        core.handle(page.whole("chan_a"))
        core.say("plain test words", project="chan_a")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], page.clicks, "chan_a" in core.unsettled), ("pending", 0, True))
        page.render("chan_a")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], page.clicks, "chan_a" in core.unsettled), ("confirmed", 1, False))


class FreshOpen(unittest.TestCase):
    """A project the tab shows whose chat the page never fetched since it arrived never settles: FRESH_AFTER past the arrival, a send
    waiting for its settled read opens it `fresh`, once, and the page goes to `/code` and back, which fetches it."""
    def setUp(self):
        self.core, self.page = support.world()
        self.page.post("chan_a", "claude", "hello")
        self.page.pump(self.core)
        for event in self.page.load("chan_b"):
            self.core.handle(event)
        self.page.unfetched.add(("chan_a", None))
        for event in self.page.load("chan_a"):  # the tab shows chan_a again by itself, its chat not fetched: unsettled
            self.core.handle(event)
        self.assertIn("chan_a", self.core.unsettled)

    def opens(self):
        return [c for c in self.page.calls if c[0] == "open"]

    def fresh_opens(self, sent):
        return [c for c in sent if c["kind"] == "open" and c.get("fresh")]

    def test_a_send_opens_it_fresh_once_past_the_bound(self):
        sent = []
        self.page.receive = lambda c: (sent.append(c), self.page.inbox.append(c))
        self.core.out = self.page.receive
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        run = next(iter(self.core.runs.values()))
        self.assertEqual((self.fresh_opens(sent), self.page.clicks, run["fresh_at"]), ([], 0, support.NOW + routerd.FRESH_AFTER))
        self.assertEqual(self.core.next_deadline(), support.NOW + routerd.FRESH_AFTER)
        self.core.clock.t = run["fresh_at"]
        self.core.tick()
        self.page.pump(self.core)
        intent = store.intents(self.core.db, 1)[-1]
        self.assertEqual((intent["status"], self.page.bounces, self.page.clicks, len(self.fresh_opens(sent))), ("confirmed", 1, 1, 1))

    def test_one_that_still_never_settles_fails_as_such(self):
        sent = []
        self.page.receive = lambda c: (sent.append(c), self.page.inbox.append(c))
        self.core.out = self.page.receive
        self.page.rendering.add(("chan_a", None))  # the fetch comes, its render never settles
        support.later(self.core, routerd.FRESH_AFTER)  # already past the bound: the first open is the fresh one
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        intent = store.intents(self.core.db, 1)[-1]
        self.assertEqual((len(self.fresh_opens(sent)), self.page.bounces), (1, 1))
        self.core.clock.t = self.core.runs[intent["id"]]["deadline"]
        self.core.tick()
        self.page.pump(self.core)
        intent = store.intent(self.core.db, intent["id"])
        self.assertEqual((intent["status"], intent["cause"], len(self.fresh_opens(sent)), self.page.clicks),
                         ("failed", "the page never settled on that place", 1, 0))

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_project_send_beside_an_open_thread_bounces_too(self):
        """The tab shows a thread beside the unsettled project: the project open still counts it shown, bounces through `/code`, whose
        list is never `complete`, and comes back."""
        for event in self.page.load("chan_a", "cmsg_1"):  # a thread's open is no arrival: the project stays unsettled
            self.core.handle(event)
        self.assertIn("chan_a", self.core.unsettled)
        sent, seen = [], []
        self.page.receive = lambda c: (sent.append(c), self.page.inbox.append(c))
        self.core.out = self.page.receive
        handle = self.core.handle
        self.core.handle = lambda e: (seen.append(e), handle(e))
        support.later(self.core, routerd.FRESH_AFTER)
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        intent = store.intents(self.core.db, 1)[-1]
        self.assertEqual((intent["status"], self.page.bounces, self.page.clicks, len(self.fresh_opens(sent))), ("confirmed", 1, 1, 1))
        self.assertIn("/code", [e.get("path") for e in seen])
        self.assertFalse(any(e["type"] == "projects" and e.get("complete") for e in seen))

    def test_a_thread_send_is_never_opened_fresh(self):
        self.page.unfetched.clear()
        self.assertIsNone(self.core.stale(self.core.board(), ("chan_a", "cmsg_1")))


class ThreadOnlyArrival(unittest.TestCase):
    """Opening a thread in the shown project keeps the project's chat as the page renders it beside the thread: it isn't read afresh,
    and a project send needs no settled read again."""
    def test_a_thread_open_keeps_the_project_settled(self):
        core, page = support.world()
        page.post("chan_a", "claude", "hello")
        page.pump(core)
        arrived = core.arrived
        for event in page.load("chan_a", "cmsg_1"):
            core.handle(event)
        chat = routerd.boards.place_of(core.board(), "chan_a", None).get("chat")
        self.assertEqual(("chan_a" in core.unsettled, "cmsg_1" in core.unsettled, chat is not None, core.arrived), (False, False, True, arrived))
        support.later(core, 5)
        core.say("plain test words", project="chan_a")
        self.assertEqual([c["kind"] for c in page.inbox], ["send"])  # no open, no wait for a settled read
        page.pump(core)
        self.assertEqual((store.intents(core.db, 1)[-1]["status"], page.clicks), ("confirmed", 1))

    def test_another_project_is_an_arrival(self):
        core, page = support.world()
        for event in page.load("chan_b"):
            core.handle(event)
        self.assertEqual(core.arrived, ("chan_b", support.NOW))


class BoundedProof(unittest.TestCase):
    """A send's proof stays small however long the chat: its baseline takes the latest do.KNOWN stored keys, and a finished send keeps
    only a tail of it."""
    def long_chat(self, page, n):
        for i in range(n):
            page.projects["chan_a"]["chat"].append({"key": f"cmsg_h{i}", "from": "claude", "text": f"old {i}", "index": i, "decision": False,
                                                    "streaming": False, "pending": False})

    def test_the_baseline_takes_the_latest_stored_keys(self):
        page = fake_page.demo()
        self.long_chat(page, 600)
        page.window = 600  # the first read shows them all, so Seen holds them all
        core, page = support.world(page=page)
        self.assertEqual(list(core.known["chan_a"])[-1], "cmsg_h599")
        page.window = 50
        proof = do.baselined(core.board(), {"project": "chan_a", "thread": None, "words": "w"}, core.known["chan_a"])
        self.assertEqual(len(proof["baseline"]), do.KEYS + do.KNOWN)
        self.assertEqual(proof["baseline"][:1] + proof["baseline"][-1:], ["cmsg_h350", "cmsg_h599"])  # the screen's latest last

    def test_a_read_moves_its_keys_to_the_end(self):
        core, page = support.world()
        core.remember("p", [{"key": "a", "index": 0}, {"key": "b", "index": 1}, {"key": "c", "index": 2}])
        core.remember("p", [{"key": "a", "index": 5}])
        self.assertEqual(list(core.known["p"]), ["b", "c", "a"])

    def test_a_finished_send_keeps_a_tail_of_its_proof(self):
        page = fake_page.demo()
        self.long_chat(page, 100)
        core, page = support.world(page=page)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual(intent["status"], "confirmed")
        self.assertEqual(intent["proof"]["baseline"], [f"cmsg_h{i}" for i in range(95, 100)])
        self.assertIn("chan_a", store.chat_projects(core.db))

    def test_a_send_failed_as_vanished_keeps_its_whole_proof(self):
        VanishedLate.setUp(self)
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        with unittest.mock.patch.object(do, "KEPT", 1):
            VanishedLate.run_out(self)
        self.assertEqual(store.intent(self.core.db, self.intent["id"])["proof"]["baseline"], ["cmsg_h0", "cmsg_h1", "cmsg_h2"])

    def vanish(self):
        VanishedLate.setUp(self)
        support.later(self.core, 2.0)
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        VanishedLate.run_out(self)

    def test_a_vanished_send_keeps_a_tail_once_its_watch_ends(self):
        with unittest.mock.patch.object(do, "KEPT", 1):
            self.vanish()
            support.later(self.core, routerd.ACCEPTED_WAIT + 1)
            self.page.post("chan_a", "claude", "later")  # any read of a place ends a watch that expired
            self.page.pump(self.core)
        self.assertEqual((self.core.watched, store.intent(self.core.db, self.intent["id"])["proof"]["baseline"]), ({}, ["cmsg_h2"]))

    def test_a_vanished_send_keeps_a_tail_at_the_tick_that_ends_its_watch(self):
        """No read of the place is needed: the watch's end is a deadline, and its tick cuts the proof."""
        with unittest.mock.patch.object(do, "KEPT", 1):
            self.vanish()
            end = self.core.next_deadline()
            self.assertEqual(end, self.core.clock() + routerd.ACCEPTED_WAIT)
            self.core.clock.t = end
            self.core.tick()
        self.assertEqual((self.core.watched, store.intent(self.core.db, self.intent["id"])["proof"]["baseline"], self.core.next_deadline()),
                         ({}, ["cmsg_h2"], None))

    def test_a_vanished_send_confirmed_late_keeps_a_tail(self):
        with unittest.mock.patch.object(do, "KEPT", 1):
            self.vanish()
            self.page.deliver("chan_a")
            self.page.pump(self.core)
        intent = store.intent(self.core.db, self.intent["id"])
        self.assertEqual((intent["status"], intent["proof"]["baseline"]), ("confirmed", ["cmsg_h2"]))

    def test_a_start_cuts_the_proofs_no_watch_holds_to_their_tail(self):
        """A send failed as VANISHED whose watch is over keeps only the tail; the time it was updated stays. One with no click reported
        that the start itself fails (`routerd restarted before the words were proved`) issued a send (it has a baseline), which may have
        clicked with no `done` heard: it is watched, its whole proof kept."""
        self.vanish()
        vanished = store.intent(self.core.db, self.intent["id"])
        self.page.composerless = True  # the send waits in the page: never clicked
        self.core.say("other words", project="chan_a")
        self.page.pump(self.core)
        live = store.intents(self.core.db, 1)[-1]
        self.assertEqual((live["status"], len(live["proof"]["baseline"]) > 1), ("pending", True))
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        with unittest.mock.patch.object(do, "KEPT", 1):
            again = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock, uptime=self.core.clock.uptime)
        vanished_now, live = store.intent(self.core.db, vanished["id"]), store.intent(self.core.db, live["id"])
        self.assertEqual((vanished_now["proof"]["baseline"], vanished_now["updated"], list(again.watched)), (["cmsg_h2"], vanished["updated"], [live["id"]]))
        self.assertEqual((live["status"], live["cause"], len(live["proof"]["baseline"]) > 1), ("failed", "routerd restarted before the words were proved", True))

    def test_a_start_watches_again_the_sends_failed_after_a_click_for_the_rest_of_their_watch(self):
        """One failed as VANISHED 60 s before, and one that clicked the start itself fails: both keep their whole proof, and a later row of
        each confirms it."""
        self.vanish()
        self.page.holds = True
        self.core.say("other words", project="chan_a")
        self.page.pump(self.core)
        live = store.intents(self.core.db, 1)[-1]
        support.later(self.core, 60)
        with unittest.mock.patch.object(do, "KEPT", 1):
            again = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock, uptime=self.core.clock.uptime)
        now = self.core.clock.uptime()
        self.assertEqual(again.watched, {self.intent["id"]: now + routerd.ACCEPTED_WAIT - 60, live["id"]: now + routerd.ACCEPTED_WAIT})
        self.assertGreater(len(store.intent(self.core.db, self.intent["id"])["proof"]["baseline"]), 1)
        self.page.connect(again)
        self.page.deliver("chan_a")
        self.page.pump(again)
        self.assertEqual([store.intent(self.core.db, i)["status"] for i in (self.intent["id"], live["id"])], ["confirmed", "confirmed"])

    status = VanishedLate.status

    def test_the_log_and_the_start_scans_read_no_proofs(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        page.pump(core)
        self.assertNotIn("proof", store.intents(core.db, 100, columns=store.BRIEF)[-1])
        self.assertEqual(set(store.intents(core.db, -1, status="confirmed", columns=store.LEAN)[-1]),
                         {"id", "tool", "status", "project", "thread", "result"})


class Mounting(unittest.TestCase):
    def test_a_send_waits_for_the_transcript_and_an_old_row_of_the_same_words_is_no_proof(self):
        page = fake_page.demo()
        page.add_project("chan_c", "gamma")
        page.projects["chan_c"]["chat"].append({"key": "cmsg_old", "from": "you", "text": "plain test words", "index": 0, "decision": False,
                                                "streaming": False, "pending": False})
        page.mounting.add(("chan_c", None))
        core, page = support.world(page=page)
        self.assertIsNone(core.board()["projects"]["chan_c"]["chat"])  # no rows yet: not an empty chat
        core.say("plain test words", project="chan_c")
        page.pump(core)
        self.assertEqual((page.clicks, store.intents(core.db, 1)[-1]["status"]), (0, "pending"))
        page.mount("chan_c")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((page.clicks, intent["status"], intent["proof"]["baseline"]), (1, "confirmed", ["cmsg_old"]))


    def test_rows_that_arrive_after_the_transcript_mounted_empty_are_not_news(self):
        page = fake_page.demo()
        page.add_project("chan_c", "gamma")
        page.mounting.add(("chan_c", None))  # its sizer is there, but hasn't stayed empty across a flush: no empty baseline yet
        core, page = support.world(page=page)
        core.say("plain test words", project="chan_c")
        page.pump(core)
        self.assertEqual((page.clicks, core.board()["projects"]["chan_c"]["chat"]), (0, None))
        for n in range(3):  # the page renders the chat's history into the sizer
            page.projects["chan_c"]["chat"].append({"key": f"cmsg_old{n}", "from": "claude" if n else "you", "text": f"old message {n}", "index": n,
                                                    "decision": False, "streaming": False, "pending": False})
        page.mount("chan_c")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((page.clicks, intent["status"], intent["proof"]["baseline"]), (1, "confirmed", ["cmsg_old0", "cmsg_old1", "cmsg_old2"]))
        self.assertEqual([f for f in core.tell() if "old message" in str(f)], [])

    def test_an_empty_chat_is_sent_to_once_a_flush_finds_it_still_empty(self):
        page = fake_page.demo()
        page.add_project("chan_c", "gamma")
        page.mounting.add(("chan_c", None))
        core, page = support.world(page=page)
        core.say("plain test words", project="chan_c")
        page.pump(core)
        self.assertEqual(page.clicks, 0)
        page.mount("chan_c")  # a later flush changed nothing inside the sizer: the chat is empty
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((page.clicks, intent["status"], intent["proof"]["baseline"]), (1, "confirmed", []))


class Sleep(unittest.TestCase):
    def test_a_clock_jump_moves_the_deadline_on_instead_of_acting(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        before = len(page.inbox)
        support.later(core, 3 * 3600)
        core.tick()
        self.assertEqual(len(page.inbox), before)
        self.assertEqual(core.next_deadline(), core.clock() + do.TIMEOUT)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")

    def test_a_clock_jump_does_not_use_up_the_wait_for_a_taken_message(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        page.swallow = True
        page.pump(core)
        self.assertTrue(next(iter(core.runs.values()))["taken"])
        support.later(core, 3 * 3600)
        core.tick()
        core.handle(page._stamp({"type": "composer", "side": "project", "draft": "", "disabled": False}))
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")
        self.assertEqual(core.next_deadline(), core.clock() + do.TIMEOUT)
        support.later(core, do.TIMEOUT)
        core.tick()
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")


@support.python_only("routerd.watch: process glue (CourierHostTests)")
class Watching(unittest.TestCase):
    class Fake:
        """A watcher whose wait blocks until the test fires an event."""
        def __init__(self, fired):
            self.fired = fired

        def wait(self):
            self.fired.wait()
            self.fired.clear()

        def close(self):
            pass

    def test_the_local_files_are_looked_at_once_at_start_and_then_only_on_an_event(self):
        fired, passes = threading.Event(), threading.Semaphore(0)

        class Core:
            def local(self, local):
                passes.release()

            def connected(self):
                return True

            def recheck_pauses(self):
                pass
        threading.Thread(target=routerd.watch, args=(Core(), lambda *a: self.Fake(fired), lambda: {}, lambda **k: ([], [])), daemon=True).start()
        self.assertTrue(passes.acquire(timeout=5))
        self.assertFalse(passes.acquire(timeout=0.2))  # nothing changed: no pass
        fired.set()
        self.assertTrue(passes.acquire(timeout=5))
        self.assertFalse(passes.acquire(timeout=0.2))


    def test_chrome_is_watched_only_while_the_page_is_away(self):
        class Stop(BaseException):  # out of the loop after one pass (watch logs and goes on after an Exception)
            pass
        for connected in (True, False):
            asked = []

            class Core:
                def connected(self):
                    return connected

                def local(self, local):
                    raise Stop

            def watched(**k):
                asked.append(k["chrome"])
                return [], []
            with self.assertRaises(Stop):
                routerd.watch(Core(), lambda *a: None, lambda: {}, watched)
            self.assertEqual(asked, [not connected])

    def test_the_page_going_away_wakes_the_watcher_at_once(self):
        passes = threading.Semaphore(0)

        class Core:
            def connected(self):
                return True

            def local(self, local):
                passes.release()

            def recheck_pauses(self):
                pass
        core = Core()
        threading.Thread(target=routerd.watch, args=(core, kwatch.Watch, lambda: {}, lambda **k: ([], [])), daemon=True).start()
        self.assertTrue(passes.acquire(timeout=5))
        self.assertFalse(passes.acquire(timeout=0.2))  # nothing armed: only the slow pass, SLOW seconds away
        core.gone()
        self.assertTrue(passes.acquire(timeout=5))

    def test_away_chrome_running_is_watched_for_its_exit_and_not_running_by_its_folder(self):
        with tempfile.TemporaryDirectory() as d:
            original, look.CHROME_DIR = look.CHROME_DIR, d
            try:
                running = look.watched(sessions=d + "/s/*.json", registry=d + "/r/*.json", apps=[1], chrome=True, chromes=[4242])
                closed = look.watched(sessions=d + "/s/*.json", registry=d + "/r/*.json", apps=[1], chrome=True, chromes=[])
                here = look.watched(sessions=d + "/s/*.json", registry=d + "/r/*.json", apps=[1], chrome=False, chromes=[4242])
            finally:
                look.CHROME_DIR = original
        self.assertEqual(((4242, d) in running[1], d in running[0]), (True, False))
        self.assertEqual((4242 in [p for p, _ in closed[1]], d in closed[0]), (False, True))
        self.assertEqual((4242 in [p for p, _ in here[1]], d in here[0]), (False, False))


class Pauses(unittest.TestCase):
    def test_a_paused_send_says_why_again_when_rechecked(self):
        core, page = support.world()
        page.connected = False
        core.connection(False)
        core.say("words for alpha", project="alpha")
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual(intent["status"], "paused")
        store.update_intent(core.db, core.clock(), intent["id"], cause="an old reason")
        core.recheck_pauses()
        self.assertIn(store.intent(core.db, intent["id"])["cause"], (do.CHROME_OPEN, "Chrome isn't running"))

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_paused_run_that_waited_for_the_tab_goes_on_when_the_newer_run_that_held_it_lets_it_go_in_the_same_pass(self):
        for let_go in (lambda core, run: run.update(stage="prove"), lambda core, run: core.runs.pop(run["id"])):  # it yields, or finishes
            core, _ = support.world()
            visits = []

            def advance(run, late=False):
                visits.append(run["id"])
                if run["id"] == 2:
                    let_go(core, run)
            core.advance = advance
            core.runs = {1: {"id": 1, "stage": "start", "paused": True, "tool": True, "deadline": None},
                         2: {"id": 2, "stage": "act", "paused": False, "tool": True, "deadline": None}}
            core.advance_all()
            self.assertEqual(visits, [2, 1])


class DevCommands(unittest.TestCase):
    def setUp(self):
        self.core, self.page = support.world()
        self.page.projects["chan_a"]["settings"]["folders"] = ["/Users/o/code"]
        self.replies = []

    def remove(self, path):
        self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path=path)
        self.page.pump(self.core)

    def test_a_dev_command_gets_the_pages_done_and_makes_no_intent(self):
        before = len(store.intents(self.core.db, 100))
        self.remove("/Users/o/code")
        self.assertEqual([(r["ok"], r["removed"], r["saved"]) for r in self.replies], [(True, True, 200)])
        self.assertEqual(self.page.projects["chan_a"]["settings"]["folders"], [])
        self.assertEqual((len(store.intents(self.core.db, 100)), self.core.runs, self.core.dev), (before, {}, {}))

    def test_a_replayed_done_for_a_dev_command_answers_it(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "remove_folder" else original(c)  # its done never comes by itself
        id_ = self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code")
        self.page.pump(self.core)
        self.core.connection(True)
        self.core.handle(self.page._stamp({"type": "commands", "waiting": [], "done": [{"id": id_, "ok": True, "error": None, "removed": True, "saved": 200}]}))
        self.assertEqual((len(self.replies), self.core.dev), (1, {}))

    def test_a_dev_command_for_a_folder_not_there_is_refused_with_the_folders_that_are(self):
        self.remove("/Users/o/other")
        self.assertEqual([(r["ok"], r["refused"], r["error"]) for r in self.replies], [(False, True, "no folder /Users/o/other; has: /Users/o/code")])

    def test_a_removal_the_server_refused_says_so(self):
        self.page.save = "refused"
        self.remove("/Users/o/code")
        self.assertEqual([r["error"] for r in self.replies], ["the server refused the folder removal (HTTP 400)"])
        self.assertEqual(self.page.projects["chan_a"]["settings"]["folders"], ["/Users/o/code"])

    def test_a_removal_the_page_neither_saved_nor_confirmed_says_so(self):
        self.page.save = "neither"
        self.remove("/Users/o/code")
        self.assertEqual([(r["ok"], r["committed"], r["unsaved"], r["error"]) for r in self.replies],
                         [(False, True, True, "neither a save nor a confirmation followed the removal")])
        self.assertEqual(self.page.projects["chan_a"]["settings"]["folders"], ["/Users/o/code"])

    def test_a_folder_whose_row_carries_a_note_is_read_and_removed_by_its_path_alone(self):
        self.page.notes["/Users/o/code"] = "Approuvé pour Remote Control uniquement sur cet ordinateur."
        self.assertIn("Approuvé", self.page.row_text("/Users/o/code"))
        self.remove("/Users/o/code")
        self.assertEqual([(r["before"], r["removed"]) for r in self.replies], [(["/Users/o/code"], True)])

    def test_a_tool_waits_to_start_while_a_dev_command_is_in_the_page(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "remove_folder" else original(c)  # its done comes only when the test says
        id_ = self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code")
        self.page.pump(self.core)
        self.core.tool("set_instructions", project="chan_a", text="new rules")
        self.page.pump(self.core)
        self.assertEqual([c[0] for c in self.page.calls], [])  # its fresh open would close the dev step's dialog under it
        self.core.handle(self.page._stamp({"type": "done", "id": id_, "ok": True, "error": None, "removed": True, "saved": 200}))
        self.page.pump(self.core)
        self.assertEqual(([c[0] for c in self.page.calls], store.intents(self.core.db, 1)[-1]["status"]), (["set_field"], "confirmed"))

    def test_a_dev_command_with_no_host_linked_says_so_at_once(self):
        self.core.connection(False)
        self.page.inbox.clear()
        self.assertIsNone(self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code"))
        self.assertEqual((self.replies, self.core.dev, self.page.inbox), ([{"ok": False, "error": "no host linked"}], {}, []))

    def test_a_send_waits_while_a_dev_command_is_in_the_page(self):
        sent = []
        id_ = self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code")
        self.core.say("plain test words", project="chan_a", finished=sent.append)
        self.assertEqual([c["kind"] for c in self.page.inbox], ["remove_folder"])  # the send waits: the dev step may have a dialog open
        self.page.pump(self.core)
        self.assertEqual((len(self.replies), sent[0]["status"], [c["kind"] for c in self.page.inbox]), (1, "confirmed", []))

    def test_a_cancelled_dev_command_is_no_longer_waited_for(self):
        id_ = self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code")
        self.core.dev_cancel(id_)
        self.page.inbox.clear()
        self.core.done({"type": "done", "id": id_, "ok": False, "error": "late"})  # must not reach the callback or a run
        self.assertEqual((self.replies, self.core.dev), ([], {}))

    def test_cancelling_a_dev_command_whose_done_already_came_says_so(self):
        id_ = self.core.dev_command("remove_folder", self.replies.append, project="chan_a", path="/Users/o/code")
        self.core.done({"type": "done", "id": id_, "ok": True})
        self.assertEqual((self.core.dev_cancel(id_), len(self.replies)), (False, 1))


@support.python_only("routerd's socket server: process glue (CourierHostTests)")
class DevSocket(unittest.TestCase):
    """The `dev_command` op through routerd's real socket: a host connection plays the page."""
    def setUp(self):
        self.json, self.dir = json, tempfile.mkdtemp(dir="/tmp")  # a short path: a unix socket's is limited
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.sock = os.path.join(self.dir, "s")
        patches = [unittest.mock.patch.object(routerd, "watch", lambda core: None)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        threading.Thread(target=routerd.serve, args=(self.sock, ":memory:"), daemon=True).start()
        for _ in range(500):
            if os.path.exists(self.sock):
                break
            time.sleep(0.01)
        self.host = self.connect()
        self.send(self.host, {"type": "commands", "waiting": [], "done": []})  # the host's first event joins it
        self.send(self.host, {"op": "board"})  # a connection's lines are handled in order: its reply says the host is linked
        self.host[1].readline()

    def connect(self):
        import socket
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(self.sock)
        self.addCleanup(s.close)
        return s, s.makefile("rb")

    def send(self, conn, message):
        conn[0].sendall((self.json.dumps(message) + "\n").encode())

    def command(self):
        while True:
            line = self.json.loads(self.host[1].readline())
            if line.get("kind") == "remove_folder" or line.get("kind") == "cancel":
                return line

    def test_a_dev_command_is_sent_to_the_page_and_answered_with_its_done(self):
        client = self.connect()
        self.send(client, {"op": "dev_command", "kind": "remove_folder", "project": "chan_a", "path": "/Users/o/code"})
        sent = self.command()
        self.assertEqual((sent["kind"], sent["project"], sent["path"]), ("remove_folder", "chan_a", "/Users/o/code"))
        self.assertNotIn("op", sent)
        self.send(self.host, {"type": "done", "id": sent["id"], "ok": True, "removed": True, "saved": 200})
        reply = self.json.loads(client[1].readline())
        self.assertEqual((reply["ok"], reply["removed"], reply["saved"]), (True, True, 200))

    def test_the_reload_dev_ops_send_their_command_to_the_host(self):
        for op in ("reload_extension", "reload_tab"):
            client = self.connect()
            self.send(client, {"op": op})
            while True:
                sent = self.json.loads(self.host[1].readline())
                if sent.get("kind") == op:
                    break
            self.assertEqual(self.json.loads(client[1].readline()), {"ok": True})

    def test_the_reload_dev_ops_say_so_when_no_host_is_linked(self):
        for op in ("reload_extension", "reload_tab"):
            client = self.connect()
            with unittest.mock.patch.object(routerd.Core, "connected", lambda self: False):
                self.send(client, {"op": op})
                self.assertEqual(self.json.loads(client[1].readline()), {"ok": False, "error": "no host linked"})

    def test_a_client_sent_id_is_dropped_and_the_command_keeps_routerds_own(self):
        client = self.connect()
        self.send(client, {"op": "dev_command", "kind": "remove_folder", "id": "mine", "project": "chan_a", "path": "/Users/o/code"})
        sent = self.command()
        self.assertNotEqual(sent["id"], "mine")
        self.assertTrue(sent["id"].startswith("c"))

    def test_a_dev_command_the_page_never_answers_is_cancelled_and_errs(self):
        client = self.connect()
        with unittest.mock.patch.object(routerd, "DEV_WAIT", 0.2):
            self.send(client, {"op": "dev_command", "kind": "remove_folder", "project": "chan_a", "path": "/x"})
            sent = self.command()
            reply = self.json.loads(client[1].readline())
        self.assertEqual((reply["ok"], reply["error"]), (False, "the page didn't answer in 0.2 s"))
        cancel = self.command()
        self.assertEqual((cancel["kind"], cancel["target"]), ("cancel", sent["id"]))


class Wake(unittest.TestCase):
    def test_a_wake_me_is_answered_with_a_wake_at_its_time_through_tick(self):
        core, page = support.world()
        page.wakes = 0  # the one played as the host connected
        core.handle({"type": "wake_me", "after": 4050})
        self.assertEqual(core.next_deadline(), NOW + 4.05)
        core.tick(NOW + 4)
        page.pump(core)
        self.assertEqual(page.wakes, 0)
        core.tick(NOW + 4.05)
        page.pump(core)
        self.assertEqual((page.wakes, core.next_deadline()), (1, None))
        core.tick(NOW + 60)
        page.pump(core)
        self.assertEqual(page.wakes, 1)

    def test_a_wake_asked_by_a_host_that_went_away_is_dropped(self):
        core, page = support.world()
        page.wakes = 0  # the one played as the host connected
        core.handle({"type": "wake_me", "after": 4000})
        core.connection(False)
        core.tick(NOW + 5)
        page.pump(core)
        self.assertEqual((page.wakes, core.next_deadline()), (0, None))

    def test_a_host_that_connects_is_sent_one_wake_so_a_wake_due_while_it_was_away_isnt_lost(self):
        core, page = support.world()
        core.handle({"type": "wake_me", "after": 4000})
        core.connection(False)
        core.tick(NOW + 5)
        core.connection(True)
        self.assertEqual([c for c in page.inbox if c["kind"] == "wake"], [{"kind": "wake"}])

    def test_every_wake_time_asked_is_kept_and_one_wake_answers_all_that_passed(self):
        core, page = support.world()
        page.wakes = 0  # the one played as the host connected
        core.handle({"type": "wake_me", "after": 5000})
        core.handle({"type": "wake_me", "after": 9000})
        self.assertEqual(core.next_deadline(), NOW + 5)
        core.handle({"type": "wake_me", "after": 1000})
        self.assertEqual(core.next_deadline(), NOW + 1)
        core.tick(NOW + 2)
        page.pump(core)
        self.assertEqual((page.wakes, core.next_deadline()), (1, NOW + 5))  # the later times survive the earlier one
        core.tick(NOW + 20)
        page.pump(core)
        self.assertEqual((page.wakes, core.next_deadline()), (2, None))  # one wake for the two that passed

    def test_a_wake_is_capped_and_junk_is_ignored(self):
        core, page = support.world()
        for junk in (None, "5", True, float("nan"), float("inf"), [1]):
            core.handle({"type": "wake_me", "after": junk})
        core.handle({"type": "wake_me"})
        self.assertIsNone(core.next_deadline())
        core.handle({"type": "wake_me", "after": 10 ** 9})
        self.assertEqual(core.next_deadline(), NOW + routerd.WAKE_CAP / 1000)

    def test_a_wake_is_no_command_in_the_page_and_changes_no_run_state(self):
        core, page = support.world()
        before = (core.commands, core.next_id(), core.tool_busy(), dict(core.runs))
        core.handle({"type": "wake_me", "after": 100})
        core.tick(NOW + 1)
        sent = page.inbox[-1]
        page.pump(core)
        self.assertEqual(sent, {"kind": "wake"})
        self.assertEqual((core.commands, core.next_id(), core.tool_busy(), dict(core.runs)), before)
        self.assertEqual((page.waiting, page.recent, page.calls), ([], [], []))


class TakenLate(unittest.TestCase):
    """The coordinator is mid-turn: the page took the words and the server queued them, and the turn outlasts the wait for a taken send."""
    def setUp(self):
        page = fake_page.demo()
        for n in range(3):
            page.projects["chan_a"]["chat"].append({"key": f"cmsg_h{n}", "from": "claude", "text": f"old {n}", "index": n, "decision": False,
                                                    "streaming": False, "pending": False})
        self.core, self.page = support.world(page=page)
        self.page.holds = True
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.intent = store.intents(self.core.db, 1)[-1]
        self.run = self.core.runs[self.intent["id"]]

    def status(self):
        i = store.intent(self.core.db, self.intent["id"])
        return i["status"], i["cause"]

    def test_a_taken_send_that_failed_is_confirmed_late_by_its_row(self):
        with unittest.mock.patch.object(do, "KEPT", 1):
            support.run_out(self.core, self.page, self.intent["id"])
            self.assertEqual(self.status(), ("failed", "the page took the words but never confirmed them"))
            self.assertIn(self.intent["id"], self.core.watched)
            self.assertEqual(len(store.intent(self.core.db, self.intent["id"])["proof"]["baseline"]), 3)  # whole while watched
            support.later(self.core, 30)
            self.page.deliver("chan_a")
            self.page.pump(self.core)
        status, cause = self.status()
        self.assertEqual((status, self.page.clicks, self.core.watched), ("confirmed", 1, {}))
        self.assertIn("confirmed late", cause)

    def test_a_stuck_send_that_failed_is_watched_too(self):
        self.run["stuck"] = True
        support.run_out(self.core, self.page, self.intent["id"])
        self.assertEqual(self.status()[1].split(":")[0], "the words stayed in the draft after a click, then the draft emptied with no row from you")
        self.assertIn(self.intent["id"], self.core.watched)

    def test_a_send_failed_with_no_click_and_nothing_in_the_page_is_not_watched(self):
        self.page.holds = False
        self.page.left_open = True  # every send is answered "a dialog is open": none clicks, none stays in the page
        self.core.say("other words", project="chan_b")
        self.page.pump(self.core)
        other = store.intents(self.core.db, 1)[-1]
        support.run_out(self.core, self.page, other["id"])
        self.assertEqual((store.intent(self.core.db, other["id"])["status"], other["id"] in self.core.watched), ("failed", False))

    def test_a_send_failed_while_still_in_the_page_is_watched(self):
        """The page may click it before the cancel reaches it."""
        self.page.holds = False
        self.page.composerless = True  # the send waits in the page for its composer
        self.core.say("other words", project="chan_b")
        self.page.pump(self.core)
        other = store.intents(self.core.db, 1)[-1]
        support.run_out(self.core, self.page, other["id"])
        self.assertEqual((store.intent(self.core.db, other["id"])["status"], other["id"] in self.core.watched), ("failed", True))

    def test_the_watch_survives_a_restart(self):
        support.run_out(self.core, self.page, self.intent["id"])
        support.later(self.core, 30)
        again = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock, uptime=self.core.clock.uptime)
        self.assertEqual(again.watched, {self.intent["id"]: self.core.clock.uptime() + routerd.ACCEPTED_WAIT - 30})
        self.page.connect(again)
        self.page.deliver("chan_a")
        self.page.pump(again)
        self.assertEqual(self.status()[0], "confirmed")


class SavedDraft(unittest.TestCase):
    """The page took the words and the server queued them; later the tab is a new document that restores a saved draft of the words."""
    def setUp(self):
        TakenLate.setUp(self)

    status = TakenLate.status

    def test_words_back_in_a_reloaded_pages_draft_are_not_sent_again(self):
        support.later(self.core, 10)  # past RELOAD_LOSS: no sign the reload lost them
        self.core.tick()
        self.page.pump(self.core)
        self.page.projects["chan_a"]["draft"] = "plain test words"
        self.page.reload(self.core, "chan_a", pending=None)
        self.page.pump(self.core)
        self.assertEqual((self.run["taken"], self.page.clicks, len([c for c in self.page.calls if c[0] == "send"])), (True, 1, 1))

    def test_nor_in_a_page_that_reloaded_while_no_host_was_linked(self):
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": 1}))
        self.core.connection(False)
        self.page.recent.clear()  # a new document: it knows nothing of the old one's `done`s
        self.page.projects["chan_a"]["draft"] = "plain test words"
        self.core.connection(True)
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": 2}, "chan_a"))
        self.core.handle(self.page._stamp({"type": "commands", "waiting": [], "done": []}))
        for event in self.page.load("chan_a"):
            self.core.handle(event)
        self.page.pump(self.core)
        self.assertEqual((self.run["taken"], self.page.clicks), (True, 1))

    def test_words_the_same_page_puts_back_are_it_giving_up(self):
        self.page.projects["chan_a"]["draft"] = "plain test words"
        self.core.handle(self.page._composer(self.page.projects["chan_a"], "project"))
        self.page.pump(self.core)
        self.assertEqual(self.page.clicks, 2)  # typed again: the page didn't send it


class Gated(unittest.TestCase):
    """A dev step (any tool command) in the page gates the sends: nothing is typed or opened until it ends."""
    def test_a_run_gated_while_opening_keeps_a_deadline_and_ends(self):
        core, page = support.world()
        page.rendering.add(("chan_a", "cmsg_2"))  # this thread's render never settles
        core.say("reply words", project="chan_a", thread="cmsg_2")
        run = core.runs[store.intents(core.db, 1)[-1]["id"]]
        self.assertEqual(run["stage"], "opening")
        core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/x")
        core.handle(page._stamp({"type": "composer", "side": "project", "draft": "", "disabled": True}))
        self.assertEqual((run["gated"], run["stage"], run["deadline"] is not None, support.armed(core)), (True, "start", True, []))
        page.pump(core)
        self.assertEqual((run["stage"], run["deadline"], support.armed(core)), ("opening", core.clock() + do.TIMEOUT, []))
        support.run_out(core, page, run["id"])
        intent = store.intent(core.db, run["id"])
        self.assertEqual((intent["status"], intent["cause"]), ("failed", "the page never settled on that place"))

    def test_a_fresh_open_gets_its_own_wait(self):
        core, page = support.world()
        for event in page.load("chan_b"):
            core.handle(event)
        page.unfetched.add(("chan_a", None))
        for event in page.load("chan_a"):  # the tab shows chan_a again by itself, its chat not fetched: unsettled
            core.handle(event)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        core.clock.t = run["fresh_at"]
        core.tick()
        self.assertEqual((run["stage"], run["fresh"], run["deadline"]), ("opening", True, core.clock() + do.TIMEOUT))

    def test_a_send_the_gate_cuts_off_keeps_its_attempt(self):
        core, page = support.world()
        page.composerless = True  # the send waits in the page
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/x")
        support.later(core, 1)
        core.safely(run, late=True)  # a deadline before the attempt's limit (a late click of an older send sets one)
        self.assertEqual((run["stage"], run["ignored"]), ("start", True))
        page.composerless = False
        page.pump(core)
        intent = store.intent(core.db, run["id"])
        self.assertEqual((intent["status"], intent["attempts"]), ("confirmed", 1))

    def test_a_send_a_dialog_held_goes_on_only_to_a_place_still_ready(self):
        core, page = support.world()
        page.left_open = True
        core.say("plain test words", project="chan_a")
        replies = []
        core.dev_command("remove_folder", replies.append, project="chan_a", path="/x")
        send, dev = page.inbox.pop(0), page.inbox.pop(0)
        for event in page.run(send):  # "a dialog is open", while the dev step is in the page
            core.handle(event)
        run = next(iter(core.runs.values()))
        self.assertTrue(run["held"])
        page.left_open = False
        for event in page.load("chan_b"):  # the tab moves meanwhile
            core.handle(event)
        page.inbox.clear()
        for event in page.run(dev):
            core.handle(event)
        self.assertEqual(([c["kind"] for c in page.inbox], len(replies)), (["open"], 1))
        page.pump(core)
        self.assertEqual((store.intent(core.db, run["id"])["status"], page.clicks), ("confirmed", 1))


class Armed(unittest.TestCase):
    """Every run that has begun and isn't paused has a deadline: nothing else is sure to wake it."""
    def test_a_send_waiting_in_the_page(self):
        core, page = support.world()
        page.composerless = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        self.assertEqual((len(core.runs), support.armed(core)), (1, []))

    def test_a_taken_send_and_one_behind_a_dev_step(self):
        core, page = support.world()
        page.holds = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        core.dev_command("remove_folder", lambda d: None, project="chan_b", path="/x")
        core.say("other words", project="chan_b")
        self.assertEqual((len(core.runs), support.armed(core)), (2, []))
        page.pump(core)
        self.assertEqual(support.armed(core), [])

    def test_a_lost_open_and_a_slow_one(self):
        core, page = support.world()
        page.slow_opens = True
        core.say("plain test words", project="chan_b")
        core.say("other words", project="chan_c" if "chan_c" in page.projects else "chan_a")
        page.pump(core)
        self.assertEqual(support.armed(core), [])
        page.settle()
        page.pump(core)
        self.assertEqual(support.armed(core), [])


class Settled(unittest.TestCase):
    def test_a_place_that_settles_before_its_fresh_open_is_due_drops_that_wake(self):
        core, page = support.world()
        for event in page.load("chan_b"):
            core.handle(event)
        page.rendering.add(("chan_a", None))
        for event in page.load("chan_a"):  # its render isn't done
            core.handle(event)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertIsNotNone(run.get("fresh_at"))
        page.holds = True
        page.render("chan_a")
        page.pump(core)
        self.assertEqual((run.get("taken"), run.get("fresh_at"), core.next_deadline()), (True, None, run["deadline"]))


class TwoTaken(unittest.TestCase):
    """Two taken sends to two projects, both queued behind their coordinators' turns: the tab can show one."""
    def test_the_one_left_goes_back_once_the_other_is_proved(self):
        core, page = support.world()
        page.holds = True
        core.say("words for a", project="chan_a")
        page.pump(core)
        a = store.intents(core.db, 1)[-1]
        core.say("words for b", project="chan_b")  # its open moves the tab: a goes back, then b does, and neither again
        page.pump(core)
        b = store.intents(core.db, 1)[-1]
        self.assertEqual((page.at, [r.get("back") for r in core.runs.values()]), (("chan_b", None), [core.moves, core.moves]))
        page.deliver("chan_b")
        page.pump(core)
        self.assertEqual((store.intent(core.db, b["id"])["status"], page.at), ("confirmed", ("chan_a", None)))
        page.deliver("chan_a")
        page.pump(core)
        self.assertEqual(store.intent(core.db, a["id"])["status"], "confirmed")


class ReviewSeams(unittest.TestCase):
    """Seams a review found: a restart that missed a click with no `done` heard, a gate that cut off a fresh open or a due retry, a send
    lost with a reloaded page, an extension reload that keeps the document, and a dev command lost with the page."""

    def test_a_restart_watches_a_send_whose_click_no_done_reported(self):
        page = fake_page.demo()
        page.holds = True
        core, page = support.world(page=page)
        core.say("plain test words", project="chan_a")
        page.run(page.inbox.pop())  # the page clicks; its `done` and rows never reach routerd: it is restarted just then
        intent = store.intents(core.db, 1)[-1]
        support.later(core, 5)
        again = routerd.Core(core.db, page.receive, clock=core.clock, uptime=core.clock.uptime)
        self.assertEqual((store.intent(again.db, intent["id"])["status"], list(again.watched)), ("failed", [intent["id"]]))
        page.outbox.clear()
        page.connect(again)  # its snapshot replays the click's ok `done`: it is watched as it was
        support.later(again, 30)
        page.deliver("chan_a")
        page.pump(again)
        self.assertEqual((store.intent(again.db, intent["id"])["status"], page.clicks), ("confirmed", 1))

    def test_a_gate_during_the_retry_wait_after_an_ignored_click_clicks_again_at_its_end(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        send = page.inbox.pop(0)
        events = page.run(send)
        page.projects["chan_a"]["draft"] = "plain test words"  # the click is ignored: the draft keeps the words, and no row comes
        page.projects["chan_a"]["chat"].pop()
        for e in events:
            if not (e["type"] == "composer" and e["draft"] == "") and e["type"] != "rows":
                core.handle(e)
        run = next(iter(core.runs.values()))
        replies = []
        core.dev_command("remove_folder", replies.append, project="chan_b", path="/x")
        dev = page.inbox.pop(0)
        core.clock.t = run["deadline"]  # TAKE_WAIT is over while the dev step holds the gate
        core.tick()
        self.assertEqual((run["gated"], run["held"], page.inbox), (True, True, []))
        support.later(core, 0.5)
        for e in page.run(dev):
            core.handle(e)
        self.assertEqual([c.get("click_only") for c in page.inbox if c["kind"] == "send"], [True])  # at once, click-only
        page.pump(core)
        intent = store.intent(core.db, run["id"])
        self.assertEqual((intent["status"], intent["attempts"]), ("confirmed", 1))

    def test_a_gate_that_cancels_a_fresh_open_asks_for_it_again(self):
        core, page = support.world()
        for e in page.load("chan_b"):
            core.handle(e)
        page.unfetched.add(("chan_a", None))
        for e in page.load("chan_a"):
            core.handle(e)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        core.clock.t = run["fresh_at"]
        page.slow_opens = True  # the fresh open waits in the page
        core.tick()
        page.pump(core)
        core.dev_command("remove_folder", lambda d: None, project="chan_b", path="/x")
        support.later(core, 0.5)
        core.safely(run)
        self.assertEqual((run["gated"], run["stage"], run["fresh"]), (True, "start", False))
        page.slow_opens = False
        page.pump(core)
        support.run_out(core, page, run["id"])
        self.assertEqual((store.intent(core.db, run["id"])["status"], page.bounces), ("confirmed", 1))

    def lost_with_a_reload(self, turning=False):
        core, page = support.world()
        t0 = core.clock()
        core.say("plain test words", project="chan_a")
        page.inbox.pop()  # handed to the page, which goes before it says what it did
        if turning:
            page.post("chan_a", "claude", "still writing", streaming=True)
            page.pump(core)
        page.reload(core, "chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertEqual((run["taken"], run["reloaded"]), (True, t0))
        support.run_out(core, page, run["id"])
        intent = store.intent(core.db, run["id"])
        return intent, core.clock() - t0, intent["id"] in core.watched

    def test_a_send_lost_with_a_reloaded_page_fails_a_wait_after_the_reload_with_its_own_cause(self):
        intent, after, watched = self.lost_with_a_reload()
        self.assertEqual((intent["status"], intent["cause"], after, watched), ("failed", routerd.WENT, do.TIMEOUT, True))

    def test_a_send_lost_with_a_reloaded_page_while_the_coordinator_writes_waits_out_its_turn(self):
        intent, after, watched = self.lost_with_a_reload(turning=True)
        self.assertEqual((intent["status"], intent["cause"], after >= routerd.ACCEPTED_WAIT, watched), ("failed", routerd.WENT, True, True))

    def test_a_gone_counts_a_page_only_when_the_next_document_differs(self):
        core, page = support.world()
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": 1000, "instance": "i1", "path": "/code", "thread": None})
        pages = core.pages
        gone = {"type": "page", "signed_in": None, "page_ok": False, "gone": True, "path": None, "thread": None}
        core.handle(gone)
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": 1000, "instance": "i1", "path": "/code", "thread": None})  # the same script back
        self.assertEqual(core.pages, pages)
        core.handle(gone)
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": 1000, "instance": "i2", "path": "/code", "thread": None})  # an extension reload
        self.assertEqual(core.pages, pages + 1)
        core.handle(gone)
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": 2000, "instance": "i3", "path": "/code", "thread": None})
        self.assertEqual(core.pages, pages + 2)
        core.handle(gone)
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": 2000, "path": "/code", "thread": None})  # no `instance` to tell by
        self.assertEqual(core.pages, pages + 3)
        core.handle(gone)
        core.handle({"type": "page", "signed_in": True, "page_ok": True, "path": "/code", "thread": None})  # no `loaded` to tell by
        self.assertEqual(core.pages, pages + 4)

    def test_a_dev_command_lost_with_a_reloaded_page_is_answered_with_an_error(self):
        core, page = support.world()
        replies = []
        core.dev_command("remove_folder", replies.append, project="chan_b", path="/x")
        page.inbox.clear()  # handed to the page, which reloads before running it
        page.reload(core, "chan_a")
        self.assertEqual(([r["ok"] for r in replies], core.dev), ([False], {}))

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_late_click_of_a_cut_off_send_keeps_the_opens_deadline(self):
        core, page = support.world()
        page.composerless = True  # the send waits in the page
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        send_id = run["command"]
        core.unsettled.add("chan_a")  # by the deadline the place is unsettled again: the run opens it, cutting the send off
        page.slow_opens = True
        core.clock.t = run["deadline"]
        core.tick()
        page.pump(core)
        core.handle({"type": "composer", "side": "project", "draft": "something else", "disabled": False, "path": "/code/project/chan_a", "thread": None})
        core.handle({"type": "done", "id": send_id, "ok": True, "error": None, "path": "/code/project/chan_a", "thread": None})  # clicked before the cancel
        self.assertEqual((run["stage"], run["deadline"] - core.clock()), ("opening", do.TIMEOUT))

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_send_that_erred_while_another_run_held_the_tab_retries_once_it_is_free(self):
        core, page = support.world()
        page.holds = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        run["stage"], run["taken"], run["clicked"] = "waiting", False, False
        run["command"] = core.command("send", side="project", text="plain test words", project="chan_a", thread=None, intent=run["id"])
        run.setdefault("sends", []).append(run["command"])
        page.inbox.clear()
        with unittest.mock.patch.object(routerd.Core, "tab_held", return_value=True):
            core.handle({"type": "done", "id": run["command"], "ok": False, "error": "the page can't be read", "path": "/code/project/chan_a", "thread": None})
        self.assertEqual((run["retry"], [c["kind"] for c in page.inbox]), (True, []))
        core.advance_all()  # the holder let the tab go: no wait for the deadline
        self.assertEqual([c["kind"] for c in page.inbox], ["send"])

    def test_a_taken_send_goes_back_only_with_a_host_linked(self):
        page = fake_page.demo()
        page.holds = True
        core, page = support.world(page=page)
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        core.connection(False)
        page.inbox.clear()
        core.safely(run)
        self.assertEqual((run.get("back"), page.inbox), (None, []))
        page.connect(core)
        page.pump(core)
        self.assertEqual(run.get("back"), core.moves)


class Assignment(unittest.TestCase):
    """do.proved_all: equal words first, a prefix only when no send of the place has equal words, and another send's row holds nobody."""
    def board(self, *texts):
        return {"projects": {"chan_a": {"chat": [{"key": f"k{n}", "index": n, "from": "you", "text": t} for n, t in enumerate(texts)]}}, "threads": {}}

    def proofs(self, *words):
        return [(w, {"project": "chan_a", "thread": None, "words": w, "baseline": []}) for w in words]

    def test_equal_words_win_over_a_prefix(self):
        out = do.proved_all(self.board("Fix it **now** please"), self.proofs("fix it", "fix it now please"))
        self.assertEqual(out, {"fix it": (False, None, None), "fix it now please": (True, None, "k0")})

    def test_a_prefix_proves_a_send_when_no_send_has_equal_words(self):
        self.assertEqual(do.proved_all(self.board("fix it now"), self.proofs("fix it")), {"fix it": (True, None, "k0")})

    def test_a_prefix_adds_at_most_a_few_words_and_fewer_than_the_send_has(self):
        self.assertFalse(do.proved_all(self.board("fix it now please"), self.proofs("fix it"))["fix it"][2])  # 2 added to a 2-word send
        self.assertFalse(do.proved_all(self.board("ok so the plan is to ship"), self.proofs("ok"))["ok"][2])  # a 1-word send: exact only
        six = "please rebuild the app and test"
        self.assertEqual(do.proved_all(self.board(six + " Edited now"), self.proofs(six))[six][2], "k0")  # a short rendered suffix
        self.assertFalse(do.proved_all(self.board(six + " and then ship it"), self.proofs(six))[six][2])  # 4 added: more than 3

    def test_the_prefix_bound(self):
        import board
        self.assertFalse(board.ends_shortly("Yes, go ahead", "yes"))
        self.assertTrue(board.ends_shortly("Yes", "yes"))
        self.assertTrue(board.ends_shortly("fix it now", "fix it"))
        self.assertFalse(board.ends_shortly("fix it now please", "fix it"))
        self.assertTrue(board.ends_shortly("one two three four five six a b c", "one two three four five six"))
        self.assertFalse(board.ends_shortly("one two three four five six a b c d", "one two three four five six"))

    def test_a_row_of_another_sends_words_is_never_a_prefix_proof(self):
        out = do.proved_all(self.board("fix it now", "fix it now"), self.proofs("fix it now", "fix it"))
        self.assertEqual(out, {"fix it now": (True, None, "k0"), "fix it": (False, None, None)})

    def test_a_prefix_row_goes_to_the_send_with_the_longest_words(self):
        out = do.proved_all(self.board("fix it now please"), self.proofs("fix it", "fix it now"))
        self.assertEqual(out["fix it now"], (True, None, "k0"))
        self.assertEqual(out["fix it"][2], None)

    def test_one_row_of_twice_sent_words_proves_the_first(self):
        out = do.proved_all(self.board("same"), self.proofs("same", "same")[:1] + [("b", self.proofs("same")[0][1])])
        self.assertEqual(out, {"same": (True, None, "k0"), "b": (False, None, None)})


class OneRowItsSend(unittest.TestCase):
    """The place's sends are judged together: a row goes to the send whose words equal it before one whose words it only starts with,
    a watched send's late row is its own, not a live send's, and a mid-turn coordinator, or a send dropped long after a reload, isn't
    taken for a lost one."""

    def setUp(self):
        self.core, self.page = support.world()

    def status(self, intent_id):
        return store.intent(self.core.db, intent_id)["status"]

    def test_a_history_navigations_stale_render_of_another_project_confirms_no_send(self):
        core, page = self.core, self.page
        a, b = "chan_" + "a" * 24, "chan_" + "b" * 24  # the server's ids, whose messages' keys start with their project's
        page.add_project(a, "alpha two"); page.add_project(b, "beta two")
        page.post(a, "you", "plain test words", key="cmsg_" + "a" * 24 + "1")
        page.holds = True
        core.say("plain test words", project=b); page.pump(core)
        stale = dict(page.whole(a), **page._stamp({}, b, None))  # the tab's path says b, the transcript still shows a's rows
        core.handle(stale); page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertNotEqual((intent["status"], (intent["result"] or {}).get("row")), ("confirmed", "cmsg_" + "a" * 24 + "1"))

    def test_a_row_goes_to_the_send_of_equal_words_not_a_lost_one_it_starts_with(self):
        core, page = self.core, self.page
        page.swallow = True  # A's click empties the draft, its row never shows
        core.say("fix it", project="chan_a")
        page.pump(core)
        a = next(iter(core.runs))
        page.swallow = False
        core.say("fix it now please", project="chan_a")
        page.pump(core)
        b = store.intents(core.db, 1)[-1]["id"]
        support.run_out(core, page, a)
        self.assertEqual((self.status(a), self.status(b)), ("failed", "confirmed"))

    def test_a_watched_lost_send_doesnt_take_a_later_sends_row_it_starts_with(self):
        core, page = self.core, self.page
        page.swallow = True
        core.say("fix it", project="chan_a")
        page.pump(core)
        a = next(iter(core.runs))
        support.run_out(core, page, a)
        self.assertEqual((self.status(a), a in core.watched), ("failed", True))
        page.swallow = False
        core.say("fix it now please", project="chan_a")
        page.pump(core)
        b = store.intents(core.db, 1)[-1]["id"]
        self.assertEqual((self.status(a), a in core.watched, self.status(b)), ("failed", True, "confirmed"))

    def test_a_watched_sends_late_row_doesnt_hold_a_live_send(self):
        core, page = self.core, self.page
        page.swallow = True
        core.say("alpha words here", project="chan_a")
        page.pump(core)
        a = next(iter(core.runs))
        support.run_out(core, page, a)
        page.swallow, page.composerless = False, True  # B's send waits in the page
        core.say("beta other words", project="chan_a")
        page.pump(core)
        b = next(iter(core.runs))
        page.post("chan_a", "you", "alpha words here")  # A's queued words show late
        page.pump(core)
        self.assertEqual((self.status(a), core.runs[b].get("accepted")), ("confirmed", None))

    def test_a_turn_begun_before_the_send_keeps_a_reloaded_send_waiting(self):
        core, page = self.core, self.page
        page.post("chan_a", "claude", "still writing", streaming=True)
        page.pump(core)
        core.say("plain test words", project="chan_a")
        page.inbox.pop()
        page.reload(core, "chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertTrue(do.turning(core.board(), store.intent(core.db, run["id"])["proof"]))
        t0 = core.clock()
        support.run_out(core, page, run["id"])
        self.assertGreaterEqual(core.clock() - t0, routerd.ACCEPTED_WAIT - do.TIMEOUT)

    def test_a_reply_being_written_under_a_provisional_key_is_a_turn(self):
        core, page = self.core, self.page
        reply = page.post("chan_a", "claude", "still writing", streaming=True, pending=True)  # `provisional:…`, kept off the Board
        page.pump(core)
        proof = {"project": "chan_a", "thread": None, "baseline": []}
        self.assertTrue(do.turning(core.board(), proof))
        page.post("chan_a", "claude", "done writing")  # it settles under its server key: the provisional row isn't sent again
        page.pump(core)
        self.assertFalse(do.turning(core.board(), proof))
        self.assertTrue(reply["key"].startswith("provisional:"))

    def test_a_reloaded_send_waits_a_wait_after_the_turn_ends_for_its_queued_row(self):
        core, page = self.core, self.page
        reply = page.post("chan_a", "claude", "still writing", streaming=True)
        page.pump(core)
        core.say("plain test words", project="chan_a")
        page.inbox.pop()
        page.reload(core, "chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertIsNotNone(run.get("vanished_at"))
        support.later(core, 100)
        page.post("chan_a", "claude", "done writing", key=reply["key"])  # the turn ends long after the reload: the queued row shows a moment later
        page.pump(core)
        self.assertEqual(store.intent(core.db, run["id"])["status"], "pending")
        self.assertEqual(run["deadline"], core.clock() + do.TIMEOUT)
        support.later(core, 2)
        page.post("chan_a", "you", "plain test words")
        page.pump(core)
        self.assertEqual(store.intent(core.db, run["id"])["status"], "confirmed")

    def cut_off_then_a_row_of_yours(self):
        core, page = self.core, self.page
        core.say("plain test words", project="chan_a")
        sent = page.inbox.pop()  # the page may click it before the cancel reaches it: its `done` is still to come
        run = next(iter(core.runs.values()))
        core.cancel_send(run)
        run["stage"] = "start"  # as a gate or the app closing leaves it
        page.inbox.clear()
        page.post("chan_a", "you", "something else entirely")  # you typed in the chat meanwhile
        page.pump(core)
        return core, page, run, sent

    def test_a_cut_off_send_not_heard_from_waits_for_its_row_after_a_foreign_row(self):
        core, page, run, sent = self.cut_off_then_a_row_of_yours()
        self.assertEqual(store.intent(core.db, run["id"])["status"], "pending")
        core.handle(page._stamp({"type": "done", "id": sent["id"], "ok": True, "error": None}))  # it had clicked
        page.post("chan_a", "you", "plain test words")
        page.pump(core)
        self.assertEqual(store.intent(core.db, run["id"])["status"], "confirmed")

    def test_a_cut_off_send_not_heard_from_is_watched_when_it_fails(self):
        core, page, run, sent = self.cut_off_then_a_row_of_yours()
        core.finish(run, "failed", "test")
        self.assertIn(run["id"], core.watched)

    def test_a_replayed_click_is_a_click_but_not_a_fresh_one(self):
        core, page = self.core, self.page
        core.say("plain test words", project="chan_a")
        sent = page.inbox.pop()  # the page clicks it, and the host drops before its `done` comes
        run = next(iter(core.runs.values()))
        core.connection(False)
        support.later(core, 60)
        core.connection(True)
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [{"type": "done", "id": sent["id"], "ok": True, "error": None}]}))
        self.assertEqual((run.get("clicked"), run.get("click_at"), run.get("click_page")), (True, None, None))
        core.handle({"type": "page", "signed_in": None, "page_ok": False, "gone": True, "path": None, "thread": None})
        self.assertIsNone(run.get("reloaded"))  # the click was long before the page went: its words had time to reach the server

    def test_a_send_that_went_with_a_page_across_a_sleep_gets_its_full_wait_from_the_wake(self):
        core, page = self.core, self.page
        core.say("plain test words", project="chan_a")
        page.inbox.pop()  # handed to the page, which goes before it says what it did
        run = next(iter(core.runs.values()))
        core.handle({"type": "page", "signed_in": None, "page_ok": False, "gone": True, "path": None, "thread": None})
        support.sleep(core, 3600)  # the Mac sleeps before the next page comes
        for e in page.load("chan_a"):
            core.handle(e)
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": []}))
        page.pump(core)
        self.assertEqual((run.get("went"), run["reloaded"]), (True, core.clock()))
        self.assertEqual((store.intent(core.db, run["id"])["status"], run["deadline"]), ("pending", core.clock() + do.TIMEOUT))

    def test_a_reloads_mark_applies_only_to_the_send_it_was_taken_for(self):
        core, page = self.core, self.page
        page.composerless = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        core.handle({"type": "page", "signed_in": None, "page_ok": False, "gone": True, "path": None, "thread": None})  # an extension reload
        for e in page.load("chan_a"):
            core.handle(e)
        core.handle({**page._stamp({"type": "commands"}), "waiting": [c["id"] for c in page.waiting], "done": []})  # it still holds the send
        self.assertIsNone(run.get("gone_at"))
        support.later(core, 100)
        core.tick()
        page.pump(core)
        core.connection(False)  # the host drops, and the page loses the later send with it: no page went
        page.waiting.clear()
        page.connect(core)
        page.pump(core)
        self.assertEqual((run.get("went"), run.get("reloaded")), (True, None))


class OpenErrors(unittest.TestCase):
    def test_a_failed_open_is_tried_again_at_its_deadline(self):
        """The worker found no tab: the open fails, nothing was sent, and the run opens again at its deadline (background.js)."""
        core, page = support.world()
        page.page_ok = False
        core.say("plain test words", project="chan_b")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertEqual((store.intents(core.db, 1)[-1]["status"], run["stage"], run["lost"]), ("pending", "start", True))
        page.page_ok = True
        support.run_out(core, page, run["id"])
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_second_failed_open_in_a_row_fails_the_run(self):
        core, page = support.world()
        page.page_ok = False
        core.say("plain test words", project="chan_b")
        page.pump(core)
        support.run_out(core, page, next(iter(core.runs)))
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], intent["cause"]), ("failed", "the page can't be read"))

    def test_a_relink_sends_nothing_before_the_worker_says_there_is_a_page(self):
        """The health kept from before the link is stale: an open sent on it would fail if the worker finds no tab."""
        core, page = support.world()
        core.connection(False)
        core.say("plain test words", project="chan_b")
        page.pump(core)
        page.inbox.clear()
        core.connection(True)
        self.assertEqual([c["kind"] for c in page.inbox if c["kind"] != "wake"], [])
        page.connect(core)
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")


class ForeignRow(unittest.TestCase):
    CAUSE = "a row from you arrived, but its words differ from what was sent"

    def test_a_row_of_yours_with_other_words_fails_a_send_that_never_clicked_at_once(self):
        """You typed in the chat meanwhile: the run's send never clicked, so there is nothing of its own to wait for."""
        core, page = support.world()
        page.composerless = True  # its send waits in the page
        core.say("plain test words", project="chan_a")
        page.pump(core)
        page.post("chan_a", "you", "something else I typed")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], intent["cause"], core.runs), ("failed", self.CAUSE, {}))

    def test_a_taken_send_keeps_the_cause_and_waits_for_its_row(self):
        core, page = support.world()
        page.swallow = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        page.post("chan_a", "you", "something else I typed")
        page.pump(core)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], intent["cause"]), ("pending", self.CAUSE))
        page.post("chan_a", "you", "plain test words")  # its own row comes after all
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")


class PausedSleep(unittest.TestCase):
    def test_a_sleep_inside_a_taken_runs_wait_does_not_use_it_up(self):
        """The deadline (the end of the taken wait) isn't past after the sleep: the jump is seen against the last check, and the wait
        moves on by the sleep, so the run doesn't take its look at once."""
        core, page = support.world()
        page.swallow = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        accepted = run["accepted"]
        support.sleep(core, routerd.ACCEPTED_WAIT - 10)
        support.later(core, 20)  # awake again past the old end of the wait
        core.tick()
        page.pump(core)
        self.assertEqual(run["accepted"], accepted + routerd.ACCEPTED_WAIT - 10)
        self.assertIsNone(run.get("looking"))
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")

    def test_a_sleep_moves_an_attempts_limit_and_a_fresh_opens_time_with_its_deadline(self):
        core, page = support.world()
        page.composerless = True  # its send waits in the page
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        self.assertEqual(run["limit"], run["deadline"])
        arrived = core.arrived[1]
        support.sleep(core, 3600)
        core.tick()
        self.assertEqual(run["limit"], core.clock() + do.TIMEOUT)  # the same attempt, not a new one at the wake
        self.assertEqual(core.arrived[1], arrived + 3600)  # the page slept too: the time it has had to settle starts again

    def test_a_long_idle_stretch_while_awake_is_no_jump(self):
        core, page = support.world()
        page.swallow = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        accepted = run["accepted"]
        support.later(core, 2 * do.TIMEOUT)
        core.handle(page._stamp({"type": "notice", "text": "hi"}))
        self.assertEqual(run["accepted"], accepted)


class ReviewRound(unittest.TestCase):
    """The review's seeds: a queued run never deadlocks a waiting one, prefixes end on words, deltas don't end turns, sleeps move looks."""

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_run_waiting_for_a_cut_off_send_lets_a_queued_run_go_and_fails_once_a_later_done_says_it_never_ran(self):
        core, page = support.world()
        page.composerless = True  # the first send waits in the page
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = core.runs[1]
        core.unsettled.add("chan_a")  # at the deadline the run opens again, cutting its send off (no `done` for it)
        core.clock.t = run["deadline"]
        core.tick()
        page.pump(core)
        page.composerless = False
        page.pump(core)
        page.post("chan_a", "you", "something I typed myself")
        page.pump(core)
        # The open after the cancel answered: the page runs in order, so the cut-off send never clicked. Nothing to wait for.
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "failed")
        core.say("second send", project="chan_a")
        page.pump(core)
        support.run_out(core, page, 2)
        self.assertEqual(store.intents(core.db, 2)[-1]["status"], "confirmed")

    def test_a_queued_run_isnt_counted_as_moving_the_tab(self):
        core, page = support.world()
        page.composerless = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        cmd, P = core.runs[1]["command"], {"path": "/code/project/chan_a", "thread": None}
        page.waiting.clear()
        core.handle({"type": "composer", "side": "project", "draft": "plain test words", "disabled": False, **P})  # clicked, ignored
        core.handle({"type": "done", "id": cmd, "ok": True, "error": None, **P})
        page.post("chan_a", "you", "something I typed myself")
        page.pump(core)
        page.composerless = False
        core.say("second send", project="chan_a")
        page.pump(core)
        self.assertEqual(core.runs[2]["stage"], "start")
        self.assertTrue(core.tab_idle(core.runs[1]))  # the second run sits behind the first: it moves nothing
        for _ in range(40):
            if 2 not in core.runs:
                break
            run = core.runs.get(1) or core.runs[2]
            core.clock.t = run["deadline"] if run["deadline"] else core.clock.t + 1
            core.tick()
            page.pump(core)
        self.assertIn(store.intents(core.db, 1)[-1]["status"], do.DONE)
        self.assertEqual(store.intents(core.db, 2)[-1]["status"], "confirmed")

    def test_a_short_send_is_no_prefix_of_a_longer_word(self):
        core, page = support.world()
        page.swallow = True  # the click empties the draft; the server never gets the words
        core.say("yes", project="chan_a")
        page.pump(core)
        page.swallow = False
        page.post("chan_a", "you", "Yesterday's build broke, look at that first")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")
        page.post("chan_a", "you", "Yes, go ahead")  # starts with the send's word, but a 1-word send matches exactly only
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")
        page.post("chan_a", "you", "Yes")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_hand_typed_message_that_starts_with_a_lost_ok_doesnt_confirm_it(self):
        core, page = support.world()
        page.swallow = True
        core.say("ok", project="chan_a")
        page.pump(core)
        page.swallow = False
        page.post("chan_a", "you", "ok so the plan is to ship today")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")

    def test_a_sentence_send_confirms_with_a_short_rendered_suffix(self):
        core, page = support.world()
        page.swallow = True
        core.say("please rebuild the app and test", project="chan_a")
        page.pump(core)
        page.swallow = False
        page.post("chan_a", "you", "please rebuild the app and test Edited now")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_the_prefix_is_word_by_word(self):
        import board
        self.assertTrue(board.starts_with("Yes, go ahead", "yes"))
        self.assertTrue(board.starts_with("Fix the **build** now", "fix the build"))
        self.assertFalse(board.starts_with("Yesterday's build", "yes"))
        self.assertFalse(board.starts_with("fix the builder", "fix the build"))
        self.assertFalse(board.starts_with("anything", "!!"))

    def test_an_older_claude_row_settling_while_a_later_one_streams_doesnt_end_the_turn(self):
        core, page = support.world()
        a = page.post("chan_a", "claude", "reading files", streaming=True)
        page.post("chan_a", "claude", "running the tests", streaming=True)
        page.pump(core)
        proof = {"project": "chan_a", "thread": None, "baseline": []}
        self.assertTrue(do.turning(core.board(), proof))
        page.finish("chan_a", a)  # the delta holds only the older row, settled
        page.pump(core)
        self.assertTrue(do.turning(core.board(), proof))

    def test_the_last_streaming_row_settling_ends_the_turn(self):
        core, page = support.world()
        page.post("chan_a", "claude", "reading files")
        b = page.post("chan_a", "claude", "running the tests", streaming=True)
        page.pump(core)
        page.finish("chan_a", b)
        page.pump(core)
        self.assertFalse(do.turning(core.board(), {"project": "chan_a", "thread": None, "baseline": []}))

    def test_the_pages_own_turning_reading_wins(self):
        import page as pages
        event = {"type": "rows", "side": "project", "path": "/code/project/chan_a", "full": False, "turning": True,
                 "rows": [{"key": "cmsg_1", "index": 0, "from": "claude", "text": "x", "streaming": False}]}
        fields = pages.seen_rows(event)[0]["fields"]
        self.assertEqual(pages.turning(fields, None)[0], True)
        self.assertEqual(pages.turning(pages.seen_rows({**event, "turning": False})[0]["fields"], {"claude_top": 5})[0], False)
        self.assertIsNone(pages.turning(pages.seen_rows({k: v for k, v in event.items() if k != "turning"})[0]["fields"], {"claude_top": 5})[0])

    def test_after_a_page_reading_a_delta_without_one_keeps_the_turn(self):
        import page as pages
        whole = {"type": "rows", "side": "project", "path": "/code/project/chan_a", "full": True, "settled": True, "turning": True,
                 "rows": [{"key": "cmsg_1", "index": 0, "from": "claude", "text": "a", "streaming": True},
                          {"key": "cmsg_2", "index": 1, "from": "claude", "text": "b", "streaming": True}]}
        writing, state = pages.turning(pages.seen_rows(whole)[0]["fields"], None)
        self.assertTrue(writing)
        delta = {"type": "rows", "side": "project", "path": "/code/project/chan_a", "full": False,
                 "rows": [{"key": "cmsg_1", "index": 0, "from": "claude", "text": "a", "streaming": False}]}
        self.assertIsNone(pages.turning(pages.seen_rows(delta)[0]["fields"], state)[0])  # an older row settling says nothing
        self.assertTrue(pages.turning(pages.seen_rows({**delta, "turning": True})[0]["fields"], state)[0])

    def test_an_older_row_settling_after_a_whole_read_keeps_the_turn(self):
        core, page = support.world()
        a = page.post("chan_a", "claude", "reading files", streaming=True)
        page.post("chan_a", "claude", "running the tests", streaming=True)
        page.outbox.clear()
        page.outbox.append(page.whole("chan_a"))
        page.pump(core)
        proof = {"project": "chan_a", "thread": None, "baseline": []}
        self.assertTrue(do.turning(core.board(), proof))
        page.finish("chan_a", a)
        page.pump(core)
        self.assertTrue(do.turning(core.board(), proof))

    def test_a_short_sleep_moves_a_looks_end_too(self):
        core, page = support.world()
        page.swallow = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = core.runs[1]
        core.clock.t = run["deadline"]
        core.tick()  # ACCEPTED_WAIT over: the look's open is sent, still in the page
        looking = run["looking"]
        support.sleep(core, 30)  # the look's end passed 10 s ago, less than a wait
        core.tick()
        self.assertEqual((store.intents(core.db, 1)[-1]["status"], run["looking"]), ("pending", looking + 30))

    def test_a_tools_failed_open_is_tried_again_once(self):
        core, page = support.world()
        page.page_ok = False
        core.tool("set_instructions", project="chan_b", text="new rules")
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")
        page.page_ok = True
        support.run_out(core, page, 1)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_tools_second_failed_open_in_a_row_fails_it(self):
        core, page = support.world()
        page.page_ok = False
        core.tool("set_instructions", project="chan_b", text="new rules")
        page.pump(core)
        support.run_out(core, page, 1)
        intent = store.intents(core.db, 1)[-1]
        self.assertEqual((intent["status"], intent["cause"]), ("failed", "the page can't be read"))

    def cut_off_then_relinked(self, loaded):
        core, page = support.world()
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": 111, "instance": "i1"}))
        page.composerless = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = core.runs[1]
        core.cancel_send(run)
        page.pump(core)
        self.assertEqual(core.unheard_sends(run), [run["command"]])
        core.connection(False)
        core.connection(True)  # the host links again: the snapshot lists every command sent before
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}, "chan_a"))
        self.assertEqual(core.unheard_sends(run), [run["command"]])  # not yet: the snapshot may be another document's
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}, "chan_a"))
        return core, run

    def test_a_snapshot_that_never_heard_of_a_cut_off_send_stops_it_being_waited_on(self):
        core, run = self.cut_off_then_relinked(111)
        self.assertEqual(core.unheard_sends(run), [])

    def test_a_snapshot_from_a_document_reloaded_while_unlinked_keeps_a_cut_off_send_waited_on(self):
        core, run = self.cut_off_then_relinked(222)
        self.assertEqual(core.unheard_sends(run), [run["command"]])

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_reads_settings_lost_while_muted_come_with_its_replayed_done(self):
        core, page = support.world()
        page.save = "unanswered"  # the act commits with no answer: a read proves it
        core.tool("set_instructions", project="chan_a", text="new rules")
        handle = core.handle
        core.handle = lambda e: None if e.get("type") == "settings" or (e.get("type") == "done" and "settings" in e) else handle(e)
        page.pump(core)
        core.handle = handle
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "pending")
        page.connect(core)  # the snapshot's `done`s carry the read
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")


class ThirdRound(unittest.TestCase):
    def run_tool(self, core, page, tool, **args):
        core.tool(tool, **args)
        page.pump(core)
        return store.intents(core.db, 1)[-1]

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_turning_only_delta_before_the_first_whole_read_leaves_the_rows_unread(self):
        core, page = support.world()
        core.acc["projects"]["chan_a"]["chat"], core._board = None, None
        core.handle(page._stamp({"type": "rows", "side": "project", "rows": [], "full": False, "turning": True}, "chan_a"))
        shown = core.board()["projects"]["chan_a"]
        self.assertEqual((shown["chat"], shown["turning"]), (None, True))

    def test_a_replayed_old_read_keeps_a_goals_mark(self):
        core, page = support.world()
        page.repos = ["acme/app"]
        page.save = "unanswered"
        self.assertEqual(self.run_tool(core, page, "add_repo", project="chan_a", repo="acme/app")["status"], "confirmed")
        self.assertEqual(self.run_tool(core, page, "set_goal", project="chan_a", text="G")["status"], "failed")
        page.save = "ok"
        page.connect(core)  # the snapshot repeats the add_repo's read, with its settings
        self.assertIn("chan_a", core.stale_goal)
        self.assertEqual(self.run_tool(core, page, "set_goal", project="chan_a", text="G")["status"], "refused")

    def test_a_replayed_old_read_isnt_a_tools_proving_read(self):
        core, page = support.world()
        page.repos = ["acme/app", "acme/other"]
        page.save = "unanswered"
        self.run_tool(core, page, "add_repo", project="chan_a", repo="acme/app")
        page.save, page.slow_reads = "nothing_took", True
        second = self.run_tool(core, page, "add_repo", project="chan_a", repo="acme/other")
        page.connect(core)
        self.assertEqual(store.intent(core.db, second["id"])["status"], "pending")
        page.release()
        page.pump(core)
        self.assertEqual(store.intent(core.db, second["id"])["status"], "confirmed")

    def test_a_taken_send_doesnt_go_back_while_another_run_is_about_to_act(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a")
        page.pump(core)
        core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/nope")
        dev = page.inbox.pop()  # in the page: the tool waits behind it
        core.tool("set_instructions", project="chan_b", text="rules")
        self.assertEqual(page.inbox, [])
        for e in page.load("chan_b"):
            core.handle(e)
        self.assertNotIn(("open", "chan_a"), [(c["kind"], c.get("project")) for c in page.inbox])
        core.handle(page._stamp({"type": "done", "id": dev["id"], "ok": True, "error": None}, "chan_b"))
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_tool_waits_for_a_taken_sends_going_back(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a")
        page.pump(core)
        for e in page.load("chan_b"):  # the tab moved: the taken send goes back at once
            core.handle(e)
        self.assertEqual([(c["kind"], c.get("project")) for c in page.inbox], [("open", "chan_a")])
        core.tool("set_instructions", project="chan_b", text="rules")
        self.assertEqual([(c["kind"], c.get("project")) for c in page.inbox], [("open", "chan_a")])
        page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")

    def test_a_sleep_moves_a_taken_sends_wait_by_the_whole_sleep(self):
        core, page = support.world()
        page.holds = True
        core.say("plain test words", project="chan_a")
        page.pump(core)
        run = next(iter(core.runs.values()))
        support.later(core, 10)
        support.sleep(core, 1000)
        core.tick()
        page.pump(core)
        self.assertGreater(run["deadline"] - core.clock(), 280)

    def test_a_later_commands_done_before_the_cancel_doesnt_say_a_cut_off_send_never_ran(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        send = page.inbox.pop()  # waits in the page while it settles
        run = next(iter(core.runs.values()))
        core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/nope")
        page.pump(core)  # a later command, answered while the send still waits
        core.cancel_send(run)
        self.assertEqual(core.unheard_sends(run), [send["id"]])

    def test_a_tool_whose_open_erred_holds_no_send_back(self):
        core, page = support.world()
        core.tool("set_instructions", project="chan_b", text="rules")
        op = page.inbox.pop()
        core.handle(page._stamp({"type": "done", "id": op["id"], "ok": False, "error": "no tab to be had"}, "chan_a"))
        core.say("plain test words", project="chan_a")
        self.assertEqual([c["kind"] for c in page.inbox], ["send"])

    @support.python_only("hands goto a bare dict and reads what it changed in place")
    def test_an_erred_open_is_its_stages_own(self):
        core, page = support.world()
        run = {"open_error": True}
        core.goto(run, "prove")
        self.assertFalse(run["open_error"])


class GoingBackBounds(unittest.TestCase):
    """A taken send's going back holds the tab for at most do.TIMEOUT, and an open no page will run holds nobody."""

    def steps(self, core, page, until, seconds=200):
        for s in range(0, seconds, 5):
            support.later(core, 5); core.tick(); page.pump(core)
            if until():
                return s + 5
        return None

    def going_back(self, mode):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a"); page.pump(core)
        for e in page.load("chan_b"):
            core.handle(e)
        back = page.inbox.pop()  # the go-back open, never run
        self.assertEqual((back["kind"], back["project"]), ("open", "chan_a"))
        if mode == "reload":
            page.reload(core, "chan_b")
        else:
            core.connection(False); page.connect(core)
            for e in page.load("chan_b"):
                core.handle(e)
        self.assertNotEqual(core.runs[1].get("open"), back["id"])  # the page said it never ran, or the host lost it: it may go back again
        core.tool("set_instructions", project="chan_b", text="rules"); page.pump(core)
        took = self.steps(core, page, lambda: store.intent(core.db, 2)["status"] == "confirmed")
        self.assertIsNotNone(took)
        self.assertLessEqual(took, do.TIMEOUT)

    def test_a_go_back_open_a_reload_dropped_holds_no_tool(self):
        self.going_back("reload")

    def test_a_go_back_open_lost_with_the_host_holds_no_tool(self):
        self.going_back("host")

    def test_an_ok_go_back_whose_tab_never_arrives_holds_a_tool_at_most_the_timeout(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a"); page.pump(core)
        for e in page.load("chan_b"):
            core.handle(e)
        back = page.inbox.pop()
        core.handle(page._stamp({"type": "done", "id": back["id"], "ok": True, "error": None}, "chan_b"))  # the tab stays on chan_b
        core.tool("set_instructions", project="chan_b", text="rules"); page.pump(core)
        self.assertEqual(store.intent(core.db, 2)["status"], "pending")  # held while the tab may still move
        self.assertLessEqual(core.next_deadline(), core.clock() + do.TIMEOUT)  # a timer ends the hold
        took = self.steps(core, page, lambda: store.intent(core.db, 2)["status"] == "confirmed")
        self.assertIsNotNone(took)
        self.assertLessEqual(took, do.TIMEOUT + 5)


class NeverRanSends(unittest.TestCase):
    def relinked(self, loaded_after):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        core.say("plain test words", project="chan_a")
        page.inbox.pop()  # lost in transit with the host: the page never got it
        core.connection(False); core.connection(True)
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}))
        run = core.runs[1]
        self.assertFalse(run.get("went"))  # not decided before the page says which document this is
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded_after, "instance": "i1"}))
        return core, page, run

    def test_a_send_the_same_document_says_never_ran_is_typed_again(self):
        core, page, run = self.relinked(1793706095915)
        for e in page.load("chan_a"):
            core.handle(e)
        self.assertFalse(run.get("went") or run.get("taken") or run.get("clicked"))
        sends = [c for c in page.inbox if c["kind"] == "send"]
        self.assertEqual(len(sends), 1)
        self.assertFalse(sends[0].get("click_only"))
        page.pump(core)
        support.run_out(core, page, 1, 40)
        self.assertEqual(store.intent(core.db, 1)["status"], "confirmed")
        self.assertEqual(page.clicks, 1)

    def test_a_paused_send_that_went_with_a_reload_is_judged_as_any_taken_one_when_it_comes_out(self):
        """Handed to a page that reloaded while the tab was signed out: out of the pause it went, and the reloaded page's rows, which
        lack it, say so at once (its wait ends do.TIMEOUT after the page went), as for a send that went unpaused."""
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        page.inbox.pop()  # handed to the page, which goes before it says what it did
        page.signed_in = False
        page.reload(core, "chan_a"); page.pump(core)
        run = core.runs[1]
        self.assertEqual((run["paused"], run.get("dropped")), (True, run["command"]))
        page.signed_in = True
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "instance": page.instance}))
        self.assertEqual((run.get("went"), run.get("vanished_at"), run["deadline"]), (True, core.clock(), core.clock() + do.TIMEOUT))
        support.run_out(core, page, 1)
        self.assertEqual((store.intent(core.db, 1)["status"], store.intent(core.db, 1)["cause"], page.clicks), ("failed", routerd.WENT, 0))

    def test_a_send_dropped_by_another_document_went(self):
        core, page, run = self.relinked(1793706099999)
        self.assertTrue(run.get("went") and run.get("taken"))
        self.assertFalse([c for c in page.inbox if c["kind"] == "send"])

    def test_an_extension_reload_keeping_the_document_doesnt_type_a_clicked_send_again(self):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        page.holds = True  # queued behind a turn: no row of it yet
        core.say("plain test words", project="chan_a")
        send = page.inbox.pop()
        core.connection(False)
        page.run(send)  # the old script clicks; its `done` is only in that script's `recent`
        core.connection(True)
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        # a new script in the same document: same `loaded`, its own `instance`, an empty `recent`
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i2"}))
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i2"}))
        for e in page.load("chan_a"):
            core.handle(e)
        page.pump(core)
        run = core.runs[1]
        self.assertTrue(run.get("went") and run.get("taken"))
        self.assertFalse(run.get("unran"))
        self.assertEqual(page.clicks, 1)

    def test_a_snapshot_without_instance_proves_no_send_never_ran(self):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded}))
        core.say("plain test words", project="chan_a")
        page.inbox.pop()
        core.connection(False); core.connection(True)
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": []}))
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded}))
        self.assertTrue(core.runs[1].get("went"))
        self.assertFalse(core.runs[1].get("unran"))

    def test_the_workers_page_less_page_event_decides_nothing(self):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        core.say("plain test words", project="chan_a")
        page.inbox.pop()
        core.connection(False); core.connection(True)
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}))
        core.handle({"type": "page", "signed_in": None, "page_ok": False})  # the worker's: no tab answered, no document named
        self.assertTrue(core.relinked)
        self.assertFalse(core.runs[1].get("went"))
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        self.assertFalse(core.relinked)

    def test_a_new_documents_done_says_nothing_of_an_old_ones_cut_off_send(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        send = page.inbox.pop()
        run = core.runs[1]
        core.cancel_send(run)
        core.handle(page._stamp({"type": "page", "gone": True}))
        core.dev_command("remove_folder", lambda d: None, project="chan_a", path="/nope")
        page.pump(core)  # the next document runs it before its `page`
        self.assertIn(send["id"], core.unheard_sends(run))


class LostMoves(unittest.TestCase):
    """A taken send's open lost with a page or a host, a host's overlap, and a taken send whose place left the Board."""

    def taken_elsewhere(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a"); page.pump(core)
        for e in page.load("chan_b"):  # you moved the tab
            core.handle(e)
        return core, page, core.runs[1]

    def test_a_look_whose_open_is_lost_with_the_host_is_sent_again_once(self):
        core, page, run = self.taken_elsewhere()
        page.inbox.pop()
        run["open"] = run["moving_to"] = None  # its going back went nowhere
        page.holds = False; page.deliver("chan_a"); page.outbox.clear()
        core.clock.t = run["deadline"]; core.tick()
        self.assertIsNotNone(run.get("looking"))
        page.inbox.clear()  # the look's open, lost with the host
        core.connection(False)
        self.assertIsNone(run.get("looking"))
        self.assertFalse([c for c in page.inbox if c["kind"] == "open"])  # not sent with no host
        core.connection(True)
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": list(page.recent)}))
        looks = [c for c in page.inbox if c["kind"] == "open" and c["project"] == "chan_a"]
        self.assertEqual(len(looks), 1)
        self.assertEqual(run["looking"], core.clock() + do.TIMEOUT)  # a fresh wait
        page.inbox = [c for c in page.inbox if c["kind"] != "open"]
        core.connection(False); core.connection(True)  # lost again: the look keeps its deadline
        self.assertIsNotNone(run.get("looking"))
        self.assertFalse([c for c in page.inbox if c["kind"] == "open"])

    def test_a_look_taken_again_after_its_end_moved_on_is_sent_again_if_its_open_is_lost(self):
        core, page, run = self.taken_elsewhere()
        page.inbox.pop()
        run["open"] = run["moving_to"] = None
        page.holds = False; page.deliver("chan_a"); page.outbox.clear()
        core.clock.t = run["deadline"]; core.tick()
        page.inbox.clear()
        core.connection(False); core.connection(True)  # the look's open is lost, and sent again once
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": list(page.recent)}))
        self.assertTrue(run["relooked"])
        run["accepted"] = core.clock()  # the coordinator's turn moved the send's end on: that look is over
        core.advance_all()
        self.assertIsNone(run.get("looking"))
        self.assertFalse(run["relooked"])  # the look taken next has its own retry

    def test_a_look_a_reloaded_page_never_ran_is_sent_again_and_confirms(self):
        core, page, run = self.taken_elsewhere()
        page.inbox.pop()
        run["open"] = run["moving_to"] = None
        page.holds = False; page.deliver("chan_a"); page.outbox.clear()
        core.clock.t = run["deadline"]; core.tick()
        end = run["looking"]
        page.inbox.clear()
        page.reload(core, "chan_b")
        self.assertTrue([c for c in page.inbox if c["kind"] == "open" and c["project"] == "chan_a"])
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        page.pump(core)
        self.assertLess(core.clock(), end + do.TIMEOUT)
        self.assertEqual(store.intent(core.db, 1)["status"], "confirmed")

    def test_a_go_back_lost_with_the_host_goes_back_again(self):
        core, page, run = self.taken_elsewhere()
        back = page.inbox.pop()
        core.connection(False); page.connect(core)
        for e in page.load("chan_b"):
            core.handle(e)
        again = [c for c in page.inbox if c["kind"] == "open" and c["project"] == "chan_a"]
        self.assertTrue(again and again[-1]["id"] != back["id"])

    def overlap(self, current):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        core.say("plain test words", project="chan_a")
        page.inbox.pop()  # lost in transit with the old host
        core.connection(True)  # the new host links before the old one's socket closes
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}))
        core.connection(False, current=current)
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        return core, page, core.runs[1]

    def test_an_older_host_leaving_after_a_newer_linked_decides_nothing(self):
        core, page, run = self.overlap(current=False)
        self.assertFalse(run.get("went") or run.get("taken"))
        self.assertTrue([c for c in page.inbox if c["kind"] == "send"])  # the same document says it never ran: typed again
        page.pump(core)
        support.run_out(core, page, 1, 40)
        self.assertEqual(store.intent(core.db, 1)["status"], "confirmed")
        self.assertEqual(page.clicks, 1)

    def test_the_host_commands_go_to_leaving_settles_the_dropped_send(self):
        core, page, run = self.overlap(current=True)
        self.assertTrue(run.get("went") and run.get("taken"))

    def test_a_retried_never_ran_send_uses_no_attempt(self):
        core, page = support.world()
        loaded = 1793706095915
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        core.say("plain test words", project="chan_a")
        page.inbox.pop()
        self.assertEqual(store.intent(core.db, 1)["attempts"], 1)
        core.connection(False); core.connection(True)
        page.inbox = [c for c in page.inbox if c["kind"] != "wake"]
        core.handle(page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}))
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        for e in page.load("chan_a"):
            core.handle(e)
        self.assertTrue([c for c in page.inbox if c["kind"] == "send"])
        self.assertEqual(store.intent(core.db, 1)["attempts"], 1)

    def test_a_paused_send_its_page_says_never_ran_keeps_its_attempt(self):
        core, page = support.world()
        core.say("plain test words", project="chan_a")
        send = page.inbox.pop()  # never reached the page
        run = core.runs[1]
        support.later(core, 15)
        run["paused"], run["dropped"], run["unran"] = True, send["id"], {send["id"]}  # paused when `replay` found it never ran
        for e in page.load("chan_a"):  # the page is back: it is made again
            core.handle(e)
        sends = [c for c in page.inbox if c["kind"] == "send"]
        self.assertEqual(len(sends), 1)
        self.assertFalse(sends[0].get("click_only"))
        self.assertEqual(store.intent(core.db, 1)["attempts"], 1)  # the same attempt
        self.assertGreater(run["deadline"] - core.clock(), do.TIMEOUT - 1)  # with a fresh wait

    def test_a_clicked_send_whose_place_left_the_board_is_a_watched_failure(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha", project="chan_a"); page.pump(core)
        self.assertTrue(core.runs[1].get("clicked"))
        others = [{"id": p, "name": v["name"]} for p, v in page.projects.items() if p != "chan_a"]
        core.handle({"type": "projects", "projects": others, "complete": True, "path": "/code/projects/browse", "thread": None})
        self.assertEqual(store.intent(core.db, 1)["status"], "failed")
        self.assertIn(1, core.watched)

    def test_an_unsent_send_whose_place_left_the_board_is_refused(self):
        core, page = support.world()
        others = [{"id": p, "name": v["name"]} for p, v in page.projects.items() if p != "chan_a"]
        core.handle({"type": "projects", "projects": others, "complete": True, "path": "/code/projects/browse", "thread": None})
        core.say("words for alpha", project="chan_a")
        self.assertEqual(store.intent(core.db, 1)["status"], "refused")

    def test_an_arrival_after_a_done_go_back_ends_its_hold(self):
        core, page, run = self.taken_elsewhere()
        back = page.inbox.pop()
        core.handle(page._stamp({"type": "done", "id": back["id"], "ok": True, "error": None}, "chan_b"))
        self.assertEqual(run.get("moving_to"), ("chan_a", None))
        for e in page.load("chan_a"):  # the tab arrived: the move is over
            core.handle(e)
        self.assertIsNone(run.get("moving_to"))
        self.assertIsNone(run.get("hold_until"))

    def test_an_arrival_before_a_go_backs_ok_done_ends_its_hold_at_the_done(self):
        core, page, run = self.taken_elsewhere()
        back = page.inbox.pop()
        for e in page.load("chan_a"):  # the arrival's `page` came before the open's `done`, as it normally does
            core.handle(e)
        core.handle(page._stamp({"type": "done", "id": back["id"], "ok": True, "error": None}, "chan_a"))
        self.assertIsNone(run.get("moving_to"))
        self.assertIsNone(run.get("hold_until"))

    def test_a_sleep_moves_an_opens_hold(self):
        core, page, run = self.taken_elsewhere()
        hold = run["hold_until"]
        support.sleep(core, 3600); core.tick()
        self.assertGreaterEqual(run["hold_until"], hold + 3600 - 1)


class LookHoldsTheTab(unittest.TestCase):
    """A taken send's look holds the tab until it ends, and a watched failed send goes back to its place while the tab is idle: its
    late row comes only in a `rows` event of that place."""
    def held(self):
        core, page = support.world()
        page.holds = True  # the coordinator is replying: your message is queued
        core.say("please look at the failing build", project="chan_a"); page.pump(core)
        a = store.intents(core.db, 1)[-1]["id"]
        page.holds = False
        page.rendering.add(("chan_a", None))  # its read doesn't settle yet: the look waits on (a settled read with no row would end it)
        support.later(core, routerd.ACCEPTED_WAIT); core.tick(); page.pump(core)  # the look: opens chan_a, still only pending
        self.assertIsNotNone(core.runs[a].get("looking"))
        return core, page, a

    def settle(self, core, page, until=lambda: False):
        for _ in range(40):
            d = core.next_deadline()
            if d is None or until():
                break
            core.clock.t = max(core.clock.t, d); core.tick(); page.pump(core)

    def opens(self, page, place):
        return [c for c in page.calls if c[0] == "open" and tuple(c[1:3]) == place]

    def test_a_send_made_during_a_look_waits_for_it_to_end(self):
        core, page, a = self.held()
        support.later(core, 2)
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)  # the owner sends elsewhere during the look
        b = store.intents(core.db, 1)[-1]["id"]
        self.assertEqual((store.intent(core.db, b)["status"], page.at), ("pending", ("chan_a", None)))  # the tab stays for the look
        support.later(core, 3); page.deliver("chan_a"); page.pump(core)  # the turn ends: the queued row shows
        self.assertEqual(store.intent(core.db, a)["status"], "confirmed")
        self.settle(core, page)
        self.assertEqual((store.intent(core.db, b)["status"], core.runs, core.watched), ("confirmed", {}, {}))

    def test_a_look_holds_a_send_at_most_until_it_ends(self):
        core, page, a = self.held()
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)
        b = store.intents(core.db, 1)[-1]["id"]
        self.settle(core, page)
        self.assertEqual((store.intent(core.db, a)["status"], store.intent(core.db, b)["status"]), ("failed", "confirmed"))
        self.assertLessEqual(store.intent(core.db, b)["updated"] - store.intent(core.db, a)["updated"], 1)  # right after the look's end

    def failed_then_moved(self):
        """The look ends with no row, then a send elsewhere moves the tab: the watched send goes back once the tab is idle."""
        core, page, a = self.held()
        self.settle(core, page, lambda: a not in core.runs)
        page.rendering.clear()  # chan_a renders from now on
        self.assertEqual((store.intent(core.db, a)["status"], a in core.watched), ("failed", True))
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")
        return core, page, a

    def test_a_watched_send_goes_back_to_its_place_and_its_late_row_confirms_it(self):
        core, page, a = self.failed_then_moved()
        self.assertEqual((page.at, len(self.opens(page, ("chan_a", None)))), (("chan_a", None), 2))  # its look's, its going back
        sends = [c for c in page.calls if c[0] == "send"]
        page.deliver("chan_a"); page.pump(core)
        i = store.intent(core.db, a)
        self.assertEqual((i["status"], core.watched), ("confirmed", {}))
        self.assertIn("confirmed late", i["cause"])
        self.assertEqual(([c for c in page.calls if c[0] == "send"], page.clicks), (sends, 2))  # the going back typed and clicked nothing

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_watched_send_goes_back_once_per_move(self):
        core, page, a = self.failed_then_moved()
        for e in page.load("chan_b"):  # you move the tab: no run's move
            core.handle(e)
        page.pump(core)
        support.later(core, 30); core.tick(); page.pump(core)
        self.assertEqual((page.at, len(self.opens(page, ("chan_a", None)))), (("chan_b", None), 2))
        core.moves += 1  # a run's open moved the tab (as a send's to another place does): it goes back once more
        core.advance_all(); page.pump(core)
        self.assertEqual((page.at, len(self.opens(page, ("chan_a", None)))), (("chan_a", None), 3))

    def test_a_watched_send_goes_back_behind_a_live_send(self):
        core, page, a = self.held()
        self.settle(core, page, lambda: a not in core.runs)
        page.rendering.clear()  # chan_a renders from now on
        page.slow_opens = True  # the next send's open waits in the page
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)
        b = store.intents(core.db, 1)[-1]["id"]
        self.assertEqual((store.intent(core.db, b)["status"], len(self.opens(page, ("chan_a", None)))), ("pending", 1))  # not while it has the tab
        page.slow_opens = False
        page.settle(); page.pump(core)
        self.assertEqual(store.intent(core.db, b)["status"], "confirmed")
        self.assertEqual((page.at, len(self.opens(page, ("chan_a", None)))), (("chan_a", None), 2))

    def test_a_taken_send_whose_place_a_watched_one_left_goes_back_to_it(self):
        core, page, a = self.held()
        self.settle(core, page, lambda: a not in core.runs)
        page.rendering.clear()  # chan_a renders from now on
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)  # confirmed: the tab is on chan_b
        page.holds = True
        core.say("and beta once more", project="chan_b"); page.pump(core)  # taken, queued: it shows its place and waits
        c = store.intents(core.db, 1)[-1]["id"]
        # The send moved the tab: the watched one went back to chan_a, then the taken one back to its place.
        self.assertEqual((store.intent(core.db, c)["status"], len(self.opens(page, ("chan_a", None))), page.at), ("pending", 3, ("chan_b", None)))
        page.holds = False
        page.deliver("chan_b"); page.pump(core)
        self.assertEqual(store.intent(core.db, c)["status"], "confirmed")

    def test_tools_made_during_a_look_wait_for_it_and_act_in_order(self):
        core, page, a = self.held()
        core.tool("set_instructions", project="chan_b", text="first rules"); page.pump(core)
        core.tool("set_instructions", project="chan_b", text="second rules"); page.pump(core)
        self.assertEqual(([c for c in page.calls if c[0] == "set_field"], page.at), ([], ("chan_a", None)))  # the look keeps the tab
        self.settle(core, page)
        self.assertEqual([i["status"] for i in store.intents(core.db, 3)], ["failed", "confirmed", "confirmed"])
        self.assertEqual(page.projects["chan_b"]["settings"]["instructions"], "second rules")

    def test_a_look_ends_once_its_settled_read_shows_no_row_and_lets_the_tab_go(self):
        core, page = support.world()
        page.swallow = True  # taken, and no row of it ever shows, not even pending
        core.say("please look at the failing build", project="chan_a"); page.pump(core)
        a = store.intents(core.db, 1)[-1]["id"]
        page.swallow = False
        support.later(core, routerd.ACCEPTED_WAIT); core.tick(); page.pump(core)  # the look's read settles with no row: the outcome is known
        self.assertEqual((store.intent(core.db, a)["status"], a in core.watched), ("failed", True))
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")  # no 20 s wait for nothing

    def test_a_look_of_a_shown_place_ends_on_the_read_that_comes_before_its_open_is_done(self):
        core, page = support.world()
        page.swallow = True
        core.say("please look at the failing build", project="chan_a"); page.pump(core)
        run = core.runs[store.intents(core.db, 1)[-1]["id"]]
        page.swallow = False
        page.slow_opens = True
        support.later(core, routerd.ACCEPTED_WAIT); core.tick(); page.pump(core)
        self.assertEqual((run["open_shown"], bool(run.get("open"))), (True, True))  # the open moves no tab
        page.outbox.append(page.whole("chan_a")); page.pump(core)  # the page's own read, before the open's `done`
        self.assertTrue(run["look_read"])

    def look_due(self, turn=False):
        core, page = support.world()
        page.holds = True  # queued: the page shows your row pending
        core.say("words for alpha one", project="chan_a"); page.pump(core)
        run = core.runs[store.intents(core.db, 1)[-1]["id"]]
        row = page.post("chan_a", "claude", "", streaming=True, pending=True) if turn else None
        page.pump(core)
        return core, page, run, row

    def test_a_read_showing_your_row_pending_does_not_end_the_look(self):
        for turn in (False, True):
            core, page, run, row = self.look_due(turn)
            core.clock.t = run["accepted"] + routerd.ACCEPTED_WAIT; core.tick(); page.pump(core)
            self.assertEqual((store.intent(core.db, run["id"])["status"], run.get("look_read")), ("pending", False))
            core.clock.t += 5
            if row:
                row["text"] = "reply"; page.finish("chan_a", row)
            page.deliver("chan_a"); page.pump(core)
            self.assertEqual(store.intent(core.db, run["id"])["status"], "confirmed")  # never failed first

    def test_a_read_from_before_the_looks_open_ran_does_not_end_it(self):
        core, page, run, _ = self.look_due()
        for e in page.load("chan_b"):  # you moved the tab: the look's open moves it back (to a place not shown when it is sent)
            core.handle(e)
        core.clock.t = run["accepted"] + routerd.ACCEPTED_WAIT
        page.slow_opens = True
        core.tick(); page.pump(core)
        self.assertIsNotNone(run.get("open"))
        stale = page.whole("chan_a")  # a render from before the open ran: a cached one, lacking your row
        stale["rows"] = [r for r in stale["rows"] if r["from"] != "you"]
        page.outbox.append(stale); page.pump(core)
        self.assertEqual((run.get("look_read"), store.intent(core.db, run["id"])["status"]), (False, "pending"))  # not the look's answer
        for r in page._rows("chan_a", None):  # the server had it: the look's own fresh read shows it keyed
            if r["pending"] and r["from"] == "you":
                r.update(key=page.key(), pending=False)
        page.settle(); page.pump(core)
        self.assertEqual(store.intent(core.db, run["id"])["status"], "confirmed")

    def test_a_send_held_by_a_look_goes_on_in_the_pass_the_look_ends(self):
        core, page, a = self.held()
        core.say("and tell beta to rebase", project="chan_b"); page.pump(core)
        b = store.intents(core.db, 1)[-1]["id"]
        self.assertEqual(store.intent(core.db, b)["status"], "pending")
        core.clock.t = core.runs[a]["looking"]; core.tick(); page.pump(core)  # the look's end: one tick
        self.assertEqual((store.intent(core.db, a)["status"], store.intent(core.db, b)["status"]), ("failed", "confirmed"))

    def mid_turn_look(self):
        """A vanished send's early look finds the coordinator mid-turn: its end moves on to the full wait."""
        core, page = support.world()
        page.holds = True
        core.say("words for alpha one", project="chan_a"); page.pump(core)
        a = store.intents(core.db, 1)[-1]["id"]
        page.holds = False
        page.reload(core, "chan_a", pending="lost"); page.pump(core)
        page.holds = True
        core.say("words for beta one", project="chan_b"); page.pump(core)  # taken on chan_b: the tab moved there
        page.holds = False
        page.post("chan_a", "claude", "", streaming=True)  # a turn starts in chan_a while the tab is on chan_b
        core.clock.t = core.runs[a]["deadline"]; core.tick(); page.pump(core)  # the look: the tab shows chan_a mid-turn
        return core, page, core.runs[a]

    def test_a_look_whose_end_moves_on_holds_nobody(self):
        core, page, run = self.mid_turn_look()
        self.assertEqual((run["looking"], run["deadline"] - core.clock()), (None, routerd.ACCEPTED_WAIT - do.TIMEOUT))
        core.tool("set_instructions", project="chan_b", text="new rules"); page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")  # not at the taken send's full wait

    def two_watched(self):
        core, page = support.world()
        page.holds = True
        core.say("words for alpha one", project="chan_a"); page.pump(core)
        core.say("words for beta one", project="chan_b"); page.pump(core)
        for _ in range(40):
            if not core.runs:
                break
            core.clock.t = max(core.clock.t + 0.05, core.next_deadline()); core.tick(); page.pump(core)
        page.holds = False
        self.assertEqual(sorted(core.watched), [1, 2])
        return core, page

    def test_a_watched_send_going_back_holds_until_its_place_is_read(self):
        core, page = self.two_watched()
        page.at = None
        page.deliver("chan_a"); page.deliver("chan_b"); page.outbox.clear()  # the server shows them; the tab is on /code
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "instance": page.instance})); page.pump(core)
        page.mounting.add(("chan_a", None))  # chan_a's rows come after its `page`
        core.tool("create_project", name="gamma"); page.pump(core)  # a run's move
        self.assertEqual((page.at, core.watch_open and core.watch_open["to"]), (("chan_a", None), ("chan_a", None)))  # held for the read
        page.mount("chan_a", None); page.pump(core)
        support.later(core, 1); core.tick(); page.pump(core)
        self.assertEqual([store.intent(core.db, i)["status"] for i in (1, 2)], ["confirmed", "confirmed"])

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_watched_going_back_to_a_shown_place_ends_on_the_read_before_its_open_is_done(self):
        core, page = self.two_watched()
        page.at = None
        page.deliver("chan_a"); page.deliver("chan_b"); page.outbox.clear()
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "instance": page.instance})); page.pump(core)
        page.mounting.add(("chan_a", None))
        page.slow_opens = True
        page.at = ("chan_a", None)  # the tab just arrived on chan_a: shown, its rows not read yet
        core.handle(page._stamp({"type": "page", "signed_in": True, "page_ok": True, "instance": page.instance}))
        core.watch_back.clear(); core.moves += 1
        core.advance_all(); page.pump(core)
        self.assertTrue(core.watch_open and core.watch_open["shown"] and core.watch_open["open"])
        page.mounting.discard(("chan_a", None))
        page.outbox.append(page.whole("chan_a")); page.pump(core)  # the page's own read, before the open's `done`
        self.assertNotEqual((core.watch_open or {}).get("to"), ("chan_a", None))  # over (the other watched send's going back may follow)

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_watched_open_a_reloaded_page_never_ran_holds_nobody(self):
        core, page = self.two_watched()
        core.watch_back.clear(); core.moves += 1
        page.slow_opens = True
        core.advance_all(); page.pump(core)
        self.assertIsNotNone(core.watch_open)
        page.slow_opens = False
        page.reload(core, "chan_b", pending="keyed"); page.pump(core)  # the open waited in the page that went
        core.say("a new message right after", project="chan_a"); page.pump(core)
        self.assertEqual(store.intents(core.db, 1)[-1]["status"], "confirmed")  # not held 20 s by an open that never ran

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_sleep_moves_a_watched_opens_hold(self):
        core, page = self.two_watched()
        core.watch_back.clear(); core.moves += 1
        page.slow_opens = True
        core.advance_all(); page.pump(core)
        hold = core.watch_open["hold_until"]
        support.sleep(core, 3600); core.tick()
        self.assertGreaterEqual(core.watch_open["hold_until"], hold + 3600 - 1)

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_look_waits_for_a_watched_send_going_back(self):
        core, page = self.two_watched()
        page.holds = True
        core.say("words for alpha two", project="chan_a"); page.pump(core)
        c = store.intents(core.db, 1)[-1]["id"]
        core.watch_back.clear(); core.moves += 1
        page.slow_opens = True
        core.advance_all(); page.pump(core)
        self.assertIsNotNone(core.watch_open)
        run = core.runs[c]
        run["accepted"] = core.clock() - routerd.ACCEPTED_WAIT  # its look is due now
        core.safely(run)
        self.assertEqual((run.get("looking"), run["deadline"]), (None, core.watch_open["hold_until"]))  # it goes once that is over

    def test_an_erred_look_looks_again_once_then_waits_for_its_end(self):
        core, page, a = self.held()
        original = page.run
        page.run = lambda c: ([page._stamp({"type": "done", "id": c["id"], "ok": False, "error": "superseded"})]
                              if c["kind"] == "open" else original(c))
        core.handle(page._stamp({"type": "done", "id": core.runs[a]["open"], "ok": False, "error": "superseded"}))
        page.inbox.clear()
        self.settle(core, page)
        looks = [c for c in page.calls if c[0] == "open"]
        self.assertEqual(store.intent(core.db, a)["status"], "failed")
        self.assertLessEqual(len(looks), 3)  # the send's open, and one look again


if __name__ == "__main__":
    unittest.main()
