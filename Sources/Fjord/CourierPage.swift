import Foundation

/// What the page tells Fjord (EVENTS.md) as Seen rows. Pure: no sockets, no waiting. Ports poc/router/page.py.
///
/// Anything unreadable is "unknown" or nil, never a guess. An event that can't be placed (no project in its path) gives no rows. A field of
/// the wrong shape (a number for a list, a list for a key) is skipped, never raised on.
enum CourierPage {
    static let states: Set<String> = ["working", "needs_you", "idle", "resolved", "unknown"]

    static func row(_ kind: String, _ subject: String, _ fields: [(String, JSON)]) -> JSON {
        ["source": "page", "kind": .string(kind), "subject": .string(subject), "fields": .object(JSONObject(fields))]
    }

    /// A server id names its project: `cmsg_<the 24 characters after chan_>…`. One that names another project is from a stale render.
    static func belongs(_ key: String, _ project: String) -> Bool {
        let own = String(String.UnicodeScalarView(project.unicodeScalars.dropFirst("chan_".count)))
        return own.unicodeScalars.count != 24 || !pyStartsWith(key, "cmsg_") || pyStartsWith(key, "cmsg_" + own)
    }

    /// (project, thread) from the address the event was stamped with: /code/project/chan_…, and ?thread=cmsg_… as `thread`.
    static func place(_ event: JSON) -> (project: String?, thread: String?) {
        let parts = pySplit((event.get("path").map { $0.isTruthy ? $0.pyStr : "" }) ?? "", "/")
        var project: String? = parts.count > 3 && Array(parts[1..<3]) == ["code", "project"] && pyStartsWith(parts[3], "chan_") ? parts[3] : nil
        if let p = project, pyStartsWith(p, "chan_pending_") {  // a project being created: the page's own id, until the server answers
            project = nil
        }
        let thread = event.get("thread")?.asString
        return (project, thread != nil && !thread!.isEmpty ? thread : nil)
    }

    /// Rows the server has, by key. A pending row (yours not yet delivered, a reply being written) isn't a message yet, and one whose key
    /// names another project is from a stale render.
    static func messages(_ rows: JSON?, _ project: String) -> [JSON] {
        var out: [JSON] = []
        for r in rows?.asArray ?? [] {
            guard case .object = r, let text = r.get("text")?.asString, let index = r.get("index"), index.isPyInt,
                  let key = r.get("key")?.asString, !key.isEmpty, !(r.get("pending")?.isTruthy ?? false), belongs(key, project) else { continue }
            let from = r.get("from")?.asString
            out.append(["key": .string(key), "index": index, "streaming": .bool(r.get("streaming") == .bool(true)),
                        "decision": .bool(r.get("decision")?.isTruthy ?? false),
                        "from": .string(from == "you" || from == "claude" ? from! : "unknown"), "text": .string(text)])
        }
        return out
    }

    /// The Claude rows of one rows event, pending ones too (a reply being written may be `provisional:…`, which `messages` keeps off the
    /// Board): what `turning` reads, folded against what the place showed before.
    static func claudeRows(_ rows: JSON?) -> [JSON] {
        (rows?.asArray ?? []).compactMap { r in
            guard case .object = r, r.get("from") == "claude", let index = r.get("index"), index.isPyInt else { return nil }
            let key = r.get("key").map { $0.isTruthy ? $0.pyStr : "" } ?? ""
            return ["key": .string(key), "index": index, "streaming": .bool(r.get("streaming") == .bool(true))]
        }
    }

    /// (writing, state): whether the coordinator is writing a reply, after one rows event, and the place's state for the next one.
    /// `fields` holds the event's `turning` (the page's own reading, when it sent one) or its `claude` rows and whether it is `full`;
    /// `prior` the place's state: its last streaming row (`turn_row`: key, index) and the highest Claude index seen (`claude_top`).
    /// A row is sent when it starts and once settled, so a delta's bottom Claude row is not the place's: an older row settling while a
    /// later one streams says nothing. A delta ends the turn only when its settled bottom row replaced the last streaming row (its key or
    /// index) or is at or above the highest Claude index seen; else nil (no information). A whole read says it outright.
    /// The page sends its reading with every rows event (`turning`); once a place had one (`paged`), an event without it says nothing, and the
    /// row fold is only for a place that never had a page reading.
    static func turning(_ fields: JSON, _ prior: JSON?) -> (writing: Bool?, state: JSON) {
        let prior: JSON = (prior?.isTruthy ?? false) ? prior! : .object(JSONObject())
        let seen: JSON = prior.get("claude_top") ?? .int(-1)
        let claude = (fields.get("claude")?.isTruthy ?? false) ? (fields.get("claude")?.asArray ?? []) : []
        let full = fields.get("full") == .bool(true)
        let top: JSON? = pyMaxBy(claude) { $0["index"]?.numeric ?? 0 }.flatMap { $0["index"] }
        var state: JSON = ["turn_row": prior.get("turn_row") ?? .null,
                           "claude_top": full ? (top ?? .null) : pyMax(seen, top ?? .int(-1)),  // top if full else max(seen, -1 if top is None else top)
                           "paged": .bool(prior.get("paged") == .bool(true))]
        if full { state["turn_row"] = .null }
        let streams = claude.filter { $0["streaming"] == .bool(true) }
        if let last = pyMaxBy(streams, { $0["index"]?.numeric ?? 0 }) {
            state["turn_row"] = [last["key"] ?? .null, last["index"] ?? .null]
        }
        var writing: Bool?
        if let turning = fields.get("turning")?.asBool {
            writing = turning
            state["paged"] = true
        } else if state["paged"] == .bool(true) {
            writing = nil
        } else if claude.isEmpty {
            writing = full ? false : nil
        } else {
            let bottom = pyMaxBy(claude) { $0["index"]?.numeric ?? 0 }!
            let turnRow = prior.get("turn_row")
            if bottom["streaming"] == .bool(true) {
                writing = true
            } else if full
                        || ((turnRow?.isTruthy ?? false) && (bottom["key"] == turnRow?[0] || bottom["index"] == turnRow?[1]))
                        || (bottom["index"]?.numeric ?? 0) >= (seen.numeric ?? -1) {
                writing = false
            } else {
                writing = nil
            }
        }
        if writing == false { state["turn_row"] = .null }
        return (writing, state)
    }

    /// The dicts in a list, or none when the page sent anything else.
    static func items(_ value: JSON?) -> [JSON] {
        (value?.asArray ?? []).filter { if case .object = $0 { return true } else { return false } }
    }

    /// A list of texts, or nil when the page sent anything else.
    static func strings(_ value: JSON?) -> [String]? {
        value?.asArray.map { $0.compactMap(\.asString) }
    }

    static func threadRow(_ project: String?, _ t: JSON) -> JSON {
        let needs = t.get("needs")
        let state = t.get("state")?.asString
        let needsText = needs?.asString
        return row("thread", t["thread"]?.asString ?? "",
                   [("project", JSON(project)), ("title", .string((t.get("title").map { $0.isTruthy ? $0.pyStr : "" }) ?? "")),
                    ("state", .string(state != nil && states.contains(state!) ? state! : "unknown")),
                    ("needs", needsText != nil && !needsText!.isEmpty ? .string(needsText!) : .null),
                    ("text", .string(pyPrefix((t.get("text").map { $0.isTruthy ? $0.pyStr : "" }) ?? "", 300))),
                    ("session", t["session"]?.asString.map(JSON.string) ?? .null)])
    }

    /// The Seen kind and subject of the side an event is about: the project's chat, or the thread's messages.
    static func sidePlace(_ event: JSON, _ project: String?, _ thread: String?) -> (kind: String, subject: String?) {
        let threadSide = event.get("side") == "thread"
        return (threadSide ? "messages" : "chat", threadSide ? thread : project)
    }

    /// The Seen rows one event makes.
    static func seenRows(_ event: JSON) -> [JSON] {
        let (project, thread) = place(event)
        let kind = event.get("type")?.asString
        if kind == "projects" {
            let listed = items(event.get("projects")).filter { p in
                guard let id = p.get("id")?.asString else { return false }
                return pyStartsWith(id, "chan_") && !pyStartsWith(id, "chan_pending_")  // a project being created has a page-made id until the server answers
            }
            var rows = listed.map { p in row("project", p["id"]!.asString!, [("name", .string((p.get("name").map { $0.isTruthy ? $0.pyStr : "" }) ?? "")), ("where", "cloud")]) }
            let all = event.get("projects")?.asArray
            let whole = all != nil && all!.allSatisfy { p in
                if case .object = p, p.get("id")?.asString != nil { return true } else { return false }
            }
            if event.get("complete") == .bool(true) && whole {  // the projects page: every project there is, so one missing from it is gone (a list it can't read says nothing)
                rows.append(row("listing", "projects", [("ids", .strings(pySorted(listed.map { $0["id"]!.asString! })))]))
            }
            return rows
        }
        if kind == "page" {
            return [row("health", "page", [("connected", true), ("signed_in", event.get("signed_in") ?? .null), ("page_ok", event.get("page_ok") ?? .null),
                                           ("away", event.get("away") ?? .null)])]
        }
        if kind == "settings", let project {  // one read of the project's settings: what the Router's tools prove themselves by
            let text: (JSON?) -> JSON = { v in v?.asString.map(JSON.string) ?? .null }
            return [row("settings", project, [("goal", text(event.get("goal"))), ("instructions", text(event.get("instructions"))),
                                              ("repos", JSON(strings(event.get("repos")))), ("folders", JSON(strings(event.get("folders")))),
                                              ("offered_folders", JSON(strings(event.get("offered_folders"))))])]
        }
        if kind == "threads", let project {
            return items(event.get("threads")).filter { t in
                guard let id = t.get("thread")?.asString, !id.isEmpty else { return false }
                return belongs(id, project)
            }.map { threadRow(project, $0) }
        }
        if kind == "rows" || kind == "composer", let project {
            let (sideKind, subject) = sidePlace(event, project, thread)
            guard let subject, !subject.isEmpty else { return [] }
            var fields: [(String, JSON)] = sideKind == "messages" ? [("project", .string(project))] : []
            func put(_ key: String, _ value: JSON) {
                if let i = fields.firstIndex(where: { $0.0 == key }) { fields[i].1 = value } else { fields.append((key, value)) }
            }
            if kind == "rows" {
                // The page's own reading when it sends one; else the Board reads it from the Claude rows (`turning`)
                if let turning = event.get("turning")?.asBool { put("turning", .bool(turning)) } else { put("claude", .array(claudeRows(event.get("rows")))) }
                return [row(sideKind, subject, [("messages", .array(messages(event.get("rows"), project))), ("full", .bool(event.get("full") == .bool(true)))] + fields)]
            }
            let draft = event.get("draft")?.asString
            return [row(sideKind, subject, [("draft", .string(draft ?? "")), ("disabled", event.get("disabled")?.asBool.map(JSON.bool) ?? .null)] + fields)]
        }
        return []
    }

    // MARK: Test bridge

    /// The functions the Python tests call, by Python name, over JSON arguments.
    static let testOps: [String: ([JSON]) throws -> JSON] = [
        "page.row": { a in row(a[0].asString ?? "", a[1].asString ?? "", a.count > 2 ? (a[2].asObject?.pairs.map { ($0.key, $0.value) } ?? []) : []) },
        "page.belongs": { a in .bool(belongs(a[0].asString ?? "", a[1].asString ?? "")) },
        "page.place": { a in let p = place(a[0]); return [JSON(p.project), JSON(p.thread)] },
        "page.messages": { a in .array(messages(a[0], a[1].asString ?? "")) },
        "page.claude_rows": { a in .array(claudeRows(a[0])) },
        "page.turning": { a in let t = turning(a[0], a.count > 1 ? a[1] : nil); return [JSON(t.writing), t.state] },
        "page.items": { a in .array(items(a[0])) },
        "page.strings": { a in JSON(strings(a[0])) },
        "page.thread_row": { a in threadRow(a[0].asString, a[1]) },
        "page.side_place": { a in let p = sidePlace(a[0], a[1].asString, a[2].asString); return [.string(p.kind), JSON(p.subject)] },
        "page.seen_rows": { a in .array(seenRows(a[0])) },
    ]
}
