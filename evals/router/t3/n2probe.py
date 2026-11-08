"""N2: written Fjord-intent probes for the "for Fjord itself?" check on Jev's path -> data/n2_probe_jev.jsonl.

T3 history holds no message meant for Fjord itself (those never reached a thread), so the check's recall can't be measured on
the moments. These are written messages for the manager (questions about the board, changes to Fjord, bare acknowledgements),
each put on a seeded random dev board, asked with the jev2 request. Written cases misled routing evals before, so this only
bounds how often the path would send such a message to a thread with the check on, raised or off."""
import concurrent.futures as cf
import json
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from run import load_moments, make_board  # noqa: E402
import n2  # noqa: E402

DATA = pathlib.Path(__file__).parent / "data"
PROBES = [
    # questions about the board or all threads
    "what's running right now?", "anything waiting on me?", "which threads finished since this morning?",
    "what did the agents do overnight", "is anything stuck?", "how many threads are open in that project", "summarize today's work",
    "what's left to review", "which one is waiting for my answer", "did any build fail today?",
    "what am I supposed to look at next", "give me the status of everything", "any PRs ready to merge?",
    # board actions and changes to Fjord
    "archive the finished ones", "archive everything older than a day", "pin the release thread",
    "stop showing me the eval threads", "mute notifications for an hour", "rename the project to fjord-app",
    "make the bar smaller", "switch to the dark theme", "hide the brief for now", "send new work to opus by default",
    "don't auto-send anymore, always ask me", "add a project for the website repo",
    # bare acknowledgements with no thread to react to
    "ok", "thanks", "got it", "cool", "nice",
]


def main():
    dev = [m for m in load_moments() if m["split"] == "dev" and m["cls"] == "follow" and len(m["board"]["threads"]) >= 3]
    rng = random.Random(41)
    todo = []
    for k, text in enumerate(PROBES):
        m = dict(rng.choice(dev)); m["message"] = text; m["id"] = f"probe{k}"
        todo.append(m)
    with cf.ThreadPoolExecutor(4) as ex:
        rows = list(ex.map(n2.call_jev2, todo))
    with open(DATA / "n2_probe_jev.jsonl", "w") as f:
        for k, r in enumerate(rows):
            r["kind"] = "ack" if k >= 25 else ("action" if k >= 13 else "question")
            f.write(json.dumps(r) + "\n")
    print("probes", len(rows))


if __name__ == "__main__":
    main()
