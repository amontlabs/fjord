import unittest

import support
from support import NOW
import do
import routerd
import store


class Deliver(unittest.TestCase):
    def setUp(self):
        self.core, self.page = support.world()
        self.done = []

    def say(self, words="plain test words", project="chan_a", thread=None, pump=True):
        self.core.say(words, project=project, thread=thread, finished=self.done.append)
        if pump:
            self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def sends(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def timeout(self):
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def test_a_send_is_proved_by_a_row_from_you_and_timed(self):
        out = self.say()
        self.assertEqual((out["status"], out["attempts"]), ("confirmed", 1))
        self.assertEqual([c[0] for c in self.page.calls], ["send"])  # the tab already shows alpha
        self.assertEqual(self.page.projects["chan_a"]["chat"][-1]["text"], "plain test words")
        self.assertEqual(set(out["result"]["ms"]), {"decided", "clicked", "proved"})
        self.assertEqual(self.done[0]["status"], "confirmed")
        self.assertIsNone(self.core.next_deadline() if not self.core.runs else None)

    def test_a_failed_command_is_retried_at_once_not_at_the_deadline(self):
        place = self.page.projects["chan_a"]
        original = self.page.run
        failures = []

        def run(command):
            if command["kind"] == "send" and not failures:
                failures.append(command)
                return [{"type": "done", "id": command["id"], "ok": False, "error": "no composer", "path": "/code", "thread": None, "visibility": "hidden"}]
            return original(command)
        self.page.run = run
        out = self.say()
        self.assertEqual((out["status"], out["attempts"]), ("confirmed", 2))
        self.assertEqual(len(place["chat"]), 1)

    def test_a_superseded_command_does_not_retry(self):
        self.page.run = lambda c: [{"type": "done", "id": c["id"], "ok": False, "error": "superseded", "path": "/code", "thread": None, "visibility": "hidden"}]
        self.assertEqual(self.say()["attempts"], 1)

    def test_a_reply_goes_to_its_thread(self):
        out = self.say(thread="cmsg_2", project=None)
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual([m["text"] for m in self.page.projects["chan_a"]["threads"]["cmsg_2"]["messages"]], ["Alpha second task", "plain test words"])

    def test_a_project_send_goes_in_once_though_the_page_reopened_a_thread_beside_it(self):
        original = self.page.run

        def run(command):  # arriving on the project, the page puts back the thread last shown there, after the open said done
            events = original(command)
            if command["kind"] == "open" and command.get("project") == "chan_a" and not command.get("thread"):
                self.page.at = ("chan_a", "cmsg_2")
            return events
        self.say("words for beta", project="chan_b")  # the tab is on beta, so alpha needs an open
        self.page.run = run
        out = self.say()
        self.assertEqual((out["status"], out["attempts"]), ("confirmed", 1))
        self.assertEqual([m["text"] for m in self.core.board()["projects"]["chan_a"]["chat"]][-1:], ["plain test words"])

    def test_a_project_open_onto_its_project_with_a_thread_beside_it_leaves_the_thread_open(self):
        self.say("words for beta", project="chan_b")  # routerd last saw the tab on beta, so alpha needs an open
        self.page.at = ("chan_a", "cmsg_2")  # meanwhile the tab moved to alpha's thread, unseen: the open finds the project shown
        out = self.say()
        self.assertEqual((out["status"], out["attempts"]), ("confirmed", 1))
        opens = [c for c in self.page.calls if c[0] == "open"]
        self.assertEqual(opens[-1][1:3], ("chan_a", None))
        self.assertEqual(self.page.at, ("chan_a", "cmsg_2"))  # the open's `done` names the thread shown, which `shows` takes as the project
        self.assertEqual([m["text"] for m in self.page.projects["chan_a"]["chat"]][-1:], ["plain test words"])

    def test_a_folder_with_no_project_is_refused(self):
        intent, _ = store.add_intent(self.core.db, NOW, "send_to_project", "plain test words", "local:repo", None, proof={"project": "local:repo", "thread": None, "words": "x"})
        self.core.start(intent, NOW)
        self.assertEqual(store.intent(self.core.db, intent["id"])["status"], "refused")
        self.assertEqual(self.page.inbox, [])

    def test_the_same_words_to_the_same_place_are_one_intent(self):
        self.say(pump=False)
        self.say(pump=False)
        self.page.pump(self.core)
        self.assertEqual(len(self.sends()), 1)
        self.assertEqual(len(self.done), 2)

    def test_the_same_words_again_after_the_first_is_confirmed_are_sent_again(self):
        self.assertEqual(self.say()["status"], "confirmed")
        out = self.say()
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual(len(self.sends()), 2)

    def test_the_same_words_after_the_window_are_sent_again(self):
        self.say()
        support.later(self.core, store.DUP_WINDOW + 1)
        self.assertEqual(self.say()["status"], "confirmed")
        self.assertEqual(len(self.sends()), 2)

    def test_another_project_is_opened_first_and_the_page_there_is_not_opened_again(self):
        self.say(project="chan_b")
        support.later(self.core, store.DUP_WINDOW + 1)
        self.say(project="chan_b")
        self.assertEqual([c[0] for c in self.page.calls], ["open", "send", "send"])
        self.assertEqual(len(self.page.projects["chan_b"]["chat"]), 2)

    def test_a_waiting_send_is_replaced_by_its_retry_and_clicks_once_when_the_page_settles(self):
        self.page.settles = True
        self.say("first words")
        out = self.say("second words")
        self.assertEqual((out["status"], out["attempts"]), ("pending", 1))  # settling: waits, no click yet
        support.later(self.core, do.TIMEOUT - 1)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(len(self.sends()), 2)  # first, second: no retry before the deadline
        out = self.timeout()
        self.assertEqual((out["status"], out["attempts"], len(self.sends())), ("pending", 2, 3))
        self.assertEqual(len(self.page.waiting), 1)  # the retry replaced the waiting send
        self.assertEqual(self.core.next_deadline(), self.core.clock() + do.TIMEOUT)
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual((store.intents(self.core.db, 1)[-1]["status"], self.page.clicks), ("confirmed", 2))

    def test_words_already_in_the_draft_are_sent_by_one_click(self):
        self.page.projects["chan_a"]["draft"] = "plain  test\nwords"
        self.page.connect(self.core)
        out = self.say("plain test words")
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual((len(self.sends()), self.page.clicks), (1, 1))

    def test_during_a_turn_the_words_are_typed_without_waiting_for_send(self):
        self.page.projects["chan_a"]["turn"] = True
        self.page.connect(self.core)
        self.assertIsNone(self.core.board()["projects"]["chan_a"]["disabled"])
        out = self.say()
        self.assertEqual((out["status"], out["attempts"], self.page.clicks), ("confirmed", 1, 1))

    def test_no_composer_waits_without_using_up_attempts(self):
        self.page.composerless = True
        out = self.say()
        self.assertEqual((out["status"], out["attempts"]), ("pending", 1))
        self.page.settle()
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], out["attempts"], self.page.clicks), ("confirmed", 1, 1))

    def test_a_newer_send_on_the_same_side_supersedes_the_waiting_one(self):
        self.page.composerless = True
        events = self.page.run({"id": "x1", "kind": "send", "side": "project", "text": "first words", "project": "chan_a", "thread": None})
        self.assertEqual(events, [])
        events = self.page.run({"id": "x2", "kind": "send", "side": "project", "text": "second words", "project": "chan_a", "thread": None})
        self.assertEqual([(e["id"], e["error"]) for e in events], [("x1", "superseded")])
        self.assertEqual([c["id"] for c in self.page.waiting], ["x2"])

    def test_retries_twice_then_failed_and_the_waiting_send_is_cancelled(self):
        self.page.settles = True
        self.say("first words")
        self.say("second words")
        self.timeout()
        out = self.timeout()
        self.assertEqual((out["status"], out["attempts"]), ("pending", 3))
        out = self.timeout()
        self.assertEqual((out["status"], out["attempts"]), ("failed", 3))
        self.assertEqual(len(self.sends()), 4)
        self.assertEqual(self.page.calls[-1][0], "cancel")
        self.assertEqual(self.page.waiting, [])
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual(self.page.clicks, 1)  # nothing clicks later
        self.assertEqual(self.done[-1]["status"], "failed")

    def test_a_refused_run_cancels_its_waiting_send(self):
        self.page.settles = True
        self.say("first words")
        self.say("second words")
        run = next(iter(self.core.runs.values()))
        self.core.finish(run, "refused", "x")
        self.page.pump(self.core)
        self.assertEqual((self.page.calls[-1][0], self.page.waiting), ("cancel", []))

    def test_a_row_from_you_with_other_words_still_stops_the_resend(self):
        self.page.swallow = True
        self.say()
        self.page.post("chan_a", "you", "something the page rendered differently")
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual(out["status"], "pending")  # the row may be an earlier queued message: wait for these words
        self.timeout()
        self.assertEqual(len(self.sends()), 1)

    def test_it_pauses_when_signed_out_and_goes_on_when_the_page_says_so(self):
        self.page.signed_in = False
        self.core.handle(self.page._stamp({"type": "page", "signed_in": False, "page_ok": True}))
        out = self.say()
        self.assertEqual((out["status"], out["cause"]), ("paused", "signed out of claude.ai"))
        self.assertEqual(self.done[0]["status"], "paused")
        self.assertEqual(self.sends(), [])
        self.page.signed_in = True
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True}))
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "confirmed")
        self.assertEqual(len(self.page.projects["chan_a"]["chat"]), 1)

    def test_a_tab_away_from_claude_code_pauses_with_that_cause_and_goes_on_when_it_is_back(self):
        self.core.handle({"type": "page", "signed_in": None, "page_ok": False, "away": True, "path": None, "thread": None})
        out = self.say()
        self.assertEqual((out["status"], out["cause"]), ("paused", "Fjord's tab has left the Claude Code page"))
        self.assertEqual(self.sends(), [])
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True}))
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "confirmed")

    def test_an_unreadable_page_pauses_and_a_disconnect_pauses(self):
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": False}))
        self.assertEqual(self.say()["cause"], "the page can't be read")
        core, page = support.world()
        core.connection(False)
        core.say("plain test words", project="chan_a")
        self.assertIn(store.intents(core.db, 1)[-1]["cause"], (do.CHROME_OPEN, "Chrome isn't running"))

    def test_words_that_landed_while_paused_are_not_sent_again(self):
        self.page.composerless = True
        out = self.say()
        self.assertEqual((out["status"], len(self.page.waiting)), ("pending", 1))  # the send waits in the page
        self.core.connection(False)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "paused")
        self.page.settle()  # the page clicks while Fjord's host is gone: its events never arrive
        self.page.outbox.clear()
        self.assertEqual(len(self.page.projects["chan_a"]["chat"]), 1)
        self.page.connect(self.core)
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.clicks), ("confirmed", 1))
        # No second send (the last call is the page's own click), and nothing left to click: the replayed `done` says it was answered.
        self.assertEqual((len(self.page.projects["chan_a"]["chat"]), self.page.calls[-1][0], self.page.waiting), (1, "send", []))

    def test_a_click_the_page_takes_late_is_never_typed_again(self):
        place, original, ignored = self.page.projects["chan_a"], self.page.run, []

        def run(command):  # the first click is reported but the words stay: a hidden tab's page still finishing the last send
            if command["kind"] == "send" and not ignored:
                ignored.append(command)
                place["draft"] = command["text"]
                return [self.page._composer(place, "project"), self.page._stamp({"type": "done", "id": command["id"], "ok": True, "error": None})]
            return original(command)
        self.page.run = run
        self.page.holds = True
        out = self.say()
        support.later(self.core, routerd.TAKE_WAIT)
        self.core.tick()
        self.assertEqual(self.page.inbox[-1]["click_only"], True)  # the retry only clicks
        place["draft"] = ""  # the page takes the first click late, before the retry runs
        self.page.post("chan_a", "you", "plain test words", pending=True)
        self.page.outbox.append(self.page._composer(place, "project"))
        self.page.pump(self.core)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.clicks), ("confirmed", 0))
        self.assertEqual([m["text"] for m in place["chat"]], ["plain test words"])

    def test_a_confirmed_send_cancels_its_retry_still_waiting_in_the_page(self):
        place, original, ignored = self.page.projects["chan_a"], self.page.run, []

        def run(command):
            if command["kind"] == "send" and not ignored:
                ignored.append(command)
                place["draft"] = command["text"]
                return [self.page._composer(place, "project"), self.page._stamp({"type": "done", "id": command["id"], "ok": True, "error": None})]
            return original(command)
        self.page.run = run
        out = self.say()
        self.page.composerless = True  # the retry waits in the page
        support.later(self.core, routerd.TAKE_WAIT)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(len(self.page.waiting), 1)
        self.page.post("chan_a", "you", "plain test words")  # the first click took after all
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.calls[-1][0], self.page.waiting), ("confirmed", "cancel", []))

    def test_a_leftover_draft_is_replaced_in_fjords_own_tab(self):
        self.page.projects["chan_a"]["draft"] = "an old draft"
        self.page.connect(self.core)
        out = self.say()
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual(self.sends()[0][0], "send")

    def test_a_failed_open_fails_the_intent(self):
        self.page.page_ok = False
        self.say(project="chan_b")
        out = self.timeout()  # a first failed open is retried at the deadline; a second in a row fails the run
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page can't be read"))

    def test_words_are_sent_exactly(self):
        words = "  Odd   spacing,\nand a line — kept  "
        self.say(words)
        self.assertEqual(self.page.calls[0][-1], words)

    def test_a_send_refused_off_its_place_waits_for_the_run_that_holds_the_tab(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)  # beta's act holds the tab
        self.core.tool("set_goal", project="beta", text="new goal")
        self.page.pump(self.core)
        self.core.say("plain test words", project="chan_a")
        run = self.core.runs[max(self.core.runs)]
        run["command"], run["sends"] = "cX", ["cX"]  # its send was out in the page when the tab moved
        self.core.handle(self.page._stamp({"type": "done", "id": "cX", "ok": False, "error": "not on that place"}))
        self.assertEqual([c for c in self.page.inbox if c["kind"] == "open"], [])  # not reopened under beta's read
        self.assertEqual(run["deadline"], self.core.clock() + do.TIMEOUT)

    def test_an_open_superseded_by_another_opens_again_at_the_deadline(self):
        self.page.slow_opens = True
        out = self.say(project="chan_b")  # its open waits for the composer
        self.page.outbox += self.page.run({"id": "x1", "kind": "open", "project": "chan_a", "thread": None})
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "pending")
        self.page.waiting.clear()
        self.page.slow_opens = False
        self.assertEqual(self.timeout()["status"], "confirmed")
        self.assertEqual(self.page.calls.count(("open", "chan_b", None)), 2)

    def test_a_run_whose_step_raises_fails_and_its_waiter_hears(self):
        import contextlib
        import io
        self.page.composerless = True
        self.say()

        def boom(*_):
            raise KeyError("x")
        self.core.ready = boom
        with contextlib.redirect_stderr(io.StringIO()):
            out = self.timeout()
        self.assertEqual((out["status"], out["cause"], self.done[-1]["status"], self.core.runs), ("failed", "routerd error: KeyError('x')", "failed", {}))

    def test_clicks_the_page_ignores_are_tried_again_within_one_attempt(self):
        place, original, sends = self.page.projects["chan_a"], self.page.run, []

        def run(command):  # every click is reported, and the words stay
            if command["kind"] == "send":
                sends.append(command)
                place["draft"] = command["text"]
                return [self.page._composer(place, "project"), self.page._stamp({"type": "done", "id": command["id"], "ok": True, "error": None})]
            return original(command)
        self.page.run = run
        out = self.say()
        for _ in range(4):
            support.later(self.core, routerd.TAKE_WAIT)
            self.core.tick()
            self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["attempts"], len(sends)), ("pending", 1, 5))
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        self.assertEqual(store.intent(self.core.db, out["id"])["attempts"], 2)  # the deadline is the limit

    def test_a_send_whose_done_was_lost_with_the_host_is_never_typed_again(self):
        self.page.composerless, self.page.holds = True, True
        out = self.say()
        self.core.connection(False)
        self.page.settle()  # the page clicks while Fjord's host is gone: its done never arrives
        self.page.outbox.clear()
        self.page.connect(self.core)
        self.page.pump(self.core)
        self.timeout()
        self.assertEqual(self.page.clicks, 1)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], len(self.page.projects["chan_a"]["chat"])), ("confirmed", 1))

    def test_a_send_lost_with_a_chrome_restart_is_never_typed_again(self):
        """The page it was handed to may have typed and clicked it before Chrome quit: it is taken, and fails as such with no row."""
        self.page.composerless = True
        out = self.say()
        self.core.connection(False)
        self.page.waiting.clear()  # Chrome quit: the page that waited on the send is gone, and the new one never heard of it
        self.page.recent.clear()
        self.page.composerless = False
        self.page.connect(self.core)
        self.page.pump(self.core)
        self.assertEqual((self.core.runs[out["id"]].get("taken"), self.sends()), (True, [("send", "project", "plain test words")]))
        support.run_out(self.core, self.page, out["id"])
        intent = store.intent(self.core.db, out["id"])
        self.assertEqual((intent["status"], intent["cause"], self.page.clicks), ("failed", routerd.WENT, 0))
        self.assertIn(out["id"], self.core.watched)  # its words may yet show

    def test_a_send_still_waiting_in_the_page_after_a_reconnect_is_left_waiting(self):
        self.page.composerless = True
        out = self.say()
        self.core.connection(False)
        self.page.connect(self.core)  # the page says the send still waits in it
        self.page.pump(self.core)
        self.assertEqual((self.page.inbox, [c["id"] for c in self.page.waiting]), ([], [self.core.runs[out["id"]]["command"]]))
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.clicks), ("confirmed", 1))

    def test_a_lost_open_that_pauses_opens_again_when_the_page_is_back(self):
        self.page.slow_opens = True
        out = self.say(project="chan_b")
        self.page.outbox += self.page.run({"id": "x1", "kind": "open", "project": "chan_a", "thread": None})  # its open is superseded
        self.page.pump(self.core)
        self.core.connection(False)
        self.page.waiting.clear()
        self.page.slow_opens = False
        self.page.connect(self.core)
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "confirmed")

    def test_a_lost_open_does_not_hold_back_a_newer_send(self):
        self.page.slow_opens = True
        first = self.say(project="chan_b")
        self.page.outbox += self.page.run({"id": "x1", "kind": "open", "project": "chan_a", "thread": None})
        self.page.pump(self.core)
        self.page.waiting.clear()
        self.page.slow_opens = False
        self.assertEqual(self.say("alpha words")["status"], "confirmed")  # at once, not after the lost run's 20 s
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "pending")
        self.assertEqual(self.timeout()["status"], "confirmed")
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "confirmed")

    def test_a_paused_run_whose_deadline_passes_waits_while_another_run_has_the_tab(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)  # beta's act holds the tab
        self.core.tool("set_goal", project="beta", text="new goal")
        self.page.pump(self.core)
        self.core.say("plain test words", project="chan_a")
        run = self.core.runs[max(self.core.runs)]
        run["paused"], run["deadline"] = True, self.core.clock()  # a late `done` gave the paused run a deadline
        self.core.tick()
        self.assertEqual([c for c in self.page.inbox if c["kind"] in ("open", "send")], [])  # not under beta's read

    def test_a_paused_run_whose_deadline_is_held_leaves_no_past_deadline(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)  # beta's act holds the tab
        self.core.tool("set_goal", project="beta", text="new goal")
        self.page.pump(self.core)
        self.core.say("plain test words", project="chan_a")
        run = self.core.runs[max(self.core.runs)]
        run["paused"], run["deadline"] = True, self.core.clock()
        self.core.tick()
        self.assertGreater(self.core.next_deadline(), self.core.clock())  # the timers sleep, rather than wake at once again and again

    def test_a_cancelled_send_no_longer_holds_the_tab_from_a_paused_run(self):
        self.page.composerless = True
        self.core.say("beta words", project="chan_b")
        self.page.pump(self.core)
        cut = self.core.runs[max(self.core.runs)]
        for event in self.page.load("chan_a"):  # the tab moves away while the send waits
            self.core.handle(event)
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()  # the send is cancelled and its place opened again; the page sends no `done` for it
        self.assertEqual([c["target"] for c in self.page.inbox if c["kind"] == "cancel"], [cut["command"]])
        self.core.say("alpha words", project="chan_a")
        cut["paused"] = True  # a pause of its own (waiting for the Claude app, say) keeps it
        other = self.core.runs[max(self.core.runs)]
        other["paused"] = True
        self.assertFalse(self.core.tab_held(other))

    def test_a_send_a_reconnected_page_does_not_list_no_longer_holds_the_tab(self):
        self.page.composerless = True
        self.core.say("beta words", project="chan_b")
        self.page.pump(self.core)
        gone = self.core.runs[max(self.core.runs)]
        self.core.connection(False)
        self.page.waiting.clear()  # a reloaded page
        self.core.say("alpha words", project="chan_a")
        other = self.core.runs[max(self.core.runs)]
        self.assertTrue(self.core.tab_held(other))
        self.core.connection(True)
        self.core.handle({"type": "commands", "waiting": [], "done": []})
        gone["paused"] = other["paused"] = True
        self.assertFalse(self.core.tab_held(other))
        self.assertNotEqual(gone.get("answered"), gone["command"])  # never marked answered: its retry still waits for its deadline

    def test_a_send_made_after_the_host_connected_is_not_dropped_by_the_pages_list(self):
        self.page.composerless = True
        self.core.connection(True)
        self.core.handle({"type": "page", "signed_in": True, "page_ok": True})  # the worker's first event: there is a page
        self.core.say("beta words", project="chan_b")
        self.page.pump(self.core)
        run = self.core.runs[max(self.core.runs)]
        self.core.handle({"type": "commands", "waiting": [], "done": []})  # the list was made before the send reached the page
        self.assertTrue(self.core.in_page(run))

    def test_nothing_acts_between_a_link_and_the_hosts_first_event(self):
        self.core.connection(True)  # the health kept from before it (page_ok true) is stale
        self.core.say("beta words", project="chan_b")
        self.page.pump(self.core)
        run = self.core.runs[max(self.core.runs)]
        self.assertEqual(store.intent(self.core.db, run["id"])["status"], "paused")
        self.assertFalse(self.core.in_page(run))
        self.core.handle({"type": "page", "signed_in": True, "page_ok": True})
        self.page.pump(self.core)
        self.assertTrue(self.core.in_page(run) or run["stage"] != "start")

    def test_a_click_that_left_the_words_then_lost_them_fails_saying_so(self):
        place, original = self.page.projects["chan_a"], self.page.run

        def run(command):  # the click is reported and the words stay; the retry waits in the page
            if command["kind"] == "send":
                if command.get("click_only"):
                    return []
                place["draft"] = command["text"]
                return [self.page._composer(place, "project"), self.page._stamp({"type": "done", "id": command["id"], "ok": True, "error": None})]
            return original(command)
        self.page.run = run
        out = self.say()
        support.later(self.core, routerd.TAKE_WAIT)
        self.core.tick()
        self.page.pump(self.core)
        place["draft"] = ""  # a navigation dropped the draft
        self.core.handle(self.page._composer(place, "project"))
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.core.tick()
        self.page.pump(self.core)
        out = self.timeout()
        self.assertEqual(out["status"], "failed")
        self.assertIn("may not have sent them", out["cause"])
        self.assertEqual(self.page.clicks, 0)

    def test_nothing_polls_between_events(self):
        self.say()
        self.assertEqual(self.core.runs, {})
        self.assertIsNone(self.core.next_deadline())


class Taken(unittest.TestCase):
    """Rows have keys; the page may show a message late, renumbered, or never."""
    def setUp(self):
        self.core, self.page = support.world()
        self.done = []

    def say(self, words="plain test words", project="chan_a"):
        self.core.say(words, project=project, finished=self.done.append)
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def sends(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def chat(self, project="chan_a"):
        return self.core.board()["projects"][project]["chat"]

    def test_no_duplicate_after_a_reload_that_renumbers_the_rows(self):
        for n in range(5):
            self.page.post("chan_a", "claude", f"old {n}")
        self.page.connect(self.core)
        self.page.holds = True
        out = self.say()
        self.assertEqual(out["status"], "pending")  # taken: the draft emptied, but the row is only pending
        self.page.renumber("chan_a", 4)
        self.page.connect(self.core)
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual(store.intents(self.core.db, 1)[-1]["status"], "confirmed")
        self.assertEqual(len(self.sends()), 1)
        self.assertEqual([m["text"] for m in self.chat() if m["from"] == "you"], ["plain test words"])

    def test_a_queued_message_confirms_and_does_not_block_the_next_send_to_another_project(self):
        self.page.holds = True
        first = self.say("first words")
        self.assertEqual(first["status"], "pending")
        self.page.holds = False
        second = self.say("second words", project="chan_b")
        self.assertEqual(second["status"], "confirmed")
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "pending")
        self.page.connect(self.core)  # back to alpha
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "confirmed")
        self.assertEqual(len(self.sends()), 2)

    def test_a_settling_send_gets_exactly_one_click_after_it_settles(self):
        self.page.settles = True
        self.say("first words")
        self.assertEqual(self.page.clicks, 1)
        second = self.say("second words")
        self.assertEqual((second["status"], self.page.clicks), ("pending", 1))  # waits: a click now would do nothing
        self.assertEqual(len(self.page.waiting), 1)
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual((store.intents(self.core.db, 1)[-1]["status"], self.page.clicks), ("confirmed", 2))
        self.assertEqual([m["text"] for m in self.chat() if m["from"] == "you"], ["first words", "second words"])

    def test_a_draft_of_other_words_is_cleared_then_the_words_are_sent_once(self):
        self.page.projects["chan_a"]["draft"] = "other words"
        self.page.connect(self.core)
        self.assertEqual(self.say()["status"], "confirmed")
        self.assertEqual(self.page.clicks, 1)
        self.assertEqual([m["text"] for m in self.chat()], ["plain test words"])

    def test_words_back_in_the_draft_mean_the_send_failed_and_it_is_sent_again(self):
        self.page.swallow = True
        self.say()
        self.page.swallow = False
        self.page.projects["chan_a"]["draft"] = "plain test words"
        self.core.handle(self.page._stamp({"type": "composer", "side": "project", "draft": "plain test words", "disabled": False}))
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], out["attempts"]), ("confirmed", 2))
        self.assertEqual([m["text"] for m in self.chat()], ["plain test words"])

    def test_a_send_the_page_keeps_giving_back_fails_with_the_pages_own_words(self):
        self.page.swallow = True
        self.say()
        for _ in range(do.RETRIES + 1):
            self.core.handle(self.page._stamp({"type": "notice", "text": "Couldn’t send the message"}))
            self.page.projects["chan_a"]["draft"] = "plain test words"
            self.core.handle(self.page._stamp({"type": "composer", "side": "project", "draft": "plain test words", "disabled": False}))
            self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page couldn't send it: Couldn’t send the message"))
        self.assertEqual(self.chat(), [])

    def test_the_same_words_typed_by_a_later_send_do_not_count_as_the_first_failing(self):
        self.page.holds = True
        self.say("continue please")
        support.later(self.core, store.DUP_WINDOW + 1)
        self.say("continue please")
        self.assertEqual(len(self.sends()), 2)
        self.assertEqual(store.intents(self.core.db, 2)[0]["attempts"], 1)

    def test_paused_runs_each_answer_and_both_go_on_in_order(self):
        self.core.connection(False)
        self.core.connection(False)
        self.core.say("alpha words", project="chan_a", finished=self.done.append)
        self.core.say("beta words", project="chan_b", finished=self.done.append)
        self.assertEqual([d["status"] for d in self.done], ["paused", "paused"])
        self.page.connect(self.core)
        self.page.pump(self.core)
        self.assertEqual([i["status"] for i in store.intents(self.core.db, 2)], ["confirmed", "confirmed"])

    def test_a_run_behind_one_that_fails_at_its_deadline_goes_on(self):
        self.page.settles = True
        self.say("first words")
        self.say("second words")
        self.say("beta words", project="chan_b")
        for _ in range(3):
            support.later(self.core, do.TIMEOUT + 1)
            self.core.tick()
            self.page.pump(self.core)
        self.assertEqual(store.intents(self.core.db, 1)[-1]["status"], "confirmed")

    def test_after_a_restart_a_load_with_no_rows_yet_is_not_a_baseline(self):
        self.page.post("chan_a", "you", "plain test words")
        self.page.connect(self.core)
        again = routerd.Core(self.core.db, self.page.receive, clock=support.Clock())
        self.assertIn("chan_a", again.known)

    def test_a_taken_message_whose_look_is_due_with_chrome_closed_fails_at_its_bound_and_is_confirmed_late(self):
        self.page.holds = True
        out = self.say()
        self.core.connection(False)
        self.page.inbox.clear()
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.core.tick()
        opens = [c for c in self.page.inbox if c["kind"] == "open"]  # no look with no host: it would be lost
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], opens, out["id"] in self.core.watched), ("failed", [], True))
        self.page.holds = False
        self.page.deliver("chan_a")
        self.page.connect(self.core)
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], len(self.sends()), self.core.runs), ("confirmed", 1, {}))
        self.assertIn("confirmed late", out["cause"])

    def test_a_taken_sends_look_waits_while_a_tool_reads(self):
        self.page.swallow = True
        first = self.say()
        support.later(self.core, routerd.ACCEPTED_WAIT - 10)
        original, reads = self.page.run, []

        def run(command):  # the tool's proving read never answers
            if command["kind"] == "read_settings":
                reads.append(command)
                return []
            return original(command)
        self.page.run, self.page.save = run, "unanswered"  # its save got no answer: a read proves it
        self.core.tool("set_instructions", project="beta", text="new rules")
        self.page.pump(self.core)
        self.assertEqual((len(reads), self.page.at), (1, ("chan_b", None)))
        support.later(self.core, 11)
        self.core.tick()
        self.assertEqual([c["kind"] for c in self.page.inbox], [])  # no open of alpha during beta's read
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "pending")

    def test_a_look_superseded_by_another_send_looks_again(self):
        self.page.swallow = True
        first = self.say()
        self.page.swallow = False
        self.page.post("chan_a", "you", "plain test words")
        self.page.outbox.clear()
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.core.tick()
        look, original = self.page.inbox[-1]["id"], self.page.run
        self.page.run = lambda c: [self.page._stamp({"type": "done", "id": look, "ok": False, "error": "superseded"})] if c["id"] == look else original(c)
        self.say("beta words", project="chan_b")
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "confirmed")

    def test_a_taken_run_that_never_proves_opens_the_place_once_then_fails_without_resending(self):
        self.page.swallow = True
        out = self.say()
        self.assertEqual(out["status"], "pending")
        support.later(self.core, routerd.ACCEPTED_WAIT - 1)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(self.page.calls[-1][0], "send")  # not yet
        support.later(self.core, 2)
        self.core.tick()
        self.page.pump(self.core)
        self.assertIn("open", [c[0] for c in self.page.calls[-3:]])
        out = store.intents(self.core.db, 1)[-1]  # its look's settled read showed no row from you: it ends then, not 20 s later
        self.assertEqual(out["status"], "failed")
        self.assertIn("never confirmed", out["cause"])
        self.assertEqual([c[0] for c in self.page.calls].count("open"), 1)
        self.assertEqual(len(self.sends()), 1)
        self.assertEqual(self.core.runs, {})

    def test_a_taken_send_does_not_go_back_while_another_takes_its_look(self):
        self.page.swallow = True
        first = self.say()
        support.later(self.core, 5)
        self.say("beta words", project="chan_b")
        support.later(self.core, routerd.ACCEPTED_WAIT - 4)  # alpha's wait is over, beta's isn't
        self.page.slow_opens = True
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual([(c["project"]) for c in self.page.waiting], ["chan_a"])  # alpha's look waits for its composer
        self.core.handle({"type": "page", "signed_in": True, "page_ok": True, "path": "/code/project/chan_a", "thread": None})  # the tab moves to alpha
        self.assertEqual([c for c in self.page.inbox if c["kind"] == "open"], [])  # beta doesn't go back under alpha's look
        self.assertTrue(self.core.runs[first["id"]]["looking"])

    def test_a_send_confirmed_while_its_look_waits_cancels_the_look(self):
        self.page.swallow = True
        out = self.say()
        self.page.swallow = False
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.page.slow_opens = True
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual([c["kind"] for c in self.page.waiting], ["open"])
        self.page.post("chan_a", "you", "plain test words")  # the row comes before the look's open is over
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.waiting), ("confirmed", []))

    def test_words_given_back_after_a_stuck_click_are_no_longer_stuck(self):
        place, original, sends = self.page.projects["chan_a"], self.page.run, []

        def run(command):  # the first click is reported and the words stay; its click-only retry waits in the page
            if command["kind"] == "send":
                sends.append(command)
                if len(sends) == 1:
                    place["draft"] = command["text"]
                    return [self.page._composer(place, "project"), self.page._stamp({"type": "done", "id": command["id"], "ok": True, "error": None})]
                if command.get("click_only"):
                    return []
            return original(command)
        self.page.run = run
        out = self.say()
        support.later(self.core, routerd.TAKE_WAIT)
        self.core.tick()
        self.page.pump(self.core)
        self.assertTrue(self.core.runs[out["id"]].get("stuck"))
        place["draft"] = ""  # taken
        self.core.handle(self.page._composer(place, "project"))
        place["draft"] = "plain test words"  # the page gave the words back: it sends them again, fresh
        self.page.swallow = True
        self.core.handle(self.page._composer(place, "project"))
        self.page.pump(self.core)
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.core.tick()
        self.page.pump(self.core)
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual(out["status"], "failed")
        self.assertIn("never confirmed them", out["cause"])

    def test_the_look_proves_a_row_the_deltas_missed(self):
        self.page.swallow = True
        self.say()
        self.page.swallow = False
        self.page.post("chan_a", "you", "plain test words")
        self.page.outbox.clear()  # never told
        support.later(self.core, routerd.ACCEPTED_WAIT + 1)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(store.intents(self.core.db, 1)[-1]["status"], "confirmed")
        self.assertEqual(len(self.sends()), 1)

    def test_a_load_that_shows_no_rows_first_does_not_prove_the_words_by_an_old_row(self):
        self.page.post("chan_a", "you", "plain test words")
        self.page.connect(self.core)
        old = self.chat()[0]["key"]
        for event in self.page.load("chan_a")[:3]:
            self.core.handle(event)
        self.core.handle(self.page._stamp({"type": "rows", "side": "project", "rows": [], "full": True}))  # the composer mounted before the transcript
        self.core.handle(self.page._stamp({"type": "composer", "side": "project", "draft": "", "disabled": True}))
        out = self.say()
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual(self.page.calls[0][0], "open")  # not ready on no rows: the place is opened for a full scan
        self.assertEqual(len(self.sends()), 1)
        self.assertIn(old, out["proof"]["baseline"])
        self.assertEqual([m["from"] for m in self.chat()], ["you", "you"])

    def test_a_thread_shown_with_no_rows_yet_is_opened_for_a_full_scan_first(self):
        for event in self.page.load("chan_a", "cmsg_2")[:3]:
            self.core.handle(event)
        self.core.handle(self.page._stamp({"type": "rows", "side": "thread", "rows": [], "full": True}))  # the composer mounted before the transcript
        self.core.handle(self.page._stamp({"type": "composer", "side": "thread", "draft": "", "disabled": True}))
        self.core.say("plain test words", thread="cmsg_2")
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], self.page.calls[0][0]), ("confirmed", "open"))
        self.assertIn("cmsg_2_opening", out["proof"]["baseline"])

    def test_a_taken_send_goes_back_each_time_the_tab_is_moved(self):
        self.page.holds = True
        self.say("first words")
        self.page.holds = False
        for n in range(2):
            self.assertEqual(self.say(f"beta words {n}", project="chan_b")["status"], "confirmed")
        self.assertEqual(self.page.calls.count(("open", "chan_a", None)), 2)

    def test_a_taken_sends_going_back_is_cancelled_when_it_finishes_and_a_superseded_one_is_no_loss(self):
        self.page.holds = True
        first = self.say("first words")
        self.page.holds = False
        original, back, sent = self.page.run, [], []

        def run(command):
            sent.append(command)
            if command["kind"] == "open" and command["project"] == "chan_a" and not back:  # its going back waits in the page
                back.append(command)
                return []
            return original(command)
        self.page.run = run
        self.say("beta words", project="chan_b")
        run = self.core.runs[first["id"]]
        self.assertEqual(run["open"], back[0]["id"])
        self.core.handle({"type": "done", "id": back[0]["id"], "ok": False, "error": "superseded"})
        self.assertEqual((run["open"], run.get("lost"), store.intent(self.core.db, first["id"])["status"]), (None, None, "pending"))
        run["open"] = back[0]["id"]  # had it still waited: the row from you comes, and nothing moves the tab later
        self.page.deliver("chan_a")
        self.page.outbox += self.page.load("chan_a")
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, first["id"])["status"], "confirmed")
        self.assertIn(back[0]["id"], [c["target"] for c in sent if c["kind"] == "cancel"])

    def test_an_empty_project_is_still_sendable(self):
        self.assertEqual(self.chat("chan_b"), [])
        self.assertEqual(self.say(project="chan_b")["status"], "confirmed")

    def test_one_streaming_row_resent_three_times_is_one_seen_row(self):
        row = self.page.post("chan_a", "claude", "Thinking…", streaming=True)
        for text in ("Thinking… a", "Thinking… a b"):
            row["text"] = text
            self.page._show("chan_a", None, [row])
        self.page.pump(self.core)
        seen = [r for r in store.seen(self.core.db) if any(m["key"] == row["key"] for m in r["fields"].get("messages", []))]
        self.assertEqual(len(seen), 1)

    def test_pending_rows_are_not_in_the_chat(self):
        self.page.holds = True
        self.say()
        self.assertEqual(self.chat(), [])
        self.page.deliver("chan_a")
        self.page.pump(self.core)
        self.assertEqual([m["text"] for m in self.chat()], ["plain test words"])

    def test_streaming_claude_text_is_not_a_claim_until_it_settles(self):
        self.page.post("chan_a", "claude", "writing…", pending=True, streaming=True)
        row = self.page.post("chan_a", "claude", "Thinking… the answer", streaming=True)
        self.page.pump(self.core)
        self.assertEqual(self.core.board()["claims"], [])
        row.update(text="the answer", streaming=False)
        self.page._show("chan_a", None, [row])
        self.page.pump(self.core)
        self.assertEqual([c["text"] for c in self.core.board()["claims"]], ["the answer"])


class Stranded(unittest.TestCase):
    """A thread whose process is gone while the Claude app runs."""
    def setUp(self):
        self.core, self.page = support.world()
        self.core.local({"sessions": {"cse_1": support.local_info("c1")}, "processes": {"c1": False}, "app": True})

    def sends(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def test_the_thread_is_stranded(self):
        self.assertEqual(self.core.board()["threads"]["cmsg_1"]["state"], "stranded")

    def test_a_reply_goes_to_the_coordinator_as_one_project_send_not_into_the_thread(self):
        events = []
        self.core.say("plain test words", thread="cmsg_1", reply=events.append)
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], out["tool"], out["project"], out["thread"]), ("confirmed", "send_to_project", "chan_a", None))
        self.assertEqual(out["args"], {"continues": "cmsg_1", "message": "plain test words"})
        self.assertEqual(self.sends(), [("send", "project", "Thread «Alpha first task» lost its process. Start a new thread in the same "
                                         "folder that continues it. Last state: d. Message: plain test words")])
        self.assertIn("coordinator", events[0]["warning"])
        self.assertEqual(events[0]["intent"]["tool"], "send_to_project")  # the decision the owner sees is the handoff

    def test_the_brief_ties_the_handoff_to_the_old_thread_with_the_owner_words(self):
        self.core.say("plain test words", thread="cmsg_1")
        self.page.pump(self.core)
        text, _ = routerd.context.build(self.core.board(), {}, store.intents(self.core.db, 10), self.core.clock())
        line = next(l for l in text.splitlines() if "plain test words" in l)
        self.assertIn("continue thread cmsg_1", line)
        self.assertNotIn("lost its process", line)

    def test_the_last_state_is_cut_to_300_characters(self):
        t = {"id": "cmsg_1", "title": None, "detail": "x " * 400, "text": None, "result": None}
        words, _ = do.handoff(t, "go on")
        last = words.split("Last state: ")[1].split(". Message:")[0]
        self.assertEqual(len(last), do.LAST)
        self.assertTrue(words.startswith("Thread «cmsg_1»"))

    def test_a_reply_to_a_live_thread_is_unaffected(self):
        self.core.local({"sessions": {"cse_2": support.local_info("c2")}, "processes": {"c1": False, "c2": True}, "app": True})
        events = []
        self.core.say("plain test words", thread="cmsg_2", reply=events.append)
        self.page.pump(self.core)
        out = store.intents(self.core.db, 1)[-1]
        self.assertEqual((out["status"], out["tool"], out["thread"], out["args"]), ("confirmed", "reply_in_thread", "cmsg_2", None))
        self.assertEqual([c[1] for c in self.sends()], ["thread"])
        self.assertIsNone(events[0]["warning"])

    def test_a_process_seen_alive_then_missing_is_gone(self):
        self.core.local({"sessions": {"cse_2": support.local_info("c2")}, "processes": {"c2": True}})
        self.assertEqual(self.core.board()["threads"]["cmsg_2"]["alive"], True)
        support.later(self.core)
        self.core.local({"sessions": {"cse_2": support.local_info("c2")}, "processes": {}})
        self.assertEqual(self.core.board()["threads"]["cmsg_2"]["alive"], False)

    def test_no_registry_entry_and_never_seen_alive_is_unknown(self):
        self.core.local({"sessions": {"cse_2": support.local_info("c2")}, "processes": {}})
        self.assertIsNone(self.core.board()["threads"]["cmsg_2"]["alive"])


class AppClosed(unittest.TestCase):
    """The Claude app isn't running: its threads wait for it, and none is stranded."""
    def setUp(self):
        self.core, self.page = support.world()
        self.local(True, True)
        self.done = []

    def local(self, alive, app):
        support.later(self.core)
        self.core.local({"sessions": {"cse_1": support.local_info("c1")}, "processes": {"c1": True} if alive else {}, "app": app})
        self.page.pump(self.core)

    def sends(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def reply(self):
        self.core.say("plain test words", thread="cmsg_1", finished=self.done.append)
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def test_a_local_thread_waits_for_the_app_and_is_not_stranded(self):
        self.local(False, False)
        self.assertEqual(self.core.board()["threads"]["cmsg_1"]["state"], "waiting_app")

    def test_a_reply_is_paused_and_goes_on_into_the_thread_when_its_process_is_back(self):
        self.local(False, False)
        out = self.reply()
        self.assertEqual((out["status"], out["cause"]), ("paused", do.APP_CLOSED))
        self.assertEqual(self.done[0]["status"], "paused")  # whoever waits is answered
        self.assertEqual(self.sends(), [])
        self.local(True, True)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["tool"], out["thread"]), ("confirmed", "reply_in_thread", "cmsg_1"))
        self.assertEqual([c[1] for c in self.sends()], ["thread"])

    def test_the_app_back_without_the_thread_hands_it_off_after_one_wait(self):
        self.local(False, False)
        out = self.reply()
        self.local(False, True)
        self.assertEqual(self.core.board()["threads"]["cmsg_1"]["state"], "stranded")
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.sends()), ("paused", []))  # it may still come back
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["tool"], out["args"]["continues"]), ("confirmed", "send_to_project", "cmsg_1"))
        self.assertEqual([c[1] for c in self.sends()], ["project"])

    def test_a_run_back_from_a_pause_waits_while_another_send_waits_in_the_page(self):
        self.local(False, False)
        reply = self.reply()
        self.page.composerless = True
        self.core.say("beta words", project="chan_b", finished=self.done.append)
        self.page.pump(self.core)
        self.assertEqual((self.page.at, len(self.page.waiting)), (("chan_b", None), 1))
        self.local(True, True)  # the reply could go on, but beta's send still waits in the page
        self.assertEqual((self.page.at, [c[0] for c in self.page.calls][-1]), (("chan_b", None), "send"))
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual([store.intent(self.core.db, i["id"])["status"] for i in store.intents(self.core.db, 2)], ["confirmed", "confirmed"])
        self.assertEqual(store.intent(self.core.db, reply["id"])["status"], "confirmed")
        self.assertEqual([m["text"] for m in self.page.projects["chan_b"]["chat"]], ["beta words"])

    def test_a_run_back_from_a_pause_waits_while_a_tool_acts(self):
        self.local(False, False)
        reply = self.reply()
        original, held = self.page.run, []

        def run(command):  # beta's act is slow
            if command["kind"] == "set_field" and not held:
                held.append(command)
                return []
            return original(command)
        self.page.run = run
        self.core.tool("set_goal", project="beta", text="new goal")
        self.page.pump(self.core)
        self.local(True, True)  # the reply could go on, but the act holds the tab
        self.assertEqual((self.page.at, self.page.inbox, self.page.calls.count(("open", "chan_a", "cmsg_1"))), (("chan_b", None), [], 0))
        self.page.outbox += original(held[0])
        self.page.pump(self.core)
        self.assertEqual([i["status"] for i in store.intents(self.core.db, 2)], ["confirmed", "confirmed"])
        self.assertEqual(store.intent(self.core.db, reply["id"])["status"], "confirmed")

    def test_a_taken_send_goes_back_while_a_reply_waits_for_the_app(self):
        self.page.holds = True
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.local(False, False)
        self.reply()  # paused, with nothing in the page
        for event in self.page.load("chan_b"):  # the tab moved
            self.core.handle(event)
        self.assertEqual([(c["kind"], c["project"]) for c in self.page.inbox], [("open", "chan_a")])

    def test_a_reply_cut_off_by_the_app_closing_is_handed_off_when_its_thread_stays_gone(self):
        self.page.composerless = True
        out = self.reply()
        self.assertEqual(store.intent(self.core.db, out["id"])["proof"]["baseline"], ["cmsg_1_opening"])  # the send waits in the thread's page
        self.local(False, False)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], self.page.waiting), ("paused", []))  # cut off
        self.page.composerless = False
        self.local(False, True)
        support.later(self.core, do.TIMEOUT)
        self.core.tick()
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["tool"], out["thread"]), ("confirmed", "send_to_project", None))
        self.assertEqual([m["key"] for m in self.page.projects["chan_a"]["threads"]["cmsg_1"]["messages"]], ["cmsg_1_opening"])

    def test_a_project_send_does_not_wait_for_the_app(self):
        self.local(False, False)
        self.core.say("plain test words", project="chan_a")
        self.page.pump(self.core)
        self.assertEqual(store.intents(self.core.db, 1)[-1]["status"], "confirmed")


class Notes(unittest.TestCase):
    def test_notes_overwrite_by_topic(self):
        core, _ = support.world()
        core.note("style", "short")
        core.note("style", "shorter")
        self.assertEqual(store.notes(core.db), {"style": "shorter"})


class Ids(unittest.TestCase):
    def test_command_ids_differ_between_starts(self):
        a, b = support.world()[0], support.world()[0]
        self.assertNotEqual(a.command("snapshot"), b.command("snapshot"))  # a replayed done of one start never matches another's


if __name__ == "__main__":
    unittest.main()
