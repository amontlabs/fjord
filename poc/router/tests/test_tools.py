import unittest

import support
from support import NOW, Spy
import do
import routerd
import store


class Tools(unittest.TestCase):
    def setUp(self):
        self.core, self.page = support.world()
        self.page.repos, self.page.connected = ["acme/app", "acme/other"], ["/Users/o/code", "/Users/o/docs"]
        self.done = []

    def run_tool(self, tool, **args):
        self.core.tool(tool, finished=self.done.append, **args)
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def calls(self, *kinds):
        return [c for c in self.page.calls if c[0] in kinds]

    def timeout(self):
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        return store.intents(self.core.db, 1)[-1]

    def settings(self, pid="chan_a"):
        return self.page.projects[pid]["settings"]


class Set(Tools):
    def test_set_goal_is_proved_by_its_saves_answer_and_keeps_the_old_value(self):
        self.settings()["goal"] = "old goal"
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["project"], out["attempts"]), ("confirmed", "chan_a", 1))
        self.assertEqual((out["result"]["before"], out["result"]["before_is"], out["result"]["acted"], out["result"]["provable"]),
                         ("old goal", "the tab's copy, maybe older", True, True))
        self.assertEqual(self.settings()["goal"], "new goal")
        self.assertEqual([c[0] for c in self.page.calls], ["set_field"])  # one command reads, acts and waits for the answer: no read after
        self.assertEqual(self.done[0]["status"], "confirmed")

    def test_set_instructions_keeps_the_old_value(self):
        self.settings()["instructions"] = "old rules"
        out = self.run_tool("set_instructions", project="chan_a", text="line one\r\nline two")
        self.assertEqual((out["status"], out["result"]["before"]), ("confirmed", "old rules"))
        self.assertEqual(self.settings()["instructions"], "line one\nline two")
        self.assertEqual(out["proof"], {"field": "instructions", "equals": "line one\nline two"})

    def test_a_tool_starts_on_a_chat_that_never_settles(self):
        """A tool acts in the settings dialog: the chat's read needn't be settled, as a send's must."""
        self.page.post("chan_a", "claude", "hello")
        self.page.pump(self.core)
        self.page.rendering.add(("chan_a", None))
        self.core.handle(self.page.whole("chan_a"))
        self.assertIn("chan_a", self.core.unsettled)
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], [c[0] for c in self.page.calls]), ("confirmed", ["set_field"]))

    def test_a_tool_whose_place_shows_no_composer_says_so(self):
        events = [e for e in self.page.load("chan_b") if e["type"] != "composer"]
        for event in events:
            self.core.handle(event)
        self.page.slow_opens = True  # its open waits for the composer too
        self.core.tool("set_instructions", project="beta", text="new rules")
        self.page.pump(self.core)
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"], self.calls("set_field")), ("failed", "the page showed that place but never its composer", []))

    def test_the_other_project_is_opened_first(self):
        out = self.run_tool("set_goal", project="beta", text="beta goal")
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual([c[0] for c in self.page.calls], ["open", "set_field"])
        self.assertEqual(self.settings("chan_b")["goal"], "beta goal")

    def test_what_is_already_so_is_confirmed_without_acting(self):
        self.settings()["instructions"] = "same"
        out = self.run_tool("set_instructions", project="alpha", text="same")
        self.assertEqual((out["status"], out["cause"], out["result"]["before"]), ("confirmed", "it was already so", "same"))
        self.assertNotIn("acted", out["result"])  # the page read it, found it so and changed nothing
        self.assertEqual((len(self.calls("set_field")), self.page.acted), (1, []))

    def test_a_repo_or_folder_already_listed_is_confirmed_without_acting(self):
        self.settings()["repos"], self.settings()["folders"] = ["acme/app"], ["/Users/o/code"]
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual((out["status"], out["cause"], out["result"]["before"]), ("confirmed", "it was already so", ["acme/app"]))
        grant = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(grant["id"])
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, grant["id"])["cause"], "it was already so")
        self.assertEqual(self.page.acted, [])

    def test_a_folder_whose_row_carries_a_note_is_already_so_by_its_path(self):
        self.settings()["folders"] = ["/Users/o/code"]
        self.page.notes["/Users/o/code"] = "Approuvé pour Remote Control uniquement sur cet ordinateur."
        grant = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(grant["id"])
        self.page.pump(self.core)
        done = store.intent(self.core.db, grant["id"])
        self.assertEqual((done["cause"], done["result"]["before"], self.page.acted), ("it was already so", ["/Users/o/code"], []))

    def test_a_page_that_says_already_so_against_its_own_read_is_not_believed(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": True, "error": None, "before": "other", "already": True, "path": "/code", "thread": None}]
                                   if c["kind"] == "set_field" else original(c))
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page said it was already so, but what it read differs"))
        self.assertNotIn(out["id"], self.core.unproved)

    def test_a_goal_the_tab_already_shows_is_said_as_the_tab_knows_it(self):
        self.settings()["goal"] = "same"  # an unchanged field saves nothing, so it can't be written again
        out = self.run_tool("set_goal", project="alpha", text="same")
        self.assertEqual((out["status"], out["cause"], out["result"]["before_is"]),
                         ("confirmed", "it was already so, as far as Fjord's tab knows", "the tab's copy, maybe older"))
        self.assertEqual(self.page.acted, [])

    def test_a_goal_is_confirmed_only_by_its_saves_answer(self):
        self.settings()["goal"] = "old goal"
        original = self.page.run

        def run(command):  # the act reports done with no answer to its save, and the tab shows the typed goal
            if command["kind"] == "set_field":
                self.settings()["goal"] = command["text"]
                return [{"type": "done", "id": command["id"], "ok": True, "error": None, "before": "old goal", "path": "/code/project/chan_a", "thread": None}]
            return original(command)
        self.page.run = run
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"], out["result"]["provable"]), ("failed", f"{do.NOT_CONFIRMED}: the page reported no answer to the save", False))
        self.assertEqual((self.calls("read_settings"), self.core.unproved), ([], set()))  # the tab's copy proves nothing, now or later

    def test_a_setting_whose_save_got_no_answer_is_proved_by_a_read(self):
        self.settings()["instructions"] = "old rules"
        self.page.save = "unanswered"  # the change took, but the page saw no answer
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], out["result"]["before"], out["result"]["acted"]), ("confirmed", "old rules", True))
        self.assertEqual([c[0] for c in self.page.calls], ["set_field", "read_settings"])

    def test_an_act_that_took_but_is_not_proved_is_never_sent_again(self):
        self.page.takes = False
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(out["status"], "pending")
        out = self.timeout()  # no proof in time: one more read, which shows nothing
        self.assertEqual((out["status"], out["cause"]), ("failed", f"{do.NOT_CONFIRMED}: no answer from the server to the instructions (network)"))
        self.assertEqual(len(self.calls("set_field")), 1)
        self.assertEqual(len(self.calls("read_settings")), 2)  # the proof and the one more
        self.assertEqual(self.core.runs, {})

    def test_a_later_read_that_shows_the_change_confirms_late(self):
        self.page.lags = True
        self.run_tool("set_instructions", project="alpha", text="new rules")
        out = self.timeout()
        self.assertEqual(out["status"], "failed")
        self.page.land()
        self.page.pump(self.core)
        self.core.handle(self.page._stamp({"type": "settings", "project": "chan_a", **self.settings(), "offered_folders": None}))
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["cause"]), ("confirmed", "confirmed by a later read"))
        self.assertEqual(len(self.calls("set_field")), 1)

    def test_a_page_error_in_the_act_is_the_answer(self):
        original, acts = self.page.run, []

        def run(command):
            acts.append(command["kind"])
            return [{"type": "done", "id": command["id"], "ok": False, "error": "no goal field", "path": "/code", "thread": None}] if command["kind"] == "set_field" else original(command)
        self.page.run = run
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"]), ("failed", "no goal field"))
        self.assertEqual(acts.count("set_field"), 1)

    def test_an_act_that_errs_before_its_change_leaves_nothing_to_reconcile(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": False, "error": "no goal field", "path": "/code", "thread": None}]
                                   if c["kind"] == "set_field" else original(c))
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["result"]["acted"]), ("failed", False))
        self.assertNotIn(out["id"], self.core.unproved)

    def test_a_goal_whose_save_got_no_answer_is_not_proved_by_the_tabs_copy(self):
        original = self.page.run

        def run(command):  # the dialog keeps the typed goal, but the save got no answer: the server may not have it
            if command["kind"] == "set_field":
                self.settings()["goal"] = command["text"]
                return [{"type": "done", "id": command["id"], "ok": False, "error": "the goal's save got no answer", "committed": True,
                         "path": "/code", "thread": None}]
            return original(command)
        self.page.run = run
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"]), ("failed", f"{do.NOT_CONFIRMED}: the goal's save got no answer", True))
        self.assertEqual(len(self.calls("read_settings")), 0)  # no proving read
        self.assertNotIn(out["id"], self.core.unproved)  # nor a later one
        self.assertEqual(self.core.runs, {})

    def test_an_act_that_errs_after_its_change_still_waits_for_a_later_read(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": False, "error": "the settings dialog stayed open", "committed": True,
                                     "path": "/code", "thread": None}] if c["kind"] == "set_field" else original(c))
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], out["cause"]), ("pending", "the settings dialog stayed open"))  # the proving read and the look decide
        self.timeout()
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"]), ("failed", f"{do.NOT_CONFIRMED}: the settings dialog stayed open", True))
        self.assertIn(out["id"], self.core.unproved)

    def test_a_setting_reads_and_acts_in_one_command_from_a_fresh_open(self):
        self.settings()["repos"] = ["acme/other"]
        self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual(self.calls("add_repo", "read_settings"), [("add_repo", "chan_a")])  # its before and its proof come with its own done
        self.assertEqual(store.intents(self.core.db, 1)[-1]["result"]["before"], ["acme/other"])

    def test_what_the_page_reports_as_before_is_data(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": True, "error": None, "before": ["acme/x", 3], "saved": 200, "path": "/code", "thread": None}]
                                   if c["kind"] == "add_repo" else original(c))
        self.assertEqual(self.run_tool("add_repo", project="alpha", repo="acme/app")["result"]["before"], ["acme/x"])
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": True, "error": None, "before": {"no": 1}, "saved": 200, "path": "/code", "thread": None}]
                                   if c["kind"] == "set_field" else original(c))
        self.assertIsNone(self.run_tool("set_instructions", project="alpha", text="x")["result"]["before"])

    def test_a_save_the_server_refused_by_status_is_not_confirmed(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": True, "error": None, "before": "", "saved": 403, "path": "/code", "thread": None}]
                                   if c["kind"] == "set_field" else original(c))
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(out["status"], "pending")  # only a 2xx is the server taking it: the proving read decides
        self.assertEqual(len(self.calls("read_settings")), 1)

    def test_a_full_home_path_is_written_as_the_page_lists_it(self):
        import os
        home = os.path.expanduser("~")
        self.assertEqual(do.tool_args("preapprove_folder", {"project": "alpha", "path": home + "/code/"})[0]["path"], "~/code")
        self.assertEqual(do.tool_args("preapprove_folder", {"project": "alpha", "path": "/tmp/x"})[0]["path"], "/tmp/x")

    def test_arguments_are_refused_before_the_page_is_touched(self):
        for tool, args in (("set_goal", {"project": "alpha", "text": "x" * 8001}), ("set_instructions", {"project": "alpha", "text": "x" * 16001}),
                           ("set_goal", {"project": "nowhere", "text": "x"}), ("set_goal", {"project": "alpha"}), ("set_goal", {"project": "alpha", "text": "x", "more": "y"}),
                           ("delete_project", {"project": "alpha"}), ("add_repo", {"project": "alpha", "repo": "no-slash"}), ("set_goal", {"project": "alpha", "text": 3})):
            self.assertEqual(self.run_tool(tool, **args)["status"], "refused", (tool, args))
        self.assertEqual(self.page.calls, [])

    def test_a_folder_with_no_project_is_refused(self):
        self.assertEqual(self.run_tool("set_goal", project="local:repo", text="x")["status"], "refused")

    def test_a_tool_pauses_when_signed_out_and_goes_on(self):
        self.core.handle(self.page._stamp({"type": "page", "signed_in": False, "page_ok": True}))
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual(out["status"], "paused")
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True}))
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "confirmed")

    def proving_read_breaks(self):
        """The act's save gets no answer (the change took), and the first proving read breaks."""
        original, reads = self.page.run, []

        def run(command):
            if command["kind"] == "read_settings":
                reads.append(command["id"])
                if len(reads) == 1:
                    return [{"type": "done", "id": command["id"], "ok": False, "error": "no settings menu", "path": "/code", "thread": None}]
            return original(command)
        self.page.run, self.page.save = run, "unanswered"
        return reads

    def test_a_proving_read_that_errs_waits_for_the_deadlines_look(self):
        reads = self.proving_read_breaks()
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], len(reads)), ("pending", 1))  # not read again at once
        out = self.timeout()
        self.assertEqual((out["status"], len(reads), len(self.calls("set_field"))), ("confirmed", 2, 1))

    def test_a_look_waits_for_the_tab_rather_than_failing_unread(self):
        reads = self.proving_read_breaks()
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.page.composerless = True  # beta's send holds the tab past the tool's look
        self.core.say("words for beta", project="chan_b")
        self.page.pump(self.core)
        self.timeout()
        self.timeout()
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], len(reads)), ("pending", 1))
        self.page.settle()
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], len(reads), len(self.calls("set_field"))), ("confirmed", 2, 1))

    def test_a_proving_read_opens_the_project_once_when_the_tab_moved(self):
        original = self.page.run

        def run(command):
            events = original(command)
            if command["kind"] == "set_field":  # a send elsewhere moved the tab before the act's done came
                done = [e for e in events if e["type"] == "done"]
                return self.page.load("chan_b") + done
            return events
        self.page.run, self.page.save = run, "unanswered"
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual([c[0] for c in self.page.calls], ["set_field", "open", "read_settings"])

    def test_a_pause_after_the_act_never_acts_again(self):
        original = self.page.run
        self.page.run = lambda c: ([self.page._stamp({"type": "page", "signed_in": False, "page_ok": True})] if c["kind"] == "set_field" else []) + original(c)
        self.page.save = "unanswered"  # a read proves it, once the page is back
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(out["status"], "paused")
        self.page.run = original
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True}))
        self.page.pump(self.core)
        self.assertEqual((store.intent(self.core.db, out["id"])["status"], len(self.calls("set_field"))), ("confirmed", 1))

    def test_a_save_the_server_refuses_is_an_error_with_nothing_done(self):
        self.page.save = "refused"
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"], out["result"]["before"]), ("failed", "the server refused the goal (HTTP 400)", False, ""))
        self.assertNotIn(out["id"], self.core.unproved)

    def test_a_retry_of_a_refused_goal_the_tab_still_shows_is_refused_not_confirmed(self):
        self.page.save = "refused"  # the tab shows the typed goal, which the server never took
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.page.save = "ok"
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"]), ("refused", "the server refused this goal earlier and Fjord's tab still shows it: reload the tab first"))
        self.assertEqual(self.page.acted, ["set_field"])  # the retry read the goal and changed nothing

    def test_a_goal_confirmed_by_its_answer_clears_its_mark(self):
        self.page.save = "unanswered"
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertIn("chan_a", self.core.stale_goal)
        self.page.save = "ok"
        self.assertEqual(self.run_tool("set_goal", project="alpha", text="other goal")["status"], "confirmed")
        self.assertNotIn("chan_a", self.core.stale_goal)
        self.assertEqual(routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).stale_goal, {})

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_marked_goal_is_forgotten_once_the_tab_was_loaded_after_it(self):
        self.core.stale_goal["chan_a"] = {"id": 1, "at": NOW, "updated": NOW, "result": {"provable": False}}
        self.core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": int((NOW - 60) * 1000), "path": "/code", "thread": None})
        self.assertIn("chan_a", self.core.stale_goal)  # loaded before it: still the typed copy
        self.core.handle({"type": "page", "signed_in": True, "page_ok": True, "loaded": int((NOW + 60) * 1000), "path": "/code", "thread": None})
        self.assertNotIn("chan_a", self.core.stale_goal)  # a fresh document read the server's goal

    def test_a_refused_goal_is_forgotten_once_the_tab_shows_another(self):
        self.page.save = "refused"
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertIn("chan_a", self.core.stale_goal)
        self.settings()["goal"] = "the server's goal"  # a reloaded tab reads the server's goal
        self.page.save = "ok"
        self.run_tool("set_goal", project="alpha", text="other goal")
        self.assertNotIn("chan_a", self.core.stale_goal)

    def test_a_refused_goal_stays_marked_across_a_host_loss_and_a_restart(self):
        self.page.save = "refused"
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.page.save = "ok"
        self.core.connection(False)  # the host went away; the tab, not reloaded, still shows the typed goal
        self.page.connect(self.core)
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"]), ("refused", "the server refused this goal earlier and Fjord's tab still shows it: reload the tab first"))
        self.core = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        self.page.connect(self.core)
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual(out["status"], "refused")
        self.assertEqual(self.page.acted, ["set_field"])

    def test_a_goal_save_unanswered_marks_the_goal_until_the_tab_is_reloaded(self):
        self.page.save = "unanswered"
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.page.save = "ok"
        for core in (self.core, routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)):
            self.core = core
            self.page.connect(core)
            out = self.run_tool("set_goal", project="alpha", text="new goal")
            self.assertEqual((out["status"], out["cause"]), ("refused", "Fjord can't tell whether the server took this goal: reload the tab first"))
            self.assertNotIn("acted", out["result"])
        self.assertEqual(self.page.acted, ["set_field"])

    def silent_goal_save(self):
        """The dialog keeps the typed goal, and its step never reports back, not even to the cancel (the host was lost, say)."""
        original = self.page.run

        def run(command):
            if command["kind"] == "set_field" and self.page.run is run:
                self.settings()["goal"] = command["text"]
                self.page.run = original  # only this one: a later act reports back
                return []
            return original(command)
        self.page.run = run

    def test_a_goal_act_that_never_finished_marks_the_goal_and_proves_nothing(self):
        self.silent_goal_save()
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.timeout()
        out = self.timeout()
        self.assertEqual((out["status"], out["result"]["acted"], out["result"]["provable"]), ("failed", True, False))
        self.assertNotIn(out["id"], self.core.unproved)
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"]), ("refused", "Fjord can't tell whether the server took this goal: reload the tab first"))

    def test_a_restart_during_a_goal_act_marks_the_goal_and_proves_nothing(self):
        self.silent_goal_save()
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.core = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        self.assertEqual((store.intent(self.core.db, out["id"])["result"]["provable"], self.core.unproved), (False, set()))
        self.page.connect(self.core)
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["cause"]), ("refused", "Fjord can't tell whether the server took this goal: reload the tab first"))

    def test_a_goal_the_page_refused_before_its_change_stays_marked_after_a_restart(self):
        original = self.page.run

        def run(command):  # the page refused the step before saving, but the field shows what was typed
            if command["kind"] == "set_field":
                self.settings()["goal"] = command["text"]
                return [{"type": "done", "id": command["id"], "ok": False, "error": "no save button", "refused": True, "path": "/code", "thread": None}]
            return original(command)
        self.page.run = run
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["result"]["acted"]), ("refused", False))
        self.assertIn("chan_a", routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).stale_goal)

    def test_a_goal_act_a_restart_cut_short_that_found_it_already_so_is_not_marked(self):
        self.settings()["goal"] = "same"
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)  # its done is lost with the host
        out = self.run_tool("set_goal", project="alpha", text="same")
        self.core = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        self.assertIn("chan_a", self.core.stale_goal)  # acted, no answer: marked
        self.page.run = original
        command = store.intent(self.core.db, out["id"])["result"]["act"]
        self.page.recent = [{"type": "done", "id": command, "ok": True, "error": None, "before": "same", "already": True, "path": "/code/project/chan_a", "thread": None}]
        self.page.connect(self.core)  # the page says again what it reported: it was already so, nothing was typed
        self.assertNotIn("chan_a", self.core.stale_goal)
        self.assertNotIn("chan_a", routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).stale_goal)
        self.assertEqual(self.run_tool("set_goal", project="alpha", text="same")["status"], "confirmed")

    def test_a_restart_marks_no_goal_a_later_save_took(self):
        self.page.save = "refused"
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.settings()["goal"] = "the server's goal"
        self.page.save = "ok"
        self.run_tool("set_goal", project="alpha", text="other goal")
        self.assertEqual(routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).stale_goal, {})

    def test_a_save_unanswered_after_the_dialog_closed_is_confirmed_by_its_proving_read(self):
        self.page.save = "unanswered"
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual((out["status"], out["result"]["acted"]), ("confirmed", True))

    def test_a_goal_save_unanswered_is_not_confirmed_even_after_a_restart(self):
        self.page.save = "unanswered"  # the dialog shows the typed goal whether or not the server has it
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual((out["status"], out["result"]["acted"]), ("failed", True))
        self.assertTrue(out["cause"].startswith(do.NOT_CONFIRMED + ": "))
        self.assertEqual(routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).unproved, set())

    def test_a_restart_never_acts_again(self):
        self.page.takes = False
        out = self.run_tool("set_instructions", project="alpha", text="new rules")
        again = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["cause"]), ("failed", "routerd restarted before the change was proved"))
        self.assertEqual(again.unproved, {out["id"]})


class Race(Tools):
    def hold_reads(self):
        """Proving reads wait in the page until `release()`; the act's save gets no answer, so a read proves it."""
        original, held = self.page.run, []

        def run(command):
            if command["kind"] == "read_settings":
                held.append(command)
                return []
            return original(command)
        self.page.run, self.page.save = run, "unanswered"

        def release():  # the later acts' saves are answered
            self.page.run, self.page.save = original, "ok"
            for command in held:
                for event in original(command):
                    self.core.handle(event)
            held.clear()
            self.page.pump(self.core)
        return held, release

    def test_a_tool_waits_to_start_while_another_runs_proving_read_is_in_the_page(self):
        held, release = self.hold_reads()
        first = self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(len(held), 1)  # its proving read waits in the page
        second = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual(self.calls("add_repo"), [])  # its fresh open would close the read's dialog under it
        release()
        self.assertEqual([store.intent(self.core.db, i["id"])["status"] for i in (first, second)], ["confirmed", "confirmed"])
        self.assertEqual([c[0] for c in self.page.calls], ["set_field", "read_settings", "add_repo"])

    def test_a_tool_that_has_not_begun_does_not_hold_the_proving_read_of_another(self):
        held, release = self.hold_reads()
        self.core.tool("set_instructions", project="alpha", text="new rules")  # beta's waits at its start: nothing sent, nothing opened
        self.core.tool("set_instructions", project="beta", text="beta rules")
        self.page.pump(self.core)
        first, second = store.intents(self.core.db, 2)[-2:]
        self.assertEqual(len(held), 1)  # alpha's read is issued at once, and beta's act waits for it (its fresh open would close the dialog)
        self.assertEqual(self.calls("open", "set_field"), [c for c in self.page.calls if c[1] == "chan_a"])
        release()
        self.assertEqual([store.intent(self.core.db, i["id"])["status"] for i in (first, second)], ["confirmed", "confirmed"])

    def test_a_read_is_issued_at_once_when_a_send_that_arrived_during_the_act_has_not_begun(self):
        """A folder act's save gave up and left the settings dialog open; a send that arrived meanwhile (still at its start) must not make
        the proving read wait for the deadline: that send would then meet the open dialog and burn its attempts."""
        self.page.save = "nothing"
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual(len(self.calls("read_settings")), 1)  # at once, not at the deadline
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "failed")
        self.assertEqual((sent[0]["status"], sent[0]["attempts"]), ("confirmed", 1))

    def test_a_send_the_tool_took_the_tab_from_goes_back_and_proves_at_once(self):
        self.page.holds = True  # beta's row shows only once delivered, as when the server is a beat late
        sent = []
        self.core.say("words for beta", project="beta", finished=sent.append)
        self.page.pump(self.core)
        self.run_tool("set_goal", project="alpha", text="new goal")
        self.assertEqual(self.page.at, ("chan_b", None))  # the tool done, the tab went back to beta
        self.page.deliver("chan_b")
        self.page.pump(self.core)
        self.assertEqual(sent[0]["status"], "confirmed")
        self.assertEqual(len([c for c in self.page.calls if c[0] == "send"]), 1)


class Late(Tools):
    """The page's replayed `done`s for acts whose runs are over (a restart cut them short)."""

    def silent_act(self, tool, kind, **args):
        """An act whose `done` is lost with the host; the core restarts, so its intent is failed, acted and unproved."""
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == kind else original(c)
        out = self.run_tool(tool, **args)
        self.page.run = original
        self.core = routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["result"]["acted"]), ("failed", True))
        return out

    def replay(self, out, **done):
        self.page.recent = [{"type": "done", "id": out["result"]["act"], "path": "/code/project/chan_a", "thread": None, "error": None, **done}]
        self.page.connect(self.core)
        return store.intent(self.core.db, out["id"])

    def test_every_tools_act_keeps_its_command_id(self):
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertRegex(out["result"]["act"], r"^c[0-9a-f]+\.\d+$")

    def test_a_replayed_saved_done_confirms_a_setting_an_earlier_start_cut_short(self):
        out = self.silent_act("add_repo", "add_repo", project="alpha", repo="acme/app")
        self.assertIn(out["id"], self.core.unproved)
        out = self.replay(out, ok=True, saved=200, before=[])
        self.assertEqual((out["status"], out["cause"]), ("confirmed", "confirmed by the page's late report of its save"))
        self.assertNotIn(out["id"], self.core.unproved)
        self.assertEqual(routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).unproved, set())

    def test_a_replayed_saved_done_confirms_a_goal_and_drops_its_mark(self):
        out = self.silent_act("set_goal", "set_field", project="alpha", text="new goal")
        self.assertIn("chan_a", self.core.stale_goal)
        out = self.replay(out, ok=True, saved=200, before="old")
        self.assertEqual((out["status"], out["result"]["provable"]), ("confirmed", True))
        self.assertNotIn("chan_a", self.core.stale_goal)
        self.assertNotIn("chan_a", routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).stale_goal)

    def test_a_replayed_refusal_before_the_change_means_nothing_was_done(self):
        out = self.silent_act("add_repo", "add_repo", project="alpha", repo="acme/app")
        out = self.replay(out, ok=False, error="no repository add button")
        self.assertEqual((out["status"], out["result"]["acted"]), ("failed", False))
        self.assertNotIn(out["id"], self.core.unproved)
        self.assertEqual(routerd.Core(self.core.db, self.page.receive, clock=self.core.clock).unproved, set())

    def test_a_replayed_refusal_of_a_goal_leaves_it_marked_as_one_the_tab_may_show(self):
        out = self.silent_act("set_goal", "set_field", project="alpha", text="new goal")
        out = self.replay(out, ok=False, error="no save button", refused=True)
        self.assertEqual((out["result"]["acted"], out["result"]["provable"]), (False, True))
        self.assertIn("chan_a", self.core.stale_goal)  # the field shows what was typed

    def test_a_replayed_done_that_committed_without_an_answer_changes_nothing(self):
        out = self.silent_act("add_repo", "add_repo", project="alpha", repo="acme/app")
        out = self.replay(out, ok=False, error="no answer from the server to the repository (network)", committed=True)
        self.assertEqual((out["status"], out["result"]["acted"]), ("failed", True))
        self.assertIn(out["id"], self.core.unproved)


class Dialogs(Tools):
    """A tool's settings dialog is open in the page: sends wait, the cut-off read goes straight to the look, and a finished read isn't cancelled."""

    def sends(self):
        return [c for c in self.page.calls if c[0] == "send"]

    def test_a_send_that_meets_a_dialog_the_page_holds_is_not_retried_at_once_nor_counted(self):
        self.page.dialogs["stray"] = ({}, "close")  # a dialog no tool run knows of: the page's guard refuses the words
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual((len(self.sends()), sent), (1, []))  # not retried against the dialog, nor failed after its attempts
        self.assertEqual(store.intents(self.core.db, 1)[-1]["attempts"], 1)
        self.page.dialogs.clear()
        self.timeout()  # at its deadline it is made again
        self.assertEqual((len(self.sends()), sent[0]["status"]), (2, "confirmed"))

    def test_the_fake_takes_a_tool_command_with_a_thread_open_beside_the_project_and_a_click_under_a_dialog(self):
        self.page.add_thread("chan_a", "cmsg_1", "a thread")
        self.page.at = ("chan_a", "cmsg_1")  # the same pathname as the project's: the page shows the thread beside it
        read = self.page.run({"id": "c1.1", "kind": "read_settings", "project": "chan_a"})
        self.assertTrue(all(e.get("ok", True) for e in read))
        self.page.dialogs["stray"] = ({}, "close")
        self.page.projects["chan_a"]["draft"] = "plain test words"
        sent = self.page.run({"id": "c1.2", "kind": "send", "side": "project", "project": "chan_a", "text": "plain test words", "click_only": True})
        self.assertTrue([e for e in sent if e["type"] == "done"][0]["ok"])  # the words are in the draft: the click needs no modal check

    def test_the_fake_clicks_words_already_in_the_draft_under_a_dialog_even_when_not_click_only(self):
        self.page.at = ("chan_a", None)
        self.page.dialogs["stray"] = ({}, "close")
        self.page.projects["chan_a"]["draft"] = "plain test words"
        sent = self.page.run({"id": "c1.1", "kind": "send", "side": "project", "project": "chan_a", "text": "plain test words"})
        self.assertEqual([(e["ok"], e["error"]) for e in sent if e["type"] == "done"], [(True, None)])  # content.js guards clearing and typing only
        self.page.projects["chan_a"]["draft"] = "other words"
        sent = self.page.run({"id": "c1.2", "kind": "send", "side": "project", "project": "chan_a", "text": "plain test words"})
        self.assertEqual([e["error"] for e in sent if e["type"] == "done"], ["a dialog is open"])  # clearing is guarded

    def test_the_fake_supersedes_the_waiting_send_before_its_dialog_guard(self):
        self.page.at = ("chan_a", None)
        self.page.composerless = True
        self.page.run({"id": "c1.1", "kind": "send", "side": "project", "project": "chan_a", "text": "plain test words"})
        self.page.composerless, self.page.dialogs["stray"] = False, ({}, "close")
        sent = self.page.run({"id": "c1.2", "kind": "send", "side": "project", "project": "chan_a", "text": "plain test words"})
        self.assertEqual([(e["id"], e["error"]) for e in sent if e["type"] == "done"], [("c1.1", "superseded"), ("c1.2", "a dialog is open")])
        self.assertEqual(self.page.waiting, [])

    def test_a_send_held_by_a_dialog_goes_on_when_the_tool_that_had_it_ends(self):
        self.page.save, self.page.slow_reads = "unanswered", True
        self.run_tool("set_instructions", project="alpha", text="new rules")  # its proving read keeps a dialog open
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual(self.sends(), [])
        self.page.release()
        self.page.pump(self.core)
        self.assertEqual((len(self.sends()), sent[0]["attempts"]), (1, 1))

    def test_a_proving_read_cut_at_the_deadline_goes_straight_to_the_look(self):
        self.page.save, self.page.slow_reads = "unanswered", True
        self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(len(self.calls("read_settings")), 1)
        self.timeout()  # the deadline cuts the read; its report comes at once
        self.assertEqual(len(self.calls("read_settings")), 2)  # the look, with no second full wait

    def test_an_act_the_page_dropped_fails_at_the_first_deadline(self):
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)  # the act is sent and never answered
        self.run_tool("set_instructions", project="alpha", text="new rules")
        self.page.run = original
        self.core.connection(True)
        self.core.handle(self.page._stamp({"type": "commands", "waiting": [], "done": []}))  # a reloaded page lists nothing: the act is gone
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page never finished the step"))  # not a second wait after a cancel

    def act_lost_with_the_host(self, loaded_after):
        """A goal's act the worker failed (no tab to hand it to, say) with its `done` lost with the host: the same document's snapshot
        neither lists it nor said it."""
        loaded = 1793706095915
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded, "instance": "i1"}))
        original = self.page.run
        self.page.run = lambda c: [] if c["kind"] == "set_field" else original(c)
        out = self.run_tool("set_goal", project="alpha", text="new goal")
        self.page.run = original
        self.core.connection(False); self.core.connection(True)
        self.core.handle(self.page._stamp({"type": "commands", "waiting": [], "done": [], "instance": "i1"}))
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "pending")  # not before the page says which document it is
        self.core.handle(self.page._stamp({"type": "page", "signed_in": True, "page_ok": True, "loaded": loaded_after, "instance": "i1"}))
        return store.intent(self.core.db, out["id"])

    def test_an_act_the_same_document_never_ran_did_nothing(self):
        out = self.act_lost_with_the_host(1793706095915)
        self.assertEqual((out["status"], out["result"]["acted"], out["result"]["provable"]), ("failed", False, True))
        self.assertNotIn("chan_a", self.core.stale_goal)  # nothing was typed in the tab
        self.assertEqual(self.settings()["goal"], "")

    def test_an_act_another_document_dropped_waits_for_its_deadline(self):
        out = self.act_lost_with_the_host(1793706099999)
        self.assertEqual(out["status"], "pending")
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page never finished the step"))

    def test_a_read_that_broke_on_its_own_still_waits_for_the_deadline(self):
        self.page.save = "unanswered"
        original, reads = self.page.run, []

        def run(command):
            if command["kind"] != "read_settings":
                return original(command)
            reads.append(command)
            return [{"type": "done", "id": command["id"], "ok": False, "error": "no settings menu", "path": "/code", "thread": None}]
        self.page.run = run
        self.run_tool("set_instructions", project="alpha", text="new rules")
        self.assertEqual(len(reads), 1)
        self.assertEqual(len(self.timeout() and reads), 2)  # the look comes at the deadline, not before

    def failing_read(self):
        """A folder pressed with no save seen: the read that arrives lacks it, so the run fails while the page still closes the dialog."""
        self.page.save, self.page.slow_close = "nothing", True
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        return store.intent(self.core.db, out["id"])

    def test_a_run_finished_by_its_settings_does_not_cancel_the_read_still_closing(self):
        out = self.failing_read()
        self.assertEqual(out["status"], "failed")
        self.assertEqual(len(self.calls("cancel")), 0)  # a cancel would make the page report a second `done`
        self.page.release()
        self.page.pump(self.core)
        self.assertEqual((self.core.closing, len(self.calls("cancel"))), ({}, 0))

    def test_a_read_still_closing_at_its_deadline_is_cancelled_and_the_sends_it_held_go_on(self):
        out = self.failing_read()
        read = [c for c in self.core.closing]
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual((self.sends(), self.core.next_deadline()), ([], NOW + do.TIMEOUT))  # held, with the close's deadline to wake it
        self.timeout()  # the dialog never closed: the read is let go, and its cancel is its first and only `done`
        self.assertEqual((self.core.closing, [c[0] for c in self.page.calls].count("cancel")), ({}, 1))
        self.assertIn(read[0], [d["id"] for d in self.page.recent if d["error"] == "the settings dialog stayed open"])
        self.assertEqual((len(self.sends()), sent[0]["status"]), (1, "confirmed"))
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "failed")

    def test_a_send_waits_while_a_proving_read_is_in_the_page(self):
        self.page.save, self.page.slow_reads = "unanswered", True
        self.run_tool("set_instructions", project="alpha", text="new rules")
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual(self.sends(), [])  # typing now could land in the dialog's fields
        self.page.release()
        self.page.pump(self.core)
        self.assertEqual((len(self.sends()), sent[0]["status"]), (1, "confirmed"))

    def test_a_send_waits_while_a_finished_read_is_still_closing_its_dialog(self):
        self.failing_read()
        sent = []
        self.core.say("plain test words", project="alpha", finished=sent.append)
        self.page.pump(self.core)
        self.assertEqual(self.sends(), [])
        self.page.release()
        self.page.pump(self.core)
        self.assertEqual((len(self.sends()), sent[0]["status"]), (1, "confirmed"))


class Environment(Tools):
    def test_an_option_the_list_marks_chosen_is_reported_already_not_as_a_save_that_never_came(self):
        self.page.chosen = ["acme/app", "/Users/o/code"]
        for tool, args in (("add_repo", {"repo": "acme/app"}), ("preapprove_folder", {"path": "/Users/o/code"})):
            out = self.run_tool(tool, project="alpha", **args)
            if tool == "preapprove_folder":
                self.core.confirm(out["id"])
                self.page.pump(self.core)
                out = store.intent(self.core.db, out["id"])
            self.assertEqual((out["status"], out["cause"]), ("failed", "the page said it was already so, but what it read differs"))
            self.assertNotIn("acted", out["result"])  # nothing was pressed, and no wait for a save followed
        self.assertEqual(self.page.acted, [])
    def test_add_repo_is_proved_by_its_saves_answer(self):
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual((out["status"], out["result"]["before"]), ("confirmed", []))
        self.assertEqual(self.settings()["repos"], ["acme/app"])
        self.assertEqual([c[0] for c in self.page.calls], ["add_repo"])

    def test_a_repo_the_page_doesnt_offer_is_refused_naming_what_was_there(self):
        out = self.run_tool("add_repo", project="alpha", repo="acme/missing")  # the search for it answered with no match: final at once
        self.assertEqual(out["status"], "refused")
        self.assertEqual(out["cause"], "no repo option acme/missing; offered: acme/app, acme/other")
        self.assertEqual(self.settings()["repos"], [])
        self.assertEqual(len(self.calls("add_repo")), 1)

    def test_several_exact_matches_are_refused_at_once(self):
        self.page.repos = ["acme/app", "acme/app"]
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual((out["status"], out["cause"]), ("refused", "2 repo options match acme/app"))
        self.assertEqual(self.settings()["repos"], [])

    def test_a_repo_whose_pick_saved_nothing_by_the_cut_off_is_read_for_proof(self):
        self.settings()["repos"] = ["acme/other"]
        self.page.save = "hang"  # pressed, and no save answered by the cut-off: one may still be under way
        self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.timeout()
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"], out["result"]["before"]),
                         ("failed", f"{do.NOT_CONFIRMED}: the page saved nothing after the repository was chosen", True, ["acme/other"]))
        self.assertIn(out["id"], self.core.unproved)  # a later read that shows it still confirms it
        self.assertEqual((len(self.calls("add_repo")), len(self.calls("read_settings"))), (1, 2))

    def test_a_repo_that_took_but_is_not_listed_is_not_added_again(self):
        self.page.takes = False
        self.run_tool("add_repo", project="alpha", repo="acme/app")
        out = self.timeout()
        self.assertEqual((out["status"], out["cause"]), ("failed", f"{do.NOT_CONFIRMED}: no answer from the server to the repository (network)"))
        self.assertEqual(len(self.calls("add_repo")), 1)
        self.assertIn(out["id"], self.core.unproved)


class Folders(Tools):
    def test_a_folder_waits_for_confirm_and_nothing_is_done_before(self):
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.assertEqual(out["status"], "awaiting")
        self.assertEqual(self.done[0]["status"], "awaiting")
        self.assertEqual(self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")["id"], out["id"])  # asked again: the same grant, still waiting
        support.later(self.core, 10 * do.TIMEOUT)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual((self.page.calls, self.core.runs), ([], {}))

    def test_confirm_runs_it_and_a_later_read_proves_it(self):
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"], self.done.append)
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["result"]["before"]), ("confirmed", []))
        self.assertEqual(self.settings()["folders"], ["/Users/o/code"])
        self.assertEqual(len(self.calls("preapprove_folder")), 1)

    def test_a_folder_this_mac_hasnt_connected_is_refused_after_confirm(self):
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/secret")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"]), ("refused", "connect /Users/o/secret in the Claude app first", False))
        self.assertEqual(len(self.calls("preapprove_folder")), 1)  # its list was opened and read, and held no such folder
        self.assertEqual(self.settings()["folders"], [])

    def test_a_folder_whose_pick_saved_nothing_says_so(self):
        self.page.save = "hang"  # offered, but not pre-approvable: the press saves nothing, and an older page waits for it
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        self.timeout()  # the step waits for a save; the deadline cuts it off and it says it saw none, but a save may be under way
        out = self.timeout()  # so a read decides: the proving one, then the look
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"]),
                         ("failed", f"{do.NOT_CONFIRMED}: the page saved nothing after the folder was chosen", True))
        self.assertIn(out["id"], self.core.unproved)
        self.assertEqual((len(self.calls("preapprove_folder")), len(self.calls("read_settings"))), (1, 2))

    NOTHING = "the page saved nothing after the folder was chosen"

    def grant(self):
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        return store.intent(self.core.db, out["id"])

    def test_a_folder_the_page_saved_nothing_for_fails_at_once_when_the_fresh_read_lacks_it(self):
        self.page.save = "nothing"  # the page's short wait saw no save: it reports at once, no cut-off needed
        out = self.grant()  # no timeout: nothing waits for a deadline or a look
        self.assertEqual((out["status"], out["cause"], out["result"]["acted"]), ("failed", self.NOTHING, True))
        self.assertNotIn(do.NOT_CONFIRMED, out["cause"])
        self.assertEqual((len(self.calls("preapprove_folder")), len(self.calls("read_settings"))), (1, 1))  # one proving read, no look
        self.assertEqual(self.core.runs, {})

    def test_a_folder_the_page_saved_nothing_for_is_confirmed_when_the_fresh_read_shows_it(self):
        self.page.save = "nothing_took"  # the save came after the page's wait, and took
        out = self.grant()
        self.assertEqual(out["status"], "confirmed")
        self.assertEqual(self.settings()["folders"], ["/Users/o/code"])
        self.assertEqual(len(self.calls("read_settings")), 1)

    def test_a_repo_the_page_saved_nothing_for_fails_at_once_when_the_fresh_read_lacks_it(self):
        self.page.save = "nothing"
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual((out["status"], out["cause"]), ("failed", "the page saved nothing after the repository was chosen"))
        self.assertEqual(len(self.calls("read_settings")), 1)

    def test_a_repo_the_page_saved_nothing_for_is_confirmed_when_the_fresh_read_shows_it(self):
        self.page.save = "nothing_took"
        self.assertEqual(self.run_tool("add_repo", project="alpha", repo="acme/app")["status"], "confirmed")

    def test_an_unanswered_save_is_still_looked_at_twice(self):
        self.page.takes = False  # a save with a network error is not "the page saved nothing": the look still decides
        out = self.run_tool("add_repo", project="alpha", repo="acme/app")
        self.assertEqual(out["status"], "pending")

    def test_a_folder_list_that_never_opened_says_so_rather_than_asking_to_connect(self):
        original = self.page.run
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": False, "error": "the folder list never opened", "before": [], "path": "/code", "thread": None}]
                                   if c["kind"] == "preapprove_folder" else original(c))
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["cause"], "the folder list never opened")
        self.page.run = lambda c: ([{"type": "done", "id": c["id"], "ok": False, "refused": True, "error": "2 folder options match /Users/o/code", "before": [], "path": "/code", "thread": None}]
                                   if c["kind"] == "preapprove_folder" else original(c))
        out = self.run_tool("preapprove_folder", project="alpha", path="/Users/o/code")
        self.core.confirm(out["id"])
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, out["id"])["cause"], "2 folder options match /Users/o/code")  # a refusal not about a missing folder is said as it is

    def test_confirm_only_acts_on_what_awaits(self):
        out = self.run_tool("set_goal", project="alpha", text="g")
        self.core.confirm(out["id"])
        self.assertEqual(len(self.calls("set_field")), 1)
        self.assertIsNone(self.core.confirm(999))

    def test_confirm_of_what_doesnt_await_still_answers(self):
        out, answers = self.run_tool("set_goal", project="alpha", text="g"), []
        self.core.confirm(out["id"], answers.append)
        self.core.confirm(999, answers.append)
        self.assertEqual([(a["id"], a.get("status"), a.get("error")) for a in answers], [(out["id"], "confirmed", None), (999, None, "no intent 999")])


class Create(Tools):
    def test_a_new_project_is_proved_by_a_list_with_its_name_and_an_unknown_id(self):
        out = self.run_tool("create_project", name="gamma", goal="make gamma")
        self.assertEqual((out["status"], out["project"], out["args"]), ("confirmed", "chan_new1", {"name": "gamma", "goal": "make gamma"}))
        self.assertEqual(self.core.board()["projects"]["chan_new1"]["name"], "gamma")
        self.assertEqual(self.page.projects["chan_new1"]["settings"]["goal"], "make gamma")
        self.assertEqual([c[0] for c in self.page.calls], ["open", "create_project"])

    def test_an_existing_name_is_refused_at_once(self):
        out = self.run_tool("create_project", name="alpha")
        self.assertEqual((out["status"], out["cause"]), ("refused", "a project named alpha already exists"))
        self.assertEqual(self.page.calls, [])

    def test_a_create_that_took_but_is_not_listed_never_creates_again(self):
        self.page.takes = False
        self.run_tool("create_project", name="gamma")
        out = self.timeout()  # the projects page is looked at once more
        self.assertEqual((out["status"], out["cause"]), ("failed", do.NOT_CONFIRMED))
        again = self.run_tool("create_project", name="gamma")
        self.assertEqual((again["status"], again["cause"]), ("refused", "an earlier create of gamma took, but isn't confirmed yet"))
        self.assertEqual(len(self.calls("create_project")), 1)

    def test_a_create_a_much_later_full_list_still_lacks_frees_its_name(self):
        self.page.takes = False
        self.run_tool("create_project", name="gamma")
        self.timeout()
        support.later(self.core, routerd.ACCEPTED_WAIT)
        where = {"path": "/code/projects/browse", "thread": None}
        self.core.handle({"type": "projects", "projects": [{"id": p, "name": v["name"]} for p, v in self.page.projects.items()], "complete": True, **where})
        self.page.takes = True
        again = self.run_tool("create_project", name="gamma")
        self.assertEqual(again["status"], "confirmed")
        self.assertEqual(len(self.calls("create_project")), 2)

    def test_a_creates_look_waits_while_a_send_has_the_tab(self):
        self.page.takes = False
        self.run_tool("create_project", name="gamma")
        self.page.composerless = True  # beta's send waits in the page
        self.core.say("words for beta", project="chan_b")
        self.page.pump(self.core)
        n = len(self.page.calls)
        self.timeout()
        self.assertNotIn(("open", None, None), self.page.calls[n:])  # the projects page isn't opened under the send

    def test_a_creates_look_held_off_past_its_deadline_still_looks(self):
        self.page.takes = False
        out = self.run_tool("create_project", name="gamma")
        self.page.composerless = True  # beta's send holds the tab past the create's look
        self.core.say("words for beta", project="chan_b")
        self.page.pump(self.core)
        self.timeout()
        self.timeout()
        self.assertEqual(store.intent(self.core.db, out["id"])["status"], "pending")
        self.page.settle()
        n = len(self.page.calls)
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["cause"]), ("failed", do.NOT_CONFIRMED))
        self.assertIn(("open", None, None), self.page.calls[n:])  # it took its look

    @support.python_only("a test writes engine state or replaces a method of the core (python object identity)")
    def test_a_local_folder_of_that_name_does_not_block_a_create(self):
        self.core.acc["projects"]["local:gamma"] = {"id": "local:gamma", "name": "gamma", "where": "local", "chat": None, "draft": None}
        self.core._board = None
        self.assertEqual(self.run_tool("create_project", name="gamma")["status"], "confirmed")

    def test_a_look_whose_list_comes_after_its_done_confirms(self):
        self.page.lags = True
        self.run_tool("create_project", name="gamma")
        original = self.page.run
        self.page.run = lambda c: (self.page.land() if c["kind"] == "open" and c["project"] is None else None) or original(c)  # it lands by the look
        out = self.timeout()
        self.assertEqual((out["status"], out["project"], self.done[-1]["status"]), ("confirmed", "chan_new1", "confirmed"))
        self.assertEqual(len(self.calls("create_project")), 1)

    def test_a_later_list_with_that_name_confirms_it(self):
        self.page.lags = True
        self.run_tool("create_project", name="gamma")
        out = self.timeout()
        self.assertEqual(out["status"], "failed")
        self.page.land()
        self.page.pump(self.core)
        out = store.intent(self.core.db, out["id"])
        self.assertEqual((out["status"], out["project"], out["cause"]), ("confirmed", "chan_new1", "confirmed by a later read"))
        self.assertEqual(len(self.calls("create_project")), 1)


if __name__ == "__main__":
    unittest.main()
