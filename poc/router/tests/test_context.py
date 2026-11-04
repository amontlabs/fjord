import unittest

import support
from support import NOW
import context


def board(n_threads=0, purpose="x" * 140):
    threads = {f"cmsg_{i}": {"id": f"cmsg_{i}", "project": "p", "title": f"Task {i}", "state": "working", "needs": None,
                             "detail": "d" * 100, "touched": NOW - i} for i in range(n_threads)}
    return {"projects": {"p": {"id": "p", "name": "alpha", "where": "cloud", "purpose": purpose}}, "threads": threads, "claims": []}


def intent(words, **more):
    return {"id": 1, "at": NOW - 60, "tool": "send_to_project", "status": "confirmed", "words": words, "project": "p", "correction": None, **more}


class Context(unittest.TestCase):
    def test_same_input_same_text_and_hash(self):
        a = context.build(board(3), {"tone": "short"}, [intent("hello")], NOW)
        self.assertEqual(a, context.build(board(3), {"tone": "short"}, [intent("hello")], NOW))

    def test_it_never_goes_over_the_cap(self):
        text, _ = context.build(board(500), {f"n{i}": "y" * 200 for i in range(10)}, [intent("z" * 500) for _ in range(30)], NOW, cap=3000)
        self.assertLessEqual(len(text), 3000)
        self.assertIn("alpha | cloud", text)

    def test_the_most_urgent_threads_survive_a_small_cap(self):
        b = board(40)
        b["threads"]["cmsg_39"]["state"] = "needs_you"
        text, _ = context.build(b, {}, [], NOW, cap=1200)
        self.assertIn("cmsg_39", text)

    def test_messages_name_the_project_not_its_id(self):
        text, _ = context.build(board(), {}, [intent("hello")], NOW)
        self.assertIn("to alpha: hello", text)

    def test_only_the_last_eight_messages_with_the_corrected_destination(self):
        intents = [intent(f"message {i}") for i in range(12)]
        intents[-1]["correction"] = {"project": "beta"}
        text, _ = context.build(board(), {}, intents, NOW)
        self.assertNotIn("message 3", text)
        self.assertIn("message 4", text)
        self.assertIn("to beta (corrected): message 11", text)

    def test_idle_threads_untouched_for_a_day_are_left_out(self):
        b = board(2)
        b["threads"]["cmsg_1"].update(state="idle", touched=NOW - 3 * 86400)
        text, _ = context.build(b, {}, [], NOW)
        self.assertIn("cmsg_0", text)
        self.assertNotIn("cmsg_1", text)

    def test_a_state_from_an_earlier_visit_says_its_age_and_the_age_moves_with_the_clock(self):
        b = board(2)
        b["threads"]["cmsg_1"]["as_of"] = NOW - 3 * 3600
        line = lambda now: next(l for l in context.build(b, {}, [], now)[0].splitlines() if "cmsg_1" in l)
        self.assertIn("| working (as of 3h ago)", line(NOW))
        self.assertIn("| working (as of 5h ago)", line(NOW + 2 * 3600))
        self.assertNotIn("as of", next(l for l in context.build(b, {}, [], NOW)[0].splitlines() if "cmsg_0" in l))


if __name__ == "__main__":
    unittest.main()
