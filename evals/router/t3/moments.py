"""N1: routing moments from the owner's T3 history (data/history.json from extract.py) -> data/moments.jsonl.

Each owner-authored message at time t, with the board as it stood just before t rebuilt from the history. Gold: a thread's first
owner message -> a new thread in its project; later ones -> that thread. See docs/design/t3-research/N1-new-work-benchmark.md.
Writes data only to the gitignored data/ folder; prints counts, never text."""
import collections
import datetime as dt
import glob
import json
import os
import pathlib
import random
import re
import sys
from zoneinfo import ZoneInfo

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from board import Board, Thread  # noqa: E402

HERE = pathlib.Path(__file__).parent
DATA = HERE / "data"
PARIS = ZoneInfo("Europe/Paris")
SEED = 20261108
TEST_SHARE = 0.45


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def day_of(at):
    """The owner's working day: local time, the day turning at 04:00."""
    return (ts(at).astimezone(PARIS) - dt.timedelta(hours=4)).date().isoformat()


# ---------------------------------------------------------------- which threads, which messages
def entrypoint(uuid):
    fs = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{uuid}.jsonl"))
    if not fs: return "nofile"
    with open(fs[0]) as f:
        for line in f:
            try: d = json.loads(line)
            except ValueError: continue
            if "entrypoint" in d: return d["entrypoint"]
    return "none"


def kind(t):
    tid, lin = t["id"], t["lineage"] or {}
    if tid.startswith("import:codex:"): return "import_codex"          # runs delegated to Codex by an agent
    if tid.startswith("import:claudeAgent:"):
        e = entrypoint(tid.split(":")[-1])
        return {"claude-desktop": "import_desktop", "cli": "import_cli"}.get(e, "import_sdk")
    if lin.get("relationshipToParent") == "subagent" or tid.startswith(("thread:delegat", "thread:provide")): return "subagent"
    if t["createdBy"] == "agent": return "agent_launch"
    if t["createdBy"] == "user" and t["source"] == "mcp": return "fjord_created"   # Fjord's T3 client stamps createdBy user, source mcp
    if t["createdBy"] == "user": return "native_owner"
    return "other"


LISTED = {"native_owner", "fjord_created", "agent_launch", "import_desktop", "import_cli"}
MOMENT_KINDS = {"native_owner", "import_desktop", "import_cli"}

NOT_OWNER = ("<task-notification", "<system-reminder", "<wake ", "<command-", "<bash-", "<local-command", "<relay ", "<ci-monitor",
             "<project_claude_message", "<artifact-view", "<environment_context", "<user_instructions", "# AGENTS.md", "Caveat:",
             "[Request interrupted", "This session is being continued", "<turn_aborted", "<user_shell_command")


def owner_kind(m):
    """'owner' for a message the owner wrote; else why not."""
    if m["role"] != "user" or m["by"] != "user": return "not_user"
    if m["src"] == "mcp": return "fjord_routed"   # sent by Fjord's router: its gold would be Fjord's own pick
    tx = m["text"].strip()
    if not tx: return "attachment_only" if m["att"] else "empty"
    if tx.startswith(("<command-", "<local-command")): return "slash"
    if tx.startswith(NOT_OWNER): return "system"
    if tx.startswith("<") and not tx.startswith("<pasted_content"): return "system"
    if re.match(r"^/[a-z][\w:-]*(\s|$)", tx): return "slash"
    return "owner"


def norm(text):
    return " ".join(re.sub(r"[^\w\s]", " ", text.lower()).split())


# ---------------------------------------------------------------- forks: one conversation under two ids
def births(threads):
    """Thread id -> when it starts to exist (a fork exists from its first message not copied from another thread); None: a pure copy."""
    keyset = collections.defaultdict(set)
    for t in threads:
        for m in t["messages"]:
            if m["role"] == "user" and m["text"].strip(): keyset[(m["text"], m["at"])].add(t["id"])
    first_unshared, first_key = {}, {}
    for t in threads:
        us = [m for m in t["messages"] if m["role"] == "user" and m["text"].strip()]
        first_key[t["id"]] = (us[0]["text"], us[0]["at"]) if us else None
        first_unshared[t["id"]] = next((m["at"] for m in us if len(keyset[(m["text"], m["at"])]) == 1), None)
    born = {t["id"]: t["created"] for t in threads}
    fork = {}
    groups = collections.defaultdict(list)
    for t in threads:
        k = first_key[t["id"]]
        if k and len(keyset[k]) > 1: groups[k].append(t["id"])
    for k, ids in groups.items():
        ids.sort(key=lambda i: (first_unshared[i] is None, first_unshared[i] or "", i))
        for i in ids[1:]:
            born[i] = first_unshared[i]
            fork[i] = ids[0]
    return born, fork


# ---------------------------------------------------------------- the board at t
class History:
    def __init__(self, H, purposes):
        self.projects = {pid: p["title"] for pid, p in H["projects"].items() if not p["deleted"] and not p["archived"]}
        self.purposes = purposes
        self.threads = [t for t in H["threads"]]
        for t in self.threads:
            t["kind"] = kind(t)
            t["msgs"] = sorted(t["messages"], key=lambda m: m["at"])
            for m in t["msgs"]: m["ok"] = owner_kind(m)
        self.born, self.fork = births(self.threads)
        self.listed = [t for t in self.threads if t["kind"] in LISTED and t["project"] in self.projects and self.born[t["id"]]]

    def board(self, t_at, exclude_msg=None):
        """The board just before t_at (an ISO time). exclude_msg: the moment's own message (never visible)."""
        T = ts(t_at)
        rows = []
        for t in self.listed:
            if self.born[t["id"]] >= t_at: continue
            if t["archived"] and t["archived"] < t_at: continue
            before = [m for m in t["msgs"] if m["at"] < t_at]
            if not before: continue
            after = [m for m in t["msgs"] if m["at"] >= t_at and m is not exclude_msg]
            prev = before[-1]
            if exclude_msg is not None and any(m is exclude_msg for m in t["msgs"]):
                # the moment's own thread: its words start a turn, so it ran only if a turn had started with no reply yet
                running = prev["role"] == "user" and bool(after) and after[0]["role"] == "assistant" \
                    and (ts(after[0]["at"]) - ts(prev["at"])).total_seconds() < 3 * 3600
            else:
                running = bool(after) and after[0]["role"] == "assistant" and (ts(after[0]["at"]) - ts(prev["at"])).total_seconds() < 3 * 3600
            running = running or any(r["start"] and r["start"] < t_at and (not r["end"] or r["end"] > t_at) and r["status"] != "failed"
                                     for r in t["runs"] if r["start"] and r["start"] > "2026-11-06")
            last_act = max(m["at"] for m in before)
            if t["settledAt"] and t["settledAt"] < t_at and last_act <= t["settledAt"] and not running: continue
            owner = [m for m in before if m["ok"] == "owner"]
            yours = [m for m in before if m["role"] == "user" and m["by"] == "user"]
            reply = next((m for m in reversed(before) if m["role"] == "assistant" and m["text"].strip()), None)
            visible = [m for m in before if (m["role"] == "assistant" and m["text"].strip()) or m["ok"] in ("owner", "fjord_routed")]
            you_last = bool(visible) and visible[-1]["role"] == "user"
            last10 = owner[-10:]
            rows.append(dict(t=t, running=running, last=last_act, reply=reply["text"] if reply else "",
                             you=owner[-1]["text"] if owner else None, you_at=owner[-1]["at"] if owner else None, you_last=you_last and bool(owner),
                             first=last10[0]["text"] if last10 else "", earlier=[m["text"] for m in owner[-3:]],
                             last_user=yours[-1]["at"] if yours else None))
        # short ids, in activity order (DeciderBoardSource.swift); imported ids use their session uuid as a native id would
        rows.sort(key=lambda r: (r["last"], r["t"]["id"]), reverse=True)
        taken, out = set(), []
        latest_told = max((r for r in rows if r["last_user"]), key=lambda r: r["last_user"], default=None)
        for r in rows:
            t = r["t"]
            raw = t["id"].split(":")[-1] if t["id"].startswith("import:") else t["id"]
            plain = "".join(ch for ch in raw.lower() if ch.isalnum())
            n = min(8, len(plain))
            while n < len(plain) and plain[:n] in taken: n += 1
            sid = plain[:n]; taken.add(sid)
            mins = max(0, int((T - ts(r["last"])).total_seconds() // 60))
            out.append(Thread(id=sid, key=t["id"], project=self.projects[t["project"]], title=t["title"],
                              flag="running" if r["running"] else "finished", running=r["running"], minutesIdle=mins,
                              said=r["reply"], youSaid=r["you"], youSaidLast=r["you_last"], branch=t["branch"] or "",
                              first=r["first"], earlier=r["earlier"],
                              youSaidMinutes=max(0, int((T - ts(r["you_at"])).total_seconds() // 60)) if r["you_at"] else None,
                              youLatest=latest_told is r))
        names = sorted(self.projects.values())
        return Board(projects=names, threads=out, purposes=self.purposes)


def thread_to_dict(t):
    return t.__dict__


def main():
    H = json.load(open(DATA / "history.json"))
    purposes = json.load(open(DATA / "purposes.json")) if (DATA / "purposes.json").exists() else {}
    hist = History(H, purposes)
    counts = collections.Counter()
    moments = []
    for t in hist.threads:
        counts["threads:" + t["kind"]] += 1
        if t["kind"] not in MOMENT_KINDS or t["project"] not in hist.projects:
            counts["msgs_skipped_thread_kind"] += sum(m["ok"] == "owner" for m in t["msgs"])
            continue
        if not hist.born[t["id"]]:
            counts["pure_copy_threads"] += 1; continue
        seen_owner = 0
        prev_norm = None; prev_at = None
        for m in t["msgs"]:
            if m["role"] != "user": continue
            ok = m["ok"]
            if ok != "owner":
                if m["by"] == "user": counts["excluded:" + ok] += 1
                continue
            if m["at"] < hist.born[t["id"]]:
                counts["excluded:fork_copy"] += 1; seen_owner += 1; continue
            nm = norm(m["text"])
            if prev_norm is not None and nm == prev_norm and (ts(m["at"]) - ts(prev_at)).total_seconds() < 1800:
                counts["excluded:retry"] += 1; prev_at = m["at"]; continue
            first = seen_owner == 0
            fork_start = t["id"] in hist.fork and not t.get("_forked_seen")
            if fork_start: t["_forked_seen"] = True
            seen_owner += 1; prev_norm, prev_at = nm, m["at"]
            cls = "new" if first else "follow"
            if fork_start: cls = "fork_start"
            moments.append(dict(id=f"{t['id']}@{m['at']}", thread=t["id"], kind=t["kind"], at=m["at"], day=day_of(m["at"]),
                                message=m["text"], cls=cls, project=hist.projects[t["project"]], _m=m))
    # boards and labels
    days = sorted({m["day"] for m in moments})
    rng = random.Random(SEED)
    test_days = set(rng.sample(days, round(len(days) * TEST_SHARE)))
    out = open(DATA / "moments.jsonl", "w")
    for mo in moments:
        b = hist.board(mo["at"], exclude_msg=mo["_m"])
        cands = b.candidates()
        gold = ("new", mo["project"]) if mo["cls"] in ("new", "fork_start") else ("thread", mo["thread"])
        gold_thread = next((x for x in b.threads if x.key == mo["thread"]), None)
        latest = min(b.threads, key=lambda x: x.minutesIdle, default=None)
        flags = []
        if len(mo["message"]) > 2000: flags.append("long")
        if mo["cls"] == "follow":
            if not gold_thread: flags.append("gold_not_listed")
            elif all(c.key != mo["thread"] for c in cands): flags.append("gold_off_board")
            elif gold_thread.running: flags.append("gold_running")
            flags.append("typed_in_thread")
        else:
            # retyped: the same words went to another thread in the last 2 hours
            nm = norm(mo["message"])
            for x in b.threads:
                xt = next(t for t in hist.threads if t["id"] == x.key)
                if any(norm(m["text"]) == nm and m["ok"] == "owner" and 0 <= (ts(mo["at"]) - ts(m["at"])).total_seconds() < 7200 for m in xt["msgs"]):
                    flags.append("retyped"); break
            flags.append("same_project_as_latest" if latest and latest.project == mo["project"] else "other_project_than_latest")
            if not any(c.project == mo["project"] for c in cands): flags.append("project_has_no_candidate")
        rec = dict(id=mo["id"], thread=mo["thread"], kind=mo["kind"], at=mo["at"], day=mo["day"], split="test" if mo["day"] in test_days else "dev",
                   cls=mo["cls"], gold=gold, project=mo["project"], flags=flags, message=mo["message"],
                   board=dict(projects=b.projects, threads=[thread_to_dict(x) for x in b.threads]),
                   n_candidates=len(cands))
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        counts["moments:" + mo["cls"]] += 1
        counts[f"moments:{rec['split']}:{mo['cls']}"] += 1
    out.close()
    counts["days"] = len(days); counts["test_days"] = len(test_days)
    for k, v in sorted(counts.items()): print(f"{k}: {v}")


if __name__ == "__main__":
    main()
