import Foundation

// The demo's working threads as the Router's summaries tell them (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6
// "Working"; shots `v2-working-summary`, `v2-working-hover`, `v2-working-card`): a few short lines the model wrote
// about each run, newest first, and the raw detail under them (the command running now, the last few steps).

extension RouterDemo {
    /// Tab handover: subagents and a dev server beside it (`activity(at:)`); Snapshot API: a long test run; Checkpoint
    /// boot: a to-do list and two waits; Upstream issue: its first summary. Times count back from `now`.
    static func work(at now: Date) -> [(String, RouterWork)] {
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        typealias S = RouterWork.Summary
        typealias Step = RouterWork.Step

        let tab = RouterWork(
            summaries: [S(id: 3, text: "Putting the caret back where it was; two reviews running", at: ago(1)),
                        S(id: 2, text: "The draft now survives the handover; the caret is next", at: ago(5)),
                        S(id: 1, text: "Found the gap: the composer remounts before the draft is copied", at: ago(9)),
                        S(id: 0, text: "Reading how the tab hands its composer over", at: ago(12))],
            now: Step(id: 9, text: "swift test --filter TabHandoverTests", mono: true, at: ago(0.4)),
            recent: [Step(id: 8, text: "Edited ComposerCaret.swift", at: ago(1)),
                     Step(id: 7, text: "rg -n \"caretRange\" Sources/Fjord", mono: true, at: ago(2)),
                     Step(id: 6, text: "Read TabHandover.swift", at: ago(3))])

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
            if let a = activity[id] { t.activity = a }
            if id == ID.checkpoint {
                t.steps = steps(["Build the boot image", "Boot the VM from the checkpoint", "Check the boot log"], running: 1)
            }
            changes.append(.upsert(t))
        }
        model.apply(.batch(changes))
    }

    /// The Router's model is writing the thread's next summary: the line sheens on the newest, which the card still leaves
    /// to it (as the records do until the new words stream in).
    static func writingSummary(_ model: RouterModel, _ id: String) {
        guard var t = model.thread(id) else { return }
        t.sentence.phase = .reassessing
        model.apply(.upsert(t))
    }
}
