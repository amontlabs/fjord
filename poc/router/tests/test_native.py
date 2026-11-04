import io
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import kwatch
import native_host


def frame(obj):
    body = json.dumps(obj).encode()
    return struct.pack("=I", len(body)) + body


class NativeFraming(unittest.TestCase):
    def test_frames_become_json_lines_on_the_socket(self):
        ours, theirs = socket.socketpair()
        stdin = io.BytesIO(frame({"type": "rows", "rows": [{"index": 1, "text": "a\nb"}]}) + b"\x03\x00\x00\x00{no" + frame({"type": "done", "id": "c1"}))
        native_host.to_socket(stdin, ours.sendall)
        ours.close()
        lines = theirs.makefile("rb").read().split(b"\n")
        self.assertEqual(json.loads(lines[0])["rows"][0]["text"], "a\nb")
        self.assertEqual(json.loads(lines[1]), {"type": "done", "id": "c1"})  # the broken frame was skipped
        self.assertEqual(len(lines), 3)  # two lines and the end

    def test_socket_lines_become_frames(self):
        out = io.BytesIO()
        lines = [b'{"id":"c1","kind":"send"}\n', b"\n", b'{"id":"c2","kind":"open"}\n']
        native_host.to_chrome(lines, out, threading.Lock())
        out.seek(0)
        self.assertEqual(json.loads(native_host.read_frame(out))["id"], "c1")
        self.assertEqual(json.loads(native_host.read_frame(out))["id"], "c2")
        self.assertIsNone(native_host.read_frame(out))

    def test_a_cut_frame_ends_the_stream(self):
        self.assertIsNone(native_host.read_frame(io.BytesIO(struct.pack("=I", 10) + b"abc")))
        self.assertIsNone(native_host.read_frame(io.BytesIO(b"")))

    def test_a_line_over_a_megabyte_is_dropped(self):
        out = io.BytesIO()
        native_host.to_chrome([b"x" * (native_host.LIMIT + 1) + b"\n"], out, threading.Lock())
        self.assertEqual(out.getvalue(), b"")


class Kqueue(unittest.TestCase):
    def test_a_file_appearing_in_a_watched_directory_wakes_the_wait_at_once(self):
        with tempfile.TemporaryDirectory() as d:
            watch = kwatch.Watch([d])
            self.assertFalse(watch.slow)
            open(os.path.join(d, "fjord.sock"), "w").close()  # during the pass: the wait must still return
            done = threading.Thread(target=watch.wait, daemon=True)
            done.start()
            done.join(5)
            self.assertFalse(done.is_alive())
            watch.close()

    def test_a_file_written_in_place_wakes_the_wait(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "90538.json")
            open(path, "w").close()
            watch = kwatch.Watch([path])
            with open(path, "a") as f:
                f.write("{}")
            done = threading.Thread(target=watch.wait, daemon=True)
            done.start()
            done.join(5)
            self.assertFalse(done.is_alive())
            watch.close()

    def test_a_missing_directory_falls_back_to_the_slow_pass(self):
        watch = kwatch.Watch(["/nonexistent/router-poc"])
        self.assertTrue(watch.slow)
        watch.close()

    def test_an_exiting_process_wakes_the_wait(self):
        import subprocess
        proc = subprocess.Popen(["sleep", "30"])
        watch = kwatch.Watch([], [proc.pid])
        self.assertFalse(watch.slow)
        proc.kill()
        done = threading.Thread(target=watch.wait, daemon=True)
        done.start()
        done.join(5)
        self.assertFalse(done.is_alive())
        proc.wait()
        watch.close()

    def test_a_process_gone_before_its_watch_is_set_is_watched_by_its_folder(self):
        import subprocess
        proc = subprocess.Popen(["true"])
        proc.wait()
        with tempfile.TemporaryDirectory() as d:
            watch = kwatch.Watch([], [(proc.pid, d)])
            self.assertFalse(watch.slow)
            open(os.path.join(d, "started"), "w").close()  # the app writes there as it starts again
            done = threading.Thread(target=watch.wait, daemon=True)
            done.start()
            done.join(5)
            self.assertFalse(done.is_alive())
            watch.close()

    def test_a_cached_pid_that_exited_is_left_out(self):
        import subprocess
        import time
        import look
        proc = subprocess.Popen(["true"])
        proc.wait()
        self.assertEqual(look.pids_of("Claude", [time.monotonic(), [proc.pid, os.getpid()]]), [os.getpid()])

    def test_a_byte_in_a_watched_pipe_wakes_the_wait_even_when_written_before(self):
        r, w = os.pipe()
        os.write(w, b"x")
        watch = kwatch.Watch([], [], [r])
        done = threading.Thread(target=watch.wait, daemon=True)
        done.start()
        done.join(5)
        self.assertFalse(done.is_alive())
        watch.close()
        os.close(r)
        os.close(w)


if __name__ == "__main__":
    unittest.main()
