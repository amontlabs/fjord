#!/usr/bin/env python3
"""Router POC: a thin client of routerd.

  router.py start                                        run routerd in the background
  router.py say "<message>" [--project X] [--thread T]   decide, do, and print the decision and the outcome
  router.py board                                        the Board in routerd's memory
  router.py tell                                         the brief: what changed and you weren't told
  router.py notes add <topic> <text> | list
  router.py log                                          intents, oldest first

Everything is a JSON line on .build/router-poc/fjord.sock. routerd holds the state; this file holds none.
"""
import argparse
import json
import os
import socket
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import context
import routerd


def connect():
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(routerd.SOCK)
    except OSError:
        sys.exit("routerd isn't running: router.py start")
    return sock


def ask(message):
    """Sends one op and yields each line routerd answers with."""
    sock = connect()
    sock.sendall((json.dumps(message) + "\n").encode())
    with sock.makefile("rb") as lines:
        for line in lines:
            yield json.loads(line)


def one(message):
    return next(ask(message))


def start():
    probe = socket.socket(socket.AF_UNIX)
    try:
        probe.connect(routerd.SOCK)
        return print("routerd is already running")
    except OSError:
        pass
    finally:
        probe.close()
    os.makedirs(routerd.STATE, exist_ok=True)
    log = open(os.path.join(routerd.STATE, "routerd.log"), "ab")
    process = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "routerd.py")],
                               stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    print(f"routerd started (pid {process.pid}); log: {log.name}")


def say(args):
    for line in ask({"op": "say", "message": args.message, "project": args.project, "thread": args.thread}):
        i = line.get("intent") or {}
        if line["event"] == "thinking":
            print(f"jev: {line['jev'].get('choice', 'no answer')} ({line['jev'].get('confidence', '-')}); asking sonnet")
        elif line["event"] == "decision":
            print(f"decision: {i['tool']} -> {i['project'] or '-'}/{i['thread'] or '-'} ({i['status']})" + (f": {i['cause']}" if i["cause"] else ""))
            for later in line.get("steps", [])[1:]:  # the setup steps after the first, done in order once it is confirmed
                print(f"  then: {later['tool']} {json.dumps(later['args'] or {}, ensure_ascii=False)} ({later['status']})")
            if line.get("warning"):
                print(f"warning: {line['warning']}")
        else:
            print(f"outcome: {i['status']}" + (f": {i['cause']}" if i["cause"] else "") + (f" {(i['result'] or {}).get('ms', '')}" if i["status"] == "confirmed" else ""))
            return


def show_board(answer):
    import time
    board = answer["board"]
    print(f"page: {board['health']}")
    for p in sorted(board["projects"].values(), key=lambda p: p["name"]):
        print(f"## {p['name']} ({p['where'] or 'unknown'}) {p['purpose']}")
        for t in board["threads"].values():
            if t["project"] == p["id"]:
                print(f"- {t['id']} | {t['title']} | {t['state']} | {context.age(answer['now'] - t['touched'])} ago" + (f" | needs: {t['needs']}" if t["needs"] else "")
                      + (f" | {t['detail'][:100]}" if t["detail"] else ""))


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    s = commands.add_parser("say")
    s.add_argument("message")
    s.add_argument("--project")
    s.add_argument("--thread")
    for name in ("start", "board", "tell", "log"):
        commands.add_parser(name)
    n = commands.add_parser("notes")
    n.add_argument("action", choices=["add", "list"])
    n.add_argument("topic", nargs="?")
    n.add_argument("text", nargs="?")
    args = parser.parse_args()
    if args.command == "start":
        start()
    elif args.command == "say":
        say(args)
    elif args.command == "board":
        show_board(one({"op": "board"}))
    elif args.command == "tell":
        print("\n".join(one({"op": "tell"})["tell"]) or "nothing new")
    elif args.command == "notes" and args.action == "add":
        print(one({"op": "notes", "topic": args.topic, "text": args.text})["intent"]["status"])
    elif args.command == "notes":
        print("\n".join(f"{k}: {v}" for k, v in one({"op": "notes"})["notes"].items()) or "(no notes)")
    else:
        for i in one({"op": "log"})["intents"]:
            print(json.dumps({k: i[k] for k in ("id", "tool", "words", "project", "thread", "status", "attempts", "cause", "context_hash")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
