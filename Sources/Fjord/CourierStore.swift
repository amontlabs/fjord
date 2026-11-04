import Foundation
import SQLite3

/// The Router's SQLite file: seen (append-only), intents, told, notes. The Board is never stored. Ports poc/router/store.py, with the same
/// schema and the same JSON column keys: the Python tests and `router.py` read this file directly.
final class CourierStore {
    static let dupWindow = 120.0  // seconds: the same tool, target and words inside it are one intent
    static let jsonColumns: Set<String> = ["args", "proof", "output", "correction", "result"]
    static let schema = "\n" + """
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
    create table if not exists intent_keys (key text primary key, intent integer not null);
    """ + "\n"

    /// The columns a start's scans of every past intent read: not `proof`, which for a send holds its baseline's keys.
    static let lean = "id, tool, status, project, thread, result"
    /// Every column but `proof`: what the debug log shows.
    static let brief = "id, at, updated, tool, args, words, project, thread, status, attempts, cause, context_hash, output, correction, result"

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { "SQLite: \(message)" }
    }

    private var db: OpaquePointer?
    /// Test hook: called with each statement before it runs; a returned error is thrown instead of running it.
    var beforeStatement: ((String) -> Error?)?

    /// `connect(path)`: opens the file (WAL, so a second process can read and write it), and creates what is missing.
    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(handle)
            throw Failure(message: why)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)  // as Python's sqlite3 waits for a lock
        _ = try query("pragma journal_mode = wal")
        try script(Self.schema)
    }

    deinit { sqlite3_close(db) }

    // MARK: SQLite plumbing

    /// `executescript`: runs every statement, no parameters.
    func script(_ sql: String) throws {
        if let e = beforeStatement?(sql) { throw e }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let why = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure(message: why)
        }
    }

    /// One statement with its parameters: the rows it returns, as objects (`dict(row)`).
    @discardableResult
    func query(_ sql: String, _ params: [JSON] = []) throws -> [JSONObject] {
        if let e = beforeStatement?(sql) { throw e }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, n)
            case .bool(let b): sqlite3_bind_int64(stmt, n, b ? 1 : 0)
            case .int(let v): sqlite3_bind_int64(stmt, n, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .string(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .array, .object: sqlite3_bind_text(stmt, n, p.encoded(), -1, transient)
            }
        }
        var rows: [JSONObject] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            var row = JSONObject()
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .string(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(db)) }

    // MARK: seen

    /// Appends rows and returns them with their ids, ready to step the Board.
    func addSeen(_ now: Double, _ rows: [JSON]) throws -> [JSON] {
        var out: [JSON] = []
        for r in rows {
            try query("insert into seen (at, source, kind, subject, fields) values (?, ?, ?, ?, ?)",
                      [.double(now), r["source"] ?? .null, r["kind"] ?? .null, r["subject"] ?? .null, .string((r["fields"] ?? .null).encoded())])
            var row = r
            row["id"] = .int(lastInsertRowID)
            row["at"] = .double(now)
            out.append(row)
        }
        return out
    }

    /// Seen rows in order. `last` keeps only the newest that many.
    func seen(last: Int? = nil) throws -> [JSON] {
        try query("select * from (select * from seen order by id desc limit ?) order by id", [.int(last ?? -1)]).map { r in
            var row = r
            row["fields"] = try JSON.parse(r["fields"]?.asString ?? "null")
            return .object(row)
        }
    }

    /// Drops chat and messages rows older than `before` (a time), except the newest of each subject and its newest with rows, which say the chat was seen.
    /// Seen is append-only while the Router runs; this is the one place it shrinks, at start.
    func compact(before: Double) throws {
        try script("drop trigger if exists seen_no_delete;")
        try query("delete from seen where kind in ('chat', 'messages') and at < ? and id not in "
                  + "(select max(id) from seen where kind in ('chat', 'messages') group by kind, subject "
                  + "union select max(id) from seen where kind in ('chat', 'messages') and fields like '%\"messages\": [{%' group by kind, subject)", [.double(before)])
        try script(Self.schema)
    }

    func lastSeenId() throws -> Int {
        try query("select coalesce(max(id), 0) as m from seen").first?["m"]?.asInt ?? 0
    }

    /// Projects whose chat has been seen at least once, with rows or by sending to it. (A send with no project, which Python's set would hold
    /// as None, is left out.)
    func chatProjects() throws -> Set<String> {
        Set(try query("select distinct subject from seen where kind = 'chat' and fields like '%\"messages\": [{%' "
                      + "union select distinct project from intents where thread is null and proof like '%\"baseline\"%'").compactMap { $0.values.first?.asString })
    }

    // MARK: intents

    /// `intent_row`: the JSON columns read back.
    static func intentRow(_ row: JSONObject?) -> JSON? {
        guard let row else { return nil }
        var out = JSONObject()
        for (k, v) in row {
            if jsonColumns.contains(k), let text = v.asString, let parsed = try? JSON.parse(text) { out[k] = parsed } else { out[k] = v }
        }
        return .object(out)
    }

    private static func dumpedColumns(_ row: JSONObject) -> JSONObject {
        var out = JSONObject()
        for (k, v) in row {
            out[k] = jsonColumns.contains(k) && !v.isNull ? .string(v.encoded()) : v
        }
        return out
    }

    /// Returns (intent, created). A repeat inside the window returns the first one while it is still pending, paused or awaiting.
    func addIntent(_ now: Double, _ tool: String, words: String? = "", project: String? = nil, thread: String? = nil, args: JSON? = nil,
                   proof: JSON? = nil, status: String = "pending", dup: Bool = true, more: [(String, JSON)] = []) throws -> (intent: JSON, created: Bool) {
        if dup, let same = try query("select * from intents where tool = ? and words = ? and project is ? and thread is ? and at > ? "
                                     + "and status in ('pending', 'paused', 'awaiting') order by id limit 1",
                                     [.string(tool), JSON(words), JSON(project), JSON(thread), .double(now - Self.dupWindow)]).first {
            return (Self.intentRow(same)!, false)
        }
        var row = JSONObject([("at", .double(now)), ("updated", .double(now)), ("tool", .string(tool)), ("words", JSON(words)), ("project", JSON(project)),
                              ("thread", JSON(thread)), ("args", args ?? .null), ("proof", proof ?? .null), ("status", .string(status))])
        for (k, v) in more { row[k] = v }
        let stored = Self.dumpedColumns(row)
        try query("insert into intents (\(stored.keys.joined(separator: ", "))) values (\(stored.keys.map { _ in "?" }.joined(separator: ", ")))", stored.values)
        return (try intent(lastInsertRowID)!, true)
    }

    @discardableResult
    func updateIntent(_ now: Double, _ intentID: Int, _ changes: [(String, JSON)]) throws -> JSON? {
        var all = JSONObject([("updated", .double(now))])
        for (k, v) in changes { all[k] = v }
        let stored = Self.dumpedColumns(all)
        try query("update intents set \(stored.keys.map { $0 + " = ?" }.joined(separator: ", ")) where id = ?", stored.values + [.int(intentID)])
        return try intent(intentID)
    }

    /// The intent an app's idempotency key named (`intent_keys`), if any.
    func keyedIntent(_ key: String) throws -> Int? {
        try query("select intent from intent_keys where key = ?", [.string(key)]).first?["intent"]?.asInt
    }

    /// `key` names `intentID` from now on.
    func keyIntent(_ key: String, _ intentID: Int) throws {
        try query("insert or replace into intent_keys (key, intent) values (?, ?)", [.string(key), .int(intentID)])
    }

    func intent(_ intentID: Int) throws -> JSON? {
        Self.intentRow(try query("select * from intents where id = ?", [.int(intentID)]).first)
    }

    func intents(limit: Int = 50, status: String? = nil, tool: String? = nil, columns: String = "*") throws -> [JSON] {
        let where_ = [("status", status), ("tool", tool)].compactMap { c, v in v.flatMap { $0.isEmpty ? nil : (c, $0) } }
        let sql = "select \(columns) from intents" + (where_.isEmpty ? "" : " where " + where_.map { "\($0.0) = ?" }.joined(separator: " and "))
            + " order by id desc limit ?"
        return try query(sql, where_.map { JSON.string($0.1) } + [.int(limit)]).reversed().map { Self.intentRow($0)! }
    }

    /// The failed intents whose proof holds more than `kept` keys of a baseline or of anchors: read whole, only those.
    func longProofs(kept: Int) throws -> [JSON] {
        try query("select * from intents where status = 'failed' and (json_array_length(proof, '$.baseline') > ? "
                  + "or json_array_length(proof, '$.anchors') > ?)", [.int(kept), .int(kept)]).map { Self.intentRow($0)! }
    }

    // MARK: told and notes

    func told() throws -> JSONObject {
        var out = JSONObject()
        for r in try query("select * from told where kind != 'mark'") { out[r["key"]?.asString ?? ""] = .object(r) }
        return out
    }

    func setTold(_ now: Double, _ key: String, _ project: String?, _ kind: String?, _ detail: String?, _ text: String?) throws {
        try query("insert or replace into told (key, at, project, kind, detail, text) values (?, ?, ?, ?, ?, ?)",
                  [.string(key), .double(now), JSON(project), JSON(kind), JSON(detail), JSON(text)])
    }

    /// The last Seen row a tell has covered.
    func mark() throws -> Int {
        guard let row = try query("select detail from told where key = 'mark:seen'").first, let detail = row["detail"]?.asString else { return 0 }
        guard let n = Int(detail) else { throw Failure(message: "mark isn't a number: \(detail)") }
        return n
    }

    func setMark(_ value: Int) throws {
        try setTold(0, "mark:seen", nil, "mark", String(value), "")
    }

    func notes() throws -> JSONObject {
        var out = JSONObject()
        for r in try query("select * from notes order by topic") { out[r["topic"]?.asString ?? ""] = r["text"] ?? .null }
        return out
    }

    func setNote(_ now: Double, _ topic: String, _ text: String) throws {
        try query("insert or replace into notes (topic, text, at) values (?, ?, ?)", [.string(topic), .string(text), .double(now)])
    }

    // MARK: Test bridge

    /// The store's functions by Python name. The first argument is the path of the database file (a connection per call); `None` for an
    /// absent value is null. Sets come back as sorted lists, and `intent_row` / `add_intent` take their JSON columns as plain values.
    static let testOps: [String: ([JSON]) throws -> JSON] = [
        "store.add_seen": { a in .array(try CourierStore(path: a[0].asString ?? "").addSeen(a[1].asDouble ?? 0, a[2].asArray ?? [])) },
        "store.seen": { a in .array(try CourierStore(path: a[0].asString ?? "").seen(last: a.count > 1 ? a[1].asInt : nil)) },
        "store.compact": { a in try CourierStore(path: a[0].asString ?? "").compact(before: a[1].asDouble ?? 0); return .null },
        "store.last_seen_id": { a in .int(try CourierStore(path: a[0].asString ?? "").lastSeenId()) },
        "store.chat_projects": { a in .strings(pySorted(Array(try CourierStore(path: a[0].asString ?? "").chatProjects()))) },
        // add_intent(path, now, tool, {words, project, thread, args, proof, status, dup, ...more})
        "store.add_intent": { a in
            let kw = a.count > 3 ? (a[3].asObject ?? JSONObject()) : JSONObject()
            let known: Set<String> = ["words", "project", "thread", "args", "proof", "status", "dup"]
            let more = kw.pairs.filter { !known.contains($0.key) }.map { ($0.key, $0.value) }
            let (intent, created) = try CourierStore(path: a[0].asString ?? "").addIntent(
                a[1].asDouble ?? 0, a[2].asString ?? "", words: kw["words"] == nil ? "" : kw["words"]?.asString, project: kw["project"]?.asString, thread: kw["thread"]?.asString,
                args: kw["args"], proof: kw["proof"], status: kw["status"]?.asString ?? "pending", dup: kw["dup"]?.isTruthy ?? true, more: more)
            return [intent, .bool(created)]
        },
        // update_intent(path, now, id, {changes})
        "store.update_intent": { a in
            try CourierStore(path: a[0].asString ?? "").updateIntent(a[1].asDouble ?? 0, a[2].asInt ?? 0, (a[3].asObject ?? JSONObject()).pairs.map { ($0.key, $0.value) }) ?? .null
        },
        "store.intent": { a in try CourierStore(path: a[0].asString ?? "").intent(a[1].asInt ?? 0) ?? .null },
        // intents(path, {limit, status, tool, columns})
        "store.intents": { a in
            let kw = a.count > 1 ? (a[1].asObject ?? JSONObject()) : JSONObject()
            return .array(try CourierStore(path: a[0].asString ?? "").intents(limit: kw["limit"]?.asInt ?? 50, status: kw["status"]?.asString, tool: kw["tool"]?.asString,
                                                                              columns: kw["columns"]?.asString ?? "*"))
        },
        "store.long_proofs": { a in .array(try CourierStore(path: a[0].asString ?? "").longProofs(kept: a[1].asInt ?? 0)) },
        "store.told": { a in .object(try CourierStore(path: a[0].asString ?? "").told()) },
        "store.set_told": { a in
            try CourierStore(path: a[0].asString ?? "").setTold(a[1].asDouble ?? 0, a[2].asString ?? "", a[3].asString, a[4].asString, a[5].asString, a[6].asString); return .null
        },
        // mark(path) reads, mark(path, value) sets
        "store.mark": { a in
            let s = try CourierStore(path: a[0].asString ?? "")
            if a.count > 1, !a[1].isNull { try s.setMark(a[1].asInt ?? 0); return .null }
            return .int(try s.mark())
        },
        "store.notes": { a in .object(try CourierStore(path: a[0].asString ?? "").notes()) },
        "store.set_note": { a in try CourierStore(path: a[0].asString ?? "").setNote(a[1].asDouble ?? 0, a[2].asString ?? "", a[3].asString ?? ""); return .null },
    ]
}
