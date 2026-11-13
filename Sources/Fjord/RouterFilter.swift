import Foundation

// The state filter works on items, not on threads (docs/design/router-v2/DESIGN.md 1.2, 4): a thread shows under a state
// token with only the items that belong to that state. Needs you keeps its Stuck, Decide and Do items (Know and the
// rest hidden); Done keeps Done threads and every Know item; Working keeps the running threads as plain working lines.
// The header stays while any of its items match. A pure function of the record and the token, so the page, the
// counts and the tests all read the same rule.

enum RouterFilter {
    /// `t` as it shows under `state`: its items cut down to that state's, or nil when nothing of it belongs there. With
    /// no state it is `t` whole.
    static func lens(_ t: RouterThread, state: RouterSection?) -> RouterThread? {
        guard let state else { return t }
        var out = t
        switch state {
        case .needsYou:
            let kept = t.ledger.items.filter { $0.kind.section == .needsYou }
            // Its asks and stops with nothing listed are the thread's own line.
            guard !kept.isEmpty || t.state == .stopped || (t.ledger.items.isEmpty && t.section == .needsYou) else { return nil }
            out.ledger.items = kept
        case .done:
            let kept = t.ledger.items.filter { $0.kind.section == .done }
            guard !kept.isEmpty || t.state == .done else { return nil }
            out.ledger.items = kept
        case .working:
            guard t.isRunning else { return nil }
            out.ledger.items = []
        }
        return out
    }

    /// Whether `t` belongs under `state` at all.
    static func matches(_ t: RouterThread, state: RouterSection?) -> Bool { lens(t, state: state) != nil }
}
