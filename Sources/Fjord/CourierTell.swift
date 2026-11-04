import Foundation

/// Tell: Board changes, minus what you were already told, as a brief. The fact-diff and the plan are pure. Ports poc/router/tell.py, apart from
/// turning facts into the words of the brief (`RouterBrief`, `RouterDigest`); the texts here are the facts' own `text` lines, as in Python.
enum CourierTell {
    static let window = 120.0  // seconds: a finish on the thread and the coordinator saying so this close are one fact. Nothing else is deduped
    static let last = 120  // characters of a stranded thread's last state in its line
    static let strands: [String] = ["working", "needs_you", "waiting_app"]  // a thread lost from one of these is news; one already done or unknown isn't

    /// `a or b or ""` as text.
    private static func text(_ values: JSON?...) -> String {
        for v in values { if let v, v.isTruthy { return v.pyStr } }
        return ""
    }

    /// context.age: the age as the brief says it.
    static func age(_ seconds: Double) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// context.as_of: the marker of a state seen on an earlier visit, empty for a live one.
    static func asOf(_ t: JSON, _ now: Double) -> String {
        guard let at = t.get("as_of")?.numeric else { return "" }
        return " (as of \(age(now - at)) ago)"
    }

    static func fact(_ t: JSON, _ kind: String) -> JSON {
        let title = text(t.get("title"), t.get("id"))
        let lastState = pyPrefix(CourierBoard.squash(text(t.get("detail"), t.get("text"))), last)
        let line: String
        switch kind {
        case "finished": line = "\(title): finished"
        case "needs_you": line = "\(title): needs you" + (t.get("needs")?.isTruthy ?? false ? " (\(t["needs"]!.pyStr))" : "")
        default: line = "«\(title)» lost its process" + (!lastState.isEmpty ? "; last: \(lastState)" : "") + ". Reply to continue it in a new thread."
        }
        return ["key": .string("\((t["id"] ?? .null).pyStr)|\(kind)|\((t["turn"] ?? .null).pyStr)"), "kind": .string(kind), "thread": t["id"] ?? .null,
                "project": t["project"] ?? .null, "text": .string(line), "detail": .string(pyPrefix(text(t.get("detail"), t.get("text")), 200)),
                "as_of": t.get("as_of") ?? .null]
    }

    static func change(_ old: JSON?, _ new: JSON) -> String? {
        let state = new["state"]?.asString
        let later = old == nil || (new["turn"]?.numeric ?? 0) > (old?["turn"]?.numeric ?? 0)
        let oldState = old?["state"]?.asString
        if state == "stranded" { return (old?.isTruthy ?? false) && strands.contains(oldState ?? "") ? state : nil }
        if state == "needs_you" && (old == nil || oldState != state || later) { return state }
        if let state, CourierBoard.finished.contains(state), old?.isTruthy ?? false, oldState == "working" || later { return "finished" }
        return nil
    }

    /// Facts that still hold, so a told one can be updated quietly when its detail changes.
    static func standing(_ after: JSON) -> [JSON] {
        let kinds = ["needs_you": "needs_you", "stranded": "stranded", "idle": "finished", "resolved": "finished"]
        return (after["threads"]?.asObject?.values ?? []).compactMap { t in t["state"]?.asString.flatMap { kinds[$0] }.map { fact(t, $0) } }
    }

    /// The Claude app closed with threads in it: one line for them all, instead of one per thread.
    static func appFact(_ before: JSON, _ after: JSON) -> JSON? {
        let waiting = (after["threads"]?.asObject?.values ?? []).filter { $0["state"] == "waiting_app" }
        guard before.get("app") != .bool(false), after.get("app") == .bool(false), !waiting.isEmpty else { return nil }
        let n = waiting.count
        return ["key": .string("app|closed|\((after["app_since"] ?? .null).pyStr)"), "kind": "app_closed", "thread": .null, "project": .null,
                "text": .string("Claude app closed; \(n) thread\(n != 1 ? "s" : "") waiting"), "detail": "", "as_of": .null]
    }

    static func facts(_ before: JSON, _ after: JSON) -> [JSON] {
        var out: [JSON] = []
        for (tid, t) in after["threads"]?.asObject ?? JSONObject() {
            if let kind = change(before["threads"]?.get(tid), t) { out.append(fact(t, kind)) }
        }
        if let f = appFact(before, after) { out.append(f) }
        return out.stableSorted(by: { Array(($0["key"]?.asString ?? "").unicodeScalars.map(\.value)) }, orderedBy: { $0.lexicographicallyPrecedes($1) })
    }

    /// Whether a fact found earlier is still so at the tell: a stranded thread or a closed app may be back by then. The rest stay news.
    static func holds(_ f: JSON, _ board: JSON) -> Bool {
        if f["kind"] == "stranded" { return board["threads"]?.get(f["thread"]?.asString ?? "\u{0}")?.get("state") == "stranded" }
        if f["kind"] == "app_closed" { return board.get("app") == .bool(false) }
        return true
    }

    static func claimKey(_ c: JSON) -> String {
        "\((c["project"] ?? .null).pyStr)|claim|\((c["key"] ?? .null).pyStr)"
    }

    /// A fact seen on an earlier visit to its project says how old it is; a live one is said as it is.
    static func aged(_ f: JSON, _ now: Double) -> JSON {
        guard f.get("as_of") != nil else { return f }
        var out = f
        out["text"] = .string((f["text"]?.pyStr ?? "") + asOf(f, now))
        return out
    }

    /// told: key -> row. Returns what to say and what to record quietly (a later version of a fact, or a repeat).
    static func plan(_ found: [JSON], _ told: JSONObject, _ claims: [JSON], _ now: Double, window: Double = Self.window) -> (say: [JSON], quiet: [JSON]) {
        let found = found.map { aged($0, now) }
        let within: (JSON) -> Bool = { now - ($0["at"]?.numeric ?? 0) <= window }
        let saidClaims = Set(told.values.filter { $0["kind"] == "claim" && within($0) }.map { $0["project"] ?? .null })  // quiets only a finish
        var say: [JSON] = [], quiet: [JSON] = []
        for f in found {
            if let old = told.get(f["key"]?.asString ?? ""), old.isTruthy {
                if (old["detail"] ?? .null) != (f["detail"] ?? .null) { quiet.append(f) }
            } else if f["kind"] == "finished" && saidClaims.contains(f["project"] ?? .null) {
                quiet.append(f)
            } else {
                say.append(f)
            }
        }
        let live = Set(found.filter { $0["kind"] == "finished" }.map { $0["project"] ?? .null })
            .union(told.values.filter { $0["kind"] == "finished" && within($0) }.map { $0["project"] ?? .null })
        for c in claims {
            let key = claimKey(c)
            if told.has(key) { continue }
            let item: JSON = ["key": .string(key), "kind": "claim", "thread": c.get("thread") ?? .null, "project": c["project"] ?? .null, "text": c["text"] ?? .null, "detail": ""]
            if (c.get("baseline")?.isTruthy ?? false) && !(c.get("decision")?.isTruthy ?? false) {
                quiet.append(item)
            } else if (c.get("decision")?.isTruthy ?? false) || !live.contains(c["project"] ?? .null) {
                say.append(item)
            } else {
                var q = item
                q["kind"] = "claim_quiet"
                quiet.append(q)
            }
        }
        return (say, quiet)
    }

    // MARK: Test bridge

    /// The functions the Python tests call, by Python name. `told` is the object of rows `store.told` gives. `tell.plan` returns `[say, quiet]`.
    static let testOps: [String: ([JSON]) throws -> JSON] = [
        "tell.fact": { a in fact(a[0], a[1].asString ?? "") },
        "tell.change": { a in JSON(change(a[0].isNull ? nil : a[0], a[1])) },
        "tell.standing": { a in .array(standing(a[0])) },
        "tell.app_fact": { a in appFact(a[0], a[1]) ?? .null },
        "tell.facts": { a in .array(facts(a[0], a[1])) },
        "tell.holds": { a in .bool(holds(a[0], a[1])) },
        "tell.claim_key": { a in .string(claimKey(a[0])) },
        "tell.aged": { a in aged(a[0], a[1].asDouble ?? 0) },
        "tell.plan": { a in
            let r = plan(a[0].asArray ?? [], a[1].asObject ?? JSONObject(), a[2].asArray ?? [], a[3].asDouble ?? 0, window: a.count > 4 ? (a[4].asDouble ?? window) : window)
            return [.array(r.say), .array(r.quiet)]
        },
    ]
}
