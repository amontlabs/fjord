"""Router v2 verdicts: real moments from the owner's T3 history (read-only) -> data/cases.json.

Reads ~/.t3/userdata/statev2.sqlite in SQLite read-only mode (never userdata/secrets). A case is a moment the app asks a
verdict for: a finished turn (a completed run: your words that started it, its last reply, the files its checkpoints
changed, the PRs linked by then with their state at the run's end) or an ask (a question or permission T3 raised, with
the reply before it). The output holds message text: it lives in the gitignored data/ folder.

    python3 evals/router/verdict/export.py                 # 150 finished turns of the last 7 days, every ask
    python3 evals/router/verdict/export.py --days 14 --finished 300 --seed 2
"""
import argparse, hashlib, json, pathlib, random, sqlite3, sys
from datetime import datetime, timedelta, timezone

DB = pathlib.Path.home() / ".t3/userdata/statev2.sqlite"
OUT = pathlib.Path(__file__).parent / "data" / "cases.json"
# T3 sends a permission's options live only; these are its labels for Claude (FEASIBILITY.md, 14 of 17 requests).
PERMISSION_OPTIONS = ["Allow once", "Allow for this thread", "Deny", "Cancel"]


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--finished", type=int, default=150)
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
        if r["thread_id"] in children or p.get("archivedAt") or p.get("deletedAt"):
            continue
        threads[r["thread_id"]] = dict(title=p.get("title") or "", project=projects.get(r["project_id"]), prs=p.get("pullRequests") or [])

    msgs = {}
    for r in con.execute("select thread_id, run_id, role, created_at, payload_json from orchestration_v2_projection_messages order by created_at"):
        if r["thread_id"] in threads:
            msgs.setdefault(r["thread_id"], []).append(dict(run=r["run_id"], role=r["role"], at=ts(r["created_at"]),
                                                            text=json.loads(r["payload_json"]).get("text") or ""))
    files = {}
    for r in con.execute("select run_id, payload_json from orchestration_v2_projection_checkpoints where run_id is not null"):
        for f in json.loads(r["payload_json"]).get("files") or []:
            files.setdefault(r["run_id"], {})[f.get("path")] = (f.get("additions") or 0, f.get("deletions") or 0)

    def first_ask(tid):
        return next((m["text"] for m in msgs.get(tid, []) if m["role"] == "user" and m["text"]), None)

    def prs_at(tid, end):
        out = []
        for pr in threads[tid]["prs"]:
            if not pr.get("linkedAt") or ts(pr["linkedAt"]) > end:
                continue
            s = pr.get("snapshot") or {}
            state = "merged" if s.get("mergedAt") and ts(s["mergedAt"]) <= end else \
                    "closed" if s.get("closedAt") and ts(s["closedAt"]) <= end else "open"
            out.append(dict(url=pr["url"], number=pr.get("number"), state=state))
        return out

    def base(tid, kind, at, key):
        t = threads[tid]
        return dict(id=f"{tid[:8]}-{key}", kind=kind, thread=tid, at=at.isoformat(), title=t["title"], project=t["project"],
                    firstAsk=first_ask(tid))

    finished = []
    for r in con.execute("select run_id, thread_id, ordinal, completed_at from orchestration_v2_projection_runs where status='completed'"):
        tid, end = r["thread_id"], ts(r["completed_at"])
        if tid not in threads or not end or end < since:
            continue
        mine = [m for m in msgs.get(tid, []) if m["run"] == r["run_id"]]
        reply = next((m["text"] for m in reversed(mine) if m["role"] == "assistant" and m["text"]), None)
        if not reply:
            continue
        c = base(tid, "finished", end, f"r{r['ordinal']}")
        c.update(run=r["run_id"], yourWords=next((m["text"] for m in reversed(mine) if m["role"] == "user" and m["text"]), None),
                 reply=reply, prs=prs_at(tid, end))
        fs = files.get(r["run_id"], {})
        c["files"] = sorted(fs)
        c["diff"] = dict(files=len(fs), added=sum(v[0] for v in fs.values()), removed=sum(v[1] for v in fs.values())) if fs else None
        finished.append(c)

    asks = []
    for r in con.execute("select turn_item_id, thread_id, run_id, type, payload_json from orchestration_v2_projection_turn_items "
                         "where type in ('approval_request', 'user_input_request')"):
        tid = r["thread_id"]
        if tid not in threads:
            continue
        p = json.loads(r["payload_json"])
        at = ts(p.get("startedAt") or p.get("updatedAt"))
        if not at:
            continue
        if r["type"] == "approval_request":
            request = dict(kind="permission", words=p.get("prompt") or p.get("title") or "", options=PERMISSION_OPTIONS)
        else:
            qs = p.get("questions") or []
            request = dict(kind="form" if len(qs) > 1 else "question", words="\n".join(q.get("question", "") for q in qs),
                           options=[o.get("label", "") for o in qs[0].get("options", [])] if len(qs) == 1 else [])
        before = [m for m in msgs.get(tid, []) if m["at"] and m["at"] <= at]
        c = base(tid, "ask", at, "q" + hashlib.sha1(r["turn_item_id"].encode()).hexdigest()[:6])
        c.update(run=r["run_id"], yourWords=next((m["text"] for m in reversed(before) if m["role"] == "user" and m["text"]), None),
                 reply=next((m["text"] for m in reversed(before) if m["role"] == "assistant" and m["text"]), None),
                 request=request, prs=prs_at(tid, at), files=[], diff=None)
        asks.append(c)

    random.Random(a.seed).shuffle(finished)
    cases = sorted(finished[:a.finished], key=lambda c: c["at"]) + sorted(asks, key=lambda c: c["at"])
    OUT.parent.mkdir(exist_ok=True)
    json.dump(cases, open(OUT, "w"), indent=1)
    print(f"{len(finished)} finished turns in {a.days} days, kept {min(len(finished), a.finished)}; {len(asks)} asks -> {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
