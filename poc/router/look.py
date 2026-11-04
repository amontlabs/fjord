"""Look at the local machine: session files and the process registry become Seen rows. The page is seen through events (page.py)."""
import glob
import json
import os
import re
import subprocess
import time

PURPOSE = 600  # a README's prose kept as the project's description
SESSIONS = os.path.expanduser("~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json")
REGISTRY = os.path.expanduser("~/.claude/sessions/*.json")
TRANSCRIPTS = os.path.expanduser("~/.claude/projects/*/{}.jsonl")
APP_DIR = os.path.expanduser("~/Library/Application Support/Claude")  # the app writes here as it starts: watched while it is closed
CHROME_DIR = os.path.expanduser("~/Library/Application Support/Google/Chrome")
FRESH_DAYS = 21
RESULT_DAYS = 2


def row(source, kind, subject, **fields):
    return {"source": source, "kind": kind, "subject": subject, "fields": fields}


def local_state(s, status):
    """The app's own words for a session: a busy process is working, a blocked or interrupted one needs you; else unknown."""
    if status == "busy":
        return "working"
    if s.get("needs") or s.get("interrupted") or s.get("category") == "blocked":
        return "needs_you"
    return {"completed": "resolved", "review_ready": "idle"}.get(s.get("category"), "unknown")


def link_child(board, s):
    """A project-thread child belongs to the page thread with its title, in the project of its folder when titles repeat."""
    same = [t for t in board["threads"].values() if t["title"] and t["title"] == s.get("title") and t["project"] in board["projects"]]
    if len(same) > 1:
        name = os.path.basename((s.get("folder") or "").rstrip("/"))
        same = [t for t in same if board["projects"][t["project"]]["name"] == name]
    return same[0]["id"] if len(same) == 1 else None


def local_rows(board, local, page_projects, now):
    """Session files and the process registry. A process that was alive and has no entry now is gone."""
    by_session = {t["session"]: t["id"] for t in board["threads"].values() if t["session"]}
    names = {p["name"]: p["id"] for p in page_projects}
    rows, local_projects = [], {}
    for key, s in local["sessions"].items():
        subject = by_session.get(key) or (link_child(board, s) if s.get("child") else None) or (None if s.get("child") else f"local:{s['cli']}")
        if subject is None or (s.get("active") and now - s["active"] > FRESH_DAYS * 86400):
            continue
        fields = {}
        if subject.startswith("local:"):
            name = os.path.basename((s["folder"] or "scratch").rstrip("/"))
            project = names.get(name, f"local:{name}")
            fields = {"project": project, "title": s.get("title")}
            local_projects[project] = row("files", "project", project, purpose=s.get("purpose", ""), **({} if name in names else {"name": name, "where": "local"}))
        alive = local["processes"].get(s["cli"])
        if alive is None and board["threads"].get(subject, {}).get("alive") is not None:  # seen alive once: gone stays gone
            alive = False
        state = local_state(s, local.get("statuses", {}).get(s["cli"]) if alive else None)
        rows.append(row("files", "thread", subject, state=state, detail=s.get("detail"), needs=s.get("needs") or None, alive=alive,
                        session=key, result=s.get("result"), active=s.get("active"), **fields))
    app = [row("files", "app", "claude", running=bool(local["app"]))] if "app" in local else []
    return [*local_projects.values(), *rows, *app]


def is_scratch(folder, home=None):
    """No project: no folder, the home folder itself, or a temp folder."""
    home = home or os.path.expanduser("~")
    return not folder or folder.rstrip("/") == home.rstrip("/") or os.path.basename(folder.rstrip("/")).startswith("scratch-") or folder.startswith(("/tmp", "/private/tmp", "/var/folders", "/private/var/folders"))


def session_info(d, now, home=None, path=None):
    """One session file as Look sees it, or None when the Board shouldn't hold it. Project-thread children are kept only to link to the page."""
    spawn = d.get("remoteControlSpawn") or {}
    active = (d.get("lastActivityAt") or 0) / 1000
    if d.get("isArchived") or now - active > FRESH_DAYS * 86400 or not d.get("cliSessionId"):
        return None
    anchors = d.get("gitAnchors") or []
    folder = (anchors[0].get("gitRoot") if anchors else None) or d.get("cwd") or spawn.get("folder")
    child = bool(spawn.get("projectThreadChild"))
    if not child and is_scratch(folder, home):
        return None
    summary = d.get("postTurnSummary") or {}
    return {"folder": folder, "title": d.get("title"), "detail": summary.get("status_detail"), "needs": summary.get("needs_action"),
            "category": summary.get("status_category"), "interrupted": bool(d.get("interruptedAwaitingPerson") or summary.get("interruptedAwaitingPerson")),
            "active": active, "cli": d["cliSessionId"], "child": child, "purpose": "" if child else purpose(folder),
            "result": result(d["cliSessionId"], path) if now - active < RESULT_DAYS * 86400 else None}


_FILES = {}  # path -> (mtime, size, value): a file unchanged since last read is not read again


def cached(path, load):
    """load(path), reused while the file's mtime and size are unchanged. Unreadable is None and is not kept."""
    try:
        st = os.stat(path)
    except OSError:
        _FILES.pop(path, None)
        return None
    key = (st.st_mtime_ns, st.st_size)
    hit = _FILES.get(path)
    if hit and hit[0] == key:
        return hit[1]
    try:
        value = load(path)
    except (OSError, ValueError):
        return None
    _FILES[path] = (key, value)
    return value


def load_json(path):
    with open(path) as f:
        return json.load(f)


def read_local(sessions=SESSIONS, registry=REGISTRY, now=None, home=None, apps=None):
    """Session files (as local_sessions in projects/router.py), the process registry, the latest result of recent sessions, and whether
    the Claude app runs (`apps`: its pids)."""
    found, processes, statuses, now = {}, {}, {}, now or time.time()
    apps = app_pids() if apps is None else apps
    for path in glob.glob(sessions):
        d = cached(path, load_json)
        if d is None:
            continue
        info = session_info(d, now, home, path)
        spawned = (d.get("remoteControlSpawn") or {}).get("ccrSessionId")
        for bridge in (d.get("bridgeSessionIds") or []) + ([spawned] if spawned else []) or [f"cli:{d.get('cliSessionId')}"]:
            if info:
                found[bridge.replace("session_", "cse_")] = info
    for path in glob.glob(registry):
        d = cached(path, load_json)
        try:
            processes[d["sessionId"]] = alive(d["pid"])
            statuses[d["sessionId"]] = d.get("status")
        except (TypeError, KeyError):
            continue
    return {"sessions": found, "processes": processes, "statuses": statuses, "app": bool(apps)}


_APP = [0.0, []]  # when it was last asked, and the pids: watched() and read_local() ask once each per pass
_CHROME = [0.0, []]  # the same for Chrome: watched() asks once per pass while the page is away


def app_pids():
    """The Claude app's main process. Its threads run inside it: with it closed none can run, which is not their being stranded."""
    return pids_of("Claude", _APP)


def chrome_pids():
    """Google Chrome's main process: while the page is away, its exit is watched (with Chrome gone, the page can't come back)."""
    return pids_of("Google Chrome", _CHROME)


def pids_of(name, cache):
    if time.monotonic() - cache[0] > 2:
        try:
            # -a: pgrep leaves out its own ancestors, and a routerd started from a Claude session runs under the app (measured)
            out = subprocess.run(["pgrep", "-a", "-x", name], capture_output=True, text=True, timeout=2).stdout
            cache[1] = [int(p) for p in out.split() if p.isdigit()]
        except (OSError, subprocess.SubprocessError):
            cache[1] = []
        cache[0] = time.monotonic()
    return [p for p in cache[1] if alive(p)]  # one that exited since it was asked is gone: its folder is watched instead


def watched(sessions=SESSIONS, registry=REGISTRY, apps=None, chrome=False, chromes=None):
    """(directories, pids) that read_local depends on: each pattern's directories from the first wildcard down, with the one above
    it even when missing (so a missing root is noticed), the registered processes, and the app: its exit, or while it is closed
    its folder, which it writes to as it starts. `chrome` (the page is away): Chrome likewise, its exit or its folder."""
    apps = app_pids() if apps is None else apps
    chromes = (chrome_pids() if chromes is None else chromes) if chrome else []
    dirs = []
    for pattern in (sessions, registry):
        parts = os.path.dirname(pattern).split(os.sep)
        wild = next((i for i, part in enumerate(parts) if "*" in part), len(parts) + 1)
        dirs.append(os.sep.join(parts[:max(1, wild)]))
        dirs += [d for n in range(wild + 1, len(parts) + 1) for d in glob.glob(os.sep.join(parts[:n])) if os.path.isdir(d)]
    pids = []
    for path in glob.glob(registry):
        d = cached(path, load_json)
        if isinstance(d, dict) and isinstance(d.get("pid"), int):
            pids.append(d["pid"])
    dirs += [] if apps else [APP_DIR]
    dirs += [CHROME_DIR] if chrome and not chromes and os.path.isdir(CHROME_DIR) else []  # while the page is away and Chrome isn't running: Chrome writes there as it starts
    pids += [(p, APP_DIR) for p in apps] + [(p, CHROME_DIR if os.path.isdir(CHROME_DIR) else None) for p in chromes]  # one gone when armed: its folder
    return list(dict.fromkeys(dirs + glob.glob(registry))), pids  # registry files are rewritten in place, which a folder doesn't see


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def purpose(folder):
    """What a repo says it is: the README's prose with tags, images and link targets stripped. Read again only when the README changes."""
    return cached(os.path.join(folder, "README.md"), prose) or "" if folder else ""


def prose(path):
    with open(path, errors="ignore") as f:
        lines = [l.strip() for l in f]
    kept = []
    for line in lines:
        line = re.sub(r"<[^>]*>", "", re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", re.sub(r"!\[[^\]]*\]\([^)]*\)", "", line))).strip()
        if line and not line.startswith(("#", "|", "```", "-", "!", "[")):
            kept.append(line)
    return " ".join(kept)[:PURPOSE]


_RESULTS = {}  # cli -> (session file's key, text): the transcript changes with every token of a busy session, the session file far less


def result(cli, session_path=None):
    """A session's latest assistant text, from the tail of its transcript. Read again only when the session file changes."""
    try:
        st = os.stat(session_path) if session_path else None
    except OSError:
        st = None
    key = (st.st_mtime_ns, st.st_size) if st else None
    hit = _RESULTS.get(cli)
    if key and hit and hit[0] == key:
        return hit[1]
    for path in glob.glob(TRANSCRIPTS.format(cli)):
        try:
            text = transcript_tail(path)
        except OSError:
            return None
        _RESULTS[cli] = (key, text)
        return text


def transcript_tail(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 100_000))
        lines = f.read().decode(errors="ignore").splitlines()
    text = None
    for line in lines:
        if '"type":"assistant"' not in line:
            continue
        try:
            blocks = json.loads(line)["message"]["content"]
        except (ValueError, KeyError):
            continue
        parts = [b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text"] if isinstance(blocks, list) else []
        text = "\n".join(parts) or text
    return text[-1500:] if text else None

