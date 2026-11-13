import Foundation

// The demo's layers (docs/design/router-v2/DESIGN.md R10; shots `v2-layer-*`): one structure for every thread and item,
// the hover the line plus more, the card the hover plus more. Install guide is Done (its outcome, why it is worth a
// look, its PR, diff and checks, the agent's last message, its history); Tab handover is Working (its summary, what runs
// beside it, its history as the source); Val Cenis booking is a thread with one item listed under its line (Needs you:
// the item, why, the agent's words, its options, the thread's history under them).

extension RouterDemo {
    /// The threads' histories as the records keep them, from their summaries and runs' starts (and any `extra` events: items
    /// raised and closed, turns ended), newest first; a run's start under its oldest event.
    static func history(_ work: RouterWork, extra: [RouterEvent] = []) -> [RouterEvent] {
        var events = work.summaries.map { RouterEvent(id: "s\($0.id)", at: $0.at, run: $0.run, kind: .summary($0.text)) } + extra
        for (run, start) in work.starts {
            guard let first = events.filter({ $0.run == run }).map(\.at).min() else { continue }
            events.append(RouterEvent(id: "r\(run)", at: first.addingTimeInterval(-1), run: run, kind: .started(start)))
        }
        return events.sorted { $0.at > $1.at }
    }

    /// Rebuilds a demo thread's history from its work, keeping the events that aren't summaries or starts.
    static func rehistory(_ t: inout RouterThread) {
        let extra = t.history.filter {
            switch $0.kind {
            case .summary, .started: false
            default: true
            }
        }
        t.history = history(t.work, extra: extra)
    }

    /// The three threads' summaries and histories, over the items' look (Tab handover over five runs).
    static func layers(_ model: RouterModel) {
        workingRuns(model)
        let now = model.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        typealias Fact = RouterSummary.Fact
        typealias S = RouterWork.Summary
        var changes: [RouterChange] = []

        if var t = model.thread(ID.guide) {
            t.prs = [.init(number: 41, state: .merged)]
            t.sentence = .init(text: "rewritten around the Chrome setup and merged", stateWord: false)
            t.summary = RouterSummary(
                sentence: t.sentence.text,
                detail: "The guide now starts from the Chrome extension and drops the old CLI path; the screenshots match the new setup.",
                facts: [Fact(kind: .pr, text: "PR #41 merged", tone: .good, link: URL(string: "https://github.com/amontlabs/docs-site/pull/41")),
                        Fact(kind: .diff, text: "4 files +96 −212"),
                        Fact(kind: .tests, text: "link check passes", tone: .good)],
                source: t.lastLines)
            t.work = RouterWork(
                summaries: [S(id: 4, text: "Screenshots retaken for the Chrome setup; opening the PR", at: ago(12), run: "g2"),
                            S(id: 3, text: "Dropping the CLI path; the guide starts from the extension", at: ago(18), run: "g2"),
                            S(id: 2, text: "Drafted the Chrome setup section from the extension's README", at: ago(41), run: "g1"),
                            S(id: 1, text: "Reading the install guide and the extension's setup flow", at: ago(47), run: "g1")],
                run: "g2",
                starts: ["g2": .asked("drop the CLI path entirely, nobody installs it that way now"),
                         "g1": .asked("rewrite the install guide around the Chrome extension")])
            t.history = history(t.work, extra: [
                RouterEvent(id: "f-g2", at: ago(10), run: "g2", kind: .finished("rewritten for the Chrome setup; PR #41 open")),
                RouterEvent(id: "c-cli", at: ago(19), run: "g2",
                            kind: .closed(.decide, "keep the CLI path as an appendix, or drop it?", how: Router.Items.Copy.answered)),
                RouterEvent(id: "f-g1", at: ago(38), run: "g1", kind: .finished("Chrome setup drafted; the CLI path still there")),
                RouterEvent(id: "x-cli", at: ago(38.5), run: "g1",
                            kind: .raised(.decide, "keep the CLI path as an appendix, or drop it?")),
            ])
            changes.append(.upsert(t))
        }

        if var t = model.thread(ID.tab) {
            t.summary = RouterSummary(
                sentence: t.sentence.text,
                detail: "Your caret fix: the field was rebuilt on the move, so it now moves the field instead; two reviews check it.",
                facts: [Fact(kind: .agents, text: "2 subagents · Opus 5.5"),
                        Fact(kind: .commands, text: "swift test --filter TabHandoverTests"),
                        Fact(kind: .waits, text: "waiting on CI")])
            rehistory(&t)
            t.history.insert(RouterEvent(id: "x-scroll", at: ago(10), run: "r4",
                                         kind: .raised(.know, "the scroll offset is kept per window, not per tab")), at: 0)
            t.history.sort { $0.at > $1.at }
            changes.append(.upsert(t))
        }

        if var t = model.thread(ID.valCenis) {
            t.ledger.items[0].detail = "The fifth sleeps on the sofa bed. The owner holds the dates until Sunday; after that the week may go to someone else."
            t.ledger.items[0].quote = t.lastLines
            t.work = RouterWork(
                summaries: [S(id: 2, text: "Comparing the price for four and for five", at: ago(14), run: "v1"),
                            S(id: 1, text: "Searching chalets in Val Cenis for 14–21 Feb", at: ago(22), run: "v1")],
                run: "v1",
                starts: ["v1": .asked("find a chalet in Val Cenis for 14–21 Feb, four of us, maybe five")])
            t.history = history(t.work, extra: [
                RouterEvent(id: "raised:i1", at: ago(12), run: "v1", kind: .raised(.decide, "reserve for five? about €62 more than for four")),
                RouterEvent(id: "f-v1", at: ago(12.1), run: "v1", kind: .finished("found a chalet for five; nothing reserved yet")),
            ])
            changes.append(.upsert(t))
        }
        model.apply(.batch(changes))
    }
}
