"""Router open-items eval: real sequences of inputs (turn ends and owner messages) from the owner's T3 history
(read-only) -> data/cases.json.

Reads ~/.t3/userdata/statev2.sqlite in SQLite read-only mode (never userdata/secrets). Per non-subagent thread, the
inputs the open-items engine reads are put in time order: a `turn` (a run that ended and has assistant text) and a
`message` (the owner's words). A run's own message is the one its payload names as `userMessageId`; an owner message
with a run id that is not its run's `userMessageId` was sent into a live run (a steer). Windows of 3 to 8 steps with at
least 2 turns are sampled to meet quotas on tags (wake, asks, steer, answers, restates). The tags only bias sampling:
the eval judges blind. The output holds message text: it lives in the gitignored data/ folder.

    python3 evals/router/items/export.py                  # last 7 days (widens to 14, then 21, if quotas fail)
    python3 evals/router/items/export.py --days 14 --seed 2
"""
import argparse, collections, json, pathlib, random, re, sqlite3, sys
from datetime import datetime, timedelta, timezone

DB = pathlib.Path.home() / ".t3/userdata/statev2.sqlite"
OUT = pathlib.Path(__file__).parent / "data" / "cases.json"
QUOTAS = dict(wake=12, asks=15, steer=8, answers=10, restates=6)
MIN_SEQ, MIN_STEPS, MAX_STEPS, PER_THREAD = 45, 3, 8, 3
ASK_PHRASES = ("want me to", "should i", "do you want", "your call", "let me know")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def asks(reply):
    tail = (reply or "").strip()
    if re.sub(r"[\s\"'`*_)\]”’]+$", "", tail).endswith("?"):
        return True
    low = tail[-700:].lower()
    return any(p in low for p in ASK_PHRASES)


def load(days):
    since = datetime.now(timezone.utc) - timedelta(days=days)
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    projects = {r["project_id"]: r["title"] for r in con.execute("select project_id, title from projection_projects")}
    children = {r[0] for r in con.execute("select child_thread_id from orchestration_v2_projection_subagents")}
    threads = {}
    for r in con.execute("select thread_id, project_id, payload_json from orchestration_v2_projection_threads"):
        p = json.loads(r["payload_json"])
        if (r["thread_id"] in children or r["thread_id"].startswith("thread:delegated-task:")
                or (p.get("lineage") or {}).get("relationshipToParent") == "subagent" or p.get("deletedAt")):
            continue
        threads[r["thread_id"]] = dict(title=p.get("title") or "", project=projects.get(r["project_id"]) or p.get("workspaceRoot"))
    msgs = collections.defaultdict(list)
    for r in con.execute("select message_id, thread_id, run_id, role, created_at, payload_json from orchestration_v2_projection_messages "
                         "where run_id is not null order by created_at"):
        if r["thread_id"] in threads:
            p = json.loads(r["payload_json"])
            msgs[r["thread_id"]].append(dict(id=r["message_id"], run=r["run_id"], role=r["role"], at=ts(r["created_at"]),
                                             by=p.get("createdBy"), text=p.get("text") or ""))
    runs = collections.defaultdict(list)
    for r in con.execute("select run_id, thread_id, status, requested_at, completed_at, payload_json from orchestration_v2_projection_runs "
                         "order by ordinal"):
        if r["thread_id"] in threads:
            runs[r["thread_id"]].append(dict(run=r["run_id"], status=r["status"], req=ts(r["requested_at"]), end=ts(r["completed_at"]),
                                             umid=json.loads(r["payload_json"]).get("userMessageId")))
    return since, threads, msgs, runs


def steps_of(tid, msgs, runs):
    ms = msgs[tid]
    by_id = {m["id"]: m for m in ms}
    starter = {r["umid"] for r in runs[tid]}
    out = []
    for r in runs[tid]:
        if not r["end"]:
            continue
        reply = next((m["text"] for m in reversed(ms) if m["run"] == r["run"] and m["role"] == "assistant" and m["text"].strip()), None)
        if not reply:
            continue
        own = by_id.get(r["umid"])
        by_user = bool(own and own["by"] == "user")
        woke = own["text"][:600] if own and not by_user else None
        out.append(dict(kind="turn", run=r["run"], status=r["status"], at=r["end"].isoformat().replace("+00:00", "Z"), _t=r["end"],
                        _req=r["req"], reply=reply, started=own["text"] if by_user else None, woke=woke, wake=woke is not None))
    for m in ms:
        if m["role"] != "user" or m["by"] != "user" or not m["text"].strip():
            continue
        during = None if m["id"] in starter else m["run"]
        before = next((x["text"] for x in reversed(ms) if x["role"] == "assistant" and x["text"].strip() and x["at"] < m["at"]), "")
        out.append(dict(kind="message", id=m["id"], at=m["at"].isoformat().replace("+00:00", "Z"), _t=m["at"], text=m["text"],
                        during=during, replyBefore=before[-1500:]))
    out.sort(key=lambda s: (s["_t"], s["kind"] == "turn"))
    return out


def tags_of(w):
    tags = set()
    for i, s in enumerate(w):
        if s["kind"] == "message" and s["during"]:
            tags.add("steer")
        if s["kind"] != "turn":
            continue
        if any(t["kind"] == "turn" and t["wake"] and 0 <= (t["_req"] - s["_t"]).total_seconds() <= 600 for t in w[i + 1:]):
            tags.add("wake")
        if asks(s["reply"]):
            tags.add("asks")
            nxt = w[i + 1] if i + 1 < len(w) else None
            if nxt and nxt["kind"] == "message" and not nxt["during"]:
                tags.add("answers")
            if nxt and nxt["kind"] == "turn":
                tags.add("restates")
    return tags


def select(cands, seed):
    rnd = random.Random(seed)
    chosen, per = [], collections.Counter()
    counts = collections.Counter()

    def free(c):
        return per[c["tid"]] < PER_THREAD and not any(
            c["tid"] == d["tid"] and c["lo"] < d["hi"] and d["lo"] < c["hi"] for d in chosen)

    def take(c):
        chosen.append(c); per[c["tid"]] += 1; counts.update(c["tags"])

    for tag in sorted(QUOTAS, key=lambda t: sum(t in c["tags"] for c in cands)):
        while counts[tag] < QUOTAS[tag]:
            pool = [c for c in cands if tag in c["tags"] and free(c)]
            if not pool:
                break
            need = lambda c: sum(counts[t] < QUOTAS[t] for t in c["tags"])
            best = max(need(c) for c in pool)
            take(rnd.choice([c for c in pool if need(c) == best]))
    rest = [c for c in cands if free(c)]
    rnd.shuffle(rest)
    rest.sort(key=lambda c: per[c["tid"]])
    for c in rest:
        if len(chosen) >= MIN_SEQ:
            break
        if free(c):
            take(c)
    return chosen, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", help="another cases file (a held-out set)")
    ap.add_argument("--exclude", help="a cases file whose steps (runs, messages) no window may contain")
    a = ap.parse_args()
    global OUT
    if a.out:
        OUT = pathlib.Path(a.out)
    seen = set()
    if a.exclude:
        for c in json.load(open(a.exclude)):
            for s in c["steps"]:
                seen.add(s.get("run") or s.get("id"))
    for days in sorted({a.days, 14, 21} if a.days <= 21 else {a.days}):
        if days < a.days:
            continue
        since, threads, msgs, runs = load(days)
        cands = []
        for tid in threads:
            st = [s for s in steps_of(tid, msgs, runs) if s["_t"] >= since]
            for lo in range(len(st)):
                for n in range(MIN_STEPS, MAX_STEPS + 1):
                    w = st[lo:lo + n]
                    if len(w) == n and sum(s["kind"] == "turn" for s in w) >= 2 \
                            and not any((s.get("run") or s.get("id")) in seen for s in w):
                        cands.append(dict(tid=tid, lo=lo, hi=lo + n, w=w, tags=tags_of(w)))
        chosen, counts = select(cands, a.seed)
        if len(chosen) >= MIN_SEQ and all(counts[t] >= q for t, q in QUOTAS.items()):
            break
        print(f"{days} days: quotas not met ({len(chosen)} sequences, {dict(counts)}); widening", file=sys.stderr)

    chosen.sort(key=lambda c: (c["tid"], c["lo"]))
    cases, n = [], collections.Counter()
    for c in chosen:
        tid, t = c["tid"], threads[c["tid"]]
        n[tid] += 1
        first = next((m["text"] for m in msgs[tid] if m["role"] == "user" and m["by"] == "user" and m["text"].strip()), "")
        cases.append(dict(id=f"{tid[:8]}-s{n[tid]}", thread=tid, title=t["title"], project=t["project"], firstAsk=first[:1000],
                          tags=sorted(c["tags"]), steps=[{k: v for k, v in s.items() if not k.startswith("_")} for s in c["w"]]))
    OUT.parent.mkdir(exist_ok=True)
    json.dump(cases, open(OUT, "w"), indent=1)
    tc = collections.Counter(t for c in cases for t in c["tags"])
    print(f"window: {days} days\nsequences: {len(cases)}  steps: {sum(len(c['steps']) for c in cases)}  "
          f"turns: {sum(s['kind'] == 'turn' for c in cases for s in c['steps'])}  threads: {len({c['thread'] for c in cases})}")
    print("tags: " + ", ".join(f"{t}={tc[t]}" for t in QUOTAS) + f"  (untagged {sum(not c['tags'] for c in cases)})")
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
