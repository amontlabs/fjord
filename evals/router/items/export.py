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
    python3 evals/router/items/export.py --said --seed 7 --days 10 --out data/held-said/cases.json --exclude ...

`--said` also cuts `said` steps: whole messages the agent posted while its run went on, coalesced as the app reads them
(`RouterItemLedgers.saidGap`: at most one per 60 s per thread, the newest waiting one read at the gap's end or when the
run ends), and samples windows with at least one, biased to those that ask something mid-run.
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


SAID_GAP = 60


def said_of(r, ms):
    """The run's mid-run messages the app reads (not its last: the turn's read has it), coalesced by SAID_GAP."""
    own = sorted((m for m in ms if m["run"] == r["run"] and m["role"] == "assistant" and m["text"].strip()), key=lambda m: m["at"])
    mid, out, last, waiting = own[:-1], [], None, None
    for m in mid:
        if waiting and last and (m["at"] - last).total_seconds() >= SAID_GAP:
            last = last + timedelta(seconds=SAID_GAP)
            out.append((last, waiting))
            waiting = None
        if last is None or (m["at"] - last).total_seconds() >= SAID_GAP:
            last = m["at"]
            out.append((m["at"], m))
            waiting = None
        else:
            waiting = m
    if waiting:
        out.append((min(last + timedelta(seconds=SAID_GAP), r["end"]), waiting))
    return out


def steps_of(tid, msgs, runs, said=False):
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
        if said:
            words = own["text"] if by_user else next((m["text"] for m in reversed(ms) if m["role"] == "user" and m["by"] == "user"
                                                       and m["text"].strip() and m["at"] <= r["req"]), None)
            for at, m in said_of(r, ms):
                # Before the turn's own step at the same instant (a waiting one read as the run ends).
                out.append(dict(kind="said", id=m["id"], run=r["run"], at=at.isoformat().replace("+00:00", "Z"),
                                _t=at - timedelta(microseconds=1), text=m["text"], started=(words or "")[:1000] or None))
    for m in ms:
        if m["role"] != "user" or m["by"] != "user" or not m["text"].strip():
            continue
        during = None if m["id"] in starter else m["run"]
        before = next((x["text"] for x in reversed(ms) if x["role"] == "assistant" and x["text"].strip() and x["at"] < m["at"]), "")
        out.append(dict(kind="message", id=m["id"], at=m["at"].isoformat().replace("+00:00", "Z"), _t=m["at"], text=m["text"],
                        during=during, replyBefore=before[-1500:]))
    out.sort(key=lambda s: (s["_t"], s["kind"] == "turn"))
    return out


def waits(st, runs_of):
    """Turns that ended while the agent's background work went on (the next run is a wake, over 30 s later): T3 showed the
    thread working, so before 2026-11-13 the app never read them. Marked `waiting` on the step."""
    nxt = {r["run"]: runs_of[i + 1] for i, r in enumerate(runs_of[:-1])}
    for s in st:
        n = nxt.get(s.get("run")) if s["kind"] == "turn" else None
        s["waiting"] = bool(n and n["req"] and n["_woke"] and (n["req"] - s["_t"]).total_seconds() > 30)


def said_tags(w):
    tags = tags_of([s for s in w if s["kind"] != "said"])
    for s in w:
        if s.get("waiting") and asks(s["reply"]):
            tags.add("waitask")
    for s in w:
        if s["kind"] == "said":
            tags.add("said")
            if asks(s["text"]):
                tags.add("midask")
    return tags


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
            need = lambda c: sum(counts[t] < QUOTAS[t] for t in c["tags"] if t in QUOTAS)
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
    ap.add_argument("--exclude", nargs="*", help="cases files whose steps (runs, messages) no window may contain")
    ap.add_argument("--said", action="store_true", help="mid-run messages too; windows with one (EVAL-items.md)")
    ap.add_argument("--waiting", action="store_true", help="windows with a turn that asks and ended while its background work went on")
    a = ap.parse_args()
    global QUOTAS, MIN_SEQ
    if a.said:
        QUOTAS, MIN_SEQ = dict(midask=8, said=15), 15
    if a.waiting:
        QUOTAS, MIN_SEQ = dict(waitask=10, midask=1), 10
    global OUT
    if a.out:
        OUT = pathlib.Path(a.out)
    seen = set()
    for path in a.exclude or []:
        for c in json.load(open(path)):
            for s in c["steps"]:
                seen.add(s.get("run") or s.get("id"))
    for days in sorted({a.days, 14, 21} if a.days <= 21 else {a.days}):
        if days < a.days:
            continue
        since, threads, msgs, runs = load(days)
        cands = []
        for tid in threads:
            for r in runs[tid]:
                own = next((m for m in msgs[tid] if m["id"] == r["umid"]), None)
                r["_woke"] = bool(own and own["by"] != "user")
            st = [s for s in steps_of(tid, msgs, runs, said=a.said) if s["_t"] >= since]
            waits(st, runs[tid])
            for lo in range(len(st)):
                for n in range(MIN_STEPS, MAX_STEPS + 1):
                    w = st[lo:lo + n]
                    if len(w) == n and sum(s["kind"] == "turn" for s in w) >= 2 \
                            and not any((s.get("run") or s.get("id")) in seen for s in w) \
                            and (a.waiting or not a.said or any(s["kind"] == "said" for s in w)) \
                            and (not a.waiting or any(s.get("waiting") and asks(s["reply"]) for s in w)):
                        cands.append(dict(tid=tid, lo=lo, hi=lo + n, w=w, tags=said_tags(w) if a.said or a.waiting else tags_of(w)))
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
          f"turns: {sum(s['kind'] == 'turn' for c in cases for s in c['steps'])}  said: {sum(s['kind'] == 'said' for c in cases for s in c['steps'])}  "
          f"threads: {len({c['thread'] for c in cases})}")
    print("tags: " + ", ".join(f"{t}={tc[t]}" for t in QUOTAS) + f"  (untagged {sum(not c['tags'] for c in cases)})")
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
