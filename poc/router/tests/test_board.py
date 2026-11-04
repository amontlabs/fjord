import unittest

import support
from support import NOW
import board as boards
import look
import store


def rows(*items):
    return [{"id": i + 1, "at": at, "source": src, "kind": kind, "subject": sub, "fields": f} for i, (at, src, kind, sub, f) in enumerate(items)]


class Fold(unittest.TestCase):
    def test_same_rows_same_board(self):
        data = rows((1, "page", "thread", "t1", {"project": "p", "state": "working"}), (2, "page", "thread", "t1", {"project": "p", "state": "idle"}))
        self.assertEqual(boards.fold(data), boards.fold(list(reversed(data))))

    def test_the_project_carries_its_last_settings_read(self):
        read = lambda goal: {"goal": goal, "instructions": "i", "repos": [], "folders": [], "offered_folders": None}
        board = boards.fold(rows((NOW, "page", "project", "chan_a", {"name": "alpha"}), (NOW + 1, "page", "settings", "chan_a", read("one")),
                                 (NOW + 2, "page", "settings", "chan_a", read("two"))))
        self.assertEqual(board["projects"]["chan_a"]["settings"]["goal"], "two")
        self.assertIsNone(boards.fold(rows((NOW, "page", "project", "chan_a", {"name": "alpha"})))["projects"]["chan_a"]["settings"])

    def test_a_project_new_after_a_full_list_stays_but_a_known_one_the_list_left_out_goes(self):
        board = boards.fold(rows((NOW, "page", "project", "chan_a", {"name": "a", "where": "cloud"}), (NOW + 1, "page", "project", "chan_b", {"name": "b", "where": "cloud"}),
                                 (NOW + 2, "page", "listing", "projects", {"ids": ["chan_a"]}), (NOW + 3, "page", "project", "chan_c", {"name": "c", "where": "cloud"}),
                                 (NOW + 4, "page", "project", "chan_b", {"name": "b", "where": "cloud"})))
        self.assertEqual(sorted(board["projects"]), ["chan_a", "chan_c"])

    def test_unknown_stays_unknown(self):
        board = boards.fold(rows((1, "page", "thread", "t1", {"project": "p", "state": "unknown", "needs": None})))
        self.assertEqual(board["threads"]["t1"]["state"], "unknown")
        self.assertIsNone(board["threads"]["t1"]["needs"])

    def test_files_outrank_page(self):
        board = boards.fold(rows((1, "files", "thread", "t1", {"project": "p", "state": "needs_you"}), (2, "page", "thread", "t1", {"state": "idle"})))
        self.assertEqual(board["threads"]["t1"]["state"], "needs_you")

    def test_unknown_from_a_trusted_source_does_not_hide_a_known_value(self):
        board = boards.fold(rows((1, "files", "thread", "t1", {"state": None}), (2, "page", "thread", "t1", {"state": "idle"})))
        self.assertEqual(board["threads"]["t1"]["state"], "idle")

    def test_turn_counts_each_time_it_starts_working(self):
        states = ["working", "idle", "working", "unknown", "working", "idle"]
        board = boards.fold(rows(*[(i, "page", "thread", "t1", {"state": s}) for i, s in enumerate(states)]))
        self.assertEqual(board["threads"]["t1"]["turn"], 2)

    def test_gone_process_that_is_not_finished_is_stranded(self):
        for state, expect in (("working", "stranded"), ("needs_you", "stranded"), ("idle", "idle"), ("resolved", "resolved")):
            board = boards.fold(rows((1, "files", "thread", "t1", {"alive": False}), (2, "page", "thread", "t1", {"state": state})))
            self.assertEqual(board["threads"]["t1"]["state"], expect)

    def test_claims_never_change_state(self):
        core, page = support.world()
        page.post("chan_a", "claude", "Everything is finished and the thread is done.")
        page.pump(core)
        board = core.board()
        self.assertEqual(board["threads"]["cmsg_1"]["state"], "working")
        self.assertEqual([c["text"] for c in board["claims"]], ["Everything is finished and the thread is done."])

    def test_claims_are_listed_once(self):
        core, page = support.world()
        page.post("chan_a", "claude", "note")
        page.pump(core)
        for event in page.load("chan_a"):  # a page load sends the rows on screen again
            core.handle(event)
        self.assertEqual(len(core.board()["claims"]), 1)

    def test_rows_merge_by_index_and_the_board_equals_a_fold_of_seen(self):
        core, page = support.world()
        for n in range(3):
            page.post("chan_a", "claude", f"note {n}")
            page.set_thread("chan_a", "cmsg_1", state=["idle", "working", "needs_you"][n])
            page.pump(core)
        self.assertEqual([m["text"] for m in core.board()["projects"]["chan_a"]["chat"]], ["note 0", "note 1", "note 2"])
        self.assertEqual(core.board()["threads"]["cmsg_1"]["state"], "needs_you")
        acc = boards.fold_into(boards.start(), store.seen(core.db))
        acc["here"] = core.acc["here"]  # where the tab is isn't in Seen; what is live depends on it
        folded = boards.finish(acc)
        self.assertEqual(folded["threads"]["cmsg_1"], core.board()["threads"]["cmsg_1"])
        self.assertEqual(folded["projects"]["chan_a"]["chat"], core.board()["projects"]["chan_a"]["chat"])

    def test_a_changed_row_replaces_its_old_self_by_key_and_a_full_scan_replaces_all(self):
        old = [{"key": "k1", "index": 1, "text": "a"}, {"key": "k2", "index": 2, "text": "b"}]
        rows = boards.merge_rows(old, [{"key": "k2", "index": 3, "text": "b!"}, {"key": "k3", "index": 2, "text": "c"}])
        self.assertEqual([m["text"] for m in rows], ["a", "c", "b!"])  # k2 moved: ordered by index, never twice
        rows = boards.merge_rows(old, [{"key": "k2", "index": 0, "text": "b"}], full=True)
        self.assertEqual([m["key"] for m in rows], ["k2"])

    def test_a_read_is_the_same_board_until_an_event_changes_it(self):
        core, page = support.world()
        first = core.board()
        self.assertIs(core.board(), first)
        page.set_thread("chan_a", "cmsg_1", state="idle")
        page.pump(core)
        self.assertIsNot(core.board(), first)

    def test_proof_needs_a_row_after_the_last_one_the_baseline_knew(self):
        rows = [{"key": "k1", "from": "claude", "text": "x", "index": 0}, {"key": "k2", "from": "you", "text": "hi", "index": 1}]
        board = {"projects": {"p": {"chat": rows}}, "threads": {}}
        proof = {"project": "p", "thread": None, "words": "hi", "baseline": ["k1", "k2"]}
        self.assertFalse(boards.proof_holds(board, proof))
        self.assertTrue(boards.proof_holds(board, {**proof, "baseline": ["k1"]}))
        self.assertFalse(boards.proof_holds(board, {**proof, "baseline": ["gone"]}))  # rows that hold none of its keys can't be placed: none is new
        self.assertTrue(boards.proof_holds(board, {**proof, "baseline": []}))  # an empty chat's baseline: all are new
        self.assertTrue(boards.proof_holds(board, {**proof, "baseline": []}))

    def test_a_renumbered_row_is_not_new(self):
        rows = [{"key": "k1", "from": "you", "text": "hi", "index": 0}]
        board = {"projects": {"p": {"chat": rows}}, "threads": {}}
        self.assertFalse(boards.proof_holds(board, {"project": "p", "thread": None, "words": "hi", "baseline": ["k1"]}))

    def test_words_are_compared_loosely_because_the_page_renders_markdown(self):
        board = {"projects": {"p": {"chat": [{"from": "you", "text": "Fix the bug in parse_url, then run the tests", "index": 3, "key": "k"}]}}, "threads": {}}
        words = "fix the **bug** in `parse_url`,\nthen run the *tests*"
        self.assertTrue(boards.proof_holds(board, {"project": "p", "thread": None, "words": words, "baseline": []}))
        self.assertFalse(boards.proof_holds(board, {"project": "p", "thread": None, "words": "something else", "baseline": []}))

    def test_an_unreadable_place_proves_nothing(self):
        board = {"projects": {"p": {"chat": None}}, "threads": {}}
        self.assertIsNone(boards.proof_holds(board, {"project": "p", "thread": None, "words": "hi", "baseline": []}))

    def test_seen_is_append_only(self):
        db = support.memory_db()
        store.add_seen(db, NOW, [look.row("page", "health", "page", connected=True)])
        with self.assertRaises(Exception):
            db.execute("delete from seen")
        with self.assertRaises(Exception):
            db.execute("update seen set kind = 'x'")


class Age(unittest.TestCase):
    """The page shows live state only for the project open in the tab: a cloud thread elsewhere is as of the last visit."""

    def board(self, here=None):
        acc = boards.fold_into(boards.start(), rows((NOW, "page", "thread", "cmsg_1", {"project": "chan_a", "state": "working"}),
                                                    (NOW + 50, "page", "chat", "chan_a", {"messages": []}),
                                                    (NOW + 90, "page", "thread", "cmsg_2", {"project": "chan_b", "state": "idle"}),
                                                    (NOW + 95, "files", "thread", "local:x", {"project": "local:x", "state": "working", "alive": True})))
        acc["here"] = here
        return boards.finish(acc)

    def test_a_cloud_thread_of_a_project_not_shown_is_as_of_its_projects_last_page_row(self):
        board = self.board(here=("chan_b", None))
        self.assertEqual(board["threads"]["cmsg_1"]["as_of"], NOW + 50)
        self.assertEqual(board["projects"]["chan_a"]["seen"], NOW + 50)

    def test_the_same_thread_is_live_while_its_project_is_the_open_place(self):
        self.assertIsNone(self.board(here=("chan_a", None))["threads"]["cmsg_1"]["as_of"])
        self.assertIsNone(self.board(here=("chan_a", "cmsg_1"))["threads"]["cmsg_1"]["as_of"])

    def test_local_threads_never_carry_an_age(self):
        for here in (None, ("chan_a", None)):
            self.assertIsNone(self.board(here)["threads"]["local:x"]["as_of"])

    def test_a_page_thread_whose_state_comes_from_files_is_live(self):
        board = boards.fold(rows((NOW, "page", "thread", "cmsg_1", {"project": "chan_a", "state": "working"}),
                                 (NOW + 1, "files", "thread", "cmsg_1", {"state": "needs_you", "alive": True})))
        self.assertIsNone(board["threads"]["cmsg_1"]["as_of"])


if __name__ == "__main__":
    unittest.main()
