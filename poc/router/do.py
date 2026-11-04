"""Do: what one intent may do next, as pure functions over the Board. routerd.py runs the steps.

Proof is a new row from you, seen in a `rows` event: one after the last row whose key the place held at the baseline (taken before
anything is sent, from a settled whole read: the latest 50 keys on screen, and the latest 200 others Seen holds for the place, which a
first render may lack). A read that holds none of them is placed by the anchors (Claude's rows that earlier
reads placed after the baseline): its rows after the earliest anchor it holds are new. Rows holding neither can't be placed, and none
is new. One row proves one send: a row that proved another send of the place is no proof. Once any such row exists, never send again. Once the page took the words (the draft emptied after the click) never send again
either, and wait for the row.
"""
import os
import subprocess
import time

import board as boards

RETRIES = 2
TIMEOUT = 20  # seconds without a row from you before the next attempt
KEYS = 50  # keys of a baseline from the rows on screen, the most recent; also the anchors kept
KNOWN = 200  # keys of a baseline from those Seen holds for the place and the screen lacks, the most recently read
KEPT = 5  # keys of the baseline and anchors a finished send's proof keeps (a watched one, failed after a click or a take or while in
# the page, or by a restart after its send, keeps them all while it is watched)
DONE = ("confirmed", "failed", "refused", "answered", "asked")
TOOLS = ("create_project", "set_instructions", "set_goal", "add_repo", "preapprove_folder")
CONFIRM = ("preapprove_folder",)  # a permission grant waits for the owner's word
ARGS = {"create_project": ("name", "goal"), "set_instructions": ("project", "text"), "set_goal": ("project", "text"),
        "add_repo": ("project", "repo"), "preapprove_folder": ("project", "path")}
PRIMARY = {"create_project": "name", "set_instructions": "text", "set_goal": "text", "add_repo": "repo", "preapprove_folder": "path"}
LIMITS = {"name": 200, "goal": 8000, "instructions": 16000}  # what the page's fields take
NOT_CONFIRMED = "done, but not confirmed"


CHROME_OPEN = "Chrome is open but Fjord's tab isn't connected: the profile picker is showing, or another profile is open, or the extension is off"


_chrome = [0.0, False]  # when it was last asked, and the answer: `blocked` is asked on every event while the page is away


def chrome_running():
    """Whether Google Chrome runs: why the page isn't connected differs, and so does what the owner should do."""
    if time.monotonic() - _chrome[0] > 5:
        try:
            _chrome[1] = subprocess.run(["pgrep", "-a", "-x", "Google Chrome"], capture_output=True, timeout=2).returncode == 0
        except (OSError, subprocess.SubprocessError):
            _chrome[1] = False
        _chrome[0] = time.monotonic()
    return _chrome[1]


def blocked(health):
    """Why nothing can be done now, else None. Null is unknown, not a reason to pause."""
    if health.get("connected") is not True:
        return CHROME_OPEN if chrome_running() else "Chrome isn't running"
    if health.get("signed_in") is False:
        return "signed out of claude.ai"
    if health.get("away") is True:
        return "Fjord's tab has left the Claude Code page"
    if health.get("page_ok") is False:
        return "the page can't be read"


def refusal(board, intent):
    if (intent["project"] or "").startswith("local:"):
        return "this folder has no Claude project yet"
    if intent["thread"] and intent["thread"] not in board["threads"]:
        return "that thread isn't on the board"
    if not intent["thread"] and intent["project"] not in board["projects"]:
        return "no such project on the page"


APP_CLOSED = "waiting for the Claude app"
LAST = 300  # characters of a stranded thread's last state in its handoff


def app_wait(board, intent):
    """A reply to a local thread while the Claude app is closed waits for the app: the thread can't run, and isn't stranded."""
    t = board["threads"].get(intent["thread"])
    if t and t["local"] and board.get("app") is False:
        return APP_CLOSED


def stranded(board, intent):
    """The thread a reply goes to, when its process is gone while the app runs: a reply there isn't delivered and wakes nothing."""
    t = board["threads"].get(intent["thread"])
    return t if t and t["state"] == "stranded" else None


def handoff(t, words):
    """(words, args) of the project send that continues a stranded thread: the owner's words, after a short note from Fjord."""
    last = boards.squash(t["detail"] or t["text"] or t["result"] or "")[:LAST] or "unknown"
    text = (f"Thread «{t['title'] or t['id']}» lost its process. Start a new thread in the same folder that continues it. "
            f"Last state: {last}. Message: {words}")
    return text, {"continues": t["id"], "message": words}


def warning(board, intent):
    """What the owner is told with the decision: a reply that waits for the app, or one that went to the coordinator instead."""
    if (intent["args"] or {}).get("continues"):
        return "that thread lost its process; the message goes to its project's coordinator, to continue it in a new thread"
    if intent["thread"] and app_wait(board, intent):
        return "the Claude app isn't running; the reply waits for it"


def baselined(board, proof, known=()):
    """The proof starts from the keys of the rows the place holds, taken before anything is sent, the latest KEYS, and the latest KNOWN
    other keys Fjord knows for the place (`known`: the keys Seen holds for it, in the order they were last read). A first render can lack
    the bottom rows: an old row the next delta brings is one of them, and not new. Those come first, so a tail of the baseline is the
    screen's latest."""
    if "baseline" in proof:
        return proof
    rows = boards.rows_of(boards.place_of(board, proof["project"], proof.get("thread")), proof.get("thread"))
    keys = [m["key"] for m in rows or []][-KEYS:]
    held = set(keys)
    return {**proof, "baseline": [k for k in known if k not in held][-KNOWN:] + keys}


def tail(proof):
    """A finished send's proof: the last KEPT keys of its baseline and anchors. The `baseline` key stays: it says the chat was sent to
    (`store.chat_projects`)."""
    return {**proof, **{k: proof[k][-KEPT:] for k in ("baseline", "anchors") if k in proof}}


def anchored(board, proof):
    """The place's rows have been read and can be placed against the baseline: they hold one of its keys or anchors, or it holds none
    (an empty chat). Rows that hold none of them (a window of older history, say) say nothing about what came after it."""
    rows = boards.rows_of(boards.place_of(board, proof["project"], proof.get("thread")), proof.get("thread"))
    known = boards.placed_by(proof)
    return rows is not None and (not known or any(m["key"] in known for m in rows))


def anchor(board, proof):
    """The proof with its anchors moved forward: the keys of Claude's rows a read placed after the baseline, the latest KEYS of them. A
    later read whose window has scrolled past the baseline (a busy chat, or its reload) is placed by them. Only Claude's: a row first
    read as `unknown` can turn out to be yours. The same proof when nothing is new."""
    rows = boards.new_rows(board, proof)
    old = list(proof.get("anchors") or ())
    keys = [m["key"] for m in rows or () if m.get("from") == "claude" and m["key"] not in old]
    return {**proof, "anchors": (old + keys)[-KEYS:]} if keys else proof


def turning(board, proof):
    """The coordinator is mid-turn: a Claude row of the place is still being written, one placed after the baseline or one already in
    it (a turn that began before the send). Your message, if the server has it, may stay queued until the turn ends."""
    shown = boards.place_of(board, proof["project"], proof.get("thread"))
    if (shown or {}).get("turning") is not None:  # the page's own reading, pending rows too (`page.turning`)
        return shown["turning"]
    rows = boards.rows_of(shown, proof.get("thread")) or ()
    return any(m.get("from") == "claude" and m.get("streaming") for m in rows)


def proved(board, proof, claimed=()):
    """(done, cause, key) of one send: `proved_all` with no other send of its place."""
    return proved_all(board, [(None, proof)], claimed)[None]


def proved_all(board, proofs, claimed=()):
    """{id: (done, cause, key)} for the sends of one place (`proofs`, [(id, proof)] in priority order), judged together: each new row
    from you goes to the send whose words it is (`boards.assign`), and `key` is that row's. Any other new row from you ends the sending
    (`cause`), but not a row that is another send's (taken by it, or with exactly its words): a send failed earlier, delivered late,
    says nothing of this one. A row in `claimed` (the place's rows that proved other sends) is skipped: one row proves one send."""
    taken = boards.assign(board, proofs, claimed)
    out = {}
    for i, proof in proofs:
        if i in taken:
            out[i] = (True, None, taken[i])
            continue
        skip = set(claimed) | boards.others(board, proofs, taken, i)
        rows = boards.from_you(board, proof, skip)
        out[i] = (True, "a row from you arrived, but its words differ from what was sent", None) if rows else (False, None, None)
    return out



def tool_args(tool, args):
    """(args, cause): the arguments with line ends as the page's fields hold them, or why they are refused."""
    if tool not in TOOLS:
        return None, f"no such tool: {tool}"
    if not isinstance(args, dict):
        return None, "the arguments aren't an object"
    extra = sorted(set(args) - set(ARGS[tool]))
    if extra:
        return None, f"unexpected arguments: {', '.join(extra)}"
    clean = {}
    for key, value in args.items():
        if value is None and key == "goal":
            continue
        if not isinstance(value, str):
            return None, f"{key} must be text"
        clean[key] = value.replace("\r\n", "\n").replace("\r", "\n")
    missing = [k for k in ARGS[tool] if k not in clean and k != "goal"]
    if missing:
        return None, f"missing: {', '.join(missing)}"
    for key in ("name", "repo", "path"):
        if key in clean and not clean[key].strip():
            return None, f"{key} is empty"
        if key in clean:
            clean[key] = clean[key].strip()
    if "name" in clean and ("\n" in clean["name"] or len(clean["name"]) > LIMITS["name"]):
        return None, f"the name must be one line of at most {LIMITS['name']} characters"
    limit = LIMITS["instructions"] if tool == "set_instructions" else LIMITS["goal"]
    for key in ("goal", "text"):
        if len(clean.get(key, "")) > limit:
            return None, f"{key} is over {limit} characters"
    if "path" in clean:  # the page lists folders under the home folder as ~/…, so a full path is written the same way
        home = os.path.expanduser("~").rstrip("/")
        path = clean["path"].rstrip("/") or "/"
        clean["path"] = "~" + path[len(home):] if path == home or path.startswith(home + "/") else path
    repo = clean.get("repo", "a/b")
    if len(repo.split("/")) != 2 or not all(repo.split("/")) or any(c.isspace() for c in repo):
        return None, "a repository is owner/name"
    return clean, None


def name_taken(board, name):
    """Why a project can't be created under this name, else None."""
    if any(p["name"] == name and p["id"].startswith("chan_") for p in board["projects"].values()):  # a local folder of that name has no project yet
        return f"a project named {name} already exists"


def tool_proof(tool, args, board):
    """What Look must see afterwards: the field equal to the text, the list holding the repo or the path, or a new project of that name."""
    if tool == "create_project":
        return {"name": args["name"], "known": sorted(board["projects"])}
    if tool in ("set_instructions", "set_goal"):
        return {"field": tool.removeprefix("set_"), "equals": args["text"]}
    return {"field": "repos" if tool == "add_repo" else "folders", "has": args.get("repo") or args.get("path")}


def created(board, proof):
    """Ids of the projects the page lists under the proof's name that weren't known before."""
    return sorted(p["id"] for p in board["projects"].values() if p["name"] == proof["name"] and p["id"].startswith("chan_") and p["id"] not in proof["known"])


def tool_proved(board, intent):
    """(holds, cause): the page shows what the tool did, in the last settings read or the projects it lists. Several new projects of one name can't be told apart."""
    proof = intent["proof"]
    if intent["tool"] == "create_project":
        new = created(board, proof)
        return len(new) == 1, f"{len(new)} new projects are named {proof['name']}" if len(new) > 1 else None
    value = ((board["projects"].get(intent["project"]) or {}).get("settings") or {}).get(proof["field"])
    return shows(proof, value), None


def shows(proof, value):
    """The field or list holds what the tool asks for."""
    return value == proof["equals"] if "equals" in proof else proof["has"] in (value or [])


def before(value, intent):
    """What the field or list held before the act, as the act's own open read it, kept on the intent so it can be put back. The page's
    report is data: anything but text for a field, or a list of text for a list, is unknown."""
    if intent["proof"]["field"] in ("repos", "folders"):
        return [v for v in value if isinstance(v, str)] if isinstance(value, list) else None
    return value if isinstance(value, str) else None


def act_command(intent):
    """(kind, fields) of the one command that acts."""
    a, project = intent["args"], intent["project"]
    if intent["tool"] == "create_project":
        return "create_project", {"name": a["name"], "goal": a.get("goal")}
    if intent["tool"] in ("set_instructions", "set_goal"):
        return "set_field", {"project": project, "field": intent["proof"]["field"], "text": a["text"]}
    if intent["tool"] == "add_repo":
        return "add_repo", {"project": project, "repo": a["repo"]}
    return "preapprove_folder", {"project": project, "path": a["path"]}
