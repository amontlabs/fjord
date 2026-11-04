"""What the page tells Fjord (EVENTS.md) as Seen rows. Pure: no sockets, no waiting.

Anything unreadable is "unknown" or None, never a guess. An event that can't be placed (no project in its path) gives no rows. A field of
the wrong shape (a number for a list, a list for a key) is skipped, never raised on.
"""
STATES = {"working", "needs_you", "paused", "done", "idle", "resolved", "unknown"}  # the page sends the first four and unknown


def row(kind, subject, **fields):
    return {"source": "page", "kind": kind, "subject": subject, "fields": fields}


def belongs(key, project):
    """A server id names its project: `cmsg_<the 24 characters after chan_>…`. One that names another project is from a stale render."""
    own = project[len("chan_"):]
    return len(own) != 24 or not key.startswith("cmsg_") or key.startswith("cmsg_" + own)


def place(event):
    """(project, thread) from the address the event was stamped with: /code/project/chan_…, and ?thread=cmsg_… as `thread`."""
    parts = str(event.get("path") or "").split("/")
    project = parts[3] if len(parts) > 3 and parts[1:3] == ["code", "project"] and parts[3].startswith("chan_") else None
    if project and project.startswith("chan_pending_"):  # a project being created: the page's own id, until the server answers
        project = None
    thread = event.get("thread")
    return project, thread if isinstance(thread, str) and thread else None


def messages(rows, project):
    """Rows the server has, by key. A pending row (yours not yet delivered, a reply being written) isn't a message yet, and one whose key
    names another project is from a stale render."""
    out = []
    for r in rows if isinstance(rows, list) else []:
        if isinstance(r, dict) and isinstance(r.get("text"), str) and isinstance(r.get("index"), int) and r.get("key") and isinstance(r["key"], str) and not r.get("pending") \
                and belongs(r["key"], project):
            out.append({"key": r["key"], "index": r["index"], "streaming": r.get("streaming") is True, "decision": bool(r.get("decision")), "from": r.get("from") if r.get("from") in ("you", "claude") else "unknown", "text": r["text"]})
    return out


def claude_rows(rows):
    """The Claude rows of one rows event, pending ones too (a reply being written may be `provisional:…`, which `messages` keeps off the
    Board): what `turning` reads, folded against what the place showed before."""
    return [{"key": str(r.get("key") or ""), "index": r["index"], "streaming": r.get("streaming") is True} for r in rows
            if isinstance(r, dict) and r.get("from") == "claude" and isinstance(r.get("index"), int)] if isinstance(rows, list) else []


def turning(fields, prior):
    """(writing, state): whether the coordinator is writing a reply, after one rows event, and the place's state for the next one.
    `fields` holds the event's `turning` (the page's own reading, when it sent one) or its `claude` rows and whether it is `full`;
    `prior` the place's state: its last streaming row (`turn_row`: key, index) and the highest Claude index seen (`claude_top`).
    A row is sent when it starts and once settled, so a delta's bottom Claude row is not the place's: an older row settling while a
    later one streams says nothing. A delta ends the turn only when its settled bottom row replaced the last streaming row (its key or
    index) or is at or above the highest Claude index seen; else None (no information). A whole read says it outright.
    The page sends its reading with every rows event (`turning`); once a place had one (`paged`), an event without it says nothing, and the
    row fold is only for a place that never had a page reading."""
    prior = prior or {}
    seen = prior.get("claude_top")
    seen = -1 if seen is None else seen
    claude, full = fields.get("claude") or [], fields.get("full") is True
    top = max((r["index"] for r in claude), default=None)
    state = {"turn_row": prior.get("turn_row"), "claude_top": top if full else max(seen, -1 if top is None else top), "paged": prior.get("paged") is True}
    if full:
        state["turn_row"] = None
    streams = [r for r in claude if r["streaming"]]
    if streams:
        last = max(streams, key=lambda r: r["index"])
        state["turn_row"] = [last["key"], last["index"]]
    if isinstance(fields.get("turning"), bool):
        writing, state["paged"] = fields["turning"], True
    elif state["paged"]:
        writing = None
    elif not claude:
        writing = False if full else None
    else:
        bottom = max(claude, key=lambda r: r["index"])
        turn_row = prior.get("turn_row")
        if bottom["streaming"]:
            writing = True
        elif full or (turn_row and (bottom["key"] == turn_row[0] or bottom["index"] == turn_row[1])) or bottom["index"] >= seen:
            writing = False
        else:
            writing = None
    if writing is False:
        state["turn_row"] = None
    return writing, state


def items(value):
    """The dicts in a list, or none when the page sent anything else."""
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def strings(value):
    """A list of texts, or None when the page sent anything else."""
    return [v for v in value if isinstance(v, str)] if isinstance(value, list) else None


def thread_row(project, t):
    needs = t.get("needs")
    return row("thread", t["thread"], project=project, title=str(t.get("title") or ""), state=t.get("state") if t.get("state") in STATES else "unknown",
               needs=needs if isinstance(needs, str) and needs else None,
               text=str(t.get("text") or "")[:300], session=t["session"] if isinstance(t.get("session"), str) else None)


def side_place(event, project, thread):
    """The Seen kind and subject of the side an event is about: the project's chat, or the thread's messages."""
    thread_side = event.get("side") == "thread"
    subject = thread if thread_side else project
    return ("messages" if thread_side else "chat"), subject


def seen_rows(event):
    """The Seen rows one event makes."""
    project, thread = place(event)
    kind = event.get("type")
    if kind == "projects":
        listed = [p for p in items(event.get("projects")) if isinstance(p.get("id"), str) and p["id"].startswith("chan_")
                  and not str(p["id"]).startswith("chan_pending_")]  # a project being created has a page-made id until the server answers
        rows = [row("project", p["id"], name=str(p.get("name") or ""), where="cloud") for p in listed]
        whole = isinstance(event.get("projects"), list) and all(isinstance(p, dict) and isinstance(p.get("id"), str) for p in event["projects"])
        if event.get("complete") is True and whole:  # the projects page: every project there is, so one missing from it is gone (a list it can't read says nothing)
            rows.append(row("listing", "projects", ids=sorted(p["id"] for p in listed)))
        return rows
    if kind == "page":
        return [row("health", "page", connected=True, signed_in=event.get("signed_in"), page_ok=event.get("page_ok"), away=event.get("away"))]
    if kind == "settings" and project:  # one read of the project's settings: what the Router's tools prove themselves by
        text = lambda v: v if isinstance(v, str) else None
        return [row("settings", project, goal=text(event.get("goal")), instructions=text(event.get("instructions")), repos=strings(event.get("repos")),
                    folders=strings(event.get("folders")), offered_folders=strings(event.get("offered_folders")))]
    if kind == "threads" and project:
        if isinstance(event.get("threads"), list) and not event["threads"]:  # the project's list rendered with no rows: its threads are all finished
            return [row("threadlist", project, ids=[])]
        return [thread_row(project, t) for t in items(event.get("threads")) if isinstance(t.get("thread"), str) and t["thread"]
                and belongs(t["thread"], project)]
    if kind in ("rows", "composer") and project:
        side_kind, subject = side_place(event, project, thread)
        if not subject:
            return []
        fields = {"project": project} if side_kind == "messages" else {}
        if kind == "rows":
            # The page's own reading when it sends one; else the Board reads it from the Claude rows (`turning`)
            fields.update({"turning": event["turning"]} if isinstance(event.get("turning"), bool) else {"claude": claude_rows(event.get("rows"))})
            return [row(side_kind, subject, messages=messages(event.get("rows"), project), full=event.get("full") is True, **fields)]
        draft = event.get("draft")
        return [row(side_kind, subject, draft=draft if isinstance(draft, str) else "", disabled=event["disabled"] if isinstance(event.get("disabled"), bool) else None, **fields)]
    return []
