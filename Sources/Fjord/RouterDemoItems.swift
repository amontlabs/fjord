import Foundation

// The demo's open items (docs/design/router-v2/OPEN-ITEMS.md; shots `v2-items*`, beat 45): Checkpoint boot, still
// running, is stuck on a boot that times out, asks whether to keep the old checkpoint, and has something to know; Bar
// count, finished, asks one thing (its line is that item). The other threads are as at t = 0.

extension RouterDemo {
    enum Item {
        static let stuck = "boot-timeout", keep = "keep-checkpoint", smaller = "image-smaller", quota = "vm-quota"
        static let push = "push-or-pr"
        static let update = "lastdrop-update"
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
            rehistory(&t)
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

    /// The items' look with what a line leaves out (shots `v2-item-*`): the owner's real case as a Do on a thread of its own
    /// (its sentence wraps, its detail links the release on its version, so the card has no button for it; its history
    /// is the fix's run and the release's), Checkpoint boot's Decide in a sentence
    /// long enough to wrap in its block, its Know with the words it came from.
    static func itemsLook(_ model: RouterModel) {
        items(model)
        let now = model.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60 - 20) }
        typealias S = RouterWork.Summary
        let line = "fix committed and pushed; lastdrop 0.8.13 released; installed app still 0.8.12"
        let update = "Install the lastdrop 0.8.13 update from its panel; you still run 0.8.12"
        var gap = RouterThread(id: ID.transcriptGap, name: "Subagent transcript gap", title: "Subagent transcript gap",
                               project: "lastdrop", state: .done, sentence: .init(text: line), since: ago(13))
        gap.lastLines = lastdropRelease
        gap.summary = RouterSummary(
            sentence: line,
            detail: "The fix is on main (d24947a) and shipped as [0.8.13](\(lastdropReleasePage)), signed and notarized; the installed app still runs 0.8.12, so it isn't live until you update.",
            facts: [.init(kind: .tests, text: "tested: both subagent transcripts kept", tone: .good)],
            source: lastdropRelease)
        gap.work = RouterWork(
            summaries: [S(id: 6, text: "Publishing the 0.8.13 release on GitHub with the notarized app", at: ago(14), run: "l2"),
                        S(id: 5, text: "Building, signing and notarizing the 0.8.13 universal app", at: ago(19), run: "l2"),
                        S(id: 4, text: "Committing the transcript fix and pushing it to main", at: ago(24), run: "l2"),
                        S(id: 3, text: "Checking a run with two subagents keeps both transcripts whole", at: ago(33), run: "l1"),
                        S(id: 2, text: "Keeping each subagent's turns in its own transcript as they arrive", at: ago(41), run: "l1"),
                        S(id: 1, text: "Tracing where the second subagent's transcript loses its turns", at: ago(52), run: "l1")],
            run: "l2",
            starts: ["l2": .asked("Commit push and make a new release"),
                     "l1": .asked("subagent transcripts have a gap when two run at once, find out why and fix it")])
        gap.history = history(gap.work, extra: [
            RouterEvent(id: "raised:\(Item.update)", at: ago(13), run: "l2", kind: .raised(.do, update)),
            RouterEvent(id: "f-l2", at: ago(13.1), run: "l2", kind: .finished(line)),
            RouterEvent(id: "f-l1", at: ago(31), run: "l1",
                        kind: .finished("transcripts kept whole with two subagents; the fix not committed yet")),
        ])
        gap.ledger = RouterLedger(items: [
            RouterItem(id: Item.update, kind: .do, sentence: update, since: ago(13),
                       detail: "The subagent transcript fix ships in [0.8.13](\(lastdropReleasePage)): it isn't live until you accept the update in the app's panel.",
                       quote: lastdropInstall),
        ])
        var changes: [RouterChange] = [.upsert(gap)]
        if var t = model.thread(ID.checkpoint) {
            for i in t.ledger.items.indices {
                switch t.ledger.items[i].id {
                case Item.keep:
                    t.ledger.items[i].sentence = "keep the 0.3 checkpoint as a fallback until the new base has booted cleanly on all three VMs, or delete it now to free 14 GB?"
                    t.ledger.items[i].quote = "The 0.3 checkpoint is still on disk (14 GB). I can keep it as a fallback until the new base boots cleanly on all three VMs, or delete it now. Which do you want?"
                case Item.smaller:
                    t.ledger.items[i].quote = "Side note: the new base image is 1.2 GB smaller than 0.3 (3.1 GB against 4.3 GB), mostly from dropping the old toolchains."
                default: break
                }
            }
            changes.append(.upsert(t))
        }
        model.apply(.batch(changes))
    }

    /// The 0.8.13 release's page, as the agent's message gives it.
    static let lastdropReleasePage = "https://github.com/amontlabs/lastdrop/releases/tag/v0.8.13"

    /// The agent's last message on the transcript gap thread (the owner's real case, 2026-11-13).
    static let lastdropRelease = """
        The fix is committed, pushed to `main` (d24947a), and released as lastdrop 0.8.13: https://github.com/amontlabs/lastdrop/releases/tag/v0.8.13
        - Build: the release is the signed universal app (Apple silicon and Intel), notarized and stapled.
        - Check: a run with two subagents now keeps both transcripts whole, with no gap between their turns.
        - Install: the app's update panel offers 0.8.13; accept it there. The installed app is still 0.8.12, so the fix isn't live until you do.
        """

    /// The lines of that message the Do comes from, a blank line between its paragraphs as the owner's real quote had:
    /// the peek's cut falls on that blank line and ends with the words above it.
    static let lastdropInstall = """
        The fix is committed, pushed to `main` (d24947a), and released as lastdrop 0.8.13: https://github.com/amontlabs/lastdrop/releases/tag/v0.8.13

        - Install: the app's update panel offers 0.8.13; accept it there. The installed app is still 0.8.12, so the fix isn't live until you do.
        """

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
