"""Router working summaries: real mid-run moments from the owner's T3 history (read-only) -> data/cases.json.

Reads ~/.t3/userdata/statev2.sqlite in SQLite read-only mode (never userdata/secrets). A moment is a point in a run that
went on for a while, just after the agent finished writing something mid-run: what the app's summary call reads then
(your words that started the run, the agent's latest words, the tool running next, the few before it, the to-do list),
plus, for the judge only, what the run really did around it (`around`: its words and tools from a few minutes before to
two minutes after). Two moments per run; the later one is told the earlier one's summary, as the app does. The output
holds message text: it lives in the gitignored data/ folder.

    python3 evals/router/summary/export.py                 # 30 moments (15 runs) of the last 7 days
    python3 evals/router/summary/export.py --runs 20 --seed 2
"""
import argparse, json, pathlib, random, sqlite3, sys
from datetime import datetime, timedelta, timezone

DB = pathlib.Path.home() / ".t3/userdata/statev2.sqlite"
OUT = pathlib.Path(__file__).parent / "data" / "cases.json"
TOOLS = ("command_execution", "dynamic_tool", "file_change", "web_search", "file_search", "subagent")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def first_line(s, cap=160):
    for line in (s or "").splitlines():
        line = line.strip()
        if line:
            return line if len(line) <= cap else line[:cap - 1] + "…"
    return ""


def tool(p, kind):
    """A tool item as the app reads it (RouterDetail.workStep): its own words, else the command's first line, else
    the tool's name and main object."""
    inp = p.get("input")
    own = p.get("title") or (inp.get("description") if isinstance(inp, dict) else None)
    if own:
        return dict(kind=kind, text=first_line(own), mono=False)
    if kind == "command_execution":
        return dict(kind="command", text=first_line(inp if isinstance(inp, str) else ""), mono=True)
    if kind == "file_change":
        return dict(kind="edit", text="Edited " + pathlib.Path(p.get("fileName") or "a file").name, mono=False)
    name = p.get("toolName") or kind
    obj = None
    if isinstance(inp, dict):
        obj = next((inp[k] for k in ("file_path", "pattern", "query", "url", "path") if isinstance(inp.get(k), str)), None)
    return dict(kind=name, text=name + (" · " + pathlib.Path(obj).name if obj else ""), mono=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--runs", type=int, default=15)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    since = datetime.now(timezone.utc) - timedelta(days=a.days)

    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    projects = {r["project_id"]: r["title"] for r in con.execute("select project_id, title from projection_projects")}
    children = {r[0] for r in con.execute("select child_thread_id from orchestration_v2_projection_subagents")}
    threads = {}
    for r in con.execute("select thread_id, project_id, payload_json from orchestration_v2_projection_threads"):
        p = json.loads(r["payload_json"])
        if r["thread_id"] in children or p.get("deletedAt"):
            continue
        threads[r["thread_id"]] = dict(title=p.get("title") or "", project=projects.get(r["project_id"]))

    runs = []
    for r in con.execute("select run_id, thread_id, requested_at, completed_at from orchestration_v2_projection_runs "
                         "where status='completed' and completed_at is not null"):
        start, end = ts(r["requested_at"]), ts(r["completed_at"])
        if r["thread_id"] in threads and end >= since and (end - start).total_seconds() >= 240:
            runs.append(dict(run=r["run_id"], thread=r["thread_id"], start=start, end=end))
    random.Random(a.seed).shuffle(runs)

    cases = []
    for run in runs:
        if len(cases) >= 2 * a.runs:
            break
        items = []
        for r in con.execute("select type, payload_json from orchestration_v2_projection_turn_items where run_id=? order by ordinal",
                             (run["run"],)):
            p = json.loads(r["payload_json"])
            at = ts(p.get("completedAt") or p.get("startedAt") or p.get("updatedAt"))
            started = ts(p.get("startedAt")) or at
            if r["type"] == "assistant_message" and p.get("text"):
                items.append(dict(t="said", text=p["text"], at=at, started=started))
            elif r["type"] == "user_message" and p.get("text"):
                items.append(dict(t="you", text=p["text"], at=at, started=started))
            elif r["type"] == "todo_list":
                items.append(dict(t="todo", steps=p.get("steps") or [], at=at, started=started))
            elif r["type"] in TOOLS:
                items.append(dict(t="tool", tool=tool(p, r["type"]), at=at, started=started))
        said = [i for i, x in enumerate(items) if x["t"] == "said"]
        # Mid-run words: not the run's last message, with a tool after them.
        mid = [i for i in said[:-1] if any(x["t"] == "tool" for x in items[i + 1:])]
        if len(mid) < 2:
            continue
        picks = [mid[len(mid) // 4], mid[(3 * len(mid)) // 4]]
        if picks[0] == picks[1]:
            continue
        you = next((x["text"] for x in items if x["t"] == "you"), None)
        if not you:
            # The words that started the run, else the last you wrote in the thread before it.
            row = con.execute("select payload_json from orchestration_v2_projection_messages where thread_id=? and role='user' "
                              "and (run_id=? or created_at <= ?) order by (run_id=?) desc, created_at desc limit 1",
                              (run["thread"], run["run"], run["start"].isoformat().replace("+00:00", "Z"), run["run"])).fetchone()
            you = json.loads(row[0]).get("text") if row else None
        prev = None
        for n, i in enumerate(picks):
            moment = items[i]["at"]
            before = [x for x in items[:i] if x["t"] == "tool"]
            after = next((x for x in items[i + 1:] if x["t"] == "tool"), None)
            todo = next((x["steps"] for x in reversed(items[:i + 1]) if x["t"] == "todo"), [])
            lo, hi = moment - timedelta(minutes=6), moment + timedelta(minutes=2)
            around = []
            for x in items:
                if not (lo <= (x["started"] or moment) <= hi):
                    continue
                tag = "NOW → " if x is items[i] else ""
                if x["t"] == "said":
                    around.append(tag + "agent wrote: " + x["text"][:1200])
                elif x["t"] == "tool":
                    around.append(tag + "tool: " + x["tool"]["text"])
            t = threads[run["thread"]]
            cid = f"{run['thread'][:8]}-{run['run'].rsplit(':', 1)[-1]}-{n}"
            cases.append(dict(id=cid, thread=run["thread"], run=run["run"], at=moment.isoformat(), title=t["title"],
                              project=t["project"], yourWords=you, said=items[i]["text"],
                              now=after["tool"] if after else None,
                              recent=[x["tool"] for x in reversed(before[-3:])],
                              steps=[dict(text=s.get("text", ""), status=s.get("status", "")) for s in todo],
                              prev=prev, around=around[-40:]))
            prev = cid
    OUT.parent.mkdir(exist_ok=True)
    json.dump(cases, open(OUT, "w"), indent=1)
    print(f"{len(runs)} long runs in {a.days} days; kept {len(cases)} moments -> {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
