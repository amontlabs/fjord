"""What the model sees when it routes: a pure query with a hard size limit."""
import hashlib

CAP = 14000  # characters
PURPOSE = 600  # a project's description: at 140 Sonnet's picks were often wrong on terse messages
LIVE_HOURS = 24
LAST_MESSAGES = 8
SENDS = ("send_to_project", "reply_in_thread")


def age(seconds):
    if seconds < 3600:
        return f"{int(seconds / 60)}m"
    if seconds < 86400:
        return f"{int(seconds / 3600)}h"
    return f"{int(seconds / 86400)}d"


def as_of(t, now):
    """The marker of a state seen on an earlier visit, empty for a live one."""
    return f" (as of {age(now - t['as_of'])} ago)" if t.get("as_of") is not None else ""


def rank(t, now):
    order = {"needs_you": 0, "stranded": 1, "working": 2, "waiting_app": 2}
    return (order.get(t["state"], 3), -t["touched"])


def live_threads(board, now):
    keep = [t for t in board["threads"].values()
            if t["state"] in ("working", "needs_you", "stranded", "waiting_app") or now - t["touched"] <= LIVE_HOURS * 3600]
    return sorted(keep, key=lambda t: rank(t, now))


def thread_line(board, t, now):
    project = board["projects"].get(t["project"], {}).get("name", t["project"])
    flags = [t["state"] + as_of(t, now)] + [f"needs: {t['needs']}"] * bool(t["needs"])
    return f"- {t['id']} | {project} | {t['title'] or 'untitled'} | {', '.join(flags)}" + (f" | {(t['detail'] or '')[:100]}" if t["detail"] else "")


def project_name(board, pid):
    return board["projects"].get(pid, {}).get("name", pid) if pid else pid


def message_lines(board, intents, now, limit):
    sent = [i for i in intents if i["tool"] in SENDS or i["status"] in ("answered", "asked")][-limit:]
    lines = []
    for i in sent:
        if i["status"] in ("answered", "asked"):
            where = "you, the manager"
        else:
            where = project_name(board, (i["correction"] or {}).get("project") or i["project"]) or "unknown"
            where += " (corrected)" * bool(i["correction"])
        handoff = (i.get("args") or {}).get("continues") if i["tool"] in SENDS else None  # the owner's words, sent on to continue a stranded thread
        where += f" (to continue thread {handoff} in a new one)" * bool(handoff)
        lines.append(f"- {age(now - i['at'])} ago, to {where}: {((i.get('args') or {}).get('message') if handoff else i['words'])[:200]}")
    return lines


def render(board, notes, intents, now, threads, messages, purpose):
    projects = [f"- {p['name']} | {p['where'] or 'unknown'} | {p['purpose'][:purpose]}" for p in sorted(board["projects"].values(), key=lambda p: p["name"])]
    parts = [("Notes", [f"- {k}: {v}" for k, v in sorted(notes.items())]), ("Projects", projects),
             ("Live threads", [thread_line(board, t, now) for t in threads]), ("Your recent messages, oldest first", message_lines(board, intents, now, messages))]
    return "\n\n".join(f"{title}:\n" + ("\n".join(lines) or "(none)") for title, lines in parts)


def build(board, notes, intents, now, cap=CAP):
    """Returns (text, hash). Over the cap, live threads go first (least urgent last), then older messages, then purposes."""
    threads, messages, purpose = live_threads(board, now), LAST_MESSAGES, PURPOSE
    text = render(board, notes, intents, now, threads, messages, purpose)
    while len(text) > cap:
        if threads:
            threads = threads[:-1]
        elif messages > 2:
            messages -= 1
        elif purpose > 0:
            purpose = max(0, purpose - 40)
        else:
            text = text[:cap]
            break
        text = render(board, notes, intents, now, threads, messages, purpose)
    return text, hashlib.sha1(text.encode()).hexdigest()[:12]
