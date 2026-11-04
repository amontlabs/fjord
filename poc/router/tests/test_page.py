import unittest

import support
from support import NOW
import board as boards
import page


def stamp(event, path="/code/project/chan_a", thread=None):
    return {**event, "path": path, "thread": thread}


class Shape(unittest.TestCase):
    def test_the_project_comes_from_the_address(self):
        self.assertEqual(page.place(stamp({})), ("chan_a", None))
        self.assertEqual(page.place(stamp({}, thread="cmsg_1")), ("chan_a", "cmsg_1"))
        self.assertEqual(page.place(stamp({}, path="/code")), (None, None))
        self.assertEqual(page.place({}), (None, None))
        self.assertEqual(page.place(stamp({}, path="/code/project/chan_pending_1")), (None, None))

    def test_rows_are_shaped_and_unknown_authors_stay_unknown(self):
        rows = page.seen_rows(stamp({"type": "rows", "side": "project", "rows": [
            {"key": "cmsg_1", "index": 1, "from": "you", "text": "hi"}, {"key": "cmsg_2", "index": 2, "from": "robot", "text": "x", "decision": True, "streaming": True},
            {"key": "cmsg_3", "index": "3", "text": "bad"}, {"key": "cmsg_4", "from": "you", "text": "no index"}, {"index": 5, "from": "you", "text": "no key"}]}))
        self.assertEqual([(r["kind"], r["subject"]) for r in rows], [("chat", "chan_a")])
        self.assertEqual(rows[0]["fields"]["messages"], [{"key": "cmsg_1", "index": 1, "streaming": False, "decision": False, "from": "you", "text": "hi"},
                                                         {"key": "cmsg_2", "index": 2, "streaming": True, "decision": True, "from": "unknown", "text": "x"}])

    def test_pending_rows_are_not_messages_and_full_is_kept(self):
        rows = page.seen_rows(stamp({"type": "rows", "side": "project", "full": True, "rows": [
            {"key": "cmsg_pending_1", "pending": True, "index": 1, "from": "you", "text": "hi"}, {"key": "provisional:2", "pending": True, "index": 2, "from": "claude", "text": "…"},
            {"key": "cmsg_3", "index": 3, "from": "claude", "text": "done"}]}))
        self.assertEqual([m["key"] for m in rows[0]["fields"]["messages"]], ["cmsg_3"])
        self.assertTrue(rows[0]["fields"]["full"])

    def test_rows_whose_keys_name_another_project_are_dropped(self):
        own, other = "chan_" + "a" * 24, "b" * 24
        rows = page.seen_rows(stamp({"type": "rows", "side": "project", "rows": [
            {"key": f"cmsg_{'a' * 24}x", "index": 0, "from": "you", "text": "mine"}, {"key": f"cmsg_{other}x", "index": 1, "from": "you", "text": "stale"}]},
            path=f"/code/project/{own}"))
        self.assertEqual([m["text"] for m in rows[0]["fields"]["messages"]], ["mine"])

    def test_thread_rows_belong_to_the_thread(self):
        rows = page.seen_rows(stamp({"type": "rows", "side": "thread", "rows": [{"index": 0, "from": "claude", "text": "a"}]}, thread="cmsg_1"))
        self.assertEqual((rows[0]["kind"], rows[0]["subject"]), ("messages", "cmsg_1"))
        self.assertEqual(page.seen_rows(stamp({"type": "rows", "side": "thread", "rows": []})), [])  # no thread in the address

    def test_a_thread_of_another_project_is_dropped(self):
        a, b = "01ALdwr3Azauc1mNNjYZvRME", "01G6g7NmUd2MSNGcfuecVcNy"
        rows = page.seen_rows(stamp({"type": "threads", "threads": [{"thread": f"cmsg_{a}x1", "state": "idle"}, {"thread": f"cmsg_{b}x2", "state": "idle"}]},
                                    path=f"/code/project/chan_{a}"))
        self.assertEqual([r["subject"] for r in rows], [f"cmsg_{a}x1"])

    def test_threads_keep_known_states_only(self):
        rows = page.seen_rows(stamp({"type": "threads", "threads": [{"thread": "cmsg_1", "title": "T", "state": "needs_you", "needs": "a choice", "text": "x"},
                                                                    {"thread": "cmsg_2", "state": "dancing", "needs": ""}, {"title": "no id"}]}))
        self.assertEqual([(r["subject"], r["fields"]["state"], r["fields"]["needs"], r["fields"]["project"]) for r in rows],
                         [("cmsg_1", "needs_you", "a choice", "chan_a"), ("cmsg_2", "unknown", None, "chan_a")])

    def test_an_empty_threads_list_finishes_the_projects_threads(self):
        rows = page.seen_rows(stamp({"type": "threads", "threads": [{"thread": "cmsg_1", "state": "working"}, {"thread": "cmsg_2", "state": "needs_you", "needs": "x"}]}))
        rows += page.seen_rows(stamp({"type": "threads", "threads": [{"thread": "cmsg_9", "state": "working"}]}, path="/code/project/chan_b"))
        empty = page.seen_rows(stamp({"type": "threads", "threads": []}))
        self.assertEqual([(r["kind"], r["subject"]) for r in empty], [("threadlist", "chan_a")])
        folded = boards.fold([{**r, "id": i, "at": NOW + i} for i, r in enumerate(rows + empty, 1)])["threads"]
        self.assertEqual([(k, t["state"], t["needs"]) for k, t in sorted(folded.items())], [("cmsg_1", "idle", None), ("cmsg_2", "idle", None), ("cmsg_9", "working", None)])
        back = page.seen_rows(stamp({"type": "threads", "threads": [{"thread": "cmsg_1", "state": "working"}]}))
        again = boards.fold([{**r, "id": i, "at": NOW + i} for i, r in enumerate(rows + empty + back, 1)])["threads"]
        self.assertEqual(again["cmsg_1"]["state"], "working")

    def test_projects_keep_only_project_ids(self):
        rows = page.seen_rows({"type": "projects", "projects": [{"id": "chan_a", "name": "alpha"}, {"id": "other", "name": "x"}, {"id": "chan_pending_1", "name": "new"}]})
        self.assertEqual([(r["subject"], r["fields"]["name"], r["fields"]["where"]) for r in rows], [("chan_a", "alpha", "cloud")])

    def test_the_projects_page_list_drops_projects_it_leaves_out(self):
        partial = page.seen_rows({"type": "projects", "projects": [{"id": "chan_a", "name": "alpha"}, {"id": "chan_b", "name": "beta"}]})
        self.assertEqual([r["kind"] for r in partial], ["project", "project"])
        full = page.seen_rows({"type": "projects", "complete": True, "projects": [{"id": "chan_a", "name": "alpha"}]})
        self.assertEqual(full[-1]["fields"], {"ids": ["chan_a"]})
        rows = [{**r, "id": i, "at": NOW + i} for i, r in enumerate(partial + full, 1)]
        self.assertEqual(sorted(boards.fold(rows)["projects"]), ["chan_a"])
        self.assertEqual(sorted(boards.fold(rows[:2])["projects"]), ["chan_a", "chan_b"])

    def test_a_settings_read_is_a_seen_row_for_its_project_and_unreadable_parts_are_unknown(self):
        out = page.seen_rows(stamp({"type": "settings", "project": "chan_a", "goal": "g", "instructions": "i", "repos": ["a/b", 3], "folders": "no", "offered_folders": None}))
        self.assertEqual((out[0]["kind"], out[0]["subject"]), ("settings", "chan_a"))
        self.assertEqual(out[0]["fields"], {"goal": "g", "instructions": "i", "repos": ["a/b"], "folders": None, "offered_folders": None})
        self.assertEqual(page.seen_rows(stamp({"type": "settings", "goal": "g"}, path="/code")), [])

    def test_composer_and_page_events(self):
        rows = page.seen_rows(stamp({"type": "composer", "side": "project", "draft": "words", "disabled": True}))
        self.assertEqual((rows[0]["kind"], rows[0]["fields"]["draft"], rows[0]["fields"]["disabled"]), ("chat", "words", True))
        rows = page.seen_rows({"type": "page", "signed_in": False, "page_ok": None})
        self.assertEqual((rows[0]["kind"], rows[0]["fields"]), ("health", {"connected": True, "signed_in": False, "page_ok": None, "away": None}))

    def test_other_events_make_no_rows(self):
        self.assertEqual(page.seen_rows({"type": "done", "id": "c1", "ok": True}), [])
        self.assertEqual(page.seen_rows({"type": "nonsense"}), [])


if __name__ == "__main__":
    unittest.main()
