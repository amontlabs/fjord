import Foundation

/// Do: what one intent may do next, as pure functions over the Board. The core runs the steps. Ports poc/router/do.py.
///
/// Proof is a new row from you, seen in a `rows` event: one after the last row whose key the place held at the baseline (taken before
/// anything is sent, from a settled whole read: the latest 50 keys on screen, and the latest 200 others Seen holds for the place, which a
/// first render may lack). A read that holds none of them is placed by the anchors (Claude's rows that earlier
/// reads placed after the baseline): its rows after the earliest anchor it holds are new. Rows holding neither can't be placed, and none
/// is new. One row proves one send: a row that proved another send of the place is no proof. Once any such row exists, never send again. Once the page took the words (the draft emptied after the click) never send again
/// either, and wait for the row.
enum CourierDo {
    static let retries = 2
    static let timeout = 20.0  // seconds without a row from you before the next attempt
    static let keys = 50  // keys of a baseline from the rows on screen, the most recent; also the anchors kept
    static let known = 200  // keys of a baseline from those Seen holds for the place and the screen lacks, the most recently read
    /// keys of the baseline and anchors a finished send's proof keeps (a watched one, failed after a click or a take or while in
    /// the page, or by a restart after its send, keeps them all while it is watched). A variable so a test can change it (`set_constant`).
    nonisolated(unsafe) static var kept = 5
    static let done: [String] = ["confirmed", "failed", "refused", "answered", "asked"]
    static let tools: [String] = ["create_project", "set_instructions", "set_goal", "add_repo", "preapprove_folder"]
    static let confirm: [String] = ["preapprove_folder"]  // a permission grant waits for the owner's word
    static let args: [String: [String]] = ["create_project": ["name", "goal"], "set_instructions": ["project", "text"], "set_goal": ["project", "text"],
                                           "add_repo": ["project", "repo"], "preapprove_folder": ["project", "path"]]
    static let primary: [String: String] = ["create_project": "name", "set_instructions": "text", "set_goal": "text", "add_repo": "repo", "preapprove_folder": "path"]
    static let limits: [String: Int] = ["name": 200, "goal": 8000, "instructions": 16000]  // what the page's fields take
    static let notConfirmed = "done, but not confirmed"

    static let chromeOpen = "Chrome is open but Fjord's tab isn't connected: the profile picker is showing, or another profile is open, or the extension is off"

    /// Whether Google Chrome runs: why the page isn't connected differs, and so does what the owner should do. Replaceable, so a core under
    /// test (or the app, from what it already knows) answers without a process.
    nonisolated(unsafe) static var chromeRunning: () -> Bool = defaultChromeRunning
    nonisolated(unsafe) private static var chromeAsked = (at: -1000.0, answer: false)  // `blocked` is asked on every event while the page is away

    static func defaultChromeRunning() -> Bool {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
        if now - chromeAsked.at > 5 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-a", "-x", "Google Chrome"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                chromeAsked.answer = p.terminationStatus == 0
            } catch {
                chromeAsked.answer = false
            }
            chromeAsked.at = now
        }
        return chromeAsked.answer
    }

    /// Why nothing can be done now, else nil. Null is unknown, not a reason to pause.
    static func blocked(_ health: JSON) -> String? {
        if health.get("connected") != .bool(true) { return chromeRunning() ? chromeOpen : "Chrome isn't running" }
        if health.get("signed_in") == .bool(false) { return "signed out of claude.ai" }
        if health.get("away") == .bool(true) { return "Fjord's tab has left the Claude Code page" }
        if health.get("page_ok") == .bool(false) { return "the page can't be read" }
        return nil
    }

    static func refusal(_ board: JSON, _ intent: JSON) -> String? {
        if pyStartsWith(intent.get("project")?.asString ?? "", "local:") { return "this folder has no Claude project yet" }
        let thread = intent.get("thread")
        if let thread, thread.isTruthy, board["threads"]?[thread.pyStr] == nil { return "that thread isn't on the board" }
        if !(thread?.isTruthy ?? false), board["projects"]?[intent.get("project")?.asString ?? "\u{0}"] == nil { return "no such project on the page" }
        return nil
    }

    static let appClosed = "waiting for the Claude app"
    static let last = 300  // characters of a stranded thread's last state in its handoff

    /// A reply to a local thread while the Claude app is closed waits for the app: the thread can't run, and isn't stranded.
    static func appWait(_ board: JSON, _ intent: JSON) -> String? {
        if let t = board["threads"]?.get(intent.get("thread")?.asString ?? "\u{0}"), t.isTruthy, t["local"]?.isTruthy ?? false, board.get("app") == .bool(false) {
            return appClosed
        }
        return nil
    }

    /// The thread a reply goes to, when its process is gone while the app runs: a reply there isn't delivered and wakes nothing.
    static func stranded(_ board: JSON, _ intent: JSON) -> JSON? {
        if let t = board["threads"]?.get(intent.get("thread")?.asString ?? "\u{0}"), t["state"] == "stranded" { return t }
        return nil
    }

    /// `a or b or c`: the first truthy value (the last one when none is).
    private static func firstTruthy(_ values: JSON?...) -> JSON {
        for v in values { if let v, v.isTruthy { return v } }
        return values.last.flatMap { $0 } ?? .null
    }

    /// (words, args) of the project send that continues a stranded thread: the owner's words, after a short note from Fjord.
    static func handoff(_ t: JSON, _ words: String) -> (text: String, args: JSON) {
        let state = CourierBoard.squash(firstTruthy(t.get("detail"), t.get("text"), t.get("result"), "").pyStr)
        let last = pyPrefix(state, Self.last).isEmpty ? "unknown" : pyPrefix(state, Self.last)
        let title = firstTruthy(t.get("title"), t.get("id")).pyStr
        let text = "Thread «\(title)» lost its process. Start a new thread in the same folder that continues it. Last state: \(last). Message: \(words)"
        return (text, ["continues": t["id"] ?? .null, "message": .string(words)])
    }

    /// What the owner is told with the decision: a reply that waits for the app, or one that went to the coordinator instead.
    static func warning(_ board: JSON, _ intent: JSON) -> String? {
        if intent.get("args")?.get("continues")?.isTruthy ?? false {
            return "that thread lost its process; the message goes to its project's coordinator, to continue it in a new thread"
        }
        if intent.get("thread")?.isTruthy ?? false, appWait(board, intent) != nil { return "the Claude app isn't running; the reply waits for it" }
        return nil
    }

    /// The proof starts from the keys of the rows the place holds, taken before anything is sent, the latest KEYS, and the latest KNOWN
    /// other keys Fjord knows for the place (`known`: the keys Seen holds for it, in the order they were last read). A first render can lack
    /// the bottom rows: an old row the next delta brings is one of them, and not new. Those come first, so a tail of the baseline is the
    /// screen's latest.
    static func baselined(_ board: JSON, _ proof: JSON, known knownKeys: [String] = []) -> JSON {
        if proof.has("baseline") { return proof }
        let thread = proof.get("thread")?.asString
        let rows = CourierBoard.rowsOf(CourierBoard.placeOf(board, proof["project"]?.asString, thread), thread)
        let onScreen = Array((rows ?? []).map { $0["key"]?.asString ?? "" }.suffix(keys))
        let held = Set(onScreen)
        var out = proof
        out["baseline"] = .strings(Array(knownKeys.filter { !held.contains($0) }.suffix(known)) + onScreen)
        return out
    }

    /// A finished send's proof: the last KEPT keys of its baseline and anchors. The `baseline` key stays: it says the chat was sent to
    /// (`store.chat_projects`).
    static func tail(_ proof: JSON) -> JSON {
        var out = proof
        for k in ["baseline", "anchors"] { if let v = proof[k]?.asArray { out[k] = .array(Array(v.suffix(kept))) } }
        return out
    }

    /// The place's rows have been read and can be placed against the baseline: they hold one of its keys or anchors, or it holds none
    /// (an empty chat). Rows that hold none of them (a window of older history, say) say nothing about what came after it.
    static func anchored(_ board: JSON, _ proof: JSON) -> Bool {
        let thread = proof.get("thread")?.asString
        guard let rows = CourierBoard.rowsOf(CourierBoard.placeOf(board, proof["project"]?.asString, thread), thread) else { return false }
        let known = CourierBoard.placedBy(proof)
        return known.isEmpty || rows.contains { known.contains($0["key"]?.asString ?? "\u{0}") }
    }

    /// The proof with its anchors moved forward: the keys of Claude's rows a read placed after the baseline, the latest KEYS of them. A
    /// later read whose window has scrolled past the baseline (a busy chat, or its reload) is placed by them. Only Claude's: a row first
    /// read as `unknown` can turn out to be yours. The same proof when nothing is new.
    static func anchor(_ board: JSON, _ proof: JSON) -> JSON {
        let rows = CourierBoard.newRows(board, proof)
        let old = proof.get("anchors")?.asArray ?? []
        let new = (rows ?? []).filter { $0.get("from") == "claude" && !old.contains($0["key"] ?? .null) }.map { $0["key"] ?? .null }
        guard !new.isEmpty else { return proof }
        var out = proof
        out["anchors"] = .array(Array((old + new).suffix(keys)))
        return out
    }

    /// The coordinator is mid-turn: a Claude row of the place is still being written, one placed after the baseline or one already in
    /// it (a turn that began before the send). Your message, if the server has it, may stay queued until the turn ends.
    static func turning(_ board: JSON, _ proof: JSON) -> Bool {
        let thread = proof.get("thread")?.asString
        let shown = CourierBoard.placeOf(board, proof["project"]?.asString, thread)
        if let t = shown?.get("turning") { return t.isTruthy }  // the page's own reading, pending rows too (`page.turning`)
        return (CourierBoard.rowsOf(shown, thread) ?? []).contains { $0.get("from") == "claude" && ($0.get("streaming")?.isTruthy ?? false) }
    }

    struct Proved: Equatable {
        var done: Bool
        var cause: String?
        var key: String?
    }

    /// (done, cause, key) of one send: `provedAll` with no other send of its place.
    static func proved(_ board: JSON, _ proof: JSON, _ claimed: Set<String> = []) -> Proved {
        provedAll(board, [(.null, proof)], claimed)[.null]!
    }

    /// {id: (done, cause, key)} for the sends of one place (`proofs`, [(id, proof)] in priority order), judged together: each new row
    /// from you goes to the send whose words it is (`CourierBoard.assign`), and `key` is that row's. Any other new row from you ends the sending
    /// (`cause`), but not a row that is another send's (taken by it, or with exactly its words): a send failed earlier, delivered late,
    /// says nothing of this one. A row in `claimed` (the place's rows that proved other sends) is skipped: one row proves one send.
    static func provedAll(_ board: JSON, _ proofs: [(id: JSON, proof: JSON)], _ claimed: Set<String> = []) -> [JSON: Proved] {
        let taken = CourierBoard.assign(board, proofs, claimed)
        var out: [JSON: Proved] = [:]
        for (i, proof) in proofs {
            if let key = taken[i] {
                out[i] = Proved(done: true, cause: nil, key: key)
                continue
            }
            let skip = claimed.union(CourierBoard.others(board, proofs, taken, i))
            let rows = CourierBoard.fromYou(board, proof, skip)
            out[i] = !(rows ?? []).isEmpty ? Proved(done: true, cause: "a row from you arrived, but its words differ from what was sent", key: nil)
                                          : Proved(done: false, cause: nil, key: nil)
        }
        return out
    }

    // MARK: Tools

    /// `str.strip()`.
    static func pyStrip(_ s: String) -> String {
        let space: (Unicode.Scalar) -> Bool = { $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value) }
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, space(f) { scalars.removeFirst() }
        while let l = scalars.last, space(l) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `text.replace("\r\n", "\n").replace("\r", "\n")`.
    private static func lineEnds(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var skipLF = false
        for u in s.unicodeScalars {
            if u == "\r" { out.append("\n"); skipLF = true; continue }
            if skipLF && u == "\n" { skipLF = false; continue }
            skipLF = false
            out.append(u)
        }
        return String(out)
    }

    /// (args, cause): the arguments with line ends as the page's fields hold them, or why they are refused.
    static func toolArgs(_ tool: String, _ args: JSON) -> (args: JSON?, cause: String?) {
        guard tools.contains(tool) else { return (nil, "no such tool: \(tool)") }
        guard let given = args.asObject else { return (nil, "the arguments aren't an object") }
        let allowed = Set(Self.args[tool]!)
        let extra = pySorted(given.keys.filter { !allowed.contains($0) })
        if !extra.isEmpty { return (nil, "unexpected arguments: \(extra.joined(separator: ", "))") }
        var clean = JSONObject()
        for (key, value) in given {
            if value.isNull && key == "goal" { continue }
            guard let text = value.asString else { return (nil, "\(key) must be text") }
            clean[key] = .string(lineEnds(text))
        }
        let missing = Self.args[tool]!.filter { !clean.has($0) && $0 != "goal" }
        if !missing.isEmpty { return (nil, "missing: \(missing.joined(separator: ", "))") }
        for key in ["name", "repo", "path"] {
            if let v = clean[key]?.asString {
                if pyStrip(v).isEmpty { return (nil, "\(key) is empty") }
                clean[key] = .string(pyStrip(v))
            }
        }
        if let name = clean["name"]?.asString, name.contains("\n") || name.unicodeScalars.count > limits["name"]! {
            return (nil, "the name must be one line of at most \(limits["name"]!) characters")
        }
        let limit = tool == "set_instructions" ? limits["instructions"]! : limits["goal"]!
        for key in ["goal", "text"] {
            if (clean[key]?.asString ?? "").unicodeScalars.count > limit { return (nil, "\(key) is over \(limit) characters") }
        }
        if let given = clean["path"]?.asString {  // the page lists folders under the home folder as ~/…, so a full path is written the same way
            var home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            while home.hasSuffix("/") { home.removeLast() }
            var path = given
            while path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty { path = "/" }
            clean["path"] = .string(path == home || pyStartsWith(path, home + "/") ? "~" + String(String.UnicodeScalarView(path.unicodeScalars.dropFirst(home.unicodeScalars.count))) : path)
        }
        let repo = clean["repo"]?.asString ?? "a/b"
        let parts = pySplit(repo, "/")
        if parts.count != 2 || !parts.allSatisfy({ !$0.isEmpty }) || repo.unicodeScalars.contains(where: { $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value) }) {
            return (nil, "a repository is owner/name")
        }
        return (.object(clean), nil)
    }

    /// Why a project can't be created under this name, else nil.
    static func nameTaken(_ board: JSON, _ name: String) -> String? {
        // a local folder of that name has no project yet
        if (board["projects"]?.asObject?.values ?? []).contains(where: { $0["name"] == .string(name) && pyStartsWith($0["id"]?.asString ?? "", "chan_") }) {
            return "a project named \(name) already exists"
        }
        return nil
    }

    /// What Look must see afterwards: the field equal to the text, the list holding the repo or the path, or a new project of that name.
    static func toolProof(_ tool: String, _ args: JSON, _ board: JSON) -> JSON {
        if tool == "create_project" {
            return ["name": args["name"] ?? .null, "known": .strings(pySorted(board["projects"]?.asObject?.keys ?? []))]
        }
        if tool == "set_instructions" || tool == "set_goal" {
            return ["field": .string(String(tool.dropFirst("set_".count))), "equals": args["text"] ?? .null]
        }
        return ["field": tool == "add_repo" ? "repos" : "folders", "has": firstTruthy(args.get("repo"), args.get("path"))]
    }

    /// Ids of the projects the page lists under the proof's name that weren't known before.
    static func created(_ board: JSON, _ proof: JSON) -> [String] {
        let known = proof["known"]?.asArray ?? []
        return pySorted((board["projects"]?.asObject?.values ?? []).filter {
            $0["name"] == proof["name"] && pyStartsWith($0["id"]?.asString ?? "", "chan_") && !known.contains($0["id"] ?? .null)
        }.map { $0["id"]?.asString ?? "" })
    }

    /// (holds, cause): the page shows what the tool did, in the last settings read or the projects it lists. Several new projects of one name can't be told apart.
    static func toolProved(_ board: JSON, _ intent: JSON) -> (holds: Bool, cause: String?) {
        let proof = intent["proof"] ?? .null
        if intent["tool"] == "create_project" {
            let new = created(board, proof)
            return (new.count == 1, new.count > 1 ? "\(new.count) new projects are named \(proof["name"]?.pyStr ?? "")" : nil)
        }
        let place = board["projects"]?.get(intent.get("project")?.asString ?? "\u{0}")
        let settings = place?.get("settings")
        let value = (settings?.isTruthy ?? false) ? settings?.get(proof["field"]?.asString ?? "") : nil
        return (shows(proof, value), nil)
    }

    /// The field or list holds what the tool asks for.
    static func shows(_ proof: JSON, _ value: JSON?) -> Bool {
        if let equals = proof["equals"] { return (value ?? .null) == equals }
        let has = proof["has"] ?? .null
        switch value ?? .null {
        case .array(let a): return a.contains(has)
        case .string(let s): return has.asString.map { s.contains($0) } ?? false
        default: return false
        }
    }

    /// What the field or list held before the act, as the act's own open read it, kept on the intent so it can be put back. The page's
    /// report is data: anything but text for a field, or a list of text for a list, is unknown.
    static func before(_ value: JSON?, _ intent: JSON) -> JSON {
        let field = intent["proof"]?["field"]?.asString
        if field == "repos" || field == "folders" {
            return value?.asArray.map { .array($0.filter { $0.asString != nil }) } ?? .null
        }
        return value?.asString != nil ? value! : .null
    }

    /// (kind, fields) of the one command that acts.
    static func actCommand(_ intent: JSON) -> (kind: String, fields: JSON) {
        let a = intent["args"] ?? .null, project = intent["project"] ?? .null
        switch intent["tool"]?.asString {
        case "create_project": return ("create_project", ["name": a["name"] ?? .null, "goal": a.get("goal") ?? .null])
        case "set_instructions", "set_goal":
            return ("set_field", ["project": project, "field": intent["proof"]?["field"] ?? .null, "text": a["text"] ?? .null])
        case "add_repo": return ("add_repo", ["project": project, "repo": a["repo"] ?? .null])
        default: return ("preapprove_folder", ["project": project, "path": a["path"] ?? .null])
        }
    }

    // MARK: Test bridge

    private static func claimed(_ a: [JSON], _ at: Int) -> Set<String> {
        a.count > at ? Set((a[at].asArray ?? []).compactMap(\.asString)) : []
    }

    private static func provedJSON(_ p: Proved) -> JSON { [.bool(p.done), JSON(p.cause), JSON(p.key)] }

    /// The functions the Python tests call, by Python name, over JSON arguments. Tuples come back as lists; `proved_all` as `[[id, [done, cause, key]], …]`;
    /// `chrome_running` is not an op (set `CourierDo.chromeRunning`).
    static let testOps: [String: ([JSON]) throws -> JSON] = [
        "do.blocked": { a in JSON(blocked(a[0])) },
        "do.refusal": { a in JSON(refusal(a[0], a[1])) },
        "do.app_wait": { a in JSON(appWait(a[0], a[1])) },
        "do.stranded": { a in stranded(a[0], a[1]) ?? .null },
        "do.handoff": { a in let h = handoff(a[0], a[1].asString ?? ""); return [.string(h.text), h.args] },
        "do.warning": { a in JSON(warning(a[0], a[1])) },
        "do.baselined": { a in baselined(a[0], a[1], known: a.count > 2 ? (a[2].asArray ?? []).compactMap(\.asString) : []) },
        "do.tail": { a in tail(a[0]) },
        "do.anchored": { a in .bool(anchored(a[0], a[1])) },
        "do.anchor": { a in anchor(a[0], a[1]) },
        "do.turning": { a in .bool(turning(a[0], a[1])) },
        "do.proved": { a in provedJSON(proved(a[0], a[1], claimed(a, 2))) },
        "do.proved_all": { a in
            let proofs = (a[1].asArray ?? []).map { (id: $0[0] ?? .null, proof: $0[1] ?? .null) }
            let result = provedAll(a[0], proofs, claimed(a, 2))
            var seen: [JSON] = []
            return .array(proofs.compactMap { p in
                if seen.contains(p.id) { return nil }
                seen.append(p.id)
                return [p.id, provedJSON(result[p.id]!)]
            })
        },
        "do.tool_args": { a in let r = toolArgs(a[0].asString ?? "", a[1]); return [r.args ?? .null, JSON(r.cause)] },
        "do.name_taken": { a in JSON(nameTaken(a[0], a[1].asString ?? "")) },
        "do.tool_proof": { a in toolProof(a[0].asString ?? "", a[1], a[2]) },
        "do.created": { a in .strings(created(a[0], a[1])) },
        "do.tool_proved": { a in let r = toolProved(a[0], a[1]); return [.bool(r.holds), JSON(r.cause)] },
        "do.shows": { a in .bool(shows(a[0], a.count > 1 && !a[1].isNull ? a[1] : nil)) },
        "do.before": { a in before(a.count > 0 && !a[0].isNull ? a[0] : nil, a[1]) },
        "do.act_command": { a in let r = actCommand(a[0]); return [.string(r.kind), r.fields] },
    ]
}
