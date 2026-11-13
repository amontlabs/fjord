import Foundation

// The demo's working threads as the Router's summaries tell them (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6
// "Working"; shots `v2-working-summary`, `v2-working-hover`, `v2-working-card`, `v2-working-card-runs`,
// `v2-working-card-scroll`): a few short lines the model wrote
// about each run, newest first, and the raw detail under them (the command running now, the last few steps).

extension RouterDemo {
    /// Tab handover: subagents and a dev server beside it (`activity(at:)`); Snapshot API: a long test run; Checkpoint
    /// boot: a to-do list and two waits; Upstream issue: its first summary. Times count back from `now`.
    static func work(at now: Date) -> [(String, RouterWork)] {
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        typealias S = RouterWork.Summary
        typealias Step = RouterWork.Step

        // Two runs: the one working now, from your words about the caret, and the one before it, from your first ask.
        let tab = RouterWork(
            summaries: [S(id: 6, text: "Putting the caret back where it was; two reviews running", at: ago(1), run: "r2"),
                        S(id: 5, text: "The caret jumps because the field is rebuilt, not moved", at: ago(4), run: "r2"),
                        S(id: 4, text: "Reproduced the caret jump with a long draft", at: ago(7), run: "r2"),
                        S(id: 3, text: "Handover tests pass; draft and scroll survive the move", at: ago(16), run: "r1"),
                        S(id: 2, text: "The draft now survives the handover; the caret is next", at: ago(19), run: "r1"),
                        S(id: 1, text: "Found the gap: the composer remounts before the draft is copied", at: ago(23), run: "r1"),
                        S(id: 0, text: "Reading how the tab hands its composer over", at: ago(26), run: "r1")],
            now: Step(id: 9, text: "swift test --filter TabHandoverTests", mono: true, at: ago(0.4)),
            recent: [Step(id: 8, text: "Edited ComposerCaret.swift", at: ago(1)),
                     Step(id: 7, text: "rg -n \"caretRange\" Sources/Fjord", mono: true, at: ago(2)),
                     Step(id: 6, text: "Read TabHandover.swift", at: ago(3))],
            run: "r2",
            starts: ["r2": .asked("the caret still jumps to the end after the handover, can you keep it where it was?"),
                     "r1": .asked("moving a tab to another window loses the draft in its composer, fix it")])

        let snapshot = RouterWork(
            summaries: [S(id: 2, text: "Restore by id passes; running the whole snapshot suite", at: ago(2)),
                        S(id: 1, text: "Wrote restore(id:) and three tests for it", at: ago(14)),
                        S(id: 0, text: "Mapped how snapshots are keyed on disk", at: ago(27))],
            now: Step(id: 5, text: "swift test --filter Snapshot", mono: true, at: ago(2)),
            recent: [Step(id: 4, text: "Edited SnapshotStore.swift", at: ago(4)),
                     Step(id: 3, text: "swift test --filter SnapshotRestore", mono: true, at: ago(6)),
                     Step(id: 2, text: "Edited SnapshotRestoreTests.swift", at: ago(9))])

        let checkpoint = RouterWork(
            summaries: [S(id: 1, text: "Image built; waiting on CI before it boots the VM", at: ago(1)),
                        S(id: 0, text: "Building the boot image from the 0.4 checkpoint", at: ago(6))],
            now: Step(id: 4, text: "gh run watch 4312 --exit-status", mono: true, at: ago(3)),
            recent: [Step(id: 3, text: "make boot-image CHECKPOINT=0.4", mono: true, at: ago(5)),
                     Step(id: 2, text: "Read scripts/boot-image.sh", at: ago(6))])

        let upstream = RouterWork(
            summaries: [S(id: 0, text: "Reproducing #2031 on the 0.4 branch before answering", at: ago(1))],
            now: Step(id: 1, text: "git switch release/0.4", mono: true, at: ago(0.2)))

        return [(ID.tab, tab), (ID.snapshot, snapshot), (ID.checkpoint, checkpoint), (ID.upstream, upstream)]
    }

    /// The working threads with their summaries and activity, as the real build will show them: each line reads its
    /// newest summary; Checkpoint boot is on its second to-do step.
    static func workingSummaries(_ model: RouterModel) {
        let now = model.now
        let activity = Dictionary(uniqueKeysWithValues: Self.activity(at: now))
        var changes: [RouterChange] = []
        for (id, work) in work(at: now) {
            guard var t = model.thread(id), t.state == .working else { continue }
            t.work = work
            if let summary = work.summaries.first {
                t.sentence = .init(text: summary.text)
                t.work.lineReadsNewest = true
            }
            rehistory(&t)
            if let a = activity[id] { t.activity = a }
            if id == ID.checkpoint {
                t.steps = steps(["Build the boot image", "Boot the VM from the checkpoint", "Check the boot log"], running: 1)
            }
            changes.append(.upsert(t))
        }
        model.apply(.batch(changes))
    }

    /// Tab handover over five runs, read as a conversation (shot `v2-working-card-runs`), each run's start as T3 marks it:
    /// your ask about the caret, which it is working on now; before it the run T3 woke when its review subagent finished,
    /// the one it woke when the background test run ended, the one it resumed after the usage limit, and your first ask.
    static func workingRuns(_ model: RouterModel) {
        workingSummaries(model)
        guard var t = model.thread(ID.tab) else { return }
        let now = model.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        typealias S = RouterWork.Summary
        t.work.summaries = [
            S(id: 7, text: "Putting the caret back where it was; two reviews running", at: ago(1), run: "r5"),
            S(id: 6, text: "The caret jumps because the field is rebuilt, not moved", at: ago(4), run: "r5"),
            S(id: 5, text: "The review found one stale draft on close; fixed it", at: ago(9), run: "r4"),
            S(id: 4, text: "Two handover tests failed on a slow window; fixed the wait", at: ago(13), run: "r3"),
            S(id: 3, text: "Picking up where it stopped: copying the draft before the remount", at: ago(31), run: "r2"),
            S(id: 2, text: "The draft now survives the handover; tests running in the background", at: ago(38), run: "r1"),
            S(id: 1, text: "Found the gap: the composer remounts before the draft is copied", at: ago(42), run: "r1"),
        ]
        t.work.run = "r5"
        t.work.starts = ["r5": .asked("the caret still jumps to the end after the handover, can you keep it where it was?"),
                         "r4": .subagents(["Review the handover diff"]),
                         "r3": .command("swift test --filter TabHandoverTests"),
                         "r2": .usageLimit,
                         "r1": .asked("moving a tab to another window loses the draft in its composer, fix it")]
        t.sentence = .init(text: t.work.summaries[0].text)
        rehistory(&t)
        model.apply(.upsert(t))
    }

    /// Tab handover's whole kept history: twenty summaries over seven runs, for the card's scrolling timeline.
    static func longHistory(at now: Date) -> RouterWork {
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        typealias S = RouterWork.Summary
        let texts: [(String, String)] = [
            ("r7", "Putting the caret back where it was; two reviews running"),
            ("r7", "The caret jumps because the field is rebuilt, not moved"),
            ("r7", "Reproduced the caret jump with a long draft"),
            ("r6", "Both reviews agree; folded their notes into the handover"),
            ("r6", "Reading the second review's notes on the scroll restore"),
            ("r5", "The slow-window wait is gone; handover tests pass"),
            ("r5", "Two handover tests failed on a slow window; fixing the wait"),
            ("r4", "Picking up where it stopped: the scroll offset on the move"),
            ("r3", "Scroll position now survives the handover too"),
            ("r3", "Reading how the list keeps its scroll offset"),
            ("r3", "Restoring the scroll offset after the composer moves"),
            ("r2", "The draft survives the handover; tests running in the background"),
            ("r2", "Copying the draft before the composer remounts"),
            ("r2", "Found the gap: the composer remounts before the draft is copied"),
            ("r1", "Handover tests written; three fail as expected"),
            ("r1", "Writing tests that move a tab with a draft in it"),
            ("r1", "Mapped where the composer's draft is kept"),
            ("r1", "Reading how the tab hands its composer over"),
            ("r1", "Looking for the tab handover in the window code"),
            ("r1", "Reading the bug report and the window's tab code"),
        ]
        let summaries = texts.enumerated().map { i, e in
            S(id: texts.count - i, text: e.1, at: ago(Double(i) * 4 + 1), run: e.0)
        }
        return RouterWork(
            summaries: summaries, run: "r7",
            starts: ["r7": .asked("the caret still jumps to the end after the handover, can you keep it where it was?"),
                     "r6": .subagents(["Review the handover diff", "Check scroll restore"]),
                     "r5": .command("swift test --filter TabHandoverTests"),
                     "r4": .usageLimit,
                     "r3": .asked("also keep the list's scroll position when the tab moves"),
                     "r2": .woken,
                     "r1": .asked("moving a tab to another window loses the draft in its composer, fix it")])
    }

    /// Tab handover's card read back (shot `v2-working-card-scroll`): its timeline scrolled down its twenty summaries, two
    /// new ones held behind the `↑ 2 new` pill at its top edge.
    static func workingScrolled(_ model: RouterModel, newer: Int = 2) {
        workingSummaries(model)
        guard var t = model.thread(ID.tab) else { return }
        let keep = t.work
        t.work = longHistory(at: model.now)
        t.work.now = keep.now
        t.work.recent = keep.recent
        t.work.lineReadsNewest = true
        t.work.pose = .init(scrolledTo: 15, newer: newer)
        t.sentence = .init(text: t.work.summaries[0].text)
        rehistory(&t)
        model.apply(.upsert(t))
    }

    /// A new summary on Tab handover, as the records land one: the line reads it, the one it read joins the card's list.
    static func newSummary(_ model: RouterModel, _ text: String) {
        guard var t = model.thread(ID.tab) else { return }
        let id = (t.work.summaries.map(\.id).max() ?? 0) + 1
        t.work.summaries.insert(.init(id: id, text: text, at: model.now, run: t.work.run), at: 0)
        t.work.summaries = Array(t.work.summaries.prefix(20))
        t.work.lineReadsNewest = true
        t.sentence = .init(text: text)
        rehistory(&t)
        model.apply(.upsert(t))
    }

    /// The pill pressed (the demo's hand on it).
    static func timelineToTop(_ model: RouterModel) {
        guard var t = model.thread(ID.tab) else { return }
        t.work.pose = .init(scrolledTo: t.work.pose?.scrolledTo, toTop: (t.work.pose?.toTop ?? 0) + 1)
        model.apply(.upsert(t))
    }

    /// The Router's model is writing the thread's next summary: the line sheens on the newest, which the card still leaves
    /// to it (as the records do until the new words stream in).
    static func writingSummary(_ model: RouterModel, _ id: String) {
        guard var t = model.thread(id) else { return }
        t.sentence.phase = .reassessing
        model.apply(.upsert(t))
    }
}
