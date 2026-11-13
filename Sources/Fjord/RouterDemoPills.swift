import Foundation

// The composer's item and answer pills on the demo's data (`RouterAnswerPills`; shots `v2-pill-*`): the items of
// `RouterDemo.items`, and Snapshot API with a Decide on its trial build and a Do on a launchd agent, so the @ list finds
// an item by a word of its sentence ("launchd") and an answer pill reads `[? trial build → Owed live tests]`.

extension RouterDemo {
    enum Pill {
        static let trial = "trial-build", launchd = "launchd-agent"
        /// What the shots type in Other and as free words.
        static let other = "the live tests on the M1 only, then beta"
        static let words = "and rebase both on main first"
    }

    static func pills(_ model: RouterModel) {
        items(model)
        let now = model.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60 - 20) }
        // Bar count's Decide in its few words.
        model.update(ID.bar) { t in
            if let i = t.ledger.items.firstIndex(where: { $0.id == Item.push }) { t.ledger.items[i].short = "push or PR" }
        }
        guard var t = model.thread(ID.snapshot) else { return }
        t.ledger = RouterLedger(items: [
            RouterItem(id: Pill.trial, kind: .decide, sentence: "the trial build passes: run the owed live tests on it first, or ship it to beta now?",
                       short: "trial build", since: ago(5), options: ["Owed live tests", "Ship it to beta now"]),
            RouterItem(id: Pill.launchd, kind: .do, sentence: "launchd still starts the old snapshot agent at login: unload its plist",
                       short: "launchd agent", since: ago(8)),
        ])
        model.apply(.upsert(t))
    }
}
