import AppKit
import Foundation

// MARK: - Paths

/// Where the Router keeps its files (Fjord's own folder; it writes nothing into `~/.claude`). Tests give their own (see `live`).
struct RouterPaths: Equatable, Sendable {
    /// `~/Library/Application Support/Fjord`.
    var support: URL

    /// The Router process's working folder.
    var routerHome: URL { support.appendingPathComponent("router", isDirectory: true) }

    /// The user's own folder; nil in a test run, which is stopped for reaching it (see `UnderTest`).
    static func live() -> RouterPaths? {
        guard !UnderTest.refuses("the Router's files (Application Support/Fjord)") else { return nil }
        return unguarded
    }

    static var unguarded: RouterPaths {
        RouterPaths(support: AppIdentity.supportDirectory())
    }
}

// MARK: - Persisted state

/// What the Router keeps across launches: its switch and the log of what it did and changed. What you act on is T3's
/// threads (RouterRecords.swift), never kept here. A file of an older version, cards and all, is read for these keys only: the rest is dropped at the next save.
struct RouterSaved: Codable, Equatable {
    /// Off by default; only offered while the Claude sessions extension is on.
    var enabled = false
    var enabledAt: Date?
    /// What the Router changed in Fjord itself, and your acts on the page, oldest first (see FjordChange.swift).
    var changes: [FjordChange] = []
    /// The decision log, oldest first (see RouterDecisions.swift).
    var decisions: [RouterDecision] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, enabledAt, changes, decisions
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(enabledAt, forKey: .enabledAt)
        try c.encode(changes, forKey: .changes)
        try c.encode(decisions, forKey: .decisions)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each part, and each element of a list, on its own: one this version can't read is left out, not the rest, and is
        // named in `dropped` (the file is then kept aside before it is written over: see `PersistedState`).
        var lost: [String] = []
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                lost.append(key.stringValue)
                return nil
            }
        }
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            guard let all: [Lossy<T>] = value(key) else { return [] }
            let read = all.compactMap(\.value)
            if read.count < all.count { lost.append("\(all.count - read.count) of \(key.stringValue)") }
            return read
        }
        enabled = value(.enabled) ?? false
        enabledAt = value(.enabledAt)
        changes = list(.changes)
        decisions = list(.decisions)
        linkUnlinkedChanges()
        dropped = lost
    }

    static let maxChanges = 500

    /// The oldest changes past `maxChanges` go; one waiting for your Apply stays.
    mutating func pruneChanges() {
        var over = changes.count - Self.maxChanges
        guard over > 0 else { return }
        changes.removeAll { change in
            guard over > 0, change.pending == nil else { return false }
            over -= 1
            return true
        }
    }

    /// What the file had that this version couldn't read ("2 of decisions"): never saved, and handed on to
    /// `PersistedState.dropped` (empty once loaded).
    var dropped: [String] = []
}

/// An element of a saved array read on its own: nil when it can't be, so one bad element doesn't take the rest with it.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Where a session came from when an inbox action started it: the category, the thing, the action and its run.
struct SessionOrigin: Codable, Equatable, Hashable {
    var category: String
    /// The thing's reference and title, in a line.
    var thing: String
    var actionID: String
    var runID: String
    /// The runtime mode the action asked for its thread (`T3RuntimeMode`); nil: T3's own default.
    var runtimeMode: String?

    /// "⚡ from <category> · <thing>": on the session's rows.
    var label: String { "⚡ from \(category) · \(thing)" }
}

extension Store {
    // MARK: Switching it

    func setRouterEnabled(_ on: Bool, now: Date = Date()) {
        guard on != router.enabled else { return }
        routerGeneration &+= 1
        var state = router
        state.enabled = on
        if on { state.enabledAt = state.enabledAt ?? now }
        router = state
        // Off: your messages' runs stop.
        if !on { routerDispatcher.stopAll(reason: RouterDispatcher.unlinkedWords, actions: true); routerDispatcher.unlinked() }
    }

    /// Where the Router's files are, when they may be touched at all: never in a demo, and in a test only where the test said.
    var routerFiles: RouterPaths? {
        if let routerPaths { return routerPaths }
        guard persists, !Store.isDemo else { return nil }
        return RouterPaths.live()
    }
}
