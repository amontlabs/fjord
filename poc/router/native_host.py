#!/usr/bin/env python3
"""Chrome's native messaging host for the Router POC: Chrome's length-prefixed stdio on one side, JSON lines on routerd's socket.

Chrome spawns it and closes stdin to end it. It keeps nothing but the line it is relaying.
"""
import json
import os
import socket
import struct
import sys
import threading

import kwatch

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOCKET = os.environ.get("FJORD_SOCKET") or os.path.join(ROOT, ".build", "router-poc", "fjord.sock")
LIMIT = 1024 * 1024  # Chrome refuses a message from a host larger than this


def read_exactly(stream, count):
    data = b""
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_frame(stream):
    """One message from Chrome, or None when Chrome closed the stream."""
    header = read_exactly(stream, 4)
    if header is None:
        return None
    body = read_exactly(stream, struct.unpack("=I", header)[0])
    return None if body is None else body


def write_frame(stream, body):
    stream.write(struct.pack("=I", len(body)) + body)
    stream.flush()


def to_socket(stdin, send):
    """Chrome's frames become JSON lines. A frame that isn't JSON is dropped. Returns when Chrome closes stdin."""
    while True:
        body = read_frame(stdin)
        if body is None:
            return
        try:
            line = json.dumps(json.loads(body), separators=(",", ":")).encode() + b"\n"
        except ValueError:
            print("native_host: dropped a frame that is not JSON", file=sys.stderr)
            continue
        send(line)


def to_chrome(lines, stdout, lock):
    """routerd's lines become Chrome's frames. A line Chrome would refuse for its size is dropped."""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if len(line) > LIMIT:
            print("native_host: dropped a line over 1 MB", file=sys.stderr)
            continue
        with lock:
            write_frame(stdout, line)


def main(path=SOCKET, arm=kwatch.Watch):
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    lock = threading.Lock()
    current = {"sock": None}

    def send(line):
        sock = current["sock"]
        if sock is None:
            return  # routerd isn't up; the page sends a snapshot when it is
        try:
            sock.sendall(line)
        except OSError:
            pass

    def serve():
        while True:
            watcher = arm([os.path.dirname(path)])  # armed before the attempt, so a socket that appears during it is not missed
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
            except OSError:
                sock.close()
                watcher.wait()
                watcher.close()
                continue
            watcher.close()
            current["sock"] = sock
            # routerd has just started or come back: have the page say what it shows.
            with lock:
                write_frame(stdout, b'{"kind":"snapshot"}')
            with sock.makefile("rb") as lines:
                to_chrome(lines, stdout, lock)
            current["sock"] = None
            sock.close()

    threading.Thread(target=serve, daemon=True).start()
    to_socket(stdin, send)


if __name__ == "__main__":
    main()
