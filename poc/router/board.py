"""The Board: projects and threads right now, folded from Seen. `fold` is pure: same rows, same board."""
import page

TRUST = {"files": 3, "page": 2, "coordinator": 1}  # local process and files, then the thread on the page, then coordinator chat
FINISHED = ("idle", "resolved")
KEEP_ROWS = 100  # the page holds only the latest rows; so does the Board
THREAD_FIELDS = ("active", "project", "title", "state", "needs", "detail", "text", "session", "alive", "result")


def known(value):
    return value is not None and value != "unknown"


def merge(by_source):
    """Each field comes from the most trusted source that knows it."""
    out = {}
    for source in sorted(by_source, key=lambda s: -TRUST.get(s, 0)):
        for key, value in by_source[source].items():
            if known(value) and key not in out:
                out[key] = value
    return out


def merge_rows(old, new, full=False):
    """Rows by key, in page order: a changed row replaces its old self. A `full` scan replaces the place's rows. A new list every time,
    so a finished board can share the old one."""
    by_key = {} if full else {m["key"]: m for m in old or []}
    by_key.update({m["key"]: m for m in new or []})
    return sorted(by_key.values(), key=lambda m: m["index"])[-KEEP_ROWS:]


def settled(m):
    """A row that counts: the server has it (pending rows never reach the Board), and a Claude row is not still being written."""
    return m.get("from") != "claude" or not m.get("streaming")


def thread_step(threads, latest, row):
    t = threads.setdefault(row["subject"], {"id": row["subject"], "turn": 0, "touched": row["at"], "last": None, "view": {}})
    by_source = latest.setdefault(("thread", row["subject"]), {})
    by_source[row["source"]] = row["fields"]
    view = merge(by_source)
    state = view.get("state")
    if state:
        asks = state == "needs_you" and t["last"] == "needs_you" and view.get("needs") and t["view"].get("needs") not in (None, view["needs"])
        if t["last"] is None or (state == "working" and t["last"] != "working") or asks:  # a second question is a new turn
            t["turn"] += 1
        t["last"] = state
    if view.get("active"):
        t["touched"] = view["active"]
    elif view != t["view"]:
        t["touched"] = row["at"]
    t["view"] = view


def finish_thread(t, app=None):
    """A local thread whose process was seen alive and is gone is stranded, unless the Claude app itself is closed (`app` False):
    then it waits for the app."""
    view = t.pop("view")
    t.pop("last")
    t.update({k: view.get(k) for k in THREAD_FIELDS})
    t["state"] = t["state"] or "unknown"
    t["local"] = t["alive"] is not None
    if t["alive"] is False and t["state"] not in FINISHED:
        t["state"] = "waiting_app" if app is False else "stranded"
    return t


def start(told=0):
    """An empty fold state. `step` adds rows to it; `finish` reads a board from it without changing it.
    `claims` holds only the claims past the told mark (a row id), so the list stays as short as what hasn't been told."""
    return {"projects": {}, "threads": {}, "latest": {}, "claims": [], "told": told, "seen_claims": set(), "last_local": {}, "newest": 0, "here": None, "listed": None, "seen": {},
            "app": None, "app_since": None,
            "health": {"connected": None, "signed_in": None, "page_ok": None}}


def step(acc, row):
    kind, subject, fields = row["kind"], row["subject"], row["fields"]
    projects, threads, latest = acc["projects"], acc["threads"], acc["latest"]
    if row["source"] == "files":
        acc["newest"] = max(acc["newest"], row["at"])
        if subject.startswith("local:"):
            acc["last_local"][subject] = row["at"]
    if row["source"] == "page" and kind in ("chat", "messages", "thread"):  # the page shows a project's chat and threads only while it is open
        project = subject if kind == "chat" else fields.get("project")
        if project:
            acc["seen"][project] = max(acc["seen"].get(project, 0), row["at"])
    if kind == "health" and row["source"] == "page":
        acc["health"] = {**acc["health"], **fields}
    elif kind == "app":  # whether the Claude app runs, and since when it has been so
        if acc["app"] != fields["running"]:
            acc["app"], acc["app_since"] = fields["running"], row["at"]
    elif kind == "project":
        if acc["listed"] is not None and subject not in projects:  # new to the Board after a full list: it was made since, not left out of it
            acc["listed"].add(subject)
        latest.setdefault(("project", subject), {})[row["source"]] = fields
        p = projects.setdefault(subject, {"id": subject, "chat": None, "draft": None, "readable": None})
        p.update(merge(latest[("project", subject)]))
    elif kind == "settings":
        projects.setdefault(subject, {"id": subject, "chat": None, "draft": None})["settings"] = dict(fields)
    elif kind == "chat":
        p = projects.setdefault(subject, {"id": subject, "chat": None, "draft": None})
        # A turning-only delta (no rows, not full) before the place's first whole read says nothing of its rows: it leaves them unread.
        if "messages" in fields and not (p.get("chat") is None and not fields["messages"] and not fields.get("full")):
            p["chat"] = merge_rows(p.get("chat"), fields["messages"], fields.get("full"))
        if "messages" in fields:  # a rows event: whether a reply is being written, against what the place showed before
            writing, p["turn_state"] = page.turning(fields, p.get("turn_state"))
            p.update({} if writing is None else {"turning": writing})
        p.update({k: fields[k] for k in ("draft", "disabled") if k in fields})
    elif kind == "thread":
        thread_step(threads, latest, row)
    elif kind == "messages":
        t = threads.setdefault(subject, {"id": subject, "turn": 0, "touched": row["at"], "last": None, "view": {}})
        # A turning-only delta (no rows, not full) before the place's first whole read says nothing of its rows: it leaves them unread.
        if "messages" in fields and not (t.get("messages") is None and not fields["messages"] and not fields.get("full")):
            t["messages"] = merge_rows(t.get("messages"), fields["messages"], fields.get("full"))
        if "messages" in fields:  # a rows event: whether a reply is being written, against what the place showed before
            writing, t["turn_state"] = page.turning(fields, t.get("turn_state"))
            t.update({} if writing is None else {"turning": writing})
        t.update({k: fields[k] for k in ("draft", "disabled") if k in fields})
    elif kind == "listing":
        acc["listed"] = set(fields["ids"])
    elif kind == "claim" and (fields["project"], fields["key"]) not in acc["seen_claims"]:
        acc["seen_claims"].add((fields["project"], fields["key"]))
        if row["id"] > acc["told"]:
            acc["claims"].append({"id": row["id"], "at": row["at"], **fields})


def finish(acc):
    gone = {s for s, at in acc["last_local"].items() if at < acc["newest"]}
    threads = {k: finish_thread(dict(t), acc["app"]) for k, t in acc["threads"].items() if k not in gone and t["view"]}
    listed = acc["listed"]  # cloud projects the last full list left out were deleted or archived
    projects = {k: dict(p) for k, p in acc["projects"].items() if k not in gone and (listed is None or p.get("where") != "cloud" or k in listed)}
    here = (acc["here"] or (None,))[0]
    for k, t in threads.items():
        t.setdefault("messages", None)
        t.setdefault("draft", None)
        files = known(acc["latest"].get(("thread", k), {}).get("files", {}).get("state"))
        live = k.startswith("local:") or files or (here is not None and t["project"] == here)
        t["as_of"] = None if live else acc["seen"].get(t["project"], t["touched"])  # a cloud thread elsewhere is only as fresh as the last visit
    for p in projects.values():
        p["seen"] = acc["seen"].get(p["id"])
        p.setdefault("name", p["id"])
        p.setdefault("where", None)
        p.setdefault("purpose", "")
        p.setdefault("settings", None)
    return {"health": dict(acc["health"]), "app": acc["app"], "app_since": acc["app_since"], "here": acc["here"], "projects": projects,
            "threads": threads, "claims": list(acc["claims"])}


def fold_into(acc, rows):
    for row in sorted(rows, key=lambda r: (r["at"], r["id"])):
        step(acc, row)
    return acc


def fold(rows):
    return finish(fold_into(start(), rows))


def project_named(board, name):
    """A project by id or by name."""
    if name in board["projects"]:
        return board["projects"][name]
    return next((p for p in board["projects"].values() if p["name"] == name), None)


def loose(text):
    """Letters and digits only, in lower case: the page renders Markdown, so a row never matches the typed words character for character."""
    text = text or ""
    return "".join(c for c in text.casefold() if c.isalnum()) or squash(text)


def tokens(text):
    """The words of a text: its runs of letters and digits, in lower case. A row that starts with a send's words starts with all its
    tokens, so "yes" is no prefix of "Yesterday's build broke"."""
    out, word = [], ""
    for c in (text or "").casefold():
        if c.isalnum():
            word += c
        elif word:
            out, word = out + [word], ""
    return out + [word] if word else out


def starts_with(text, words):
    """The text's first tokens are all the words' tokens (a prefix ending on a word boundary). Words with no token start nothing."""
    mine = tokens(words)
    return bool(mine) and tokens(text)[:len(mine)] == mine


def ends_shortly(text, words):
    """The text starts with the words (`starts_with`) and adds at most min(3, the words' token count - 1) tokens: a row may carry a
    few rendered words after the message, but a short send must match (nearly) exactly, a 1-token one ("yes", "ok") exactly, so a
    hand-typed message that starts with it can't prove it."""
    mine = tokens(words)
    return starts_with(text, words) and len(tokens(text)) - len(mine) <= min(3, len(mine) - 1)


def squash(text):
    """Whitespace normalized: how drafts are compared, so multi-line words can't differ by a line break."""
    return " ".join((text or "").split())


def place_of(board, project, thread=None):
    return board["threads"].get(thread) if thread else board["projects"].get(project)


def rows_of(place, thread=None):
    """A place's rows in page order, or None when they haven't been read."""
    return (place or {}).get("messages" if thread else "chat")


def placed_by(proof):
    """The keys a read is placed against: the baseline's, and the anchors, Claude's rows that reads placed after it (`do.anchor`)."""
    return set(proof.get("baseline") or ()) | set(proof.get("anchors") or ())


def new_rows(board, proof):
    """The rows after the last one whose key was in the baseline, in current order. A read that holds no baseline key (a busy chat whose
    window scrolled past it) is placed by the anchors instead: the rows after the earliest one it holds, since your row, queued while they
    were written, can take its key before the later ones. All of them when the baseline is empty (an empty chat) and nothing is
    anchored. None when unreadable. Rows that hold none of those keys can't be placed against them (a reloaded page's window of older
    history, whose keys Fjord never saw, would look new): none of them is new, and a later read that holds one of the keys says."""
    messages = rows_of(place_of(board, proof["project"], proof.get("thread")), proof.get("thread"))
    if messages is None:
        return None
    baseline, anchors = set(proof.get("baseline") or ()), set(proof.get("anchors") or ())
    last = max((i for i, m in enumerate(messages) if m["key"] in baseline), default=None)
    if last is None:
        last = min((i for i, m in enumerate(messages) if m["key"] in anchors), default=None)
    if last is None:
        return messages if not (baseline or anchors) else []
    return messages[last + 1:]


def from_you(board, proof, claimed=()):
    """New rows from you in the proof's place, or None when the place can't be read. A `claimed` row already proved another send: one
    row proves one send, so it is another message's, not this one's."""
    rows = new_rows(board, proof)
    return None if rows is None else [m for m in rows if m.get("from") == "you" and m["key"] not in claimed]


def assign(board, proofs, claimed=()):
    """{id: key}: the new rows from you given to the sends of one place, `proofs` ([(id, proof)], in priority order), together, so a
    row goes to the send whose words it is. First each send takes its earliest new row whose words (loosely) equal its own; only then
    does one with none take its earliest row that starts with its words and adds only a few (`ends_shortly`), the longest words choosing
    first, and never a row taken or one whose words equal another send's (that row is the other send's message, even if not new to
    it). `claimed` rows proved earlier sends: no one takes them."""
    rows = {i: from_you(board, p, claimed) or [] for i, p in proofs}
    words = {i: loose(p["words"]) for i, p in proofs}
    taken = {}
    for i, _ in proofs:
        row = next((m for m in rows[i] if m["key"] not in taken.values() and loose(m.get("text")) == words[i]), None)
        if row:
            taken[i] = row["key"]
    exact = set(words.values())
    # The longest words first (priority breaks a tie: the sort is stable): a row that starts with two sends' words is the longer one's.
    for i, _ in sorted(proofs, key=lambda p: -len(words[p[0]])):
        if i not in taken:
            row = next((m for m in rows[i] if m["key"] not in taken.values() and loose(m.get("text")) not in exact
                        and ends_shortly(m.get("text"), dict(proofs)[i]["words"])), None)
            if row:
                taken[i] = row["key"]
    return taken


def others(board, proofs, taken, i):
    """The keys of rows that are another send's of the place than `i`'s: taken by it (`assign`), or with exactly its words."""
    words = {loose(p["words"]) for j, p in proofs if j != i}
    mine = dict(proofs)[i]
    rows = {m["key"] for m in from_you(board, mine) or () if loose(m.get("text")) in words}
    return ({k for j, k in taken.items() if j != i} | rows) - {taken.get(i)}


def proving_row(board, proof, claimed=()):
    """The earliest new row from you, not `claimed`, that has these words (loosely: equal first, else starting with them), else None."""
    key = assign(board, [(None, proof)], claimed).get(None)
    return next((m for m in from_you(board, proof, claimed) or () if m["key"] == key), None) if key else None


def proof_holds(board, proof, claimed=()):
    """True when a new row from you has these words (loosely), False when none matches, None when unreadable."""
    rows = from_you(board, proof, claimed)
    return None if rows is None else proving_row(board, proof, claimed) is not None
