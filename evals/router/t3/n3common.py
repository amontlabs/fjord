"""N3 shared pieces: the stratified dev sample, full-thread context before t (for the judges, the agentic tools and the
Haiku summaries) and hindsight after t. Reads data/history.json and data/moments.jsonl; writes nothing; never prints text.

Strata (dev only, drawn from N2's v4 dev set so N2's cached answers can be reused):
  new          every `new` first message (T3 gold: a new thread)
  nc           every `new_continues` first message
  f_dis        follow-ups where N2's v4 top-1 guess was not the T3 gold thread (oversampled)
  f_agr        follow-ups where it was (a random slice)
Each stratum weighs (its size in the dev population) / (sampled), so rates come back to the natural ratio."""
import collections
import datetime as dt
import functools
import json
import pathlib
import random
import re
import sys

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
DATA = HERE / "data"
import board as B  # noqa: E402

SAMPLE = DATA / "n3_sample.json"
SEED = 3108


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


@functools.lru_cache(None)
def moments():
    """The sampled moments, from the slim files written after sampling."""
    out = {}
    for name in ("n3_moments.jsonl", "n3_moments_test.jsonl"):   # slim copies of the sampled moments (the full file is 1 GB)
        if (DATA / name).exists(): out.update({m["id"]: m for m in map(json.loads, open(DATA / name))})
    return out


@functools.lru_cache(None)
def history():
    from moments import History
    H = json.load(open(DATA / "history.json"))
    hist = History(H, {})
    hist.by_id = {t["id"]: t for t in hist.threads}
    hist.projname = hist.projects
    return hist


def make_sample(n_follow_dis=77, n_follow_agr=77, split="dev", v4name="n2_v4_dev"):
    import n2score as S
    M = S.M
    v4 = S.load(v4name)
    ids = [i for i in v4 if M[i]["split"] == split]
    rng = random.Random(SEED)
    strata = collections.defaultdict(list)
    for i in sorted(ids):
        k = M[i]["klass"]
        if k == "new": strata["new"].append(i)
        elif k == "new_continues": strata["nc"].append(i)
        elif k == "follow":
            ok = tuple(S.tup(v4[i]["guess"])) == tuple(M[i]["gold"])
            strata["f_agr" if ok else "f_dis"].append(i)
    n_follow_pop = S.N_FOLLOW[split]
    n_follow_set = len(strata["f_agr"]) + len(strata["f_dis"])
    pick, weight = {}, {}
    for k, pool in strata.items():
        want = {"f_dis": n_follow_dis, "f_agr": n_follow_agr}.get(k, len(pool))
        got = sorted(rng.sample(pool, min(want, len(pool))))
        pop = len(pool) * (n_follow_pop / n_follow_set if k.startswith("f_") else 1)
        for i in got: pick[i] = k; weight[i] = pop / len(got)
    return {"ids": pick, "weight": weight, "sizes": {k: len(v) for k, v in strata.items()}}


PURPOSES = json.load(open(DATA / "purposes.json"))


def make_board(m):
    return B.Board(projects=m["board"]["projects"], threads=[B.Thread(**t) for t in m["board"]["threads"]], purposes=PURPOSES)


def load_sample():
    return json.load(open(SAMPLE))


# ---------------------------------------------------------------- thread text before t
def owner_or_agent(m):
    return (m["role"] == "assistant" and m["text"].strip()) or m.get("ok") == "owner"


def turns_before(tid, t_at, exclude_at=None):
    t = history().by_id[tid]
    return [m for m in t["msgs"] if m["at"] < t_at and owner_or_agent(m)]


def clip(s, n):
    s = " ".join(B.redact(s).split())
    return s if len(s) <= n else s[:n] + " […]"


def clip_tail(s, n):
    s = " ".join(B.redact(s).split())
    return s if len(s) <= n else "[…] " + s[-n:]


def digest(tid, t_at, budget=5000, first_n=1200, owner_n=500, reply_n=300, last_reply_n=1500):
    """A thread's transcript before t: its first ask, then as many recent turns as fit, newest kept first."""
    ms = turns_before(tid, t_at)
    if not ms: return ""
    first = next((m for m in ms if m["role"] == "user"), None)
    head = f"[first ask] {clip(first['text'], first_n)}" if first else ""
    rest = [m for m in ms if m is not first]
    lines, used = [], len(head)
    last_reply = next((m for m in reversed(rest) if m["role"] == "assistant"), None)
    for m in reversed(rest):
        if m["role"] == "user": s = f"[owner] {clip(m['text'], owner_n)}"
        elif m is last_reply: s = f"[agent, latest reply] {clip_tail(m['text'], last_reply_n)}"
        else: s = f"[agent] {clip(m['text'], reply_n)}"
        if used + len(s) > budget and lines: break
        lines.append(s); used += len(s)
    skipped = len(rest) - len(lines)
    out = [head] + ([f"[… {skipped} earlier turns not shown]"] if skipped else []) + list(reversed(lines))
    return "\n".join(x for x in out if x)


def full_text(tid, t_at):
    """Every owner and agent turn before t, unclipped but redacted (BM25 index, read_thread)."""
    return [(m["role"], m["at"], " ".join(B.redact(m["text"]).split())) for m in turns_before(tid, t_at)]


def hindsight(m, replies=3, owners=4, later_threads=5, hours=48):
    """What happened after the message: the thread it went to (next replies and owner messages), and new threads the owner
    opened in the same project within `hours`."""
    h = history()
    t = h.by_id[m["thread"]]
    after = [x for x in t["msgs"] if x["at"] > m["at"] and owner_or_agent(x)]
    out = []
    rs = [x for x in after if x["role"] == "assistant"][:replies]
    os_ = [x for x in after if x["role"] == "user"][:owners]
    seq = sorted(rs + os_, key=lambda x: x["at"])
    for x in seq:
        out.append(f"[{'agent' if x['role'] == 'assistant' else 'owner'}] {clip(x['text'], 600 if x['role'] == 'assistant' else 300)}")
    T = ts(m["at"])
    later = []
    for o in h.listed:
        if o["id"] == m["thread"] or o["project"] != t["project"]: continue
        b = h.born[o["id"]]
        if not b or b <= m["at"] or (ts(b) - T).total_seconds() > hours * 3600: continue
        fo = next((x for x in o["msgs"] if x.get("ok") == "owner" and x["at"] >= b), None)
        if fo: later.append((b, fo["text"]))
    later.sort()
    lt = [f"- {clip(tx, 300)}" for _, tx in later[:later_threads]]
    return "\n".join(out), "\n".join(lt)


def judge_threads(m, cap=8, judge_new=None):
    """Threads shown to the judges: the decider board's candidates, plus the thread the owner typed in (follow-ups), plus
    N1's judge-related thread, plus the latest threads of the moment's project, newest first, capped."""
    b = make_board(m)
    cands = b.candidates()
    keys = [t.key for t in B.by_recency(cands)]
    extra = []
    if m["cls"] == "follow": extra.append(m["thread"])
    if judge_new and judge_new.get(m["id"], {}).get("thread_key"): extra.append(judge_new[m["id"]]["thread_key"])
    same = [t.key for t in B.by_recency(b.threads) if t.project == m["project"]][:3]
    out = []
    for k in extra + keys + same:
        if k not in out and k != (m["thread"] if m["cls"] != "follow" else None): out.append(k)
    must = set(extra)
    kept = [k for k in out if k in must] + [k for k in out if k not in must]
    return kept[:cap], {t.key: t for t in b.threads}


if __name__ == "__main__":
    s = make_sample()
    json.dump(s, open(SAMPLE, "w"))
    print("strata sizes", s["sizes"], "picked", collections.Counter(s["ids"].values()),
          "weights", {k: round(next(s["weight"][i] for i in s["ids"] if s["ids"][i] == k), 2) for k in set(s["ids"].values())})
