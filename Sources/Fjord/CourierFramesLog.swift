import Foundation

// The one log of items (docs/design/router-watch-and-briefs.md §2): every observed item stored once, under its own id.
//
// For the briefs (RouterBrief*), through the host:
//   `CourierHost.items(project:after:)`         -> [CourierItem], oldest first, every kind
//   `CourierHost.statusChanges(project:after:)` -> [CourierItem] of kind "status" only
//   `CourierHost.statuses(project:)`            -> [thread id: status], the latest recorded status of each thread
//   `CourierHost.watch()`                       -> [project id: CourierWatch], live / stale(since) / none (§1.5)
// `project: nil` reads every project. `CourierItem.seq` is the cursor: strictly increasing across kinds and projects; a brief stores
// the last `seq` it read as its `cursor` and passes it back as `after` (0 reads from the start).
//
// Kinds, ids and content (content is JSON with these keys; absent keys are absent, not null):
//   "project"  id chan_…                        {name}
//   "thread"   id the thread's root message key {title, needs, text}       (section, unread and the status are not content)
//   "row"      id data-entry-key                {from, text, decision, index, answered?, options?, card?}; `thread` nil for the
//                                                project chat (the coordinator's rows), the thread's id for a thread view's rows
//   "card"     id the decision row's key        {kind: "plan"|"question", options: [String], answered: Bool}; `thread` set
//   "session"  id the local session id          {state, title, needs, detail}; `thread` the Board's thread id
//   "status"   id the thread's id               {status: "working"|"needs you"|"paused"|"done", needs?: "permission"}; `thread` set
//   "answer"   id answer:<intent id>            {card, option, text}: your answer through Fjord, once proved; `thread` set
// An item is appended only when its content differs from the last one stored for (kind, id): a reload, a handover, a second frame
// or a coordinator repeat adds nothing. Volatile fields (`CourierLog.volatile`: a row's `index`, a thread row's `text`, its innerText
// with relative times) are stored but never compared, so a renumbering or a clock tick adds nothing either. A streaming row is stored once settled; `turning` and streaming text are never items.

struct CourierItem: Equatable, Sendable {
    let seq: Int
    let at: Double
    let project: String?
    let thread: String?
    let kind: String
    let id: String
    let content: JSON
}

/// A project's watch (§1.5): its frame is live, stale since a time, or there is none.
enum CourierWatch: Equatable, Sendable {
    case live
    case stale(since: Double)
    case none
}

/// A thread's owed check and last thread-view read, as `checks` stores them (§1.8).
struct CourierCheck: Equatable {
    var thread: String
    var project: String
    var owed: Bool
    var why: String?
    var needs: Bool
    var time: Double?
    var readAt: Double?
    var readRow: String?
}

extension CourierStore {
    func addItem(_ now: Double, project: String?, thread: String?, kind: String, id: String, content: JSON) throws -> Int {
        try query("insert into items (at, project, thread, kind, item, content) values (?, ?, ?, ?, ?, ?)",
                  [.double(now), JSON(project), JSON(thread), .string(kind), .string(id), .string(content.encoded())])
        return lastInsertRowID
    }

    /// The newest content of every (kind, id): what a new item is compared against.
    func latestItems() throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try query("select kind, item, content from items where seq in (select max(seq) from items group by kind, item)") {
            out[(r["kind"]?.asString ?? "") + "\u{1}" + (r["item"]?.asString ?? "")] = r["content"]?.asString ?? ""
        }
        return out
    }

    func items(project: String?, after: Int, kind: String? = nil) throws -> [CourierItem] {
        var sql = "select * from items where seq > ?"
        var params: [JSON] = [.int(after)]
        if let project { sql += " and project = ?"; params.append(.string(project)) }
        if let kind { sql += " and kind = ?"; params.append(.string(kind)) }
        return try query(sql + " order by seq", params).map { r in
            CourierItem(seq: r["seq"]?.asInt ?? 0, at: r["at"]?.numeric ?? 0, project: r["project"]?.asString, thread: r["thread"]?.asString,
                        kind: r["kind"]?.asString ?? "", id: r["item"]?.asString ?? "", content: (try? JSON.parse(r["content"]?.asString ?? "null")) ?? .null)
        }
    }

    func checks() throws -> [String: CourierCheck] {
        var out: [String: CourierCheck] = [:]
        for r in try query("select * from checks") {
            let t = r["thread"]?.asString ?? ""
            out[t] = CourierCheck(thread: t, project: r["project"]?.asString ?? "", owed: (r["owed"]?.asInt ?? 0) != 0, why: r["why"]?.asString,
                                  needs: (r["needs"]?.asInt ?? 0) != 0, time: r["time"]?.numeric, readAt: r["read_at"]?.numeric, readRow: r["read_row"]?.asString)
        }
        return out
    }

    func putCheck(_ c: CourierCheck) throws {
        try query("insert or replace into checks (thread, project, owed, why, needs, time, read_at, read_row) values (?, ?, ?, ?, ?, ?, ?, ?)",
                  [.string(c.thread), .string(c.project), .int(c.owed ? 1 : 0), JSON(c.why), .int(c.needs ? 1 : 0), JSON(c.time), JSON(c.readAt), JSON(c.readRow)])
    }
}

/// The log in memory: the newest content of each item, so a repeat is dropped without a query, and the threads' statuses.
final class CourierLog {
    let db: CourierStore
    /// Fields stored but left out of the comparison, by kind: they change with no change to the item.
    static let volatile: [String: Set<String>] = ["row": ["index"], "thread": ["text"]]
    private var last: [String: String]
    private var stable: [String: String] = [:]  // (kind, id) -> the newest content without its volatile fields
    private(set) var status: [String: String] = [:]  // thread -> the latest recorded status
    private(set) var statusProject: [String: String] = [:]
    private(set) var statusAt: [String: Double] = [:]  // thread -> when its latest status was recorded
    private(set) var statusNeeds: [String: String] = [:]  // thread -> its latest status's `needs` (permission)
    /// The newest log position: the briefs hear of new items by it moving.
    private(set) var lastSeq = 0

    init(_ db: CourierStore) {
        self.db = db
        last = (try? db.latestItems()) ?? [:]
        for (key, text) in last {
            let kind = String(key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            stable[key] = Self.volatile[kind] == nil ? text : Self.stableText(kind, (try? JSON.parse(text)) ?? .null)
        }
        lastSeq = ((try? db.query("select max(seq) as seq from items")) ?? []).first?["seq"]?.asInt ?? 0
        for i in (try? db.items(project: nil, after: 0, kind: "status")) ?? [] { noteStatus(i.id, project: i.project, at: i.at, i.content) }
    }

    private func noteStatus(_ thread: String, project: String?, at: Double, _ content: JSON) {
        status[thread] = content["status"]?.asString
        statusAt[thread] = at
        statusNeeds[thread] = content.get("needs")?.asString
        if let project { statusProject[thread] = project }
    }

    /// The newest content stored for (kind, id), if any.
    func latest(kind: String, id: String) -> JSON? {
        last[kind + "\u{1}" + id].flatMap { try? JSON.parse($0) }
    }

    /// Stores the item unless its content is the last stored for (kind, id). Returns whether it was new.
    static func stableText(_ kind: String, _ content: JSON) -> String {
        guard let drop = volatile[kind], var o = content.asObject else { return content.encoded() }
        for k in drop { o[k] = nil }
        return JSON.object(o).encoded()
    }

    @discardableResult
    func record(_ now: Double, project: String?, thread: String?, kind: String, id: String, content: JSON) throws -> Bool {
        let key = kind + "\u{1}" + id, text = content.encoded(), same = Self.stableText(kind, content)
        if stable[key] == same { return false }
        lastSeq = max(lastSeq, try db.addItem(now, project: project, thread: thread, kind: kind, id: id, content: content))
        last[key] = text
        stable[key] = same
        if kind == "status" { noteStatus(id, project: project, at: now, content) }
        return true
    }

    /// A thread's status, recorded only when it differs from the last one recorded for that thread.
    @discardableResult
    func setStatus(_ now: Double, project: String?, thread: String, _ value: String, needs: String? = nil) throws -> Bool {
        var content: JSON = ["status": .string(value)]
        if let needs { content["needs"] = .string(needs) }
        if status[thread] == value && needs == nil { return false }
        return try record(now, project: project, thread: thread, kind: "status", id: thread, content: content)
    }

    func statuses(project: String?) -> [String: String] {
        var out: [String: String] = [:]
        for (t, s) in status where project == nil || statusProject[t] == project { out[t] = s }
        return out
    }
}
