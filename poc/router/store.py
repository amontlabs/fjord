"""The Router's SQLite file: seen (append-only), intents, told, notes. The Board is never stored."""
import json
import sqlite3

DUP_WINDOW = 120  # seconds: the same tool, target and words inside it are one intent
JSON_COLUMNS = ("args", "proof", "output", "correction", "result")
SCHEMA = """
create table if not exists seen (id integer primary key autoincrement, at real not null, source text not null,
    kind text not null, subject text not null, fields text not null);
create index if not exists seen_by_kind on seen (kind, subject);
create trigger if not exists seen_no_update before update on seen begin select raise(abort, 'seen is append-only'); end;
create trigger if not exists seen_no_delete before delete on seen begin select raise(abort, 'seen is append-only'); end;
create table if not exists intents (id integer primary key autoincrement, at real not null, updated real, tool text not null,
    args text, words text, project text, thread text, proof text, status text not null, attempts integer not null default 0,
    cause text, context_hash text, output text, correction text, result text);
create table if not exists told (key text primary key, at real not null, project text, kind text, detail text, text text);
create table if not exists notes (topic text primary key, text text not null, at real not null);
"""


def connect(path):
    db = sqlite3.connect(path, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    return db


def add_seen(db, now, rows):
    """Appends rows and returns them with their ids, ready to step the Board."""
    out = []
    for r in rows:
        cursor = db.execute("insert into seen (at, source, kind, subject, fields) values (?, ?, ?, ?, ?)",
                            (now, r["source"], r["kind"], r["subject"], json.dumps(r["fields"], ensure_ascii=False)))
        out.append({**r, "id": cursor.lastrowid, "at": now})
    db.commit()
    return out


def seen(db, last=None):
    """Seen rows in order. `last` keeps only the newest that many."""
    rows = db.execute("select * from (select * from seen order by id desc limit ?) order by id", (last if last is not None else -1,))
    return [{**dict(r), "fields": json.loads(r["fields"])} for r in rows]


def compact(db, before):
    """Drops chat and messages rows older than `before` (a time), except the newest of each subject and its newest with rows, which say the chat was seen.
    Seen is append-only while the Router runs; this is the one place it shrinks, at start."""
    db.executescript("drop trigger if exists seen_no_delete;")
    db.execute("delete from seen where kind in ('chat', 'messages') and at < ? and id not in "
               "(select max(id) from seen where kind in ('chat', 'messages') group by kind, subject "
               "union select max(id) from seen where kind in ('chat', 'messages') and fields like '%\"messages\": [{%' group by kind, subject)", (before,))
    db.commit()
    db.executescript(SCHEMA)


def last_seen_id(db):
    return db.execute("select coalesce(max(id), 0) from seen").fetchone()[0]


def chat_projects(db):
    """Projects whose chat has been seen at least once, with rows or by sending to it."""
    return {r[0] for r in db.execute("select distinct subject from seen where kind = 'chat' and fields like '%\"messages\": [{%' "
                                  "union select distinct project from intents where thread is null and proof like '%\"baseline\"%'")}


def intent_row(row):
    return {k: json.loads(v) if k in JSON_COLUMNS and v is not None else v for k, v in dict(row).items()} if row else None


def add_intent(db, now, tool, words="", project=None, thread=None, args=None, proof=None, status="pending", dup=True, **more):
    """Returns (intent, created). A repeat inside the window returns the first one while it is still pending, paused or awaiting."""
    same = dup and db.execute("select * from intents where tool = ? and words = ? and project is ? and thread is ? and at > ? "
                      "and status in ('pending', 'paused', 'awaiting') order by id limit 1", (tool, words, project, thread, now - DUP_WINDOW)).fetchone()
    if same:
        return intent_row(same), False
    row = {"at": now, "updated": now, "tool": tool, "words": words, "project": project, "thread": thread, "args": args, "proof": proof,
           "status": status, **more}
    row = {k: json.dumps(v, ensure_ascii=False) if k in JSON_COLUMNS and v is not None else v for k, v in row.items()}
    cursor = db.execute(f"insert into intents ({', '.join(row)}) values ({', '.join('?' * len(row))})", list(row.values()))
    db.commit()
    return intent(db, cursor.lastrowid), True


def update_intent(db, now, intent_id, **changes):
    changes = {"updated": now, **changes}
    changes = {k: json.dumps(v, ensure_ascii=False) if k in JSON_COLUMNS and v is not None else v for k, v in changes.items()}
    db.execute(f"update intents set {', '.join(k + ' = ?' for k in changes)} where id = ?", [*changes.values(), intent_id])
    db.commit()
    return intent(db, intent_id)


def intent(db, intent_id):
    return intent_row(db.execute("select * from intents where id = ?", (intent_id,)).fetchone())


# The columns a start's scans of every past intent read: not `proof`, which for a send holds its baseline's keys.
LEAN = "id, tool, status, project, thread, result"
# Every column but `proof`: what the debug log shows.
BRIEF = "id, at, updated, tool, args, words, project, thread, status, attempts, cause, context_hash, output, correction, result"


def intents(db, limit=50, status=None, tool=None, columns="*"):
    where = [(c, v) for c, v in (("status", status), ("tool", tool)) if v]
    sql = (f"select {columns} from intents" + (" where " + " and ".join(f"{c} = ?" for c, _ in where) if where else "")
           + " order by id desc limit ?")
    return [intent_row(r) for r in reversed(db.execute(sql, [*(v for _, v in where), limit]).fetchall())]


def long_proofs(db, kept):
    """The failed intents whose proof holds more than `kept` keys of a baseline or of anchors: read whole, only those."""
    return [intent_row(r) for r in db.execute("select * from intents where status = 'failed' and (json_array_length(proof, '$.baseline') > ? "
                                              "or json_array_length(proof, '$.anchors') > ?)", (kept, kept))]


def told(db):
    return {r["key"]: dict(r) for r in db.execute("select * from told where kind != 'mark'")}


def set_told(db, now, key, project, kind, detail, text):
    db.execute("insert or replace into told (key, at, project, kind, detail, text) values (?, ?, ?, ?, ?, ?)", (key, now, project, kind, detail, text))
    db.commit()


def mark(db, value=None):
    """The last Seen row a tell has covered."""
    if value is None:
        row = db.execute("select detail from told where key = 'mark:seen'").fetchone()
        return int(row[0]) if row else 0
    set_told(db, 0, "mark:seen", None, "mark", str(value), "")


def notes(db):
    return {r["topic"]: r["text"] for r in db.execute("select * from notes order by topic")}


def set_note(db, now, topic, text):
    db.execute("insert or replace into notes (topic, text, at) values (?, ?, ?)", (topic, text, now))
    db.commit()
