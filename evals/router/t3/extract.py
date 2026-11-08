"""N1: read the owner's T3 history (read-only) into evals/router/t3/data/history.json.

Reads ~/.t3/userdata/statev2.sqlite in SQLite read-only mode (never userdata/secrets). Writes threads with their
messages, runs and metadata. The output holds message text: it lives in the gitignored data/ folder."""
import glob, json, pathlib, sqlite3, sys

DB = pathlib.Path.home() / ".t3/userdata/statev2.sqlite"
OUT = pathlib.Path(__file__).parent / "data" / "history.json"

def main():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    projects = {r["project_id"]: dict(title=r["title"], root=r["workspace_root"], archived=r["archived_at"], deleted=r["deleted_at"])
                for r in con.execute("select * from projection_projects")}
    threads = {}
    for r in con.execute("select thread_id, project_id, created_at, archived_at, deleted_at, payload_json from orchestration_v2_projection_threads"):
        p = json.loads(r["payload_json"])
        threads[r["thread_id"]] = dict(
            id=r["thread_id"], project=r["project_id"], created=r["created_at"], archived=p.get("archivedAt"), deleted=p.get("deletedAt"),
            title=p.get("title") or "", createdBy=p.get("createdBy"), source=p.get("creationSource"), origin=p.get("historyOrigin"),
            lineage=p.get("lineage") or {}, forkedFrom=p.get("forkedFrom"), branch=p.get("branch"), settledAt=p.get("settledAt"),
            settledOverride=p.get("settledOverride"), provider=p.get("providerInstanceId"), titleState=None, messages=[], runs=[])
    for r in con.execute("select thread_id, title_state_json from projection_threads"):
        if r["thread_id"] in threads and r["title_state_json"]:
            threads[r["thread_id"]]["titleState"] = json.loads(r["title_state_json"])
    for r in con.execute("select thread_id, role, created_at, updated_at, payload_json from orchestration_v2_projection_messages order by created_at, message_id"):
        t = threads.get(r["thread_id"])
        if not t: continue
        p = json.loads(r["payload_json"])
        t["messages"].append(dict(role=r["role"], at=r["created_at"], upd=r["updated_at"], by=p.get("createdBy"), src=p.get("creationSource"),
                                  text=p.get("text") or "", att=len(p.get("attachments") or []), run=p.get("runId")))
    for r in con.execute("select thread_id, requested_at, completed_at, status from orchestration_v2_projection_runs"):
        t = threads.get(r["thread_id"])
        if t: t["runs"].append(dict(start=r["requested_at"], end=r["completed_at"], status=r["status"]))
    # Imported threads T3 cut ("N earlier messages were not imported": it keeps the first user message and the recent history):
    # the gap is filled from the session's own Claude transcript, text messages only, tagged src "transcript".
    cut = {r[0] for r in con.execute("select thread_id from orchestration_v2_projection_turn_items where type='system_notice' "
                                      "and json_extract(payload_json,'$.message') like '%earlier messages were not imported%'")}
    for tid in cut:
        t = threads.get(tid)
        if not t or not tid.startswith("import:claudeAgent:"): continue
        ms = sorted(t["messages"], key=lambda m: m["at"])
        if len(ms) < 2: continue
        lo, hi = ms[0]["at"], ms[1]["at"]
        added = 0
        for path in glob.glob(str(pathlib.Path.home() / f".claude/projects/*/{tid.split(':')[-1]}.jsonl")):
            for line in open(path):
                try: d = json.loads(line)
                except ValueError: continue
                if d.get("type") not in ("user", "assistant") or d.get("isSidechain") or d.get("isMeta"): continue
                at = d.get("timestamp") or ""
                if not (lo < at < hi): continue
                c = d["message"]["content"]
                texts = [c] if isinstance(c, str) else [x.get("text", "") for x in c if x.get("type") == "text"]
                text = "\n".join(x for x in texts if x)
                if not text: continue
                role = d["type"]
                t["messages"].append(dict(role=role, at=at, upd=at, by="user" if role == "user" else "agent", src="transcript",
                                          text=text, att=0, run=None))
                added += 1
        t["filled"] = added
    subs = [dict(parent=r["thread_id"], child=r["child_thread_id"], origin=r["origin"]) for r in
            con.execute("select thread_id, child_thread_id, origin from orchestration_v2_projection_subagents")]
    OUT.parent.mkdir(exist_ok=True)
    json.dump(dict(projects=projects, threads=list(threads.values()), subagents=subs), open(OUT, "w"))
    print("threads", len(threads), "messages", sum(len(t["messages"]) for t in threads.values()), file=sys.stderr)

if __name__ == "__main__":
    main()
