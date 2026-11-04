"""Tell: Board changes, minus what you were already told, as a brief. The fact-diff and the plan are pure."""

import board as boards
import context

WINDOW = 120  # seconds: a finish on the thread and the coordinator saying so this close are one fact. Nothing else is deduped
LAST = 120  # characters of a stranded thread's last state in its line
STRANDS = ("working", "needs_you", "waiting_app")  # a thread lost from one of these is news; one already done or unknown isn't


def fact(t, kind):
    title = t["title"] or t["id"]
    last = boards.squash(t["detail"] or t["text"] or "")[:LAST]
    text = {"finished": f"{title}: finished", "needs_you": f"{title}: needs you" + (f" ({t['needs']})" if t["needs"] else ""),
            "stranded": f"«{title}» lost its process" + (f"; last: {last}" if last else "") + ". Reply to continue it in a new thread."}[kind]
    return {"key": f"{t['id']}|{kind}|{t['turn']}", "kind": kind, "thread": t["id"], "project": t["project"], "text": text,
            "detail": (t["detail"] or t["text"] or "")[:200], "as_of": t.get("as_of")}


def change(old, new):
    state, later = new["state"], old is None or new["turn"] > old["turn"]
    if state == "stranded":
        return state if old and old["state"] in STRANDS else None
    if state == "needs_you" and (old is None or old["state"] != state or later):
        return state
    if state in boards.FINISHED and old and (old["state"] == "working" or later):
        return "finished"


def standing(after):
    """Facts that still hold, so a told one can be updated quietly when its detail changes."""
    kinds = {"needs_you": "needs_you", "stranded": "stranded", "idle": "finished", "resolved": "finished", "done": "finished"}
    return [fact(t, kinds[t["state"]]) for t in after["threads"].values() if t["state"] in kinds]


def app_fact(before, after):
    """The Claude app closed with threads in it: one line for them all, instead of one per thread."""
    waiting = [t for t in after["threads"].values() if t["state"] == "waiting_app"]
    if before.get("app") is not False and after.get("app") is False and waiting:
        n = len(waiting)
        return {"key": f"app|closed|{after['app_since']}", "kind": "app_closed", "thread": None, "project": None,
                "text": f"Claude app closed; {n} thread{'s' * (n != 1)} waiting", "detail": "", "as_of": None}


def facts(before, after):
    out = [fact(t, kind) for tid, t in after["threads"].items() if (kind := change(before["threads"].get(tid), t))]
    out += [f for f in [app_fact(before, after)] if f]
    return sorted(out, key=lambda f: f["key"])


def holds(f, board):
    """Whether a fact found earlier is still so at the tell: a stranded thread or a closed app may be back by then. The rest stay news."""
    if f["kind"] == "stranded":
        return board["threads"].get(f["thread"], {}).get("state") == "stranded"
    if f["kind"] == "app_closed":
        return board.get("app") is False
    return True


def claim_key(c):
    return f"{c['project']}|claim|{c['key']}"


def aged(f, now):
    """A fact seen on an earlier visit to its project says how old it is; a live one is said as it is."""
    return {**f, "text": f["text"] + context.as_of(f, now)} if f.get("as_of") is not None else f


def plan(found, told, claims, now, window=WINDOW):
    """told: key -> row. Returns what to say and what to record quietly (a later version of a fact, or a repeat)."""
    found = [aged(f, now) for f in found]
    said_claims = {t["project"] for t in told.values() if t["kind"] == "claim" and now - t["at"] <= window}  # quiets only a finish
    say, quiet = [], []
    for f in found:
        old = told.get(f["key"])
        if old:
            if old["detail"] != f["detail"]:
                quiet.append(f)
        elif f["kind"] == "finished" and f["project"] in said_claims:
            quiet.append(f)
        else:
            say.append(f)
    live = {f["project"] for f in found if f["kind"] == "finished"} | {t["project"] for t in told.values() if t["kind"] == "finished" and now - t["at"] <= window}
    for c in claims:
        key = claim_key(c)
        if key in told:
            continue
        item = {"key": key, "kind": "claim", "thread": c.get("thread"), "project": c["project"], "text": c["text"], "detail": ""}
        if c.get("baseline") and not c.get("decision"):
            quiet.append(item)
        elif c.get("decision") or c["project"] not in live:
            say.append(item)
        else:
            quiet.append({**item, "kind": "claim_quiet"})
    return say, quiet
