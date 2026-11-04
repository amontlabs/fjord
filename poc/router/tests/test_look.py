import json
import os
import tempfile
import unittest

import support
from support import NOW
import look


def write_session(root, name, **more):
    d = {"cliSessionId": name, "title": f"title {name}", "cwd": "/Users/someone/code/alpha", "lastActivityAt": (NOW - 3600) * 1000, "postTurnSummary": {}, **more}
    os.makedirs(os.path.join(root, "a", "b"), exist_ok=True)
    with open(os.path.join(root, "a", "b", f"local_{name}.json"), "w") as f:
        json.dump(d, f)


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class Sessions(unittest.TestCase):
    def read(self, **files):
        with tempfile.TemporaryDirectory() as root:
            for name, more in files.items():
                write_session(root, name, **more)
            return look.read_local(os.path.join(root, "*", "*", "local_*.json"), os.path.join(root, "none", "*.json"), NOW, "/Users/someone", apps=[1])

    def test_old_archived_and_scratch_sessions_stay_off_the_board(self):
        out = self.read(fresh={}, old={"lastActivityAt": (NOW - 22 * 86400) * 1000}, archived={"isArchived": True}, home={"cwd": "/Users/someone"},
                        temp={"cwd": "/tmp/x"}, nofolder={"cwd": None})
        self.assertEqual([s["cli"] for s in out["sessions"].values()], ["fresh"])

    def test_a_project_thread_child_is_kept_only_to_link_and_has_no_folder_of_its_own(self):
        out = self.read(kid={"cwd": None, "remoteControlSpawn": {"projectThreadChild": True, "ccrSessionId": "session_X1", "folder": "/Users/someone/code/alpha"}})
        info = out["sessions"]["cse_X1"]
        self.assertEqual((info["child"], info["folder"]), (True, "/Users/someone/code/alpha"))

    def test_the_session_files_own_activity_time_is_kept(self):
        self.assertEqual(self.read(a={})["sessions"]["cli:a"]["active"], NOW - 3600)

    def test_the_summary_becomes_the_detail_and_the_category_is_kept(self):
        out = self.read(a={"postTurnSummary": {"status_detail": "Waiting for review", "status_category": "review_ready", "needs_action": ""}})
        self.assertEqual((out["sessions"]["cli:a"]["detail"], out["sessions"]["cli:a"]["category"]), ("Waiting for review", "review_ready"))


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class State(unittest.TestCase):
    def test_mapping(self):
        cases = [({"category": "review_ready"}, None, "idle"), ({"category": "completed"}, None, "resolved"), ({"category": "blocked"}, None, "needs_you"),
                 ({"needs": "Should I push?"}, None, "needs_you"), ({"interrupted": True}, None, "needs_you"), ({"category": "completed"}, "busy", "working"),
                 ({}, None, "unknown"), ({"category": "completed"}, "idle", "resolved")]
        for info, status, expect in cases:
            self.assertEqual(look.local_state(info, status), expect, info)

    def test_a_busy_process_makes_the_thread_working_and_unknown_stays_unknown(self):
        core, page = support.world()
        local = {"sessions": {"cse_2": support.local_info("c2", category="review_ready"), "cse_1": support.local_info("c1")},
                 "processes": {"c2": True, "c1": True}, "statuses": {"c2": "busy", "c1": "idle"}}
        core.local(local)
        threads = core.board()["threads"]
        self.assertEqual(threads["cmsg_2"]["state"], "working")
        self.assertEqual(threads["cmsg_1"]["state"], "working")  # the page says working; files know nothing more


    def test_files_know_the_age_and_the_doing_line(self):
        core, page = support.world()
        core.local({"sessions": {"cse_2": support.local_info("c2", category="review_ready", detail="Reviewing the diff")}, "processes": {}})
        t = core.board()["threads"]["cmsg_2"]
        self.assertEqual((t["touched"], t["detail"], t["state"]), (NOW - 7200, "Reviewing the diff", "idle"))


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class Gone(unittest.TestCase):
    def test_a_local_project_missing_from_the_latest_pass_leaves_the_board(self):
        core, page = support.world()
        core.local({"sessions": {"cse_8": support.local_info("c8", folder="/Users/x/old"), "cse_9": support.local_info("c9", folder="/Users/x/new")},
                    "processes": {}})
        self.assertIn("local:old", core.board()["projects"])
        support.later(core)
        core.local({"sessions": {"cse_9": support.local_info("c9", folder="/Users/x/new")}, "processes": {}})
        board = core.board()
        self.assertNotIn("local:old", board["projects"])
        self.assertNotIn("local:c8", board["threads"])
        self.assertIn("local:new", board["projects"])

    def test_a_pass_that_changes_nothing_writes_nothing(self):
        core, page = support.world()
        local = {"sessions": {"cse_9": support.local_info("c9", folder="/Users/x/new")}, "processes": {}}
        core.local(local)
        rows = core.db.execute("select count(*) from seen").fetchone()[0]
        support.later(core)
        core.local(local)
        self.assertEqual(core.db.execute("select count(*) from seen").fetchone()[0], rows)


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class Purpose(unittest.TestCase):
    def purpose(self, text):
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "README.md"), "w") as f:
                f.write(text)
            return look.purpose(folder)

    def test_html_images_and_badges_are_dropped(self):
        text = '# Name\n\n<p align="center"><img src="x.png" width="80"></p>\n<br>\n[![ci](a.svg)](b)\n\nA tool that does one thing well. It has more.\n'
        self.assertEqual(self.purpose(text), "A tool that does one thing well. It has more.")

    def test_tags_inside_a_line_and_links_are_stripped(self):
        self.assertEqual(self.purpose("Reads <b>your</b> [notes](http://x) fast<br>"), "Reads your notes fast")

    def test_no_readme_is_empty(self):
        self.assertEqual(look.purpose("/nonexistent"), "")


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class Stat(unittest.TestCase):
    def test_unchanged_files_are_not_read_again(self):
        look._FILES.clear()
        with tempfile.TemporaryDirectory() as root:
            write_session(root, "a")
            readme = os.path.join(root, "README.md")
            with open(readme, "w") as f:
                f.write("One sentence here.")
            pattern = os.path.join(root, "*", "*", "local_*.json")
            loads = []
            load = look.load_json
            look.load_json = lambda p: loads.append(p) or load(p)
            try:
                look.read_local(pattern, os.path.join(root, "none", "*.json"), NOW, "/Users/someone", apps=[1])
                look.read_local(pattern, os.path.join(root, "none", "*.json"), NOW, "/Users/someone", apps=[1])
                self.assertEqual(len(loads), 1)
                self.assertEqual(look.purpose(root), "One sentence here.")
                with open(readme, "w") as f:
                    f.write("A different sentence.")
                self.assertEqual(look.purpose(root), "A different sentence.")
            finally:
                look.load_json = load


@support.python_only("look.py's session reading becomes the app's own: Swift unit tests cover it")
class Link(unittest.TestCase):
    def setUp(self):
        self.core, self.page = support.world(session=False)  # the live page gives no session id

    def add_beta_thread(self):
        self.page.add_thread("chan_b", "cmsg_9", "Alpha first task")
        self.page.set_thread("chan_b", "cmsg_9", state="idle")
        self.page.pump(self.core)

    def child(self, title, **more):
        return support.local_info("k1", folder="/Users/x/alpha", title=title, child=True, **more)

    def test_a_child_links_to_the_page_thread_with_its_title(self):
        local = {"sessions": {"cse_K": self.child("Alpha first task", detail="Editing the parser")}, "processes": {"k1": False}}
        self.core.local(local)
        board = self.core.board()
        t = board["threads"]["cmsg_1"]
        self.assertEqual((t["state"], t["detail"], t["alive"]), ("stranded", "Editing the parser", False))
        self.assertFalse([k for k in board["threads"] if k.startswith("local:")])

    def test_an_unmatched_child_adds_nothing(self):
        self.core.local({"sessions": {"cse_K": self.child("No such thread")}, "processes": {}})
        board = self.core.board()
        self.assertEqual(sorted(board["threads"]), ["cmsg_1", "cmsg_2", "cmsg_3"])
        self.assertFalse([k for k in board["projects"] if k.startswith("local:")])

    def test_a_repeated_title_is_told_apart_by_the_folder(self):
        self.add_beta_thread()
        self.core.local({"sessions": {"cse_K": self.child("Alpha first task", detail="in alpha")}, "processes": {}})
        threads = self.core.board()["threads"]
        self.assertEqual((threads["cmsg_1"]["detail"], threads["cmsg_9"]["detail"]), ("in alpha", None))

    def test_a_title_in_two_projects_with_no_folder_match_is_left_alone(self):
        self.add_beta_thread()
        local = {"sessions": {"cse_K": support.local_info("k1", folder="/Users/x/gamma", title="Alpha first task", child=True)}, "processes": {}}
        self.core.local(local)
        self.assertIsNone(self.core.board()["threads"]["cmsg_1"]["detail"])


if __name__ == "__main__":
    unittest.main()
