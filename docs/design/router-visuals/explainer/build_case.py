"""Build the creator's user message for one real moment.
usage: build_case.py <owner-message ISO time> <thread title prefix> <out dir>
Writes user.md (exactly what the creator receives after the system prompt) and ask.txt."""
import sqlite3, json, re, sys, pathlib, datetime as dt

DB = pathlib.Path.home() / ".t3/userdata/statev2.sqlite"
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
P = lambda s: dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
hm = lambda d: d.strftime("%H:%M")

def redact(s):
    s = re.sub(r"/Users/[^/\s\"']+", "~", s or "")
    s = re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "<email>", s)
    s = re.sub(r"\b(sk-[\w-]{8,}|gh[pousr]_\w{16,}|xox\w-[\w-]{10,}|AKIA\w{12,}|eyJ[\w-]{20,}\.[\w-]+\.[\w-]+)", "<token>", s)
    s = re.sub(r"(?i)(token|secret|password|api[_-]?key)=\S+", r"\1=<redacted>", s)
    return s.replace("polarzero", "user")

def esc(s): return s.replace("<", "‹").replace(">", "›")  # keep our tags unambiguous

at, title, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
t_ask = P(at)
th = con.execute("select thread_id, title from orchestration_v2_projection_threads where title like ?", (title + "%",)).fetchall()
best = None
for tid, ttl in th:
    for mid, ca, pj in con.execute("select message_id, created_at, payload_json from orchestration_v2_projection_messages where thread_id=? and role='user'", (tid,)):
        d = abs((P(ca) - t_ask).total_seconds())
        if d < 5 and (best is None or d < best[0]): best = (d, tid, ttl, ca)
assert best, "message not found"
_, tid, ttl, ask_at = best
proj = con.execute("select p.title from orchestration_v2_projection_threads t left join projection_projects p on p.project_id=t.project_id where t.thread_id=?", (tid,)).fetchone()[0] or "no project"

msgs = [(P(ca), role, json.loads(pj).get("text") or "") for ca, role, pj in con.execute(
    "select created_at, role, payload_json from orchestration_v2_projection_messages where thread_id=? and created_at<=? order by created_at", (tid, ask_at))]
ask = msgs[-1][2]
real_user = lambda m: m[1] == "user" and not m[2].lstrip().startswith("<")
# group into turns: a user message, then all agent text until the next real user message
turns = []
for m in msgs[:-1]:
    if real_user(m): turns.append(["you", m[0], m[2]])
    elif m[1] == "assistant":
        if turns and turns[-1][0] == "agent": turns[-1][2] += "\n\n" + m[2]
        else: turns.append(["agent", m[0], m[2]])
turns = turns[-4:]                      # the focused reply plus about two exchanges before it
focus = max(i for i, t in enumerate(turns) if t[0] == "agent")
since = turns[0][1] - dt.timedelta(minutes=5)

act = []
for ty, pj in con.execute("select type, payload_json from orchestration_v2_projection_turn_items where thread_id=? and type in ('command_execution','dynamic_tool','file_change','subagent','web_search') and updated_at>=? and updated_at<=?",
                          (tid, since.isoformat()[:19] + "Z", ask_at)):
    d = json.loads(pj)
    if not d.get("startedAt"): continue
    s = P(d["startedAt"])
    if ty == "command_execution":
        line = "Bash " + (d.get("input") or "").strip().split("\n")[0][:90]
    elif ty == "dynamic_tool":
        inp = d.get("input")
        brief = json.dumps(inp)[:70] if inp else ""
        line = f"{d.get('toolName')} {brief}"
    elif ty == "file_change":
        line = "Edit " + pathlib.Path(d.get("fileName") or "?").name
    elif ty == "web_search":
        line = "Web search"
    else:
        continue
    act.append((s, redact(line)))
for pj, st in con.execute("select payload_json, status from orchestration_v2_projection_subagents where thread_id=?", (tid,)):
    d = json.loads(pj)
    if not d.get("startedAt") or P(d["startedAt"]) < since or P(d["startedAt"]) > P(ask_at): continue
    end = f"→ {hm(P(d['completedAt']))}" if d.get("completedAt") else "(still running)"
    act.append((P(d["startedAt"]), redact(f"subagent \"{(d.get('title') or 'subagent')[:60]}\" · {d.get('model') or '?'} · {hm(P(d['startedAt']))} {end}")))
act.sort()
if len(act) > 40: act = act[:12] + [(None, f"… {len(act) - 32} more …")] + act[-20:]

def turn_xml(i, t):
    who, when, text = t
    text = redact(text).strip()
    limit = 7000 if i == focus else 1500
    if len(text) > limit: text = text[:limit] + " …"
    f = ' focus="true"' if i == focus else ""
    return f'  <turn by="{who}" at="{hm(when)}"{f}>{esc(text)}</turn>'

lines = [f"<ask>{esc(redact(ask).strip())}</ask>", f'<thread name="{esc(redact(ttl))}" project="{esc(proj)}">']
lines += [turn_xml(i, t) for i, t in enumerate(turns)]
lines += ["  <activity>"] + [f"    {hm(s) + ' ' if s else ''}{l}" for s, l in act] + ["  </activity>", "</thread>"]
out.mkdir(parents=True, exist_ok=True)
(out / "user.md").write_text("\n".join(lines) + "\n")
(out / "ask.txt").write_text(redact(ask).strip())
print(out / "user.md", len("\n".join(lines)), "chars,", len(act), "activity lines")
