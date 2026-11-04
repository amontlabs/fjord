#!/usr/bin/env python3
"""Where does a project's coordinator put each message? Sends a fixed list, one at a time, and logs the outcome.

  coordinator_test.py <channel> <out.jsonl>

`expect` is written before the run: new (a new thread, or a quick answer in the conversation), or the key of the
earlier message whose thread should get this one, or here (no thread at all).
"""
import json
import pathlib
import re
import subprocess
import sys
import time

CLIENT = pathlib.Path(__file__).resolve().parents[3] / ".build" / "projects-poc"
MESSAGES = [
    ("junie", "In lcu, what does adapters/junie.mjs do? Two sentences. Don't change anything.", "new"),
    ("junie-tests", "which tests cover it?", "junie"),
    ("bundle", "How does the release bundle get built? Short answer, don't change anything.", "new"),
    ("bundle-junie", "and does it include the Junie adapter?", "bundle"),
    ("junie-win", "back to the Junie one: does it work on Windows? Don't change anything.", "junie"),
    ("approve", "How does per-app approval work in lcu? Keep it short, no changes.", "new"),
    ("approve-store", "where are those approvals stored?", "approve"),
    ("count", "how many threads are running right now?", "here"),
    ("version", "Would a --version flag on the lcu CLI be easy to add? Just tell me, change nothing.", "new"),
    ("thanks", "ok thanks", "here"),
]
QUIET, LIMIT = 20, 240


def timeline(channel):
    return json.loads(subprocess.run([CLIENT, "timeline", channel], capture_output=True, text=True, timeout=60).stdout)


def notice(row):
    kind = re.search(r'"kind":"(\w+)"', row["body"]) if row["notice"] else None
    session = re.search(r'"session_id":"(\w+)"', row["body"])
    return {"kind": kind.group(1), "session": session.group(1) if session else None} if kind else None


def main():
    channel, out = sys.argv[1], pathlib.Path(sys.argv[2])
    done = {json.loads(l)["key"] for l in out.read_text().splitlines()} if out.exists() else set()
    for key, text, expect in MESSAGES:
        if key in done:
            continue
        before = {r["id"] for r in timeline(channel)}
        started = time.time()
        sent = json.loads(subprocess.run([CLIENT, "send", channel, text], capture_output=True, text=True, timeout=60).stdout)
        rows, last_change, seen = [], time.time(), set(before)
        while time.time() - started < LIMIT:
            time.sleep(5)
            current = timeline(channel)
            fresh = [r for r in current if r["id"] not in seen]
            if fresh:
                seen.update(r["id"] for r in fresh)
                rows += fresh
                last_change = time.time()
            if rows and time.time() - last_change > QUIET and not any(r["working"] for r in current):
                break
        events = [n for n in map(notice, reversed(rows)) if n]
        replies = [r["body"][:200] for r in reversed(rows) if not r["notice"] and r["from"] != "you"]
        with out.open("a") as f:
            f.write(json.dumps({"key": key, "text": text, "expect": expect, "message_id": sent.get("message_id"),
                                "events": events, "replies": replies, "seconds": round(time.time() - started)}) + "\n")


if __name__ == "__main__":
    main()
