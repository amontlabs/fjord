#!/usr/bin/env python3
"""Runs the whole Router POC on a scripted list: manager, then delivery, then wait until the project settles.

  POC_ONLY=<project> POC_ALIASES='{"<project>":"<folder>"}' messy_test.py <messages.json> <out.jsonl>

Each message is [key, expect, text]. expect is alternatives split by |: new or new:<stream>, a stream name, here,
ask, other. The list lives outside the repo because it is modeled on real messages.
"""
import json
import pathlib
import re
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import router

QUIET, LIMIT = 15, 200


def rows(channel):
    return router.client("timeline", channel)


def settle(channel, before):
    started, changed, seen, fresh = time.time(), time.time(), set(before), []
    while time.time() - started < LIMIT:
        time.sleep(4)
        current = rows(channel)
        new = [r for r in current if r["id"] not in seen]
        if new:
            seen.update(r["id"] for r in new)
            fresh += new
            changed = time.time()
        if time.time() - changed > QUIET and not any(r["working"] for r in current):
            break
    return fresh


def landed(fresh):
    for r in reversed(fresh):
        found = re.search(r'"kind":"(thread_started|message_routed)".*?"session_id":"(\w+)"', r["body"]) if r["notice"] else None
        if found:
            return found.group(1), found.group(2)
    return None, None


def main():
    messages, out = json.load(open(sys.argv[1])), pathlib.Path(sys.argv[2])
    done = [json.loads(l) for l in out.read_text().splitlines()] if out.exists() else []
    streams = {d["stream"]: d["landed"] for d in done if d.get("stream") and d.get("landed")}
    keys = {d["key"] for d in done}
    for key, expect, text in messages:
        if key in keys:
            continue
        projects = router.world()
        channel = next(g["channel"] for g in projects if g["channel"])
        prompt = router.route_prompt(projects, text)
        decision, seconds, cost = router.decide(router.ROUTE_ROLE, prompt, router.ROUTE_SCHEMA, "claude-sonnet-5-5", projects)
        decision = router.settled(projects, decision, "claude-sonnet-5-5", prompt)
        asked = decision["action"] == "ask"
        if asked:  # stands in for your click: the right place when the list says there is one
            pick = next((e for e in expect.split("|") if e in streams), None)
            if pick:
                decision = {**decision, "action": "follow_up", "session": streams[pick], "project": "lcu"}
            elif any(e.startswith("new") for e in expect.split("|")):
                decision = {**decision, "action": "new_work", "session": "", "project": "lcu"}
        before = {r["id"] for r in rows(channel)}
        group = next((g for g in projects if g["project"] == decision["project"]), None)
        session = next((s for g in projects for s in g["sessions"] if s["id"] == decision["session"]), None)
        route, where = "none", None
        if decision["action"] == "follow_up" and session and session["thread"] and session["connected"]:
            router.client("send", channel, text, session["thread"])
            route, where = "direct", session["id"]
        elif decision["action"] == "new_work" and group and group["channel"]:
            router.client("send", channel, text)
            route = "coordinator"
        fresh = settle(channel, before) if route != "none" else []
        kind, session_id = landed(fresh)
        router.remember(text, decision, session["title"] if session else None)
        where = session_id or where
        stream = next((e.split(":")[1] for e in expect.split("|") if e.startswith("new:")), None)
        if stream and kind == "thread_started":
            streams[stream] = where
        names = {v: k for k, v in streams.items()}
        record = {"key": key, "text": text, "expect": expect, "action": decision["action"], "project": decision["project"],
                  "reason": decision["reason"], "confidence": decision["confidence"], "asked": asked, "route": route, "event": kind, "handed_over": decision.get("handed_over", False), "project_confidence": decision.get("project_confidence"), "landed": where,
                  "stream_hit": names.get(where), "stream": stream, "seconds": round(seconds, 1), "usd": round(cost, 4),
                  "reply": next((r["body"][:160] for r in reversed(fresh) if not r["notice"] and r["from"] != "you"), None)}
        with out.open("a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


def score(path):
    outcome = {"right": 0, "asked": 0, "wrong": 0, "coordinator answered": 0}
    for line in open(path):
        r = json.loads(line)
        allowed = r["expect"].split("|")
        right = (r["stream_hit"] in allowed or (r["event"] == "thread_started" and any(e.startswith("new") for e in allowed))
                 or (r["action"] == "answer_here" and "here" in allowed) or (r["project"] != "lcu" and r["action"] != "answer_here" and "other" in allowed))
        answered = r["route"] == "coordinator" and not r["event"] and r["reply"]
        result = "asked" if r["asked"] else "right" if right else "coordinator answered" if answered else "wrong"
        outcome[result] += 1
        if result != "right":
            print(result, r["key"], r["expect"], r["action"], r["project"], r["confidence"], r["reason"][:110])
    print(outcome)


if __name__ == "__main__":
    score(sys.argv[2]) if sys.argv[1] == "score" else main()
