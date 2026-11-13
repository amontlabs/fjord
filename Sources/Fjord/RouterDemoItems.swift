import Foundation

// The demo's open items (docs/design/router-v2/OPEN-ITEMS.md; shots `v2-items*`, beat 45): Checkpoint boot, still
// running, is stuck on a boot that times out, asks whether to keep the old checkpoint, and has something to know; Bar
// count, finished, asks one thing (its line is that item). The other threads are as at t = 0.

extension RouterDemo {
    enum Item {
        static let stuck = "boot-timeout", keep = "keep-checkpoint", smaller = "image-smaller", quota = "vm-quota"
        static let push = "push-or-pr"
        /// Your words to Checkpoint boot in the shots and the beat.
        static let reply = "keep 0.3 for now; boot it with 4 GB of RAM"
    }

    /// Checkpoint boot with Stuck, Decide and Know while it runs; Bar count with one Decide. The working threads read their
    /// summaries.
    static func items(_ model: RouterModel) {
        workingSummaries(model)
        let now = model.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60 - 20) }
        var changes: [RouterChange] = []
        if var t = model.thread(ID.checkpoint) {
            t.work.summaries.insert(.init(id: 9, text: "Booting the VM again with a longer timeout", at: ago(0.5)), at: 0)
            t.sentence = .init(text: "Booting the VM again with a longer timeout")
            t.ledger = RouterLedger(items: [
                RouterItem(id: Item.stuck, kind: .stuck, sentence: "the VM boot times out at the same step, third try", since: ago(4)),
                RouterItem(id: Item.keep, kind: .decide, sentence: "keep the 0.3 checkpoint as a fallback, or delete it?",
                           since: ago(9), options: ["Keep it as a fallback", "Delete it"]),
                RouterItem(id: Item.smaller, kind: .know, sentence: "the boot image is 1.2 GB smaller on the new base", since: ago(6)),
            ])
            changes.append(.upsert(t))
        }
        if var t = model.thread(ID.bar) {
            t.ledger = RouterLedger(items: [
                RouterItem(id: Item.push, kind: .decide, sentence: "push to main, or open a PR first?", since: ago(3),
                           options: ["Open a PR first", "Push to main"]),
            ])
            changes.append(.upsert(t))
        }
        model.apply(.batch(changes))
    }

    /// Right after your words to Checkpoint boot: they show in its block, its items sheen, its header has Fjord's mark.
    static func itemsSent(_ model: RouterModel) {
        model.update(ID.checkpoint) { $0.ledger.sent(Item.reply) }
    }

    /// The read of your words: the choice is answered, the stuck boot restated (its age resets), a step for you is new.
    static let replyRead = RouterLedgerRead(
        close: [Item.keep: Router.Items.Copy.answered],
        merge: [Item.stuck],
        add: [RouterItem(id: Item.quota, kind: .do, sentence: "raise the VM memory quota to 4 GB in the silo console", since: .now)])

    /// The read of the next turn: the agent got past the timeout.
    static let turnRead = RouterLedgerRead(close: [Item.stuck: Router.Items.Copy.doneByAgent])
}

extension RouterModel {
    /// A read of a thread's open items landed: closed items strike with how, new ones land lit; after the strike they fold
    /// away and the new ones are at rest (at once in a still).
    func itemsRead(_ id: String, _ read: RouterLedgerRead, settle: Bool = true) {
        let now = self.now
        var r = read
        for i in r.add.indices { r.add[i].since = now }
        animate(.spatial) { update(id) { $0.ledger.land(r, at: now) } }
        guard settle else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Router.Items.strike))
            guard let self else { return }
            self.animate(.spatial) { self.update(id) { $0.ledger.settle() } }
        }
    }

    /// A turn of the thread ended: its open items are read again.
    func itemsTurnEnded(_ id: String) {
        animate(.fade) { update(id) { $0.ledger.turnEnded() } }
    }
}
