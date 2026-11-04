import Foundation

/// The fold state of the Board (what `board.start()` returns in Python): a reference type, as the Python dict is, so `step` mutates the
/// one the core holds.
final class CourierAcc {
    struct ClaimKey: Hashable { let project: JSON; let key: JSON }
    struct Place: Hashable { let kind: String; let subject: String }

    var projects = JSONObject()
    var threads = JSONObject()
    var latest: [Place: JSONObject] = [:]  // (kind, subject) -> {source: fields}
    var claims: [JSON] = []
    var told: Int
    var seenClaims: Set<ClaimKey> = []
    var lastLocal: [String: JSON] = [:]
    var newest: JSON = .int(0)
    var here: JSON = .null  // [project, thread] or null
    var listed: Set<String>?
    var seen: [String: JSON] = [:]
    var app: JSON = .null
    var appSince: JSON = .null
    var health: JSONObject = JSONObject([("connected", .null), ("signed_in", .null), ("page_ok", .null)])

    init(told: Int = 0) { self.told = told }
}

/// The Board: projects and threads right now, folded from Seen. `fold` is pure: same rows, same board. Ports poc/router/board.py.
/// Boards, rows, proofs and places are JSON objects with the Python field names.
enum CourierBoard {
    static let trust: [String: Int] = ["files": 3, "page": 2, "coordinator": 1]  // local process and files, then the thread on the page, then coordinator chat
    static let finished: Set<String> = ["idle", "resolved"]
    static let keepRows = 100  // the page holds only the latest rows; so does the Board
    static let threadFields = ["active", "project", "title", "state", "needs", "detail", "text", "session", "alive", "result"]

    static func known(_ value: JSON?) -> Bool {
        guard let value, !value.isNull else { return false }
        return value != "unknown"
    }

    /// Each field comes from the most trusted source that knows it.
    static func merge(_ bySource: JSONObject) -> JSONObject {
        var out = JSONObject()
        for source in bySource.keys.stableSorted(by: { -(trust[$0] ?? 0) }) {
            for (key, value) in bySource[source]?.asObject ?? JSONObject() where known(value) && !out.has(key) {
                out[key] = value
            }
        }
        return out
    }

    /// Rows by key, in page order: a changed row replaces its old self. A `full` scan replaces the place's rows. A new list every time,
    /// so a finished board can share the old one.
    static func mergeRows(_ old: [JSON]?, _ new: [JSON]?, full: Bool = false) -> [JSON] {
        var byKey = JSONObject()
        func keyOf(_ m: JSON) -> String { m["key"]?.pyStr ?? "" }
        if !full { for m in old ?? [] { byKey[keyOf(m)] = m } }
        for m in new ?? [] { byKey[keyOf(m)] = m }
        return Array(byKey.values.stableSorted(by: { $0["index"]?.numeric ?? 0 }).suffix(keepRows))
    }

    /// A row that counts: the server has it (pending rows never reach the Board), and a Claude row is not still being written.
    static func settled(_ m: JSON) -> Bool {
        m.get("from") != "claude" || !(m.get("streaming")?.isTruthy ?? false)
    }

    static func threadStep(_ acc: CourierAcc, _ row: JSON) {
        let subject = row["subject"]?.asString ?? ""
        var t = acc.threads[subject]?.asObject ?? JSONObject([("id", .string(subject)), ("turn", .int(0)), ("touched", row["at"] ?? .null), ("last", .null), ("view", .object(JSONObject()))])
        let place = CourierAcc.Place(kind: "thread", subject: subject)
        var bySource = acc.latest[place] ?? JSONObject()
        bySource[row["source"]?.asString ?? ""] = row["fields"] ?? .null
        acc.latest[place] = bySource
        let view = merge(bySource)
        let state = view["state"].flatMap { $0.isNull ? nil : $0 }
        if let state, state.isTruthy {
            let last = t["last"] ?? .null
            let prevNeeds = t["view"]?.get("needs")
            let asks = state == "needs_you" && last == "needs_you" && (view["needs"]?.isTruthy ?? false) && prevNeeds != nil && prevNeeds != view["needs"]
            if last.isNull || (state == "working" && last != "working") || asks {  // a second question is a new turn
                t["turn"] = .int((t["turn"]?.asInt ?? 0) + 1)
            }
            t["last"] = state
        }
        if let active = view["active"], active.isTruthy {
            t["touched"] = active
        } else if JSON.object(view) != t["view"] {
            t["touched"] = row["at"] ?? .null
        }
        t["view"] = .object(view)
        acc.threads[subject] = .object(t)
    }

    /// A local thread whose process was seen alive and is gone is stranded, unless the Claude app itself is closed (`app` false):
    /// then it waits for the app.
    static func finishThread(_ thread: JSONObject, app: JSON? = nil) -> JSONObject {
        var t = thread
        let view = t.pop("view") ?? .object(JSONObject())
        t.pop("last")
        for k in threadFields { t[k] = view.get(k) ?? .null }
        if !(t["state"]?.isTruthy ?? false) { t["state"] = "unknown" }
        t["local"] = .bool(!(t["alive"] ?? .null).isNull)
        if t["alive"] == .bool(false), !finished.contains(t["state"]?.asString ?? "") {
            t["state"] = app == .bool(false) ? "waiting_app" : "stranded"
        }
        return t
    }

    /// An empty fold state. `step` adds rows to it; `finish` reads a board from it without changing it.
    /// `claims` holds only the claims past the told mark (a row id), so the list stays as short as what hasn't been told.
    static func start(told: Int = 0) -> CourierAcc { CourierAcc(told: told) }

    static func step(_ acc: CourierAcc, _ row: JSON) {
        let kind = row["kind"]?.asString ?? ""
        let subject = row["subject"]?.asString ?? ""
        let source = row["source"]?.asString ?? ""
        let fields = row["fields"] ?? .object(JSONObject())
        let at = row["at"] ?? .null
        if source == "files" {
            acc.newest = pyMax(acc.newest, at)
            if pyStartsWith(subject, "local:") { acc.lastLocal[subject] = at }
        }
        if source == "page" && ["chat", "messages", "thread"].contains(kind) {  // the page shows a project's chat and threads only while it is open
            let project = kind == "chat" ? subject : fields.get("project")?.asString
            if let project, !project.isEmpty { acc.seen[project] = pyMax(acc.seen[project] ?? .int(0), at) }
        }
        if kind == "health" && source == "page" {
            var health = acc.health
            health.update(fields.asObject ?? JSONObject())
            acc.health = health
        } else if kind == "app" {  // whether the Claude app runs, and since when it has been so
            let running = fields["running"] ?? .null
            if acc.app != running { acc.app = running; acc.appSince = at }
        } else if kind == "project" {
            if acc.listed != nil && !acc.projects.has(subject) {  // new to the Board after a full list: it was made since, not left out of it
                acc.listed!.insert(subject)
            }
            let place = CourierAcc.Place(kind: "project", subject: subject)
            var latest = acc.latest[place] ?? JSONObject()
            latest[source] = fields
            acc.latest[place] = latest
            var p = acc.projects[subject]?.asObject ?? JSONObject([("id", .string(subject)), ("chat", .null), ("draft", .null), ("readable", .null)])
            p.update(merge(latest))
            acc.projects[subject] = .object(p)
        } else if kind == "settings" {
            var p = acc.projects[subject]?.asObject ?? JSONObject([("id", .string(subject)), ("chat", .null), ("draft", .null)])
            p["settings"] = fields
            acc.projects[subject] = .object(p)
        } else if kind == "chat" {
            var p = acc.projects[subject]?.asObject ?? JSONObject([("id", .string(subject)), ("chat", .null), ("draft", .null)])
            rowsEvent(&p, fields)
            acc.projects[subject] = .object(p)
        } else if kind == "thread" {
            threadStep(acc, row)
        } else if kind == "messages" {
            var t = acc.threads[subject]?.asObject ?? JSONObject([("id", .string(subject)), ("turn", .int(0)), ("touched", at), ("last", .null), ("view", .object(JSONObject()))])
            rowsEvent(&t, fields, key: "messages")
            acc.threads[subject] = .object(t)
        } else if kind == "threadlist" {  // the project's page lists no thread: each one it showed is finished (idle), until a later row says otherwise
            for (k, _) in acc.threads.pairs {
                let place = CourierAcc.Place(kind: "thread", subject: k)
                guard let pageView = acc.latest[place]?["page"], pageView.get("state")?.asString.map({ !finished.contains($0) }) ?? true,
                      acc.threads[k]?["view"]?.get("project")?.asString == subject else { continue }
                var f = pageView.asObject ?? JSONObject()
                f["state"] = "idle"; f["needs"] = .null
                threadStep(acc, ["source": "page", "kind": "thread", "subject": .string(k), "at": at, "fields": .object(f)])
            }
        } else if kind == "listing" {
            acc.listed = Set((fields["ids"]?.asArray ?? []).compactMap(\.asString))
        } else if kind == "claim" {
            let claim = CourierAcc.ClaimKey(project: fields["project"] ?? .null, key: fields["key"] ?? .null)
            if !acc.seenClaims.contains(claim) {
                acc.seenClaims.insert(claim)
                if (row["id"]?.asInt ?? 0) > acc.told {
                    var c = JSONObject([("id", row["id"] ?? .null), ("at", at)])
                    c.update(fields.asObject ?? JSONObject())
                    acc.claims.append(.object(c))
                }
            }
        }
    }

    /// The `chat` and `messages` branches of `step`, which differ only in where the place keeps its rows.
    private static func rowsEvent(_ p: inout JSONObject, _ fields: JSON, key rowsKey: String = "chat") {
        // A turning-only delta (no rows, not full) before the place's first whole read says nothing of its rows: it leaves them unread.
        if let messages = fields["messages"] {
            let unread = (p[rowsKey] ?? .null).isNull
            if !(unread && !messages.isTruthy && !(fields.get("full")?.isTruthy ?? false)) {
                p[rowsKey] = .array(mergeRows(p.get(rowsKey)?.asArray, messages.asArray, full: fields.get("full")?.isTruthy ?? false))
            }
            // a rows event: whether a reply is being written, against what the place showed before
            let (writing, state) = CourierPage.turning(fields, p.get("turn_state"))
            p["turn_state"] = state
            if let writing { p["turning"] = .bool(writing) }
        }
        for k in ["draft", "disabled"] { if let v = fields[k] { p[k] = v } }
    }

    static func finish(_ acc: CourierAcc) -> JSON {
        let gone = Set(acc.lastLocal.filter { _, at in (at.numeric ?? 0) < (acc.newest.numeric ?? 0) }.keys)
        var threads = JSONObject()
        for (k, t) in acc.threads where !gone.contains(k) && (t.asObject?["view"]?.isTruthy ?? false) {
            threads[k] = .object(finishThread(t.asObject!, app: acc.app))
        }
        let listed = acc.listed  // cloud projects the last full list left out were deleted or archived
        var projects = JSONObject()
        for (k, p) in acc.projects where !gone.contains(k) && (listed == nil || p.get("where") != "cloud" || listed!.contains(k)) {
            projects[k] = p
        }
        let here: JSON? = acc.here.isTruthy ? acc.here[0] : nil
        for (k, t) in threads {
            var t = t.asObject!
            if !t.has("messages") { t["messages"] = .null }
            if !t.has("draft") { t["draft"] = .null }
            let files = known(acc.latest[.init(kind: "thread", subject: k)]?["files"]?.get("state"))
            let live = pyStartsWith(k, "local:") || files || (here != nil && !here!.isNull && t["project"] == here)
            if live {
                t["as_of"] = .null
            } else if let project = t["project"]?.asString, let seen = acc.seen[project] {
                t["as_of"] = seen  // a cloud thread elsewhere is only as fresh as the last visit
            } else {
                t["as_of"] = t["touched"] ?? .null
            }
            threads[k] = .object(t)
        }
        for (k, p) in projects {
            var p = p.asObject!
            p["seen"] = acc.seen[p["id"]?.asString ?? ""] ?? .null
            if !p.has("name") { p["name"] = p["id"] ?? .null }
            if !p.has("where") { p["where"] = .null }
            if !p.has("purpose") { p["purpose"] = "" }
            if !p.has("settings") { p["settings"] = .null }
            projects[k] = .object(p)
        }
        return ["health": .object(acc.health), "app": acc.app, "app_since": acc.appSince, "here": acc.here, "projects": .object(projects),
                "threads": .object(threads), "claims": .array(acc.claims)]
    }

    @discardableResult
    static func foldInto(_ acc: CourierAcc, _ rows: [JSON]) -> CourierAcc {
        let sorted = rows.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            let (ax, ay) = (x["at"]?.numeric ?? 0, y["at"]?.numeric ?? 0)
            if ax != ay { return ax < ay }
            let (ix, iy) = (x["id"]?.numeric ?? 0, y["id"]?.numeric ?? 0)
            if ix != iy { return ix < iy }
            return a.offset < b.offset
        }
        for (_, row) in sorted { step(acc, row) }
        return acc
    }

    static func fold(_ rows: [JSON]) -> JSON { finish(foldInto(start(), rows)) }

    /// A project by id or by name.
    static func projectNamed(_ board: JSON, _ name: String) -> JSON? {
        if let p = board["projects"]?[name] { return p }
        return board["projects"]?.asObject?.values.first { $0["name"] == .string(name) }
    }

    /// Letters and digits only, in lower case: the page renders Markdown, so a row never matches the typed words character for character.
    static func loose(_ text: String?) -> String {
        let text = text ?? ""
        let kept = String(String.UnicodeScalarView(casefold(text).unicodeScalars.filter(isAlnum)))
        return kept.isEmpty ? squash(text) : kept
    }

    /// Python's `str.casefold` (full case folding).
    static func casefold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Python's `str.isalnum` on one character: a letter, or a decimal, digit or numeric character.
    static func isAlnum(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// The words of a text: its runs of letters and digits, in lower case. A row that starts with a send's words starts with all its
    /// tokens, so "yes" is no prefix of "Yesterday's build broke".
    static func tokens(_ text: String?) -> [String] {
        var out: [String] = []
        var word = String.UnicodeScalarView()
        for c in casefold(text ?? "").unicodeScalars {
            if isAlnum(c) {
                word.append(c)
            } else if !word.isEmpty {
                out.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { out.append(String(word)) }
        return out
    }

    /// The text's first tokens are all the words' tokens (a prefix ending on a word boundary). Words with no token start nothing.
    static func startsWith(_ text: String?, _ words: String?) -> Bool {
        let mine = tokens(words)
        return !mine.isEmpty && Array(tokens(text).prefix(mine.count)) == mine
    }

    /// The text starts with the words (`startsWith`) and adds at most min(3, the words' token count - 1) tokens: a row may carry a
    /// few rendered words after the message, but a short send must match (nearly) exactly, a 1-token one ("yes", "ok") exactly, so a
    /// hand-typed message that starts with it can't prove it.
    static func endsShortly(_ text: String?, _ words: String?) -> Bool {
        let mine = tokens(words)
        return startsWith(text, words) && tokens(text).count - mine.count <= min(3, mine.count - 1)
    }

    /// Whitespace normalized: how drafts are compared, so multi-line words can't differ by a line break.
    static func squash(_ text: String?) -> String {
        let space: (Unicode.Scalar) -> Bool = { $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value) }
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for c in (text ?? "").unicodeScalars {
            if space(c) {
                if !word.isEmpty { words.append(String(word)); word = String.UnicodeScalarView() }
            } else {
                word.append(c)
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words.joined(separator: " ")
    }

    static func placeOf(_ board: JSON, _ project: String?, _ thread: String? = nil) -> JSON? {
        if let thread, !thread.isEmpty { return board["threads"]?.get(thread) }
        return project.flatMap { board["projects"]?.get($0) }
    }

    /// A place's rows in page order, or nil when they haven't been read.
    static func rowsOf(_ place: JSON?, _ thread: String? = nil) -> [JSON]? {
        place?.get(thread != nil && !thread!.isEmpty ? "messages" : "chat")?.asArray
    }

    /// The keys a read is placed against: the baseline's, and the anchors, Claude's rows that reads placed after it (`do.anchor`).
    static func placedBy(_ proof: JSON) -> Set<String> {
        Set((proof.get("baseline")?.asArray ?? []).compactMap(\.asString)).union((proof.get("anchors")?.asArray ?? []).compactMap(\.asString))
    }

    /// The rows after the last one whose key was in the baseline, in current order. A read that holds no baseline key (a busy chat whose
    /// window scrolled past it) is placed by the anchors instead: the rows after the earliest one it holds, since your row, queued while they
    /// were written, can take its key before the later ones. All of them when the baseline is empty (an empty chat) and nothing is
    /// anchored. nil when unreadable. Rows that hold none of those keys can't be placed against them (a reloaded page's window of older
    /// history, whose keys Fjord never saw, would look new): none of them is new, and a later read that holds one of the keys says.
    static func newRows(_ board: JSON, _ proof: JSON) -> [JSON]? {
        let thread = proof.get("thread")?.asString
        guard let messages = rowsOf(placeOf(board, proof["project"]?.asString, thread), thread) else { return nil }
        let baseline = Set((proof.get("baseline")?.asArray ?? []).compactMap(\.asString))
        let anchors = Set((proof.get("anchors")?.asArray ?? []).compactMap(\.asString))
        let keyIn: (Set<String>) -> (JSON) -> Bool = { keys in { keys.contains($0["key"]?.asString ?? "\u{0}") } }
        var last = messages.indices.last(where: { keyIn(baseline)(messages[$0]) })
        if last == nil { last = messages.indices.first(where: { keyIn(anchors)(messages[$0]) }) }
        guard let last else { return baseline.isEmpty && anchors.isEmpty ? messages : [] }
        return Array(messages[(last + 1)...])
    }

    /// New rows from you in the proof's place, or nil when the place can't be read. A `claimed` row already proved another send: one
    /// row proves one send, so it is another message's, not this one's.
    static func fromYou(_ board: JSON, _ proof: JSON, _ claimed: Set<String> = []) -> [JSON]? {
        newRows(board, proof)?.filter { $0.get("from") == "you" && !claimed.contains($0["key"]?.asString ?? "\u{0}") }
    }

    /// {id: key}: the new rows from you given to the sends of one place, `proofs` ([(id, proof)], in priority order), together, so a
    /// row goes to the send whose words it is. First each send takes its earliest new row whose words (loosely) equal its own; only then
    /// does one with none take its earliest row that starts with its words and adds only a few (`endsShortly`), the longest words choosing
    /// first, and never a row taken or one whose words equal another send's (that row is the other send's message, even if not new to
    /// it). `claimed` rows proved earlier sends: no one takes them.
    static func assign(_ board: JSON, _ proofs: [(id: JSON, proof: JSON)], _ claimed: Set<String> = []) -> [JSON: String] {
        // dict(proofs): a later pair with the same id replaces the earlier
        var proofOf: [JSON: JSON] = [:]
        for (i, p) in proofs { proofOf[i] = p }
        var rows: [JSON: [JSON]] = [:]
        var words: [JSON: String] = [:]
        for (i, p) in proofs {
            rows[i] = fromYou(board, p, claimed) ?? []
            words[i] = loose(p["words"]?.asString)
        }
        var taken: [JSON: String] = [:]
        for (i, _) in proofs {
            let held = Set(taken.values)
            if let row = rows[i]!.first(where: { !held.contains($0["key"]?.asString ?? "\u{0}") && loose($0.get("text")?.asString) == words[i]! }) {
                taken[i] = row["key"]?.asString ?? ""
            }
        }
        let exact = Set(words.values)
        // The longest words first (priority breaks a tie: the sort is stable): a row that starts with two sends' words is the longer one's.
        for (i, _) in proofs.stableSorted(by: { -words[$0.id]!.count }) {  // len(words) is a count of code points
            if taken[i] == nil {
                let held = Set(taken.values)
                let mine = proofOf[i]!["words"]?.asString
                if let row = rows[i]!.first(where: { !held.contains($0["key"]?.asString ?? "\u{0}") && !exact.contains(loose($0.get("text")?.asString))
                                                && endsShortly($0.get("text")?.asString, mine) }) {
                    taken[i] = row["key"]?.asString ?? ""
                }
            }
        }
        return taken
    }

    /// The keys of rows that are another send's of the place than `i`'s: taken by it (`assign`), or with exactly its words.
    static func others(_ board: JSON, _ proofs: [(id: JSON, proof: JSON)], _ taken: [JSON: String], _ i: JSON) -> Set<String> {
        let words = Set(proofs.filter { $0.id != i }.map { loose($0.proof["words"]?.asString) })
        var mine: JSON = .null
        for (j, p) in proofs where j == i { mine = p }
        let rows = Set((fromYou(board, mine) ?? []).filter { words.contains(loose($0.get("text")?.asString)) }.map { $0["key"]?.asString ?? "" })
        let others = Set(taken.filter { $0.key != i }.map(\.value)).union(rows)
        return taken[i].map { others.subtracting([$0]) } ?? others
    }

    /// The earliest new row from you, not `claimed`, that has these words (loosely: equal first, else starting with them), else nil.
    static func provingRow(_ board: JSON, _ proof: JSON, _ claimed: Set<String> = []) -> JSON? {
        guard let key = assign(board, [(.null, proof)], claimed)[.null] else { return nil }
        return (fromYou(board, proof, claimed) ?? []).first { $0["key"]?.asString == key }
    }

    /// True when a new row from you has these words (loosely), False when none matches, nil when unreadable.
    static func proofHolds(_ board: JSON, _ proof: JSON, _ claimed: Set<String> = []) -> Bool? {
        fromYou(board, proof, claimed) == nil ? nil : provingRow(board, proof, claimed) != nil
    }

    // MARK: Test bridge

    nonisolated(unsafe) private static var accs: [Int: CourierAcc] = [:]
    nonisolated(unsafe) private static var nextAcc = 1

    private static func acc(_ j: JSON) throws -> CourierAcc {
        guard let n = j["acc"]?.asInt, let a = accs[n] else { throw JSONError.invalid("no such acc") }
        return a
    }

    private static func proofs(_ j: JSON) -> [(id: JSON, proof: JSON)] {
        (j.asArray ?? []).map { ($0[0] ?? .null, $0[1] ?? .null) }
    }

    private static func claimedKeys(_ a: [JSON], _ at: Int) -> Set<String> {
        a.count > at ? Set((a[at].asArray ?? []).compactMap(\.asString)) : []
    }

    /// The functions the Python tests call, by Python name, over JSON arguments. An acc (`board.start()`) is `{"acc": n}`; `assign` returns
    /// `[[id, key], …]` (JSON objects can't have int keys) and the sets of `others` and `placed_by` come back sorted.
    static let testOps: [String: ([JSON]) throws -> JSON] = [
        "board.known": { a in .bool(known(a.first)) },
        "board.merge": { a in .object(merge(a[0].asObject ?? JSONObject())) },
        "board.merge_rows": { a in .array(mergeRows(a[0].asArray, a[1].asArray, full: a.count > 2 && a[2].isTruthy)) },
        "board.settled": { a in .bool(settled(a[0])) },
        "board.start": { a in
            let n = nextAcc
            nextAcc += 1
            accs[n] = start(told: a.first?.asInt ?? 0)
            return ["acc": .int(n)]
        },
        "board.step": { a in step(try acc(a[0]), a[1]); return .null },
        "board.fold_into": { a in foldInto(try acc(a[0]), a[1].asArray ?? []); return a[0] },
        "board.finish": { a in finish(try acc(a[0])) },
        // Sets a field of an acc the way a core does: here, told, app, listed (a list of ids).
        "board.acc_set": { a in
            let acc = try acc(a[0])
            switch a[1].asString ?? "" {
            case "here": acc.here = a[2]
            case "told": acc.told = a[2].asInt ?? 0
            case "app": acc.app = a[2]
            default: throw JSONError.invalid("can't set \(a[1].pyStr)")
            }
            return .null
        },
        "board.fold": { a in fold(a[0].asArray ?? []) },
        "board.project_named": { a in projectNamed(a[0], a[1].asString ?? "") ?? .null },
        "board.loose": { a in .string(loose(a[0].asString)) },
        "board.tokens": { a in .strings(tokens(a[0].asString)) },
        "board.starts_with": { a in .bool(startsWith(a[0].asString, a[1].asString)) },
        "board.ends_shortly": { a in .bool(endsShortly(a[0].asString, a[1].asString)) },
        "board.squash": { a in .string(squash(a[0].asString)) },
        "board.place_of": { a in placeOf(a[0], a[1].asString, a.count > 2 ? a[2].asString : nil) ?? .null },
        "board.rows_of": { a in rowsOf(a[0].isNull ? nil : a[0], a.count > 1 ? a[1].asString : nil).map { .array($0) } ?? .null },
        "board.placed_by": { a in .strings(pySorted(Array(placedBy(a[0])))) },
        "board.new_rows": { a in newRows(a[0], a[1]).map { .array($0) } ?? .null },
        "board.from_you": { a in fromYou(a[0], a[1], claimedKeys(a, 2)).map { .array($0) } ?? .null },
        "board.assign": { a in
            .array(assign(a[0], proofs(a[1]), claimedKeys(a, 2)).map { [$0.key, .string($0.value)] })
        },
        "board.others": { a in
            let taken = Dictionary(uniqueKeysWithValues: (a[2].asArray ?? []).map { (($0[0] ?? .null), $0[1]?.asString ?? "") })
            return .strings(pySorted(Array(others(a[0], proofs(a[1]), taken, a[3]))))
        },
        "board.proving_row": { a in provingRow(a[0], a[1], claimedKeys(a, 2)) ?? .null },
        "board.proof_holds": { a in proofHolds(a[0], a[1], claimedKeys(a, 2)).map(JSON.bool) ?? .null },
    ]
}

/// The plan's name for the fold functions.
typealias CourierFold = CourierBoard
