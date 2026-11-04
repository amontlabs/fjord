#!/usr/bin/env python3
"""Local link between Fjord and its browser extension. Listens on 127.0.0.1 only.

  bridge.py serve <log.jsonl>             run the bridge
  bridge.py read <channel>                read a project's visible thread list
  bridge.py send <channel> <text> [thread]   type in the real composer
"""
import json
import queue
import sys
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 47831
PAGE = "https://claude.ai/code/project/"
waiting = queue.Queue()
results = {}
done = threading.Condition()
log_path = None


def log(record):
    with open(log_path, "a") as f:
        f.write(json.dumps({"t": time.time(), **record}, ensure_ascii=False) + "\n")


class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.send_header("access-control-allow-origin", self.headers.get("origin", "*"))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        return json.loads(raw) if raw else {}

    def do_OPTIONS(self):
        log({"preflight": self.path, "origin": self.headers.get("origin")})
        self.send_response(204)
        self.send_header("access-control-allow-origin", self.headers.get("origin", "*"))
        self.send_header("access-control-allow-methods", "GET, POST")
        self.send_header("access-control-allow-headers", "content-type")
        self.end_headers()

    def do_GET(self):
        log({"get": self.path, "origin": self.headers.get("origin")})
        if self.path == "/next":
            try:
                self.reply(waiting.get(timeout=20))
            except queue.Empty:
                self.reply({})

    def do_POST(self):
        body = self.body()
        if self.path == "/beat":
            log({"beat": body})
            self.reply({})
        elif self.path == "/result":
            log({"result": body})
            with done:
                results[body["id"]] = body
                done.notify_all()
            self.reply({})
        elif self.path == "/command" and self.client_address[0] == "127.0.0.1":
            command = {"id": str(uuid.uuid4()), **body}
            waiting.put(command)
            with done:
                done.wait_for(lambda: command["id"] in results, timeout=90)
                self.reply(results.pop(command["id"], {"error": "no answer from the extension"}))


def command(body):
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}/command", json.dumps(body).encode(), {"content-type": "application/json"})
    print(urllib.request.urlopen(request, timeout=100).read().decode())


def main():
    global log_path
    verb = sys.argv[1]
    if verb == "serve":
        log_path = sys.argv[2]
        ThreadingHTTPServer(("127.0.0.1", PORT), Bridge).serve_forever()
    elif verb == "read":
        command({"kind": "read", "url": PAGE + sys.argv[2]})
    elif verb == "diagnose":
        command({"kind": "diagnose"})
    elif verb == "send":
        thread = sys.argv[4] if len(sys.argv) > 4 else None
        url = PAGE + sys.argv[2] + (f"?thread={thread}" if thread else "")
        command({"kind": "send", "url": url, "text": sys.argv[3], "inThread": bool(thread)})


if __name__ == "__main__":
    main()
