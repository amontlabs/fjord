import unittest

import fake_page
import support
from support import NOW
import routerd
import store
import tell
import board as boards


def thread(state, turn, detail="", **more):
    return {"id": "t1", "project": "p", "title": "Task", "state": state, "turn": turn, "needs": None, "detail": detail, "text": "", **more}


def board(*threads):
    return {"threads": {t["id"]: t for t in threads}, "projects": {}, "claims": []}


class Facts(unittest.TestCase):
    def test_finished_is_keyed_by_the_change(self):
        found = tell.facts(board(thread("working", 1)), board(thread("idle", 1)))
        self.assertEqual([f["key"] for f in found], ["t1|finished|1"])

    def test_no_change_no_fact(self):
        self.assertEqual(tell.facts(board(thread("working", 1)), board(thread("working", 1))), [])

    def test_new_thread_already_idle_is_not_a_finish(self):
        self.assertEqual(tell.facts(board(), board(thread("idle", 1))), [])

    def test_needs_you_and_a_next_turn(self):
        self.assertEqual(tell.facts(board(thread("working", 1)), board(thread("needs_you", 1)))[0]["key"], "t1|needs_you|1")
        self.assertEqual(tell.facts(board(thread("idle", 1)), board(thread("idle", 2)))[0]["key"], "t1|finished|2")

    def test_a_second_question_on_the_same_turn_is_a_new_fact(self):
        a = thread("needs_you", 1, needs="which db")
        self.assertEqual(tell.facts(board(thread("working", 1)), board(a))[0]["key"], "t1|needs_you|1")
        rows = [{"id": i, "at": NOW + i, "kind": "thread", "subject": "t1", "source": "page", "fields": {"project": "p", "state": "needs_you", "needs": n}}
                for i, n in enumerate(("which db", "which db", "which port"), 1)]
        after = boards.fold(rows)
        self.assertEqual(after["threads"]["t1"]["turn"], 2)

    def test_the_key_ignores_wording(self):
        a = tell.facts(board(thread("working", 1)), board(thread("idle", 1, detail="one way")))[0]
        b = tell.facts(board(thread("working", 1)), board(thread("idle", 1, detail="another way")))[0]
        self.assertEqual(a["key"], b["key"])

    def test_a_fact_from_an_earlier_visit_is_told_with_its_age_at_the_time_of_telling(self):
        f = tell.facts(board(thread("working", 1)), board(thread("needs_you", 1, as_of=NOW - 600)))[0]
        self.assertEqual(tell.plan([f], {}, [], NOW)[0][0]["text"], "Task: needs you (as of 10m ago)")
        self.assertEqual(tell.plan([f], {}, [], NOW + 3600)[0][0]["text"], "Task: needs you (as of 1h ago)")
        self.assertEqual(f["key"], "t1|needs_you|1")  # the key is the change, whatever its age

    def test_a_live_fact_is_told_as_it_is(self):
        f = tell.facts(board(thread("working", 1)), board(thread("needs_you", 1, as_of=None)))[0]
        self.assertEqual(tell.plan([f], {}, [], NOW)[0][0]["text"], "Task: needs you")


class TellOnce(unittest.TestCase):
    def setUp(self):
        self.core, self.page = support.world()
        self.page.post("chan_a", "you", "an earlier message")  # a chat seen with rows: what comes next is news
        self.page.pump(self.core)
        self.core.tell()  # the first brief covers the starting state

    def look(self, seconds=10):
        support.later(self.core, seconds)
        self.page.pump(self.core)
        return self.core.tell()

    def finish(self):
        self.page.set_thread("chan_a", "cmsg_1", state="idle")

    def test_a_thread_post_and_the_coordinator_repeat_are_one_fact(self):
        self.finish()
        self.assertEqual(len(self.look()), 1)
        self.page.post("chan_a", "claude", "That task is done.")
        self.assertEqual(self.look(), [])
        self.assertEqual(self.look(), [])

    def test_the_coordinator_first_makes_the_thread_post_quiet(self):
        self.page.post("chan_a", "claude", "Heads up, the first task wrapped up.")
        self.assertEqual(len(self.look()), 1)
        self.finish()
        self.assertEqual(self.look(), [])

    def test_a_needs_you_is_told_even_after_a_coordinator_claim(self):
        self.page.post("chan_a", "claude", "Heads up, the first task wrapped up.")
        self.assertEqual(len(self.look()), 1)
        self.page.set_thread("chan_a", "cmsg_1", state="needs_you", needs="a choice")
        self.assertEqual(len(self.look()), 1)

    def test_a_coordinator_question_is_told_after_a_thread_needs_you(self):
        self.page.set_thread("chan_a", "cmsg_1", state="needs_you", needs="a choice")
        self.assertEqual(len(self.look()), 1)
        self.page.post("chan_a", "claude", "Which one do you want?")
        self.assertEqual(len(self.look()), 1)

    def test_a_finish_long_after_a_claim_is_told(self):
        self.page.post("chan_a", "claude", "Heads up, the first task wrapped up.")
        self.assertEqual(len(self.look()), 1)
        support.later(self.core, tell.WINDOW + 1)
        self.finish()
        self.assertEqual(len(self.look()), 1)

    def test_a_coordinator_message_with_a_decision_is_told_even_when_matching(self):
        self.finish()
        self.page.post("chan_a", "claude", "Done.", decision=True)
        self.assertEqual(len(self.look()), 2)

    def test_old_chat_on_the_first_look_is_recorded_not_told(self):
        self.page.post("chan_b", "claude", "An old message.")
        core, page = support.world(page=self.page)  # a fresh process that has never seen this chat
        self.assertNotIn("An old message.", core.tell())
        page.post("chan_b", "claude", "A new message.", decision=True)
        for event in page.load("chan_b"):  # the tab goes to beta and shows it
            core.handle(event)
        self.assertEqual(core.tell(), ["A new message."])

    def test_a_coordinator_message_with_no_thread_change_is_told_once(self):
        self.page.post("chan_a", "claude", "Waiting on nothing.")
        self.assertEqual(len(self.look()), 1)
        self.assertEqual(self.look(), [])

    def test_the_first_reply_in_an_empty_chat_is_told_though_the_tab_moved_away(self):
        page = fake_page.demo()
        page.add_project("chan_c", "gamma")
        core, page = support.world(page=page)
        core.tell()
        page.holds = True
        core.say("start the new thing", project="chan_c")
        page.pump(core)
        core.say("and alpha too", project="chan_a")
        page.pump(core)
        page.deliver("chan_c")
        page.post("chan_c", "claude", "which database should it use?")
        support.later(core, routerd.ACCEPTED_WAIT + 1)
        core.tick()
        page.pump(core)
        self.assertEqual(core.tell(), ["which database should it use?"])

    def test_two_messages_with_the_same_words_are_two_facts(self):
        self.page.post("chan_a", "claude", "OK")
        self.assertEqual(len(self.look()), 1)
        self.page.post("chan_a", "claude", "OK")
        self.assertEqual(len(self.look()), 1)

    def test_told_suppresses_repeats_and_a_later_version_updates_quietly(self):
        self.finish()
        self.assertEqual(len(self.look()), 1)
        self.page.set_thread("chan_a", "cmsg_1", text="a fuller summary")
        self.assertEqual(self.look(), [])
        self.assertEqual(store.told(self.core.db)["cmsg_1|finished|1"]["detail"], "a fuller summary")

    def test_a_finish_between_two_tells_is_not_lost_to_a_later_change(self):
        self.finish()
        self.page.pump(self.core)
        self.page.set_thread("chan_a", "cmsg_1", state="working")
        self.page.pump(self.core)
        self.assertEqual(len(self.core.tell()), 1)

    def test_a_restart_keeps_what_was_told_and_what_was_not(self):
        self.finish()
        self.page.pump(self.core)  # seen, not yet told
        again, page = support.world(db=self.core.db, page=self.page)
        self.assertEqual(len(again.tell()), 1)
        self.assertEqual(again.tell(), [])


class Lost(unittest.TestCase):
    """A thread losing its process, and the Claude app closing, are each told once."""
    def setUp(self):
        self.core, self.page = support.world()
        self.page.set_thread("chan_a", "cmsg_2", state="working")
        self.page.pump(self.core)
        self.local({"c1": True, "c2": True}, True)
        self.core.tell()

    def local(self, processes, app):
        support.later(self.core)
        sessions = {"cse_1": support.local_info("c1", detail="Editing the parser"), "cse_2": support.local_info("c2", detail="")}
        self.core.local({"sessions": sessions, "processes": processes, "app": app})

    def test_a_working_thread_that_loses_its_process_is_told_once(self):
        self.local({"c2": True}, True)
        self.assertEqual(self.core.tell(), ["«Alpha first task» lost its process; last: Editing the parser. Reply to continue it in a new thread."])
        self.local({"c2": True}, True)
        self.assertEqual(self.core.tell(), [])

    def test_one_line_per_stranded_thread(self):
        self.local({}, True)
        self.assertEqual(len(self.core.tell()), 2)

    def test_a_finished_thread_losing_its_process_is_not_news(self):
        self.page.set_thread("chan_a", "cmsg_2", state="idle")
        self.page.pump(self.core)
        self.core.tell()
        self.local({"c1": True}, True)
        self.assertEqual(self.core.tell(), [])

    def test_the_app_closing_is_one_line_for_all_its_threads_and_none_is_stranded(self):
        self.local({}, False)
        self.assertEqual(self.core.tell(), ["Claude app closed; 2 threads waiting"])
        self.local({}, False)
        self.assertEqual(self.core.tell(), [])

    def test_threads_back_with_the_app_are_not_news(self):
        self.local({}, False)
        self.core.tell()
        self.local({"c1": True, "c2": True}, True)
        self.assertEqual(self.core.tell(), [])

    def test_threads_the_app_did_not_bring_back_are_told_as_lost(self):
        self.local({}, False)
        self.core.tell()
        self.local({"c2": True}, True)
        self.assertEqual(len(self.core.tell()), 1)

    def test_a_loss_that_is_back_before_the_tell_is_not_told(self):
        self.local({"c2": True}, True)
        self.local({"c1": True, "c2": True}, True)
        self.assertEqual(self.core.tell(), [])
        self.local({}, False)
        self.local({"c1": True, "c2": True}, True)
        self.assertEqual(self.core.tell(), [])


if __name__ == "__main__":
    unittest.main()
