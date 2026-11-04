"""A kqueue wait (macOS only, standard library): block until a directory changes, a process exits or a pipe has a byte to read.

Armed before a pass and waited on after it, so what happens during the pass is one more pass and a burst is no more than that.
A directory that is missing or a watch that can't be set makes `slow` true: `wait` then also wakes every SLOW seconds, for that
case only (the other watches still wake it at once).
"""
import errno
import os
import select

SLOW = 30.0
DIR = select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME | select.KQ_NOTE_EXTEND


class Watch:
    def __init__(self, dirs=(), pids=(), reads=()):
        self.kq, self.fds, self.slow, armed = select.kqueue(), [], False, 0
        for path in dirs:
            armed += self.folder(path)
        for pid in pids:  # (pid, folder): a process gone before its watch is set is watched by its folder, which it writes to as it starts
            pid, folder = pid if isinstance(pid, tuple) else (pid, None)
            done = self.arm(select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT), gone=True)
            armed += done or (self.folder(folder) if folder else 0)
        for fd in reads:  # level-triggered: a byte written before the watch was set wakes it at once
            self.arm(select.kevent(fd, select.KQ_FILTER_READ, select.KQ_EV_ADD))
        self.slow = self.slow or not armed

    def folder(self, path):
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            self.slow = True
            return 0
        self.fds.append(fd)
        return self.arm(select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, DIR))

    def arm(self, event, gone=False):
        try:
            self.kq.control([event], 0)
            return 1
        except OSError as e:
            self.slow = self.slow or not (gone and e.errno == errno.ESRCH)  # a process that is already gone was just seen gone
            return 0

    def wait(self):
        self.kq.control(None, 1, SLOW if self.slow else None)

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.kq.close()
