import Foundation

// The event and command shapes of poc/router/EVENTS.md, as JSON-backed wrappers: the core reads Python dicts everywhere, and these keep
// the Python field names so the port stays line for line. Each wraps a JSON value and adds typed accessors, nothing else.

/// An event from the page (`rows`, `threads`, `projects`, `composer`, `page`, `done`, `settings`, `wake_me`, `commands`, `notice`).
struct CourierEvent {
    var json: JSON
    init(_ json: JSON) { self.json = json }
    var type: String? { json.get("type")?.asString }
    var path: String? { json.get("path")?.asString }
    var thread: String? { json.get("thread")?.asString }
    var id: String? { json.get("id")?.asString }
    subscript(key: String) -> JSON? { json[key] }
    func get(_ key: String) -> JSON? { json.get(key) }
}

/// A command routerd sends the page: `{"id": …, "kind": …, …fields}` (`wake` has no id).
struct CourierCommand {
    var json: JSON
    init(_ json: JSON) { self.json = json }
    /// `{"id": id, "kind": kind, **fields}`.
    init(id: String?, kind: String, fields: [(String, JSON)] = []) {
        var o = JSONObject()
        if let id { o["id"] = .string(id) }
        o["kind"] = .string(kind)
        for (k, v) in fields { o[k] = v }
        json = .object(o)
    }
    var id: String? { json.get("id")?.asString }
    var kind: String? { json.get("kind")?.asString }
    subscript(key: String) -> JSON? { json[key] }
}

/// A send's proof (`intent["proof"]`): the place and words, the baseline and the anchors it is placed by.
struct CourierProof {
    var json: JSON
    init(_ json: JSON) { self.json = json }
    var project: String? { json.get("project")?.asString }
    var thread: String? { json.get("thread")?.asString }
    var words: String? { json.get("words")?.asString }
    var baseline: [String]? { json.get("baseline")?.asArray?.compactMap(\.asString) }
    var anchors: [String] { (json.get("anchors")?.asArray ?? []).compactMap(\.asString) }
}

/// A row of the `intents` table as `store.intent` reads it, JSON columns parsed.
struct CourierIntent {
    var json: JSON
    init(_ json: JSON) { self.json = json }
    var id: Int { json["id"]?.asInt ?? 0 }
    var tool: String { json["tool"]?.asString ?? "" }
    var status: String { json["status"]?.asString ?? "" }
    var project: String? { json.get("project")?.asString }
    var thread: String? { json.get("thread")?.asString }
    var words: String? { json.get("words")?.asString }
    var cause: String? { json.get("cause")?.asString }
    var attempts: Int { json["attempts"]?.asInt ?? 0 }
    var args: JSON? { json.get("args") }
    var proof: JSON? { json.get("proof") }
    var result: JSON? { json.get("result") }
    subscript(key: String) -> JSON? { json[key] }
}

/// A run: the per-intent state of the core (`runs[id]`). A reference type, as the Python dict is, so every holder sees its changes.
final class Run {
    var fields: JSONObject
    init(_ fields: JSONObject = JSONObject()) { self.fields = fields }
    var id: Int { fields["id"]?.asInt ?? 0 }
    subscript(key: String) -> JSON? {
        get { fields[key] }
        set { fields[key] = newValue }
    }
    /// `run.get(key)`: nil for a missing key and for null alike.
    func get(_ key: String) -> JSON? { fields.get(key) }
    var json: JSON { .object(fields) }
}
