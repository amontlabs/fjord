"""Router open-items engine: how many model reads a day would the owner's real days cost? Counts only, no text.

One read per turn end (an ended run with assistant text) and per owner message (createdBy user). Messages that came
after a turn on the same thread the same (local) day are an upper bound for the reads of messages that arrive when a
thread has something open. Reads ~/.t3/userdata/statev2.sqlite read-only; non-subagent threads only.

    python3 evals/router/items/calls.py [--days 7]
"""
import argparse, collections, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from export import load, steps_of


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    a = ap.parse_args()
    since, threads, msgs, runs = load(a.days)
    day = lambda s: s["_t"].astimezone().date().isoformat()
    turns, owner, after = (collections.Counter() for _ in range(3))
    for tid in threads:
        seen = set()
        for s in steps_of(tid, msgs, runs):
            if s["_t"] < since:
                continue
            d = day(s)
            if s["kind"] == "turn":
                turns[d] += 1; seen.add(d)
            else:
                owner[d] += 1
                after[d] += d in seen
    days = sorted(set(turns) | set(owner))
    print(f"{'day':<12}{'turn ends':>10}{'owner msgs':>12}{'after a turn':>14}{'total':>8}")
    tot = {d: turns[d] + owner[d] for d in days}
    for d in days:
        print(f"{d:<12}{turns[d]:>10}{owner[d]:>12}{after[d]:>14}{tot[d]:>8}")
    print(f"average {sum(tot.values()) / len(days):.0f}/day, busiest {max(days, key=tot.get)} ({max(tot.values())}); "
          f"upper bound with only after-a-turn messages: {sum(turns[d] + after[d] for d in days) / len(days):.0f}/day")


if __name__ == "__main__":
    main()
