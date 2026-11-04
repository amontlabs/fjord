import unittest

import support
from support import NOW, Spy
import decide
import do
import routerd
import store


def sonnet(**out):
    return Spy(({"action": "to_project", "project": "alpha", "reason": "r", "confidence": 0.9, "alternatives": [], "answer": "", **out}, 0.1, 0.0))


def step(tool, **args):
    return {"tool": tool, "args": args}


def jev(choice="alpha", confidence=0.9, silent=0.0, setup=0.0):
    return Spy({"choice": choice, "confidence": confidence, "probabilities": {choice: confidence}, "silent": silent, "setup": setup, "ms": 1200})


class Say:
    """One say through a core with these models. `events` holds the replies, `done` the finished intent."""
    def __init__(self, test, jev_fn=None, sonnet_fn=None, words="routing test words", **target):
        self.jev, self.sonnet = jev_fn or Spy(), sonnet_fn or Spy()
        self.core, self.page = support.world(routerd.Models(self.jev, self.sonnet))
        self.events, self.done = [], []
        self.core.say(words, reply=self.events.append, finished=self.done.append, **target)
        self.page.pump(self.core)

    @property
    def intent(self):
        return next(e["intent"] for e in self.events if e["event"] == "decision")


@support.python_only("model calls (Jev, Sonnet) aren't the engine's: the app's Jev tests cover deciding")
class ToolCheck(unittest.TestCase):
    def test_an_unproved_create_holds_its_name_by_the_ids_core_keeps(self):
        core, _ = support.world()
        acted, _ = store.add_intent(core.db, NOW, "create_project", "gamma", args={"name": "gamma"}, status="failed", result={"acted": True})
        self.assertEqual(decide.tool_check(core.db, core.board(), "create_project", {"name": "gamma"}), (None, None))
        self.assertEqual(decide.tool_check(core.db, core.board(), "create_project", {"name": "gamma"}, {acted["id"]}),
                         (None, "an earlier create of gamma took, but isn't confirmed yet"))


@support.python_only("model calls (Jev, Sonnet) aren't the engine's: the app's Jev tests cover deciding")
class Explicit(unittest.TestCase):
    def test_an_explicit_project_uses_no_model(self):
        s = Say(self, project="beta")
        self.assertEqual((s.intent["tool"], s.intent["project"], s.intent["output"]["by"]), ("send_to_project", "chan_b", "explicit"))
        self.assertEqual(s.jev.calls + s.sonnet.calls, [])

    def test_an_explicit_thread_uses_no_model(self):
        s = Say(self, thread="cmsg_3")
        self.assertEqual((s.intent["tool"], s.intent["project"], s.intent["thread"]), ("reply_in_thread", "chan_b", "cmsg_3"))
        self.assertEqual(s.jev.calls + s.sonnet.calls, [])

    def test_unknown_explicit_targets_are_refused(self):
        self.assertEqual(Say(self, project="nowhere").intent["status"], "refused")
        self.assertEqual(Say(self, thread="cmsg_99").intent["status"], "refused")


@support.python_only("model calls (Jev, Sonnet) aren't the engine's: the app's Jev tests cover deciding")
class Routed(unittest.TestCase):
    def test_a_sure_jev_is_taken_and_sonnet_is_not_called(self):
        s = Say(self, jev(), words="routing test words")
        self.assertEqual((s.intent["tool"], s.intent["project"], s.intent["output"]["by"]), ("send_to_project", "chan_a", "jev"))
        self.assertEqual(s.intent["output"]["jev"]["confidence"], 0.9)
        self.assertEqual(s.sonnet.calls, [])
        self.assertEqual([e["event"] for e in s.events], ["decision"])
        self.assertEqual(s.done[0]["status"], "confirmed")
        self.assertEqual(s.page.projects["chan_a"]["chat"][-1]["text"], "routing test words")

    def test_jev_gets_the_tested_request(self):
        s = Say(self, jev(), words="routing test words")
        state, questions = s.jev.calls[0]
        self.assertEqual(state["message"], "routing test words")
        self.assertEqual(sorted(questions["route"]["criteria"]), ["alpha", "beta", "here", "unclear"])
        self.assertIn("thread: Alpha first task", "".join(v for k, v in state.items() if k.startswith("options")))

    def test_under_the_bar_jev_gives_way_to_one_sonnet_call(self):
        s = Say(self, jev(confidence=0.69), sonnet(project="beta"))
        self.assertEqual([e["event"] for e in s.events], ["thinking", "decision"])
        self.assertEqual((s.intent["project"], s.intent["output"]["by"]), ("chan_b", "sonnet"))
        self.assertEqual((len(s.jev.calls), len(s.sonnet.calls)), (1, 1))
        self.assertEqual(s.intent["output"]["jev"]["confidence"], 0.69)
        self.assertEqual(s.intent["output"]["sonnet"]["confidence"], 0.9)
        self.assertIn("<message>routing test words</message>", s.sonnet.calls[0][1])
        self.assertTrue(s.intent["context_hash"])

    def test_jev_choosing_here_goes_to_sonnet_which_answers(self):
        s = Say(self, jev("here"), sonnet(action="answer_here", answer="Two projects."))
        self.assertEqual((s.intent["status"], s.intent["cause"]), ("answered", "Two projects."))
        self.assertEqual(s.page.calls, [])

    def test_a_message_jev_is_sure_needs_no_reply_calls_nobody(self):
        s = Say(self, jev("here", 0.9, silent=0.9), words="routing test words")
        self.assertEqual((s.intent["status"], s.intent["cause"], s.intent["output"]["by"]), ("answered", "", "jev"))
        self.assertEqual([e["event"] for e in s.events], ["decision"])
        self.assertEqual((s.sonnet.calls, s.page.calls), ([], []))
        self.assertEqual(s.done[0]["status"], "answered")

    def test_silence_needs_both_answers_sure(self):
        for choice, confidence, silent in (("here", 0.69, 0.9), ("here", 0.9, 0.69), ("alpha", 0.9, 0.9)):
            self.assertEqual(decide.jev_silent(jev(choice, confidence, silent).answers[0]), False)

    def test_the_same_acknowledgement_twice_is_kept_twice(self):
        answer = jev("here", 0.9, silent=0.9).answers[0]
        s = Say(self, Spy(answer, answer))
        s.core.say("routing test words", reply=s.events.append, finished=s.done.append)
        self.assertEqual([d["status"] for d in s.done], ["answered", "answered"])
        self.assertEqual(len({d["id"] for d in s.done}), 2)

    def test_sonnet_under_its_bar_asks(self):
        s = Say(self, jev("unclear", 0.9), sonnet(confidence=0.49, alternatives=["beta"]))
        self.assertEqual(s.intent["status"], "asked")
        self.assertIn("beta", s.intent["cause"])

    def test_a_project_that_does_not_exist_is_an_ask(self):
        self.assertEqual(Say(self, jev("unclear"), sonnet(project="ghost")).intent["status"], "asked")

    def test_a_failing_jev_falls_to_sonnet(self):
        s = Say(self, Spy(RuntimeError("down")), sonnet())
        self.assertEqual((s.intent["project"], s.intent["output"]["jev"]), ("chan_a", {"error": "down"}))

    def test_both_failing_is_recorded(self):
        s = Say(self, Spy(RuntimeError("down")), Spy(RuntimeError("boom")))
        self.assertEqual(s.intent["status"], "failed")
        self.assertIn("boom", s.intent["cause"])
        self.assertEqual(s.done[0]["status"], "failed")

    def test_a_malformed_sonnet_answer_fails_and_its_waiter_hears(self):
        s = Say(self, Spy(RuntimeError("down")), Spy(({"project": "alpha"}, 0.1, 0.0)))  # no action
        self.assertEqual((s.intent["status"], [d["status"] for d in s.done]), ("failed", ["failed"]))
        self.assertIn("action", s.intent["cause"])

    def test_a_correction_is_kept_on_the_intent_and_outranks_the_destination(self):
        s = Say(self, jev())
        s.core.correct(s.intent["id"], "beta")
        self.assertEqual(store.intent(s.core.db, s.intent["id"])["correction"]["project"], "beta")
        self.assertEqual(decide.history(s.core.board(), store.intents(s.core.db))[-1], ("routing test words", "beta"))

    def test_history_names_the_project_not_its_id(self):
        s = Say(self, jev())
        self.assertEqual(decide.history(s.core.board(), store.intents(s.core.db))[-1], ("routing test words", "alpha"))

    def test_context_carries_notes_and_the_last_words(self):
        core, page = support.world(routerd.Models(jev(confidence=0.1), sonnet()))
        core.note("style", "short replies")
        core.say("first words here", project="alpha")
        core.say("second words here")
        prompt = core.models.sonnet.calls[0][1]
        self.assertIn("style: short replies", prompt)
        self.assertIn("first words here", prompt)

    def test_nothing_secret_goes_to_jev(self):
        s = Say(self, jev(), words="use sk-abcdefghijklmnopqrstuv1234 for it")
        self.assertNotIn("sk-abcdef", s.jev.calls[0][0]["message"])


@support.python_only("model calls (Jev, Sonnet) aren't the engine's: the app's Jev tests cover deciding")
class Setup(unittest.TestCase):
    def test_a_setup_request_is_never_taken_by_jev_alone(self):
        board = support.world()[0].board()
        self.assertIsNone(decide.jev_pick(board, jev("alpha", 0.99, setup=decide.SETUP_BAR).answers[0]))
        self.assertEqual(decide.jev_pick(board, jev("alpha", 0.99, setup=0.49).answers[0])["id"], "chan_a")
        s = Say(self, jev("alpha", 0.99, setup=0.9), sonnet(action="to_project", project="alpha"), words="set alpha's goal")
        self.assertEqual((len(s.jev.calls), len(s.sonnet.calls)), (1, 1))
        self.assertEqual(s.jev.calls[0][1]["setup"]["type"], "noul")

    def test_sonnets_tool_becomes_an_intent_and_runs(self):
        out = sonnet(action="tool", project="", steps=[step("create_project", name="gamma")], confidence=0.9)
        s = Say(self, jev("alpha", 0.9, setup=0.9), out, words="make a project called gamma")
        self.assertEqual([e["event"] for e in s.events], ["thinking", "decision"])
        self.assertEqual((s.intent["tool"], s.intent["words"], s.intent["output"]["by"]), ("create_project", "make a project called gamma", "sonnet"))
        self.assertEqual((s.done[0]["status"], s.done[0]["project"]), ("confirmed", "chan_new1"))

    def test_sonnets_tool_carries_its_args_and_a_grant_waits(self):
        out = sonnet(action="tool", project="", steps=[step("preapprove_folder", project="alpha", path="/p")], confidence=0.9)
        s = Say(self, jev("alpha", 0.9, setup=0.9), out)
        self.assertEqual((s.intent["status"], s.intent["project"], s.intent["args"]), ("awaiting", "chan_a", {"project": "alpha", "path": "/p"}))
        self.assertEqual(s.page.calls, [])

    def test_a_tool_sonnet_is_unsure_of_asks(self):
        out = sonnet(action="tool", project="", steps=[step("set_goal", project="alpha", text="x")], confidence=0.3)
        s = Say(self, jev("alpha", 0.9, setup=0.9), out)
        self.assertEqual(s.intent["status"], "asked")
        self.assertIn("unsure about the tool", s.intent["cause"])
        self.assertEqual(s.page.calls, [])

    def test_a_tool_sonnet_invents_is_refused(self):
        s = Say(self, jev("alpha", 0.9, setup=0.9), sonnet(action="tool", project="", steps=[step("delete_project", project="alpha")]))
        self.assertEqual((s.intent["status"], s.intent["cause"]), ("refused", "no such tool: delete_project"))

    def test_the_schema_offers_the_five_tools_and_no_delete(self):
        steps = decide.SCHEMA["properties"]["steps"]
        self.assertEqual(steps["items"]["properties"]["tool"]["enum"], ["create_project", "set_instructions", "set_goal", "add_repo", "preapprove_folder"])
        self.assertEqual((steps["type"], steps["items"]["required"]), ("array", ["tool", "args"]))
        self.assertIn("tool", decide.SCHEMA["properties"]["action"]["enum"])
        self.assertNotIn("steps", decide.SCHEMA["required"])
        self.assertIn("one step per change, in the order", decide.ROLE)
        self.assertIn("a step may name the project an earlier create_project makes", decide.ROLE)

    def test_a_plain_send_is_not_changed_by_the_tools(self):
        s = Say(self, jev(), words="routing test words")
        self.assertEqual((s.intent["tool"], s.done[0]["status"]), ("send_to_project", "confirmed"))
        s.core.tool("set_goal", project="alpha", text="g")
        s.page.pump(s.core)
        support.later(s.core, store.DUP_WINDOW + 1)
        s.core.say("routing test words", project="alpha")
        s.page.pump(s.core)
        self.assertEqual(store.intents(s.core.db, 1)[-1]["status"], "confirmed")
        self.assertEqual(decide.history(s.core.board(), store.intents(s.core.db))[-1], ("routing test words", "alpha"))


@support.python_only("model calls (Jev, Sonnet) aren't the engine's: the app's Jev tests cover deciding")
class Steps(unittest.TestCase):
    """Several setup changes in one message: one intent per step, each started once the one before it is confirmed."""
    def say(self, *steps, takes=True, lags=False):
        self.core, self.page = support.world(routerd.Models(jev("alpha", 0.9, setup=0.9), sonnet(action="tool", project="", steps=list(steps))))
        self.page.repos, self.page.connected, self.page.takes, self.page.lags = ["acme/app"], ["/Users/o/code"], takes, lags
        self.events, self.done = [], []
        self.core.say("set things up", reply=self.events.append, finished=self.done.append)
        self.page.pump(self.core)
        self.decision = next(e for e in self.events if e["event"] == "decision")
        return [store.intent(self.core.db, i["id"]) for i in self.decision.get("steps") or [self.decision["intent"]]]

    def test_a_repo_is_added_to_the_project_the_step_before_creates(self):
        create, add = self.say(step("create_project", name="site"), step("add_repo", project="site", repo="acme/app"))
        self.assertEqual([i["status"] for i in self.decision["steps"]], ["pending", "queued"])  # the owner sees both at once
        self.assertEqual((create["status"], add["status"], add["project"]), ("confirmed", "confirmed", "chan_new1"))
        self.assertEqual(self.page.projects["chan_new1"]["settings"]["repos"], ["acme/app"])
        self.assertEqual([c[0] for c in self.page.calls], ["open", "create_project", "open", "add_repo"])
        self.assertEqual([(d["id"], d["status"]) for d in self.done], [(add["id"], "confirmed")])  # the outcome is the last step's

    def test_a_failed_step_refuses_the_ones_after_it(self):
        create, goal = self.say(step("create_project", name="docs"), step("set_goal", project="docs", text="g"), takes=False)
        self.assertEqual((create["status"], goal["status"]), ("pending", "queued"))
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        create, goal = store.intent(self.core.db, create["id"]), store.intent(self.core.db, goal["id"])
        self.assertEqual((create["status"], goal["status"]), ("failed", "refused"))
        self.assertEqual(goal["cause"], "step 1 (create_project) failed: done, but not confirmed")
        self.assertEqual([c[0] for c in self.page.calls], ["open", "create_project", "open"])
        self.assertEqual([(d["id"], d["status"]) for d in self.done], [(create["id"], "failed")])

    def test_a_step_confirmed_late_says_so_on_the_steps_it_stopped(self):
        rules, goal = self.say(step("set_instructions", project="alpha", text="rules"), step("set_goal", project="alpha", text="g"), lags=True)
        support.later(self.core, do.TIMEOUT + 1)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, goal["id"])["cause"],
                         "step 1 (set_instructions) failed: done, but not confirmed: no answer from the server to the instructions (network)")
        self.page.land()
        self.page.pump(self.core)
        self.core.handle(self.page._stamp({"type": "settings", "project": "chan_a", **self.page.projects["chan_a"]["settings"], "offered_folders": None}))
        rules, goal = store.intent(self.core.db, rules["id"]), store.intent(self.core.db, goal["id"])
        self.assertEqual((rules["status"], goal["status"]), ("confirmed", "refused"))
        self.assertEqual(goal["cause"], "step 1 (set_instructions) was confirmed later, by a read; this step wasn't run")
        self.assertEqual(self.page.projects["chan_a"]["settings"]["goal"], "")

    def test_a_step_refused_at_once_refuses_the_rest_and_nothing_is_done(self):
        create, add = self.say(step("create_project", name="alpha"), step("add_repo", project="alpha", repo="acme/app"))
        self.assertEqual((create["status"], add["status"]), ("refused", "refused"))
        self.assertEqual(add["cause"], "step 1 (create_project) refused: a project named alpha already exists")
        self.assertEqual(self.page.calls, [])

    def test_wrong_arguments_in_a_later_step_refuse_every_step(self):
        goal, add = self.say(step("set_goal", project="alpha", text="g"), step("add_repo", project="alpha", repo="no-slash"))
        self.assertEqual((goal["status"], goal["cause"]), ("refused", "step 2 (add_repo) refused: a repository is owner/name"))
        self.assertEqual((add["status"], add["cause"]), ("refused", "a repository is owner/name"))
        self.assertEqual(self.page.calls, [])

    def test_a_grant_in_the_middle_waits_for_confirm_and_so_does_the_step_after_it(self):
        goal, grant, rules = self.say(step("set_goal", project="alpha", text="g"), step("preapprove_folder", project="alpha", path="/Users/o/code"),
                                      step("set_instructions", project="alpha", text="rules"))
        self.assertEqual([goal["status"], grant["status"], rules["status"]], ["confirmed", "awaiting", "queued"])
        self.assertEqual([(d["id"], d["status"]) for d in self.done], [(grant["id"], "awaiting")])
        support.later(self.core, 10 * do.TIMEOUT)
        self.core.tick()
        self.page.pump(self.core)
        self.assertEqual(store.intent(self.core.db, rules["id"])["status"], "queued")
        confirmed = []
        self.core.confirm(grant["id"], confirmed.append)
        self.page.pump(self.core)
        self.assertEqual([store.intent(self.core.db, i)["status"] for i in (grant["id"], rules["id"])], ["confirmed", "confirmed"])
        self.assertEqual([(d["id"], d["status"]) for d in confirmed], [(rules["id"], "confirmed")])
        self.assertEqual(self.page.projects["chan_a"]["settings"]["instructions"], "rules")

    def test_a_restart_refuses_the_steps_still_queued(self):
        _, rules = self.say(step("preapprove_folder", project="alpha", path="/Users/o/code"), step("set_instructions", project="alpha", text="rules"))
        routerd.Core(self.core.db, self.page.receive, clock=self.core.clock)
        rules = store.intent(self.core.db, rules["id"])
        self.assertEqual((rules["status"], rules["cause"]), ("refused", "routerd restarted before the step before it was confirmed"))

    def test_one_step_is_one_intent_as_before(self):
        (goal,) = self.say(step("set_goal", project="alpha", text="g"))
        self.assertNotIn("steps", self.decision)
        self.assertEqual((goal["status"], goal["words"], self.done[0]["id"]), ("confirmed", "set things up", goal["id"]))


if __name__ == "__main__":
    unittest.main()
