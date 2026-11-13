import AppKit
import SwiftUI

// `--window --router-v2-load [--quit-after]` (IMPLEMENTATION.md 1.10, 2.4): the demo's page grown to 60 lines in a
// 1617 × 1188 window, under the load the speed gates are read on. For twelve seconds: eight lines stream a verdict's
// words, a word every 40 ms, each stream ending and the next starting; the selected Working line's reply grows; and T3's
// records arrive, one every 30 ms, each timed as "T3 event" from the record taken to its change committed. Most keep
// their line's place (a step, a new dot), one in eight moves it to another state; "T3 event work" is the record's own
// main-thread work, to the end of `apply`. Read with
// `scripts/morph-timings.sh --args "--window --router-v2-load --quit-after"`. `FJORD_LOAD_OFF=streams,reply,records,moves`
// leaves those parts out, to see what each costs.
//
// `--router-v2-load real`: the shape of the owner's T3 day instead of the stress above. Twenty lines, two of them
// streaming a verdict's words, a record about every second (one in ten moves its line), for thirty seconds, no reply
// growing; and each working line's summary at the engine's rate, one a minute per line spread over the minute: its line
// sheens for the call, its words stream, it lands on the card's timeline. The synthetic load stays the gate's target;
// this one must be comfortably green. `FJORD_LOAD_OFF=summaries` leaves the summaries out. And open items (R7) as the
// records hand them on, one read every six seconds (busier than the owner's day, about 330 a day): a block's header
// pulses and its items sheen, the read lands four seconds later (one item closes and strikes, one is restated, one is new),
// and 1.6 s later the ledger settles. `FJORD_LOAD_OFF=items` leaves them out. `FJORD_LOAD_BLOCKS=1` adds a line that
// becomes a block (a second item) and a line again every half second, each timed as "Block" to its commit.

@MainActor
enum RouterLoad {
    static var isRequested: Bool { CommandLine.arguments.contains("--router-v2-load") }

    /// `--router-v2-load real`: the realistic scenario.
    static var isReal: Bool { variant == "real" }
    /// `--router-v2-load select`: the synthetic page with nothing coming from T3, a card opened after another (↓) every
    /// 300 ms for 24 s, for the Select gate (the demo script selects nine times).
    static var isSelect: Bool { variant == "select" }

    private static var variant: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--router-v2-load"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var lines: Int { isReal ? 20 : 60 }
    static var streaming: Int { isReal ? 2 : 8 }
    static var seconds: Double { isReal ? 30 : isSelect ? 24 : 12 }
    /// Between two records, in ms: every 30 ms, or about a second (700–1300 ms) in the real one.
    static func recordPause(_ n: Int) -> Int { isReal ? 700 + (n * 7919) % 601 : 30 }
    /// One record in `moveEvery` moves its line.
    static var moveEvery: Int { isReal ? 10 : 8 }

    /// The demo's records and 49 more, across five projects and every state.
    static func records() -> RouterModel {
        let model = RouterDemo.records()
        let start = model.clockStart
        let projects = ["fjord", "silo", "lcu", "docs-site", "val-cenis"]
        let states: [RouterThread.State] = [.working, .working, .working, .done, .done, .needsYou(.question), .stopped]
        var more: [RouterChange] = []
        for i in 0..<max(0, lines - model.threads.count) {
            let state = states[i % states.count]
            var t = RouterThread(id: "load-\(i)", name: "Load thread \(i + 1)", title: "A thread of the load scenario, \(i + 1)",
                                   project: projects[i % projects.count], state: state,
                                   sentence: .init(text: state == .working ? "Editing File\(i).swift" : "finished the step \(i)"),
                                   since: start.addingTimeInterval(-Double(i * 97 + 30)))
            t.lastLines = "Line \(i): the agent's last words, long enough to wrap once in the card at its width."
            if state == .needsYou(.question) { t.options = ["Yes", "No"] }
            if state == .stopped { t.stop = .init(error: "exit 1", lastStep: "swift build") }
            more.append(.upsert(t))
        }
        model.apply(.batch(more))
        return model
    }

    /// Plays the load once the window is up; quits after it with `--quit-after`.
    static func play(_ model: RouterModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // The gate's size (docs/performance.md: demo data at the default size understates real costs).
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 800 }) {
                window.setContentSize(NSSize(width: 1617, height: 1188))
                window.center()
            }
            let working = model.threads.filter { $0.state == .working }.map(\.id)
            if let first = working.first { model.select(.line(first)) }
            // The resize lays every row out again at the new width and the card opens: drawn before the timed events
            // start, so the first ones measure the load, not the setup.
            try? await Task.sleep(for: .seconds(0.6))
            let streams = Array(model.threads.filter { $0.state != .working }.map(\.id).prefix(streaming))
            let end = Date().addingTimeInterval(seconds)
            if isSelect {
                while Date() < end {
                    model.step(down: true)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if CommandLine.arguments.contains("--quit-after") { NSApp.terminate(nil) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                let off = ProcessInfo.processInfo.environment["FJORD_LOAD_OFF"] ?? ""
                for (n, id) in streams.enumerated() where !off.contains("streams") {
                    group.addTask { @MainActor in await stream(model, id, offset: n, until: end) }
                }
                if !off.contains("records") { group.addTask { @MainActor in await records(model, until: end) } }
                if isReal, !off.contains("summaries") {
                    group.addTask { @MainActor in await summaries(model, until: end) }
                }
                if isReal, !off.contains("items") {
                    group.addTask { @MainActor in await items(model, until: end) }
                }
                if ProcessInfo.processInfo.environment["FJORD_LOAD_BLOCKS"] != nil {
                    group.addTask { @MainActor in await blocks(model, until: end) }
                }
                if let first = working.first, !off.contains("reply"), !isReal {
                    group.addTask { @MainActor in await reply(model, first, until: end) }
                }
            }
            if CommandLine.arguments.contains("--quit-after") { NSApp.terminate(nil) }
        }
    }

    private static let words = "the composer keeps its draft through the handover and the caret lands where it was, then the spacing matches T3's own at every size"
        .split(separator: " ").map(String.init)

    /// A verdict's words, a word every 40 ms through `post`, done at the end of each line; the next line after a beat.
    private static func stream(_ model: RouterModel, _ id: String, offset: Int, until end: Date) async {
        try? await Task.sleep(for: .milliseconds(37 * offset))
        while Date() < end {
            guard let stream = model.thread(id)?.sentence.stream else { return }
            let count = 8 + (offset * 3) % words.count / 2
            for n in 1...count where Date() < end {
                model.post(.words(id, stream: stream + 1, text: words.prefix(n).joined(separator: " "), done: n == count))
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// T3's records: one every 30 ms (about a second in the real scenario), each timed to its commit.
    private static func records(_ model: RouterModel, until end: Date) async {
        var n = 0
        while Date() < end {
            n += 1
            let ids = model.threads.map(\.id)
            guard !ids.isEmpty else { return }
            let id = ids[(n * 7919) % ids.count]
            if var t = model.thread(id) {
                if n % moveEvery == 0, ProcessInfo.processInfo.environment["FJORD_LOAD_OFF"]?.contains("moves") != true {
                    // Another state: the line moves.
                    t.state = t.state == .working ? .done : .working
                    t.sentence = .init(text: t.state == .working ? "Starting" : "finished", stream: t.sentence.stream)
                    t.since = model.now
                } else if t.state == .working {
                    t.sentence = .init(text: "Editing File\(n % 40).swift", stream: t.sentence.stream)
                } else {
                    t.isNew.toggle()
                }
                let event = RouterSignposts.begin("T3 event"), work = RouterSignposts.begin("T3 event work")
                model.apply(.upsert(t))
                RouterSignposts.end(work)
                RouterSignposts.end(event, afterCommit: true)
            }
            try? await Task.sleep(for: .milliseconds(recordPause(n)))
        }
    }

    /// Working summaries as the records hand them on: one working line after another, each once a minute, the line sheening
    /// for a call's length (4 s, Haiku's p50), its words streaming a word every 40 ms, then the record with the summary on
    /// top of its timeline.
    private static func summaries(_ model: RouterModel, until end: Date) async {
        var n = 0
        while Date() < end {
            let working = model.threads.filter { $0.state == .working }.map(\.id)
            guard !working.isEmpty else { return }
            let id = working[n % working.count]
            n += 1
            try? await Task.sleep(for: .seconds(60 / Double(working.count)))
            guard Date() < end, var t = model.thread(id), t.state == .working else { continue }
            t.sentence.phase = .reassessing
            model.apply(.upsert(t))
            try? await Task.sleep(for: .seconds(4))
            guard var t = model.thread(id), t.state == .working else { continue }
            let line = Array(words.dropFirst(n % 6).prefix(9))
            let stream = t.sentence.stream + 1
            t.work.lineReadsNewest = false
            model.apply(.upsert(t))
            for k in 1...line.count {
                model.post(.words(id, stream: stream, text: line.prefix(k).joined(separator: " "), done: k == line.count))
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard var t = model.thread(id) else { continue }
            let text = line.joined(separator: " ")
            t.work.summaries.insert(.init(id: (t.work.summaries.first?.id ?? -1) + 1, text: text, at: Date()), at: 0)
            t.work.summaries = Array(t.work.summaries.prefix(20))
            t.work.lineReadsNewest = true
            t.sentence = .init(text: text, stream: stream)
            let event = RouterSignposts.begin("T3 event"), work = RouterSignposts.begin("T3 event work")
            model.apply(.upsert(t))
            RouterSignposts.end(work)
            RouterSignposts.end(event, afterCommit: true)
        }
    }

    /// Open items as the records hand them on: a read every six seconds on one of four lines, each a timed record.
    private static func items(_ model: RouterModel, until end: Date) async {
        func put(_ t: RouterThread) {
            let event = RouterSignposts.begin("T3 event"), work = RouterSignposts.begin("T3 event work")
            model.apply(.upsert(t))
            RouterSignposts.end(work)
            RouterSignposts.end(event, afterCommit: true)
        }
        let ids = Array(model.threads.filter { $0.state == .working || $0.state == .done }.map(\.id).prefix(4))
        var next = 0
        for (k, id) in ids.enumerated() {
            guard var t = model.thread(id) else { continue }
            t.ledger = RouterLedger(items: [
                RouterItem(id: "i\(next)", kind: k % 2 == 0 ? .decide : .stuck, sentence: "keep the old checkpoint, or delete it?", since: model.now),
                RouterItem(id: "i\(next + 1)", kind: .know, sentence: "the boot image is 1.2 GB smaller", since: model.now),
            ])
            next += 2
            // Set up untimed unless FJORD_LOAD_ITEMS_SEED is set: a line becoming a block is timed apart.
            if ProcessInfo.processInfo.environment["FJORD_LOAD_ITEMS_SEED"] != nil { put(t) } else { model.apply(.upsert(t)) }
        }
        var n = 0
        while Date() < end, !ids.isEmpty {
            try? await Task.sleep(for: .seconds(6))
            let id = ids[n % ids.count]
            n += 1
            guard Date() < end, var t = model.thread(id) else { continue }
            t.ledger.turnEnded()
            put(t)
            try? await Task.sleep(for: .seconds(4))
            guard var t = model.thread(id), let first = t.ledger.live.first else { continue }
            let restated = t.ledger.live.dropFirst().first?.id
            next += 1
            t.ledger.land(RouterLedgerRead(close: [first.id: Router.Items.Copy.doneByAgent], merge: Set([restated].compactMap { $0 }),
                                          add: [RouterItem(id: "i\(next)", kind: .do, sentence: "sign in to Silo to boot the VM", since: model.now)]),
                          at: model.now)
            put(t)
            try? await Task.sleep(for: .seconds(Router.Items.strike))
            guard var t = model.thread(id) else { continue }
            t.ledger.settle()
            put(t)
        }
    }

    /// Lines with one item that get a second (each becomes a block) and lose it again, every half second, a line after
    /// another (each line's first time is timed too).
    private static func blocks(_ model: RouterModel, until end: Date) async {
        let ids = model.threads.filter { $0.ledger.isEmpty && $0.state != .stopped }.map(\.id)
        guard !ids.isEmpty else { return }
        let one = RouterItem(id: "b1", kind: .decide, sentence: "keep the old checkpoint, or delete it?", since: model.now)
        let two = RouterItem(id: "b2", kind: .know, sentence: "the boot image is 1.2 GB smaller", since: model.now)
        for id in ids {
            guard var t = model.thread(id) else { continue }
            t.ledger = RouterLedger(items: [one])
            model.apply(.upsert(t))
        }
        var n = 0
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(500))
            let id = ids[(n / 2) % ids.count]
            guard var t = model.thread(id) else { return }
            n += 1
            t.ledger = RouterLedger(items: n % 2 == 1 ? [one, two] : [one])
            let block = RouterSignposts.begin("Block")
            model.apply(.upsert(t))
            RouterSignposts.end(block, afterCommit: true)
        }
    }

    /// The selected line's reply, growing a word every 60 ms.
    private static func reply(_ model: RouterModel, _ id: String, until end: Date) async {
        var out = ""
        var n = 0
        while Date() < end {
            out += (out.isEmpty ? "" : " ") + words[n % words.count]
            n += 1
            model.post(.reply(id, text: out, writing: true))
            try? await Task.sleep(for: .milliseconds(60))
        }
        model.post(.reply(id, text: out, writing: false))
    }
}
