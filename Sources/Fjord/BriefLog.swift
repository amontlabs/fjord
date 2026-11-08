import Foundation
import SQLite3

// Fjord's own log of what happened per project (docs/design/t3-port-plan.md, Step 13). T3 has no per-project event log, so
// `Store` appends here on real transitions: a thread appears, a turn finishes, a request or plan appears or is answered, you
// send words, a pull request is linked, a run stops short. It lives in briefs.db beside the versions and marks.

/// What the log last saw of a thread: the next shell row is compared with it, so a relaunch logs what changed meanwhile.
struct BriefThreadFacts: Codable, Equatable, Sendable {
    var project: String
    var title: String
    var running: Bool
    var stopped: Bool
    var runEnded: Double?
    var userAt: Double?
    var prs: [String]

    init(_ t: AgentThread) {
        project = t.projectID
        title = t.title
        running = t.running
        stopped = t.status == .failed || t.limitStopped
        runEnded = t.lastRunEndedAt?.timeIntervalSince1970
        userAt = t.lastUserMessage?.timeIntervalSince1970
        prs = t.pullRequests.map(\.url).filter { !$0.isEmpty }
    }
}

/// The log: items stored once by id, in one order for every project (a project's cursor counts these).
final class BriefLog: @unchecked Sendable {
    static let recentWindow = 86_400.0
    static let textCap = 600

    private var db: OpaquePointer?
    private let lock = NSLock()

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BriefStoreFailure(message: "can't open \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
        let sql = """
        create table if not exists brief_log (seq integer primary key autoincrement, id text not null unique, project text not null,
            thread text, kind text not null, at real not null, text text not null, options text not null, status text);
        create index if not exists brief_log_project on brief_log (project, seq);
        create table if not exists brief_seen (thread text primary key, facts text not null);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BriefStoreFailure(message: String(cString: sqlite3_errmsg(db))) }
    }

    deinit { sqlite3_close(db) }

    // MARK: Items

    /// Stores an item of `project` unless its id was seen: whether it is new.
    @discardableResult
    func append(_ item: BriefItem, project: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let options = (try? JSONEncoder().encode(item.options)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        var stmt: OpaquePointer?
        let sql = "insert or ignore into brief_log (id, project, thread, kind, at, text, options, status) values (?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, item.id); bind(stmt, 2, project); bind(stmt, 3, item.thread); bind(stmt, 4, item.kind.rawValue)
        sqlite3_bind_double(stmt, 5, item.at)
        bind(stmt, 6, String(item.text.prefix(Self.textCap * 2))); bind(stmt, 7, options); bind(stmt, 8, item.status?.rawValue)
        sqlite3_step(stmt)
        return sqlite3_changes(db) > 0
    }

    func items(project: String, after cursor: Int) -> [BriefItem] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "select seq, id, thread, kind, at, text, options, status from brief_log where project = ? and seq > ? order by seq limit 60"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, project)
        sqlite3_bind_int64(stmt, 2, Int64(cursor))
        var out: [BriefItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = BriefItem.Kind(rawValue: Self.text(stmt, 3) ?? "") else { continue }
            out.append(BriefItem(seq: Int(sqlite3_column_int64(stmt, 0)), id: Self.text(stmt, 1) ?? "", at: sqlite3_column_double(stmt, 4),
                                 kind: kind, thread: Self.text(stmt, 2), text: Self.text(stmt, 5) ?? "",
                                 options: (try? JSONDecoder().decode([String].self, from: Data((Self.text(stmt, 6) ?? "[]").utf8))) ?? [],
                                 status: Self.text(stmt, 7).flatMap(ThreadState.init(rawValue:))))
        }
        return out
    }

    func projects() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select distinct project from brief_log order by project", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let p = Self.text(stmt, 0) { out.append(p) } }
        return out
    }

    // MARK: What was seen

    func seen() -> [String: BriefThreadFacts] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select thread, facts from brief_seen", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: BriefThreadFacts] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = Self.text(stmt, 0), let json = Self.text(stmt, 1),
               let facts = try? JSONDecoder().decode(BriefThreadFacts.self, from: Data(json.utf8)) { out[id] = facts }
        }
        return out
    }

    func setSeen(_ thread: String, _ facts: BriefThreadFacts) {
        lock.lock(); defer { lock.unlock() }
        guard let json = (try? JSONEncoder().encode(facts)).map({ String(decoding: $0, as: UTF8.self) }) else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "insert or replace into brief_seen (thread, facts) values (?, ?)", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, thread); bind(stmt, 2, json)
        sqlite3_step(stmt)
    }

    func forget(_ thread: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from brief_seen where thread = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, thread)
        sqlite3_step(stmt)
    }

    /// Drops the log rows of projects, and the seen rows of threads, that are not listed.
    func purge(keepingProjects projects: Set<String>, threads: Set<String>) {
        for p in self.projects() where !projects.contains(p) {
            lock.lock()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "delete from brief_log where project = ?", -1, &stmt, nil) == SQLITE_OK, let stmt {
                bind(stmt, 1, p)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            lock.unlock()
        }
        for t in seen().keys where !threads.contains(t) { forget(t) }
    }

    // MARK: Transitions

    /// What happened to a thread between what the log saw (`old`) and the shell now (`t`): pure. A thread the log never saw
    /// is news only while it is recent (so a first launch writes the last day's briefs, not every old thread's).
    static func events(old: BriefThreadFacts?, thread t: AgentThread, now: Double) -> [BriefItem] {
        let new = BriefThreadFacts(t)
        guard new != old else { return [] }
        var out: [BriefItem] = []
        func clip(_ s: String) -> String { s.count > textCap ? String(s.prefix(textCap)) + "…" : s }
        func item(_ id: String, _ kind: BriefItem.Kind, _ text: String, at: Double, status: ThreadState? = nil) -> BriefItem {
            BriefItem(seq: 0, id: "\(id):\(t.id)", at: at, kind: kind, thread: t.id, text: text, status: status)
        }
        let active = t.lastActivity.timeIntervalSince1970
        guard let old else {
            if now - active <= recentWindow {
                let said = t.latestMessage.map { "\n" + clip($0) } ?? ""
                out.append(item("new", .thread, t.title + said, at: active, status: t.running ? .working : t.finished ? .done : nil))
            }
            return out
        }
        if let ended = new.runEnded, ended != old.runEnded, !t.running {
            out.append(item("done@\(Int(ended))", .message, "finished: " + (t.latestMessage.map(clip) ?? t.title), at: ended, status: .done))
        }
        if let said = new.userAt, said != old.userAt {
            out.append(item("sent@\(Int(said))", .message, "you sent: " + (t.lastUserText.map(clip) ?? "a message"), at: said))
        }
        if new.stopped, !old.stopped {
            out.append(item("stopped@\(Int(active))", .stranded, "stopped: " + (t.lastError.map(clip) ?? "the run stopped before it finished"),
                            at: active, status: .needsYou))
        }
        for pr in t.pullRequests where !pr.url.isEmpty && !old.prs.contains(pr.url) {
            let title = pr.title.map { " " + $0 } ?? ""
            out.append(item("pr@\(pr.url)", .pullRequest, "pull request\(pr.number.map { " #\($0)" } ?? "")\(title): \(pr.url)", at: active))
        }
        return out
    }

    /// A request or plan that appeared on a thread (read from its projection): it waits on you.
    static func request(_ r: ThreadRequest, title: String, at: Double) -> BriefItem {
        var text: String, options: [String] = []
        switch r.body {
        case .plan(let markdown):
            text = "a plan to approve: " + String(markdown.prefix(textCap))
            options = ThreadRequest.planChoices
        case .approval(let kind, let prompt, let decisions):
            text = "asks for a permission (\(kind)): " + (prompt.isEmpty ? title : String(prompt.prefix(textCap)))
            options = decisions.map(ThreadRequest.label)
        case .question(let questions):
            text = "asks: " + questions.map(\.question).joined(separator: "\n").prefix(textCap)
            if questions.count == 1, let q = questions.first, !q.multiSelect { options = q.options.map(\.label) }
        }
        return BriefItem(seq: 0, id: "ask:\(r.id)", at: at, kind: .card, thread: r.threadID, text: text, options: options, status: .needsYou)
    }

    // MARK: SQLite helpers

    private func bind(_ stmt: OpaquePointer, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(stmt, i) }
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
}
