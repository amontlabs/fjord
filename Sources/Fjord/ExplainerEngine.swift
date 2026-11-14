import Foundation
import os

// Show me's engine (docs/design/router-visuals/SHOWME.md §3, §2.4, §6, §13): keeps the request queue and the runs, starts one
// Opus explainer thread per request when its source turn ends, reads each explainer's final from its last message, and gives
// the dock its list. It runs off T3's shell stream (`shell(_:)`), with no timers or polling. The renderer (P2) saves versions
// and tells it (`ExplainerRenderHost`).

/// One explainer, as the dock lists it (§6). The page's `RouterExplainer` is drawn from it.
struct ExplainerItem: Identifiable, Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Waiting for its thread's turn, or for its creator to start.
        case queued
        /// Being made: its latest draft (0 before the first), what that draft's render asked to fix.
        case making(draft: Int, fixing: String)
        case ready
        case failed(String)
    }

    /// The explainer thread's id (a request's, while queued).
    let id: String
    var title: String
    /// The source thread's title.
    var thread: String
    /// The source thread's id.
    var source: String
    var answer: String
    var captions: [String]
    var since: Date
    var stage: Stage
    /// Seconds, from the render's timing.
    var length: Int
    /// The final's page (the latest version's while making): the player's file.
    var page: URL?
    var posterLight: URL?
    var posterDark: URL?
    /// The final fell back to a draft: the run ended with no code of its own (§2.4).
    var draft = false
    var unseen = false
    /// It has a thread in T3 (a run, not a request that never launched): Open in T3 has somewhere to go.
    var launched = false
    /// What was asked of it, oldest first: the original, then one per follow-up. Each finished one is its final; the one being
    /// made shows its latest draft. Drafts are never listed.
    var versions: [Version] = []

    struct Version: Equatable, Sendable {
        /// "Original", or the follow-up's words.
        var label: String
        var at: Date
        var making = false
        var answer = ""
        var captions: [String] = []
        var length = 0
        var page: URL?
        var posterLight: URL?
        var posterDark: URL?
    }

    static let original = "Original"

    /// The explainer as its version `index` shows it (nil, or one it doesn't have: the newest): that version's film, ready
    /// unless it's the one being made.
    func version(_ index: Int?) -> ExplainerItem {
        guard let last = versions.indices.last else { return self }
        let v = versions[index.map { min(max($0, 0), last) } ?? last]
        var out = self
        out.answer = v.answer.isEmpty ? answer : v.answer
        out.captions = v.captions; out.length = v.length; out.page = v.page
        out.posterLight = v.posterLight; out.posterDark = v.posterDark
        if !v.making { out.stage = .ready } else if out.stage == .ready { out.stage = .making(draft: 0, fixing: "") }
        return out
    }
}

/// An explainer thread Fjord started, kept in `runs/<id>/run.json` (the renderer keeps `meta.json` beside it).
struct ExplainerRun: Codable, Equatable, Sendable {
    var id: String
    /// What the creator passes to every `preview` call (§13): short, so it copies cleanly.
    var ticket: String
    var source: String
    var sourceTitle: String
    /// Your message it explains; nil for a card's latest reply.
    var ask: String?
    var askText: String
    var createdAt: Date
    /// The thread's latest run that was read for a final (its id; its completion time when T3 names no run): a follow-up
    /// is a new run, read again when it ends.
    var finalizedRun: String?
    /// The final version, once a run ended.
    var final: Int?
    var finalAt: Date?
    var draft = false
    var failed: String?
    var watchedAt: Date?
    /// What was asked, oldest first: the original, then each follow-up, with its final once a run ended. nil in a run saved
    /// before versions were kept: its one final is the original.
    var asks: [Ask]?

    struct Ask: Codable, Equatable, Sendable {
        /// The follow-up's words; nil for the original.
        var words: String?
        var at: Date
        var final: Int?
    }

    /// `asks`, the original included for a run saved before.
    var versions: [Ask] { asks ?? [Ask(words: nil, at: createdAt, final: final)] }

    var unseen: Bool {
        guard final != nil, let finalAt else { return false }
        return watchedAt.map { $0 < finalAt } ?? true
    }
}

/// Which version is the final when a run ends (§2.4): the last ```js block of the thread's last reply.
enum ExplainerFinal {
    enum Outcome: Equatable {
        /// The block is the last preview's code: that version.
        case version(Int)
        /// The block differs from every preview: render it as the next version.
        case render(String)
        /// No block (interrupted, failed, a usage limit): the last version that isn't broken, as a draft.
        case draft(Int)
        case failed
    }

    static func decide(lastReply: String?, versions: [ExplainerVersion]) -> Outcome {
        if let code = lastReply.flatMap(codeBlock) {
            if let last = versions.last, trimmed(last.code) == trimmed(code) { return .version(last.number) }
            return .render(code)
        }
        if let good = versions.last(where: { !$0.broken }) { return .draft(good.number) }
        return .failed
    }

    /// The last fenced `js` or `javascript` block (`EX/run.py`'s pattern).
    static func codeBlock(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = fence.matches(in: text, range: range).last, let body = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[body])
    }

    private static let fence = try! NSRegularExpression(pattern: "```(?:js|javascript)\\n(.*?)```", options: [.dotMatchesLineSeparators])
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class ExplainerEngine: ExplainerRenderHost {
    /// The creator's model: Opus 5.5 at its default effort, as the evals ran it (§1.4).
    static let model = "claude-opus-5-5"
    nonisolated static let log = Logger(subsystem: InboxLog.subsystem, category: "explainers")
    /// The dock lists the newest ones.
    static let listed = 20

    /// What the engine reaches outside itself; tests stand in for all of it.
    struct Env {
        /// T3's whole shell, the hidden project included (`T3Store.hidden`).
        var hidden: @MainActor () -> T3ShellState
        /// The Router's shell (`T3Store.shell`): where source threads are.
        var shell: @MainActor () -> T3ShellState
        /// Keeps the project's folder out of the Router's shell (`T3Store.hiddenRoot`).
        var hide: @MainActor (String) -> Void
        /// A thread's projection, read once.
        var snapshot: @MainActor (String) async -> T3Projection?
        /// T3's provider instance for `model` in a project (its raw JSON), nil when T3 doesn't offer it.
        var model: @MainActor (_ slug: String, _ project: T3JSON?) async -> ThreadLaunchModel?
        var dispatch: @MainActor (T3Command) async throws -> Void
        /// One `ProjectMutation` (`ExplainerProject.liveMutate`).
        var mutate: @MainActor (T3JSON) async throws -> T3JSON
        var now: () -> Date = Date.init
        /// `ExplainerProject.sync()`, off the main actor.
        var sync: @Sendable (ExplainerProject) async throws -> Void = ExplainerEngine.syncDetached
        /// The clock `at=` times are read in, and the short name the input swaps for `user`.
        var zone = TimeZone.current
        var user = NSUserName()
        /// Fjord's own threads (the runs), kept off the Router whatever T3 does with their project (`T3Store.hide(threads:)`).
        var hideThreads: @MainActor (Set<String>) -> Void = { _ in }
        /// The queue, the runs and their versions read back from disk, off the main actor.
        var load: @Sendable (ExplainerProject) async -> Loaded = ExplainerEngine.loadDetached
    }

    /// What `start()` reads back: the queue, the runs, and each run's versions (the code of its latest only, the one a final is
    /// compared with: a run's older code can be megabytes and nothing reads it).
    struct Loaded: Sendable {
        var queue = ExplainerQueue()
        var runs: [String: ExplainerRun] = [:]
        var versions: [String: [ExplainerVersion]] = [:]
    }

    nonisolated static func loadDetached(_ project: ExplainerProject) async -> Loaded {
        await Task.detached(priority: .userInitiated) { () -> Loaded in
            let runs = loadRuns(project.runs)
            let store = ExplainerVersions(runs: project.runs)
            var versions: [String: [ExplainerVersion]] = [:]
            for id in runs.keys { versions[id] = store.versions(of: id, code: .latest) }
            return Loaded(queue: ExplainerQueue.load(project.queue), runs: runs, versions: versions)
        }.value
    }

    nonisolated static func syncDetached(_ project: ExplainerProject) async throws {
        try await Task.detached(priority: .utility) { () throws -> Void in try project.sync() }.value
    }

    let project: ExplainerProject?
    let renderer: ExplainerRendering?
    var env: Env
    /// Every change to the list, for the page's Show me state.
    var onChange: (([ExplainerItem]) -> Void)?

    private(set) var queue = ExplainerQueue()
    private(set) var runs: [String: ExplainerRun] = [:]
    /// Each run's saved versions, oldest first (from the renderer: read at start, then kept as it tells them).
    private(set) var versions: [String: [ExplainerVersion]] = [:]
    /// The Explainers project's id in T3, once `ensure` answered.
    private(set) var projectID: String?
    /// Requests that left the queue with no explainer, until the dock is told: shown failed for this app run.
    private(set) var dropped: [String: (ExplainerRequest, ExplainerQueue.Dropped)] = [:]
    private(set) var started = false
    /// The queue and runs were read back from disk.
    private(set) var loaded = false
    /// The preview server is up, and `.mcp.json` names it: a creator launched before would never get its tool (Claude Code
    /// reads the file once per session).
    private(set) var serving = false
    /// The project's row was in T3's shell since `ensure` answered: once it leaves, T3 lost the project and it's made again.
    private var projectSeen = false
    /// T3 has answered with its shell once since start: the queue was read against it.
    private(set) var evaluated = false
    private var ensuring = false
    private var launching: Set<String> = []
    private var finalizing: Set<String> = []
    /// Explainer threads whose `thread.settle` is on its way.
    private var settling: Set<String> = []
    private(set) var items: [ExplainerItem] = []

    init(project: ExplainerProject?, renderer: ExplainerRendering?, env: Env) {
        self.project = project; self.renderer = renderer; self.env = env
    }

    // MARK: Start

    /// Once per app run, before T3's shell arrives: hides the project, reads the queue and the runs back (off the main actor),
    /// refreshes the project's files and starts the renderer's preview server. Nothing happens without a project (a test, a
    /// demo). Nothing launches until the files are fresh and the server is up.
    func start() {
        guard let project, !started else { return }
        started = true
        // Before T3's first shell, Router on or off: Triage's lists read the shell too.
        env.hide(project.root.path)
        let load = env.load, sync = env.sync
        Task { [weak self] in
            let disk = await load(project)
            guard let self else { return }
            // A request made while the disk was read is kept after the ones read back.
            var queue = disk.queue
            for r in self.queue.requests where !queue.requests.contains(where: { $0.id == r.id }) { queue.requests.append(r) }
            self.queue = queue
            self.runs.merge(disk.runs) { now, _ in now }
            self.versions.merge(disk.versions) { now, _ in now }
            self.loaded = true
            self.env.hideThreads(Set(self.runs.keys).union(self.queue.requests.map(\.id)))
            self.publish()
            if self.env.hidden().answered { self.shell(nil) }
        }
        Task { [weak self] in
            do { try await sync(project) } catch { Self.log.error("the project's files weren't refreshed: \(String(describing: error), privacy: .public)") }
            guard let self else { return }
            if let renderer = self.renderer {
                do { try await renderer.start(project: project, host: self) } catch {
                    return Self.log.error("the preview server didn't start: \(String(describing: error), privacy: .public)")
                }
            }
            self.serving = true
            self.pump()
            self.publish()
        }
    }

    nonisolated static func loadRuns(_ folder: URL) -> [String: ExplainerRun] {
        let fm = FileManager.default
        var out: [String: ExplainerRun] = [:]
        for dir in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("run.json")),
                  let run = try? ExplainerQueue.coder.decoder.decode(ExplainerRun.self, from: data) else { continue }
            out[run.id] = run
        }
        return out
    }

    // MARK: Requests

    /// A send with Show me that T3 took (`.taken`): the explainer starts when the turn it went into ends.
    func requested(source: String, ask: String?, sentAt: Date) {
        guard started else { return }
        queue.afterTurn(source: source, ask: ask, sentAt: sentAt)
        if let r = queue.requests.last { env.hideThreads([r.id]) }
        saveQueue()
        shell(nil)
    }

    /// Show me on a Done card: an explainer of its latest reply, now.
    func requested(reply source: String) {
        guard started else { return }
        queue.now(source: source, at: env.now())
        if let r = queue.requests.last { env.hideThreads([r.id]) }
        saveQueue()
        shell(nil)
    }

    /// The owner's words for an explainer: a new version that answers them. They go as the owner's, unwrapped, into its
    /// thread (steering a run still making one); creators run in parallel, so nothing waits for another.
    func followUp(_ id: String, words: String) async throws {
        guard runs[id] != nil else { throw ThreadSendFailure("That explainer isn't Fjord's anymore") }
        try await env.dispatch(.messageDispatch(threadId: id, messageId: UUID().uuidString.lowercased(), text: words,
                                                dispatch: .startImmediately(intent: .steer)))
        // Read again: a final may have landed while T3 took the words.
        guard var run = runs[id] else { return }
        run.failed = nil
        var asks = run.versions
        if let last = asks.last, last.final == nil, last.words != nil {
            // Steered into a follow-up still being made: one version answers both.
            asks[asks.count - 1].words = (last.words ?? "") + ", " + words
        } else {
            asks.append(ExplainerRun.Ask(words: words, at: env.now().toMilliseconds))
        }
        run.asks = asks
        runs[id] = run
        save(run)
        publish()
    }

    /// The panel showed this explainer selected while the window was key.
    func watched(_ id: String) {
        guard var run = runs[id], run.unseen else { return }
        run.watchedAt = env.now().toMilliseconds
        runs[id] = run
        save(run)
        publish()
    }

    // MARK: The shell

    /// A shell item (or nil: the shell as a whole changed): turns that ended, explainers that finished, launches to make.
    func shell(_ item: T3ShellItem?) {
        guard started, loaded, project != nil else { return }
        let hidden = env.hidden()
        guard hidden.answered else { return }
        if let id = projectID {
            if hidden.projects[id] != nil { projectSeen = true } else if projectSeen {
                // T3 lost the project (deleted there): make it again rather than launch into nothing.
                projectID = nil; projectSeen = false
                ensure()
            }
        }
        if !evaluated {
            evaluated = true
            // A request whose thread exists was launched before the app last quit.
            for r in queue.requests where hidden.threads[r.id] != nil { queue.remove(r.id) }
        }
        switch item {
        case .synchronized?, .snapshot?, nil: ensure()
        default: break
        }
        let before = queue
        for (r, why) in queue.advance(shell: env.shell(), now: env.now()) { dropped[r.id] = (r, why) }
        if queue != before { saveQueue() }
        for run in runs.values {
            // Each of the thread's runs is read once, when it ends: a later change to the row (a rename, a visit) isn't one.
            guard let row = hidden.threads[run.id], row.activeRunId == nil, !row.status.isLive,
                  let done = row.latestRunId ?? row.latestRunCompletedAt?.text, run.finalizedRun != done else { continue }
            finalize(run.id, through: done)
        }
        pump()
        publish()
    }

    /// Makes sure T3 has the project (archived), once per connection, after T3 said what it holds.
    private func ensure() {
        guard projectID == nil, !ensuring, let project else { return }
        ensuring = true
        let shell = env.hidden(), mutate = env.mutate
        Task { [weak self] in
            do {
                let id = try await project.ensure(in: shell, mutate: mutate)
                self?.projectID = id
                self?.ensuring = false
                self?.pump()
                self?.publish()
            } catch {
                Self.log.error("T3 has no explainers project: \(String(describing: error), privacy: .public)")
                self?.ensuring = false
            }
        }
    }

    // MARK: Launch

    /// Every ready request starts its creator now: creators run in parallel (§13).
    private func pump() {
        guard projectID != nil, serving else { return }
        for r in queue.ready where !launching.contains(r.id) {
            launching.insert(r.id)
            Task { [weak self] in await self?.launch(r) }
        }
    }

    /// The input built from the source thread, the run written, then one `launchThread` straight to T3: not
    /// `Store.launchThread`, which refuses an archived project and puts the launch in History (§3.3).
    func launch(_ r: ExplainerRequest) async {
        defer { launching.remove(r.id) }
        guard let project, let projectID else { return }
        func fail(_ why: String) {
            queue.remove(r.id); saveQueue()
            dropped[r.id] = (r, .turnStopped)
            failures[r.id] = why
            publish()
        }
        guard let source = await env.snapshot(r.source) else { return fail("Fjord couldn't read the thread") }
        let shell = env.shell()
        // A turn that ended before the send landed, or a steer queued as the next run, isn't the one asked about: wait for
        // the next completion.
        if let ask = r.ask, !ExplainerQueue.answered(source, ask: ask) {
            queue.notYet(r.id, after: shell.threads[r.source]?.latestRunCompletedAt?.date ?? r.sentAt)
            saveQueue()
            return publish()
        }
        let projectName = shell.projects[source.thread.projectId].map { $0.title.isEmpty ? URL(fileURLWithPath: $0.workspaceRoot).lastPathComponent : $0.title } ?? "no project"
        guard let input = ExplainerInput.make(source, project: projectName, ask: r.ask, zone: env.zone, user: env.user) else {
            return fail("There's no answer to explain yet")
        }
        guard let model = await env.model(Self.model, env.hidden().projects[projectID]?.raw) else {
            return fail("T3 doesn't offer Opus 5.5")
        }
        let title = shell.threads[r.source]?.title ?? source.thread.title
        env.hideThreads([r.id])
        var run = ExplainerRun(id: r.id, ticket: Self.mintTicket(), source: r.source, sourceTitle: title, ask: r.ask,
                               askText: input.askText, createdAt: env.now().toMilliseconds)
        run.asks = [ExplainerRun.Ask(words: nil, at: run.createdAt)]
        let text = Self.message(ticket: run.ticket, input: input)
        let folder = project.runs.appendingPathComponent(r.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: folder.appendingPathComponent("input.md"), options: .atomic)
        runs[r.id] = run
        versions[r.id] = []
        save(run)
        var request = ThreadLauncher.request(thread: r.id, project: projectID, message: ThreadMessage(text: text), model: model,
                                             runtimeMode: .fullAccess, interactionMode: .default, workspace: .root)
        request.title = Self.title(input.askText)
        request.generateTitle = false
        do {
            try await env.dispatch(.launchThread(request))
            queue.remove(r.id); saveQueue()
        } catch {
            queue.remove(r.id); saveQueue()
            var failed = run
            failed.failed = "T3 didn't start it: \(error.localizedDescription)"
            runs[r.id] = failed
            save(failed)
        }
        publish()
    }

    /// Why a request failed before it had a run, for the dock (this app run only).
    private(set) var failures: [String: String] = [:]

    /// What the creator gets: its ticket on the first line, then the question, the thread and its activity.
    static func message(ticket: String, input: ExplainerInput.Input) -> String {
        "<ticket>\(ticket)</ticket>\n" + input.text
    }

    static func title(_ ask: String) -> String {
        let line = ask.split(whereSeparator: \.isNewline).first.map(String.init) ?? ask
        let short = line.count > 60 ? String(line.prefix(59)) + "…" : line
        return "Explainer: " + (short.isEmpty ? "an answer" : short)
    }

    static func mintTicket() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    // MARK: The final

    /// A run of the explainer's thread ended: its final is the last reply's code block (§2.4).
    private func finalize(_ id: String, through done: String) {
        guard !finalizing.contains(id), var run = runs[id] else { return }
        finalizing.insert(id)
        run.finalizedRun = done
        runs[id] = run
        save(run)
        Task { [weak self] in await self?.finish(id) }
    }

    func finish(_ id: String) async {
        defer { finalizing.remove(id) }
        guard var run = runs[id] else { return }
        let before = (run.final, run.draft)
        let asked = run.versions.count
        var answered: Int?
        let reply = await env.snapshot(id).flatMap(Self.lastReply)
        let saved = versions[id] ?? []
        switch ExplainerFinal.decide(lastReply: reply, versions: saved) {
        case .version(let n): run.final = n; run.draft = false; run.failed = nil; answered = n
        case .draft(let n): run.final = n; run.draft = true; run.failed = nil; answered = n
        case .failed: run.failed = "The explainer didn't finish"
        case .render(let code):
            if let renderer, let v = try? await renderer.render(code, ticket: ExplainerTicket(run: id, ask: run.askText)) {
                record(v)
                run.final = v.number; run.draft = false; run.failed = nil; answered = v.number
            } else if let good = saved.last(where: { !$0.broken }) {
                run.final = good.number; run.draft = true; run.failed = nil; answered = good.number
            } else {
                run.failed = "The explainer didn't finish"
            }
        }
        // Only a new final is news: the same one read again keeps its time (and whether it was seen).
        if run.final != nil, (run.final, run.draft) != before { run.finalAt = env.now().toMilliseconds }
        // A follow-up that ran meanwhile keeps the newer state, its words included.
        if let current = runs[id] { run.watchedAt = current.watchedAt; run.finalizedRun = current.finalizedRun; run.asks = current.asks }
        // The newest ask when the run ended is this run's: a final newer than the versions before answers it; with nothing
        // new (no code, or an older version's) the ask goes. An ask before it that never got one goes too; one made since (a
        // follow-up while this was read) stays, still to answer.
        var asks = run.versions
        if asked > 0, asked <= asks.count {
            let i = asked - 1
            let floor = asks[..<i].compactMap(\.final).max() ?? 0
            if let answered, answered > floor { asks[i].final = answered } else { asks[i].final = -1 }
            run.asks = asks.enumerated().filter { $0.element.final.map { $0 > 0 } ?? ($0.offset > i) }.map(\.element)
        }
        runs[id] = run
        save(run)
        publish()
        await settleThread(id)
    }

    /// A finalized explainer's thread is settled in T3: it's Fjord's own, done, and nothing in it needs the owner. Only once:
    /// a thread T3 already has settled, or one a follow-up has running again (its next finalize settles it), is left as it is.
    func settleThread(_ id: String) async {
        guard let row = env.hidden().threads[id], row.settledAt == nil, row.activeRunId == nil, !row.status.isLive,
              settling.insert(id).inserted else { return }
        defer { settling.remove(id) }
        do {
            try await env.dispatch(.threadSettle(threadId: id))
        } catch {
            Self.log.error("Couldn't settle explainer \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The reply of the thread's latest run: the agent's last message after the last of yours. A follow-up that stopped
    /// before replying has none, so an earlier reply's code isn't taken for its final.
    static func lastReply(_ p: T3Projection) -> String? {
        let messages = p.messages.enumerated().sorted {
            ($0.element.createdAt?.date ?? .distantPast, $0.offset) < ($1.element.createdAt?.date ?? .distantPast, $1.offset)
        }.map(\.element)
        let after = messages.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
        return messages[after...].last { $0.role == "assistant" }?.text
    }

    // MARK: The renderer's host

    func ticket(_ ticket: String) -> ExplainerTicket? {
        guard let run = runs.values.first(where: { $0.ticket == ticket }) else { return nil }
        return ExplainerTicket(run: run.id, ask: run.askText)
    }

    func versionSaved(_ version: ExplainerVersion) {
        record(version)
        publish()
    }

    private func record(_ v: ExplainerVersion) {
        var list = versions[v.run] ?? []
        list.removeAll { $0.number == v.number }
        list.append(v)
        list.sort { $0.number < $1.number }
        versions[v.run] = list
    }

    // MARK: The dock's list

    /// The newest `listed` explainers: queued requests, the runs, and requests that stopped this app run.
    func list() -> [ExplainerItem] {
        let shell = env.shell(), hidden = env.hidden()
        var out: [ExplainerItem] = []
        // A request being launched is a run already: it's listed once, as the run.
        for r in queue.requests where runs[r.id] == nil {
            out.append(ExplainerItem(id: r.id, title: "Show me", thread: shell.threads[r.source]?.title ?? "", source: r.source,
                                     answer: "", captions: [], since: r.sentAt, stage: .queued, length: 0))
        }
        for (r, why) in dropped.values where runs[r.id] == nil {
            let reason = failures[r.id] ?? {
                switch why {
                case .turnStopped: "Its turn stopped"
                case .threadGone: "Its thread is gone"
                case .expired: "It waited over a day"
                }
            }()
            out.append(ExplainerItem(id: r.id, title: "Show me", thread: shell.threads[r.source]?.title ?? "", source: r.source,
                                     answer: "", captions: [], since: r.sentAt, stage: .failed(reason), length: 0))
        }
        for run in runs.values {
            let saved = versions[run.id] ?? []
            let shown = run.final.flatMap { n in saved.first { $0.number == n } } ?? saved.last
            let live = hidden.threads[run.id].map { $0.activeRunId != nil || $0.status.isLive } ?? false
            let stage: ExplainerItem.Stage
            if live || (run.final == nil && run.failed == nil) {
                stage = .making(draft: saved.last?.number ?? 0, fixing: saved.last?.note ?? "")
            } else if let failed = run.failed, run.final == nil {
                stage = .failed(failed)
            } else {
                stage = .ready
            }
            out.append(ExplainerItem(id: run.id, title: shown?.title ?? run.askText, thread: run.sourceTitle, source: run.source,
                                     answer: shown?.answer ?? "", captions: shown?.captions ?? [], since: run.createdAt,
                                     stage: stage, length: Int((shown?.length ?? 0).rounded()), page: shown?.page,
                                     posterLight: shown?.posterLight, posterDark: shown?.posterDark, draft: run.draft,
                                     unseen: run.unseen, launched: true,
                                     versions: Self.versions(run, saved: saved, live: live)))
        }
        return Array(out.sorted { ($0.since, $0.id) > ($1.since, $1.id) }.prefix(Self.listed))
    }

    /// What was asked of a run, each its final's film; the newest, while its run is live, its latest draft (or nothing yet).
    /// An ask that ended with no final isn't listed.
    static func versions(_ run: ExplainerRun, saved: [ExplainerVersion], live: Bool) -> [ExplainerItem.Version] {
        let asks = run.versions
        return asks.enumerated().compactMap { i, ask in
            let newest = i == asks.count - 1
            // From the send on: T3's row turns live a moment later. A run that ended with nothing new fails it.
            let making = newest && ask.final == nil && (live || run.failed == nil)
            let film: ExplainerVersion?
            if let n = ask.final {
                film = saved.first { $0.number == n }
            } else if making {
                // The drafts saved since the version before: the newest of them.
                let floor = asks[..<i].compactMap(\.final).max() ?? 0
                film = saved.last { $0.number > floor }
            } else {
                return nil
            }
            return ExplainerItem.Version(label: ask.words ?? ExplainerItem.original, at: ask.at, making: making,
                                         answer: film?.answer ?? "", captions: film?.captions ?? [],
                                         length: Int((film?.length ?? 0).rounded()), page: film?.page,
                                         posterLight: film?.posterLight, posterDark: film?.posterDark)
        }
    }

    /// T3 has the project: Show me can be asked for (the page's toggle and dock show only then).
    var ready: Bool { projectID != nil && serving }
    private var publishedReady = false

    private func publish() {
        let next = list()
        guard next != items || ready != publishedReady else { return }
        items = next
        publishedReady = ready
        onChange?(next)
    }

    // MARK: Disk

    private func saveQueue() {
        guard let project else { return }
        do { try queue.save(project.queue) } catch { Self.log.error("the queue wasn't saved: \(String(describing: error), privacy: .public)") }
    }

    private func save(_ run: ExplainerRun) {
        guard let project else { return }
        let folder = project.runs.appendingPathComponent(run.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ExplainerQueue.coder.encoder.encode(run).write(to: folder.appendingPathComponent("run.json"), options: .atomic)
        } catch { Self.log.error("run \(run.id, privacy: .public) wasn't saved: \(String(describing: error), privacy: .public)") }
    }
}

extension ExplainerEngine {
    /// The app's engine: the project in Fjord's support folder (none in a test or a demo), T3 through the store.
    static func live(_ store: Store, renderer: ExplainerRendering? = nil) -> ExplainerEngine {
        let project = (UnderTest.isRunning || Store.isDemo) ? nil : ExplainerProject.at(support: store.routerFiles?.support)
        let env = Env(
            hidden: { [weak store] in store?.t3.store.hidden ?? T3ShellState() },
            shell: { [weak store] in store?.t3.store.shell ?? T3ShellState() },
            hide: { [weak store] root in store?.t3.store.hiddenRoot = root },
            snapshot: { [weak store] id in await store?.t3.store.readSnapshot(id) },
            model: { [weak store] slug, project in
                guard let store else { return nil }
                let config = try? await store.launchSupport.config()
                return ThreadLauncher.model(slug: slug, project: project, config: config, siblings: [])
            },
            dispatch: { [weak store] command in
                guard let store else { throw ThreadLaunchFailure("Fjord is closing") }
                try await store.dispatch(command)
            },
            mutate: { body in try await ExplainerProject.liveMutate(body) },
            hideThreads: { [weak store] ids in store?.t3.store.hide(threads: ids) })
        return ExplainerEngine(project: project, renderer: renderer, env: env)
    }
}
