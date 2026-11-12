import AppKit
import SwiftUI

// `--window --router-v2-load [--quit-after]` (IMPLEMENTATION.md 1.10, 2.4): the demo's page grown to 60 lines in a
// 1617 × 1188 window, under the load the speed gates are read on. For twelve seconds: eight lines stream a verdict's
// words, a word every 40 ms, each stream ending and the next starting; the selected Working line's reply grows; and T3's
// records arrive, one every 30 ms, each timed as "T3 event" from the record taken to its change committed. Most keep
// their line's place (a step, a new dot), one in eight moves it to another state; "T3 event work" is the record's own
// main-thread work, to the end of `apply`. Read with
// `scripts/morph-timings.sh --args "--window --router-v2-load --quit-after"`.

@MainActor
enum RouterV2Load {
    static var isRequested: Bool { CommandLine.arguments.contains("--router-v2-load") }

    static let lines = 60
    static let streaming = 8
    static let seconds: Double = 12

    /// The demo's records and 49 more, across five projects and every state.
    static func records() -> RouterV2Model {
        let model = RouterV2Demo.records()
        let start = model.clockStart
        let projects = ["fjord", "silo", "lcu", "docs-site", "val-cenis"]
        let states: [RouterV2Thread.State] = [.working, .working, .working, .done, .done, .needsYou(.question), .stopped]
        var more: [RouterV2Change] = []
        for i in 0..<(lines - model.threads.count) {
            let state = states[i % states.count]
            var t = RouterV2Thread(id: "load-\(i)", name: "Load thread \(i + 1)", title: "A thread of the load scenario, \(i + 1)",
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
    static func play(_ model: RouterV2Model) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // The gate's size (docs/performance.md: demo data at the default size understates real costs).
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 800 }) {
                window.setContentSize(NSSize(width: 1617, height: 1188))
                window.center()
            }
            let working = model.threads.filter { $0.state == .working }.map(\.id)
            if let first = working.first { model.select(.line(first)) }
            let streams = Array(model.threads.filter { $0.state != .working }.map(\.id).prefix(streaming))
            let end = Date().addingTimeInterval(seconds)
            await withTaskGroup(of: Void.self) { group in
                for (n, id) in streams.enumerated() {
                    group.addTask { @MainActor in await stream(model, id, offset: n, until: end) }
                }
                group.addTask { @MainActor in await records(model, until: end) }
                if let first = working.first {
                    group.addTask { @MainActor in await reply(model, first, until: end) }
                }
            }
            if CommandLine.arguments.contains("--quit-after") { NSApp.terminate(nil) }
        }
    }

    private static let words = "the composer keeps its draft through the handover and the caret lands where it was, then the spacing matches T3's own at every size"
        .split(separator: " ").map(String.init)

    /// A verdict's words, a word every 40 ms through `post`, done at the end of each line; the next line after a beat.
    private static func stream(_ model: RouterV2Model, _ id: String, offset: Int, until end: Date) async {
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

    /// T3's records: one every 30 ms, each timed to its commit.
    private static func records(_ model: RouterV2Model, until end: Date) async {
        var n = 0
        while Date() < end {
            n += 1
            let ids = model.threads.map(\.id)
            guard !ids.isEmpty else { return }
            let id = ids[(n * 7919) % ids.count]
            if var t = model.thread(id) {
                if n % 8 == 0 {
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
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The selected line's reply, growing a word every 60 ms.
    private static func reply(_ model: RouterV2Model, _ id: String, until end: Date) async {
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
