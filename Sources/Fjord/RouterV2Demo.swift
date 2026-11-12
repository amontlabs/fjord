import AppKit
import SwiftUI

// Router v2's demo (docs/design/router-v2/DESIGN.md 6): the fake records at t = 0, and a fake T3 that takes the page's
// acts and answers with the latencies measured on real data (FEASIBILITY.md): T3 takes a send in 0.35 s, a run starts
// 0.9 s after it, a steer lands in 3 s; a verdict's state lands at 1.9 s and its words stream to 2.5 s, four calls at
// most at once; a destination read takes 0.5 s for a follow-up to an idle thread and 3.2 s for a new thread, an unsure
// place or a running thread. `--window --router-v2-demo` shows the page on it and plays the storyboard
// (RouterV2DemoScript.swift); the window's shots use the same records for their stills.

@MainActor
enum RouterV2Demo {
    /// The page the window shows in place of the Router's, when there is one: the demo's, or a shot's.
    static var model: RouterV2Model?
    static var stage: RouterV2Stage?
    private static var source: RouterV2DemoSource?
    private static var script: RouterV2DemoScript?

    static var isRequested: Bool { CommandLine.arguments.contains("--router-v2-demo") }

    /// `--window --router-v2-demo [--from <beat>] [--until <beat>] [--beats 5,6,14] [--speed <x>] [--reduce-motion]
    /// [--frames <dir> [--frames-rate <n>]]`.
    static func install() {
        let model = records()
        let source = RouterV2DemoSource(model: model)
        let stage = RouterV2Stage()
        model.source = source
        model.scripted = true
        if let speed = value("--speed").flatMap(Double.init), speed > 0 { source.speed = speed }
        let script = RouterV2DemoScript(model: model, source: source, stage: stage)
        script.from = value("--from").flatMap(Int.init)
        script.until = value("--until").flatMap(Int.init)
        script.only = value("--beats").map { $0.split(separator: ",").compactMap { Int($0) } }
        self.model = model
        self.source = source
        self.stage = stage
        self.script = script
        if WindowRecorder.isRequested {
            // Filmed from its first move: the script starts as the frames start.
            // (The script starts once: a second notification does nothing.)
            NotificationCenter.default.addObserver(forName: WindowRecorder.startedNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { script.start() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { script.start() }
        }
    }

    static var reduceMotion: Bool { CommandLine.arguments.contains("--reduce-motion") }

    /// `--frames <dir>`: the script's frames, for checking its motion where nothing can be filmed; `--frames-rate <n>`
    /// a second (10 without it; 30 or 60 over a few beats to see a transition frame by frame).
    static let frames: RouterV2Frames? = value("--frames").map {
        RouterV2Frames(dir: $0, rate: value("--frames-rate").flatMap(Double.init) ?? RouterV2Frames.rate)
    }

    private static func value(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    // MARK: Records at t = 0 (6.2)

    enum ID {
        static let settings = "settings", valCenis = "val-cenis", briefs = "briefs", updater = "updater", disk = "disk"
        static let guide = "guide", bar = "bar", tab = "tab", snapshot = "snapshot", checkpoint = "checkpoint"
        static let upstream = "upstream", glass = "glass"
    }

    static let plan: [String] = [
        "1. Add a `briefs` table to BriefLog: id, project, thread, body, written_at.",
        "2. Write `BriefLog.save(_:)` and `BriefLog.latest(for:)` on that table.",
        "3. Copy the old rows from briefs.db once, at the first launch after the update.",
        "4. Keep briefs.db untouched until the copy is checked row by row.",
        "5. Point `RouterBriefs` at BriefLog for reads.",
        "6. Point the brief engine at BriefLog for writes.",
        "7. Move the Told marks into a `told` column.",
        "8. Move the read marks the same way.",
        "9. Delete `BriefStore` and its JSON fallback.",
        "10. Seed BriefLog from `DemoBriefs`, so the shots keep their data.",
        "11. Update the eval dump to read from BriefLog.",
        "12. Add a migration test: 200 old rows in, 200 new rows out.",
        "13. Add a test for a copy interrupted halfway: it starts again cleanly.",
        "14. Add a test for an empty briefs.db.",
        "15. Run the Router's suites, then the full suite once.",
        "16. Measure the page's first draw on 500 briefs before and after.",
        "17. Keep the old file for one release, then delete it on launch.",
        "18. Note the new table in DEVELOPMENT.md.",
        "19. Note the one-time copy in the release notes.",
        "20. Remove the `briefs.db` path from the uninstall script.",
        "21. Check the History drawer still finds its Reverts.",
        "22. Check the bar's count against the page's on real data.",
        "23. Open the PR with the migration notes.",
    ]

    /// The page at t = 0: eleven threads, five older ones, Settings layout selected with its card open.
    static func records(still: Bool = false) -> RouterV2Model {
        let model = RouterV2Model()
        model.still = still
        let start = model.clockStart
        func ago(_ minutes: Double) -> Date { start.addingTimeInterval(-minutes * 60 - 25) }
        typealias T = RouterV2Thread

        var settings = T(id: ID.settings, name: "Settings layout", title: "Redesign the Settings window", project: "fjord",
                         state: .needsYou(.question), sentence: .init(text: "sidebar, one page, or tabs?"), since: ago(25))
        settings.lastLines = "I can do a sidebar with sections, one scrolling page, or tabs. One page is simplest to maintain; the sidebar scales best if Settings keeps growing."
        settings.options = ["A sidebar with sections", "One scrolling page", "Tabs across the top"]

        var valCenis = T(id: ID.valCenis, name: "Val Cenis booking", title: "Book the Val Cenis chalet, 14–21 Feb", project: nil,
                         state: .needsYou(.step), sentence: .init(text: "reserve for five? about €62 more than for four"), since: ago(12))
        valCenis.lastLines = "The chalet takes five with the sofa bed. For five it is €1,302 for the week instead of €1,240. I have not reserved anything yet."
        valCenis.question = "Reserve for five, or keep it at four?"
        valCenis.options = ["Reserve for five (+€62)", "Keep it at four"]

        var briefs = T(id: ID.briefs, name: "Briefs migration", title: "Move the briefs into BriefLog", project: "fjord",
                       state: .needsYou(.plan), sentence: .init(text: "plan ready: move briefs into BriefLog, copy the old rows once"),
                       since: ago(6))
        briefs.plan = plan
        // T3 gives a plan no options: these two are Fjord's; "no" is typing what to change.
        briefs.options = ["Yes, and auto-accept edits", "Yes, and manually approve edits"]

        var updater = T(id: ID.updater, name: "Updater", title: "Ship the updater", project: "lcu", state: .needsYou(.form),
                        sentence: .init(text: "silent or ask first? stable or beta?"), since: ago(2))
        updater.isNew = true
        updater.form = [.init(id: "install", title: "How should updates install?", options: ["Silently", "Ask first"]),
                        .init(id: "channel", title: "Which channel?", options: ["Stable", "Beta"])]

        // A real stop: T3 fails a run on a provider or transport error, not on a failed test (that is a finished turn).
        var disk = T(id: ID.disk, name: "Disk test", title: "Find the flaky disk test", project: "silo", state: .stopped,
                     sentence: .init(text: "failed: the connection to Claude dropped"), since: ago(60))
        disk.stop = .init(error: "The connection to Claude dropped: the stream closed before the turn finished.",
                          lastStep: "running `swift test --filter SnapshotRestore`")

        var guide = T(id: ID.guide, name: "Install guide", title: "Rewrite the install guide", project: "docs-site", state: .done,
                      sentence: .init(text: "rewritten for the Chrome setup; PR #41"), since: ago(10))
        guide.worth = .look
        guide.isNew = true
        guide.lastLines = "Rewrote the guide around the Chrome extension setup and removed the old CLI path. Screenshots are updated."
        guide.prs = [.init(number: 41, state: .open)]
        guide.diff = .init(files: 4, added: 96, removed: 212)

        var bar = T(id: ID.bar, name: "Bar count", title: "Count untold needs-you on the bar", project: "fjord", state: .done,
                    sentence: .init(text: "counts only unread; tests pass, not pushed"), since: ago(50))
        bar.lastLines = "The bar now counts only the entries you have not read. The tests pass. Nothing is pushed yet."
        bar.diff = .init(files: 3, added: 41, removed: 12)

        // Working lines as real data gives them: the running to-do step when the thread has a list (one here), else
        // the agent's latest words, else the running tool.
        let tab = T(id: ID.tab, name: "Tab handover", title: "Hand the tab over without a gap", project: "fjord", state: .working,
                    sentence: .init(text: "Editing TabHandover.swift"), since: ago(12))

        let snapshot = T(id: ID.snapshot, name: "Snapshot API", title: "Snapshot API: restore by id", project: "silo", state: .working,
                         sentence: .init(text: "swift test --filter SnapshotRestore", mono: true), since: ago(31))

        var checkpoint = T(id: ID.checkpoint, name: "Checkpoint boot", title: "Boot the Linux VM from a checkpoint", project: "silo",
                           state: .working, sentence: .init(text: "Building the boot image"), since: ago(6))
        checkpoint.steps = steps(["Building the boot image", "Booting the VM from the checkpoint", "Checking the boot log"], running: 0)

        let upstream = T(id: ID.upstream, name: "Upstream issue", title: "Answer upstream issue #2031", project: "silo", state: .working,
                         sentence: .init(text: "I'll reproduce it on the 0.4 branch first."), since: ago(18))

        func days(_ d: Double) -> Date { start.addingTimeInterval(-d * 86_400 - 3_600) }
        let older: [RouterV2Older] = [
            .init(id: "canvas", name: "Drop the canvas layout", project: "fjord", since: days(3)),
            .init(id: "glass-fallback", name: "Glass capture fallback", project: "fjord", since: days(2)),
            .init(id: "decider-score", name: "Score the decider on last week's moments", project: "fjord", since: days(2)),
            .init(id: "approval-copy", name: "Approval panel copy", project: "lcu", since: days(4)),
            .init(id: "sitemap", name: "Sitemap and redirects", project: "docs-site", since: days(2)),
        ]
        // The page's first load: one update.
        let threads = [settings, valCenis, briefs, updater, disk, guide, bar, tab, snapshot, checkpoint, upstream]
        model.apply(.batch(threads.map { .upsert($0) } + [.older(older)]))
        // On page open: the first Needs-you line, its card open.
        model.selection = .line(ID.settings)
        return model
    }

    static func steps(_ texts: [String], running: Int) -> [RouterV2Thread.Step] {
        texts.enumerated().map { i, text in .init(id: i, text: text, state: i < running ? .done : i == running ? .running : .pending) }
    }

    /// Checkpoint boot's permission (beat 12), as T3 asks it: the command, T3's four options and a warning; no reason
    /// (T3 sends none).
    static func askPermission(_ model: RouterV2Model) {
        let command = "git worktree remove --force ~/silo-work/checkpoint-old"
        model.asked(ID.checkpoint, .permission, line: command, mono: true) {
            $0.permission = .init(command: command, warning: "--force discards uncommitted changes there.", warned: [1, 2])
            $0.options = ["Allow once", "Allow for this thread", "Deny", "Cancel"]
            $0.lastLines = ""
            $0.steps = []
        }
    }
}

/// `--window --router-v2-demo --frames <dir>`: while the script plays, the window server's picture of the app's own window
/// ten times a second, as `frame-0001.jpg`…, to check a beat's motion frame by frame. The window is the app's own, so it
/// needs no Screen Recording permission. Not a film (10 frames a second): `scripts/record-window.sh` makes those.
@MainActor
final class RouterV2Frames {
    static let rate: Double = 10

    private let dir: String
    private let rate: Double
    private var timer: Timer?
    private var count = 0
    private var began = Date()
    private let writes = DispatchGroup()

    init(dir: String, rate: Double) {
        self.dir = dir
        self.rate = max(1, min(60, rate))
    }

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        began = Date()
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snap() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func snap() {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 800 })?.contentView,
              let image = ShotCapture.windowImage(of: view) else { return }
        count += 1
        // Named by its time since the frames began, in hundredths of a second: `frame-01234.jpg` is at 12.34 s.
        let at = Int((Date().timeIntervalSince(began) * 100).rounded())
        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "frame-%05d.jpg", at))
        // Encoded off the main thread, so the page keeps its pace.
        let picture = Picture(image: image)
        writes.enter()
        DispatchQueue.global(qos: .utility).async { [writes] in
            let rep = NSBitmapImageRep(cgImage: picture.image)
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: url)
            writes.leave()
        }
    }

    /// What just happened, on the frames' own clock: `v2-frame 01234  move settings` says which frames show a line's
    /// move or a change in the destination row, so they can be checked without looking for them.
    static func note(_ text: String) { RouterV2Demo.frames?.mark(text) }

    private func mark(_ text: String) {
        guard timer != nil else { return }
        let at = Int((Date().timeIntervalSince(began) * 100).rounded())
        FileHandle.standardError.write(Data(String(format: "v2-frame %05d  %@\n", at, text).utf8))
    }

    /// A picture nothing else holds, handed to the queue that encodes it.
    private struct Picture: @unchecked Sendable {
        let image: CGImage
    }

    /// The last frames are on disk when this returns.
    func finish() {
        timer?.invalidate()
        timer = nil
        writes.wait()
    }
}

/// The demo's T3 and the Router's model: they answer the page's acts after the latencies measured on real data
/// (FEASIBILITY.md). `speed` divides every wait.
@MainActor
final class RouterV2DemoSource: RouterV2Source {
    /// A Working line as real data gives it: a to-do step or the agent's words (sans), or the running command (mono).
    struct Line {
        var text: String
        var mono = false

        static func command(_ text: String) -> Line { Line(text: text, mono: true) }
        static func words(_ text: String) -> Line { Line(text: text) }
    }

    unowned let model: RouterV2Model
    var speed: Double = 1
    /// T3 can't be reached: sends are refused at once.
    var unreachable = false
    /// What each thread's next run shows as it starts, in order.
    var steps: [String: [Line]] = [
        RouterV2Demo.ID.settings: [.words("Reading SettingsView.swift")],
        RouterV2Demo.ID.valCenis: [.words("Thinking")],
        RouterV2Demo.ID.briefs: [.words("Editing BriefLog.swift")],
        RouterV2Demo.ID.updater: [.words("Editing UpdatePrompt.swift")],
        RouterV2Demo.ID.disk: [.command("swift test --filter SnapshotRestore")],
        RouterV2Demo.ID.checkpoint: [.command("git worktree remove --force ~/silo-work/checkpoint-old"),
                                     .command("rm ~/silo-work/checkpoint-old.img")],
        RouterV2Demo.ID.bar: [.command("git push -u origin bar-count")],
        RouterV2Demo.ID.tab: [.words("I'll re-measure the composer's spacing against T3.")],
        RouterV2Demo.ID.snapshot: [.words("Editing Snapshots.swift")],
    ]
    /// What the Router reads of the script's drafts: the place, and for a new thread the settings the words name, as
    /// the real decider's structured output will give them.
    var reads: [String: RouterV2Read] = [:]
    /// The names the model gives the threads started here, by their first words.
    var names: [String: String] = [:]
    var newSteps: [String: Line] = [:]
    /// A thread's next run starts this long after its send (0.9 s without one).
    var runDelay: [String: Double] = [:]

    /// A destination read: Jev answers in half a second when it is sure of a follow-up to an idle thread; a new thread,
    /// an unsure place, a running thread and any settings in the words need Sonnet.
    static let quickRead = 0.5, slowRead = 3.2
    /// A verdict (Haiku, streamed): its state lands first, its words stream until `verdictEnd`; `verdictCalls` at once.
    static let verdictState = 1.9, verdictWords = 2.0, verdictEnd = 2.5, verdictCalls = 4
    /// Claude stops its running tool a few seconds after a steer: "steering…" until then.
    static let steer = 3.0
    /// A new thread's name: a field of its first model call.
    static let naming = 2.2

    /// Each thread's fingerprint: an answer to an older one is dropped (a run started meanwhile, T3 dropped).
    private var prints: [String: Int] = [:]
    private var calls = 0
    private var waiting: [() -> Void] = []

    init(model: RouterV2Model) {
        self.model = model
    }

    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds / speed))
            work()
        }
    }

    @discardableResult private func bump(_ id: String) -> Int {
        prints[id, default: 0] += 1
        return prints[id, default: 0]
    }

    private func current(_ id: String, _ print: Int) -> Bool { prints[id] == print }

    func read(_ draft: String, selected: String?) {
        let read = reads[draft] ?? fallback(draft, selected: selected)
        after(time(of: read)) { [model] in model.apply(.read(read)) }
    }

    private func time(of read: RouterV2Read) -> Double {
        guard read.sure, read.launch == RouterV2LaunchAsk(), case .thread(let id)? = read.places.first,
              let t = model.thread(id), !t.isRunning else { return Self.slowRead }
        return Self.quickRead
    }

    /// A draft the script doesn't know: the selected thread, else what the words address ("silo: …"), else no guess.
    private func fallback(_ draft: String, selected: String?) -> RouterV2Read {
        if let selected { return RouterV2Read(draft: draft, places: [.thread(selected)], sure: true) }
        if let colon = draft.firstIndex(of: ":") {
            let address = draft[..<colon].lowercased()
            if let t = model.threads.first(where: { $0.name.lowercased() == address }) {
                return RouterV2Read(draft: draft, places: [.thread(t.id)], sure: true)
            }
            if let p = model.projects.first(where: { $0.lowercased() == address }) {
                let words = draft[draft.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return RouterV2Read(draft: draft, places: [.newThread(project: p)], sure: true, name: RouterV2.firstWords(words))
            }
        }
        return RouterV2Read(draft: draft, places: [], sure: false)
    }

    func send(_ words: String, to thread: String, steering: Bool, continuing: Bool) {
        let print = bump(thread)
        if unreachable {
            // T3 is down: the error comes at once.
            after(0.05) { [model] in model.refused(thread, reason: RouterV2.Copy.unreachable, offline: true) }
            return
        }
        let starts = steering ? Self.steer : runDelay.removeValue(forKey: thread) ?? 0.9
        // A steer is taken when the running tool stops: "steering…" until then.
        if !steering { after(0.35) { [self] in if current(thread, print) { model.taken(thread) } } }
        after(starts) { [self] in
            guard current(thread, print) else { return }
            // The run's first line, taken when it starts (a send that was refused took none).
            let step = steps[thread]?.first ?? Line(text: steering ? "Thinking" : RouterV2.Copy.starting)
            if steps[thread]?.isEmpty == false { steps[thread]?.removeFirst() }
            model.runStarted(thread, step: step.text, mono: step.mono)
        }
    }

    func queue(_ words: String, on thread: String) {}

    /// T3 sends a thread's queued words as its turn ends: taken, then a run, as a send.
    func queuedWent(_ thread: String) { send("", to: thread, steering: false, continuing: false) }

    func start(_ thread: String, words: String, project: String, launch: RouterV2Launch) {
        let print = bump(thread)
        let name = names[words]
        let step = newSteps[words] ?? Line(text: "Thinking")
        after(0.35) { [self] in if current(thread, print) { model.taken(thread) } }
        after(0.9) { [self] in if current(thread, print) { model.runStarted(thread, step: step.text, mono: step.mono) } }
        if let name { after(Self.naming) { [model] in model.named(thread, name) } }
    }

    /// A stop you asked for: the thread goes to Done (T3's `latestRunStopRequested`), not to Needs you.
    func stop(_ thread: String) {
        bump(thread)
        model.interrupted(thread)
    }

    func visit(_ thread: String) {}
    func open(_ thread: String) {}

    // MARK: Scripted T3 events

    /// T3 drops: the connection line shows, and what was on its way is refused (its line returns, a failure line enters).
    func drop() {
        unreachable = true
        model.connection(lost: true)
        for t in model.threads where t.state == .sent && t.sent?.status != .taken {
            bump(t.id)
            model.refused(t.id, reason: RouterV2.Copy.unreachable, offline: true)
        }
    }

    func reconnect() {
        unreachable = false
        model.connection(lost: false)
    }

    /// A model call for a thread whose fingerprint just moved: its state at 1.9 s, its words streaming from 2.0 s to
    /// about 2.5 s. Four calls at most at once: the others wait, their lines sheening. Dropped if the thread moves on
    /// meanwhile (a run starts).
    func verdict(_ id: String, line: String, stateWord: Bool = true, state: @escaping (RouterV2Model) -> Void = { _ in }) {
        let print = bump(id)
        let call = { [self] in
            after(Self.verdictState) { [self] in if current(id, print) { state(model) } }
            after(Self.verdictWords) { [self] in
                if current(id, print), model.thread(id)?.sentence.phase == .reassessing { model.line(id, line, stateWord: stateWord) }
            }
            after(Self.verdictEnd) { [self] in
                calls -= 1
                if !waiting.isEmpty {
                    calls += 1
                    waiting.removeFirst()()
                }
            }
        }
        if calls < Self.verdictCalls {
            calls += 1
            call()
        } else {
            waiting.append(call)
        }
    }

    /// A turn ends: Done at once, then the verdict: worth a look or quiet, or (`step`) it left you a step and moves to
    /// Needs you, its ask streaming; `result` is the line it keeps for Done.
    func endTurn(_ id: String, worth: RouterV2Thread.Worth = .quiet, line: String, lastLines: String? = nil, prs: [RouterV2Thread.PR] = [],
                 diff: RouterV2Thread.Diff? = nil, step: (ask: String, options: [String], result: String)? = nil, stateWord: Bool = true) {
        model.turnEnded(id, lastLines: lastLines, prs: prs, diff: diff)
        guard model.thread(id)?.state == .done else { return }
        verdict(id, line: line, stateWord: stateWord) { model in
            if let step { model.verdict(id, step: step.ask, options: step.options, result: step.result) } else { model.verdict(id, worth: worth) }
        }
    }

    /// A thread that just finished starts again on its own (a wake after background work: one run end in four within
    /// 30 s): back to Working, and the verdict under way is dropped, no line written.
    func restart(_ id: String, _ step: Line) {
        bump(id)
        model.runStarted(id, step: step.text, mono: step.mono)
    }

    /// The agent writes its reply: the card's last lines grow word by word.
    func write(_ id: String, _ text: String, every: Double = 0.075) {
        let words = text.split(separator: " ").map(String.init)
        Task { @MainActor [model, speed] in
            var out = ""
            for (i, word) in words.enumerated() {
                guard let t = model.thread(id), t.state == .working else { return }
                out += (out.isEmpty ? "" : " ") + word
                model.reply(id, out, writing: i < words.count - 1)
                try? await Task.sleep(for: .seconds(every / speed))
            }
        }
    }
}

// MARK: - The demo's T3 events

/// What T3 and the Router's models do in the demo (DESIGN.md 3): each event builds the thread's next record from the one
/// the page holds and hands it to `apply`, as the real store does (IMPLEMENTATION.md 1.2). The script, the demo's
/// source and the shots call these; nothing else does.
extension RouterV2Model {
    /// A turn ends with no request: Working → Done at once, "finished", the sentence sheening until the verdict.
    func turnEnded(_ id: String, lastLines: String? = nil, prs: [RouterV2Thread.PR] = [], diff: RouterV2Thread.Diff? = nil) {
        guard var t = thread(id) else { return }
        // Queued words go as the turn ends: the row rises into the line, which becomes Sent.
        if let words = t.queued {
            t.queued = nil
            t.state = .sent
            t.sent = .init(words: words, status: .sending)
            t.since = now
            apply(.upsert(t))
            (source as? RouterV2DemoSource)?.queuedWent(id)
            return
        }
        t.state = .done
        t.worth = .quiet
        t.sentence = .init(text: RouterV2.Copy.finished, phase: .reassessing, stream: t.sentence.stream)
        t.since = now
        t.isNew = true
        t.sent = nil
        t.writing = false
        t.steps = []
        t.launch = nil
        t.result = nil
        if let lastLines { t.lastLines = lastLines }
        if !prs.isEmpty { t.prs = prs }
        if let diff { t.diff = diff }
        apply(.upsert(t))
    }

    /// The verdict's state, which comes first: Done worth a look or quiet, or it left you a step (the line moves to Needs
    /// you at once, still sheening).
    func verdict(_ id: String, worth: RouterV2Thread.Worth = .quiet, step ask: String? = nil, options: [String] = [],
                 result: String? = nil) {
        guard var t = thread(id), t.state == .done else { return }
        if let ask {
            t.state = .needsYou(.step)
            t.question = ask
            t.options = options
            t.result = result
            t.since = now
        } else {
            t.worth = worth
        }
        apply(.upsert(t))
    }

    /// The model's line lands: its words stream in over the sentence's place.
    func line(_ id: String, _ text: String, stateWord: Bool = true) {
        guard var t = thread(id) else { return }
        if t.sentence.text == text, t.sentence.stateWord == stateWord, !t.sentence.mono {
            // The same words (a PR merged, the result didn't change): nothing streams, the sheen just goes.
            t.sentence.phase = .settled
            apply(.upsert(t))
            return
        }
        let words = RouterV2Change.words(id, stream: t.sentence.stream + 1, text: text, done: true)
        if t.sentence.stateWord != stateWord {
            t.sentence.stateWord = stateWord
            apply(.batch([.upsert(t), words]))
        } else {
            apply(words)
        }
    }

    /// The model names a thread: once.
    func named(_ id: String, _ name: String) { apply(.named(id, name)) }

    /// A new request (question, form, plan, permission): Needs you at once with the kind's mark and T3's words verbatim;
    /// the card is complete at once.
    func asked(_ id: String, _ ask: RouterV2Thread.Ask, line: String, mono: Bool = false, card: (inout RouterV2Thread) -> Void) {
        guard var t = thread(id) else { return }
        t.state = .needsYou(ask)
        t.sentence = .init(text: line, mono: mono, phase: .reassessing, stream: t.sentence.stream)
        t.since = now
        t.isNew = true
        t.sent = nil
        t.writing = false
        card(&t)
        apply(.upsert(t))
    }

    /// T3 has your words: the status goes (there is no "delivered").
    func taken(_ id: String) {
        guard var t = thread(id), t.state == .sent else { return }
        t.sent?.status = .taken
        apply(.upsert(t))
    }

    /// A run starts (your send, a rerun, T3 on its own): Working, under the Sent lines.
    func runStarted(_ id: String, step: String = RouterV2.Copy.starting, mono: Bool = false, steps: [RouterV2Thread.Step] = []) {
        guard var t = thread(id) else { return }
        t.state = .working
        t.sentence = .init(text: step, mono: mono, stream: t.sentence.stream)
        t.since = now
        t.sent = nil
        t.paused = false
        t.stop = nil
        t.steps = steps
        // A new turn: the agent has said nothing in it yet.
        t.lastLines = ""
        t.diff = nil
        // What it asked is answered.
        t.question = nil; t.options = []; t.form = []; t.plan = []; t.permission = nil
        t.result = nil
        t.isNew = false
        apply(.upsert(t))
    }

    /// The running step changes: the sentence cross-fades.
    func step(_ id: String, _ text: String, mono: Bool = false, steps: [RouterV2Thread.Step]? = nil) {
        guard var t = thread(id) else { return }
        t.sentence = .init(text: text, mono: mono, stream: t.sentence.stream)
        if let steps { t.steps = steps }
        apply(.upsert(t))
    }

    /// A run you stopped yourself (T3's `latestRunStopRequested`): Done, not Needs you. Code only: nothing sheens.
    func interrupted(_ id: String) {
        guard var t = thread(id), t.isRunning else { return }
        t.state = .done
        t.worth = .quiet
        t.sentence = .init(text: RouterV2.Copy.stoppedByYou, stream: t.sentence.stream)
        t.since = now
        t.sent = nil
        t.writing = false
        t.queued = nil
        t.steps = []
        t.launch = nil
        apply(.upsert(t))
    }

    /// A run T3 failed (a provider or transport error, a usage limit with no resume): Stopped, at the end of Needs you.
    /// Code only: nothing sheens.
    func failed(_ id: String, error: String, lastStep: String, line: String? = nil) {
        guard var t = thread(id) else { return }
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        t.state = .stopped
        t.sentence = .init(text: line ?? "failed: " + first, stream: t.sentence.stream)
        t.stop = .init(error: error, lastStep: lastStep)
        t.since = now
        t.sent = nil
        t.writing = false
        t.queued = nil
        apply(.upsert(t))
    }

    /// Paused at the usage limit, resuming on its own: stays Working, the dots stop.
    func paused(_ id: String, line: String) {
        guard var t = thread(id) else { return }
        t.paused = true
        t.sentence = .init(text: line, stream: t.sentence.stream)
        apply(.upsert(t))
    }

    /// A pull request opens, merges or closes: the state word flips (the view pops it) and the sentence sheens, since the
    /// PR's state is in the fingerprint.
    func pr(_ id: String, _ number: Int, _ state: RouterV2Thread.PR.State) {
        guard var t = thread(id) else { return }
        if let i = t.prs.firstIndex(where: { $0.number == number }) { t.prs[i].state = state } else {
            t.prs.append(.init(number: number, state: state))
        }
        if t.state == .done || t.state == .needsYou(.step) { t.sentence.phase = .reassessing }
        apply(.upsert(t))
    }

    /// Settled, snoozed or archived in T3: the line leaves. No toast: it wasn't done here.
    func left(_ id: String) { apply(.remove(id)) }

    /// A new thread (or one unsettled, reopened, its snooze over): its line grows in, in its state's section.
    func appeared(_ t: RouterV2Thread) { apply(.upsert(t)) }

    /// Your send is refused, or T3 drops: the line returns to the state and place it had, a failure line enters.
    func refused(_ id: String, reason: String, offline: Bool = false) { apply(.refused(id, reason: reason, offline: offline)) }

    func connection(lost: Bool) { apply(.connection(lost: lost)) }

    /// The agent's reply as it is written.
    func reply(_ id: String, _ text: String, writing: Bool) { apply(.reply(id, text: text, writing: writing)) }

    /// The thread's messages loaded.
    func loaded(_ id: String) {
        guard var t = thread(id) else { return }
        t.loading = false
        apply(.upsert(t))
    }
}
