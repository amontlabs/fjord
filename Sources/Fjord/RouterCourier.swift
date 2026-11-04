import AppKit
import Foundation
import Observation

// A message or a tool for a claude.ai project goes to the Swift delivery engine (`CourierHost`), not through a session:
// the dispatcher hands it over here, and its pill over the composer follows the engine's updates (docs/design/
// router-swift-port.md, "The seam"). The pill says only what the engine said: its causes are plain sentences, shown as
// they are. Nothing routes here until `enabled`, once the fuzz gate is green.

enum RouterCourier {
    /// The dispatcher hands claude.ai targets to the engine. Off: no target is one, and local targets go as they always went.
    /// Flipping this is the only change the code needs; a live run turns it on without it (`on`).
    static let enabled = false

    /// The hidden switch: `--courier` at launch, or `defaults write <Fjord's bundle id> routerCourier -bool YES`. Never under
    /// a test or in a demo, whatever the defaults say.
    static let flag = "--courier"
    static let defaultsKey = "routerCourier"

    /// Whether the engine runs and claude.ai places are targets: `enabled`, or the hidden switch.
    static var on: Bool { override ?? (enabled || (!UnderTest.isRunning && !Store.isDemo && hiddenSwitch)) }

    /// A test turns it on for itself.
    nonisolated(unsafe) static var override: Bool?

    /// The claude.ai places the dispatcher offers: the engine's Board as last shared, while it is on.
    @MainActor static func places(_ store: Store) -> [CourierPlace] {
        on ? store.routerCourierLink.places : []
    }

    /// Whether a claude.ai target can be sent to now: the engine is on and the Board has its project (and thread).
    @MainActor static func eligible(_ target: Target, store: Store) -> Bool {
        guard on else { return false }
        let link = store.routerCourierLink
        return target.thread == nil ? link.place(target) != nil : link.thread(target) != nil
    }

    /// A claude.ai target as a button: the project's name, or the thread's title in its project.
    @MainActor static func option(_ target: Target, store: Store) -> RouterAskBack.Option? {
        guard eligible(target, store: store) else { return nil }
        let link = store.routerCourierLink
        if let thread = link.thread(target) {
            return .init(target: target.targetID, title: thread.title.isEmpty ? "Untitled thread" : RouterPointers.inert(thread.title, 60),
                         detail: "claude.ai · \(target.project)")
        }
        return .init(target: target.targetID, title: target.project, detail: "claude.ai project")
    }

    private static let hiddenSwitch = CommandLine.arguments.contains(flag) || UserDefaults.standard.bool(forKey: defaultsKey)

    /// A claude.ai place, as a target id: `claude-project:<project>` or `claude-thread:<project>/<thread>` (a thread id has no
    /// slash; a project's name may).
    enum Target: Equatable {
        case project(String)
        case thread(project: String, thread: String)

        init?(_ targetID: String) {
            if targetID.hasPrefix("claude-project:") {
                let project = String(targetID.dropFirst("claude-project:".count))
                guard !project.isEmpty else { return nil }
                self = .project(project)
            } else if targetID.hasPrefix("claude-thread:") {
                let rest = targetID.dropFirst("claude-thread:".count)
                guard let slash = rest.lastIndex(of: "/"), slash != rest.startIndex, rest.index(after: slash) != rest.endIndex else { return nil }
                self = .thread(project: String(rest[..<slash]), thread: String(rest[rest.index(after: slash)...]))
            } else {
                return nil
            }
        }

        var targetID: String {
            switch self {
            case .project(let p): "claude-project:\(p)"
            case .thread(let p, let t): "claude-thread:\(p)/\(t)"
            }
        }

        var project: String {
            switch self {
            case .project(let p), .thread(let p, _): p
            }
        }

        var thread: String? { if case .thread(_, let t) = self { t } else { nil } }
    }

    /// The one thing that lets a paused intent go on, by the engine's code for why it waits (`CourierUpdate.pause`): never read
    /// from its sentence. A pause with no code (a restart's) gets no button.
    static func action(_ pause: CourierPause?) -> RouterCourierPills.Action? {
        switch pause {
        case .chromeClosed: .openChrome
        // Chrome runs but the tab doesn't link (the extension off, the native host not registered, another profile): the
        // setup's checks say which.
        case .chromeNotConnected: .openSetup
        case .signedOut: .signIn
        case .away, .tabUnreadable: .openTab
        case .appClosed: .showClaudeApp
        case nil: nil
        }
    }
}

/// The engine in the app: started at launch while `RouterCourier.on` (never in a demo or a test), its updates fed to the pills,
/// its Board's health and places kept here on the main actor for the setup and the dispatcher, stopped on quit.
@MainActor final class RouterCourierLink: RouterCourierSetupHost {
    private(set) var host: CourierHost?
    /// The Board as last shared: what the dispatcher offers Jev and how the setup reads the page.
    private(set) var snapshot = CourierSnapshot()
    private var following: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<CourierSetupHealth>.Continuation] = [:]
    /// Called when the places change (the dispatcher's targets are read again).
    var placesChanged: () -> Void = {}

    lazy var setup = RouterCourierSetup(host: self)

    var places: [CourierPlace] { snapshot.places }
    var running: Bool { host != nil }

    /// Starts `host` (the app's socket and database by default) and feeds `pills` from it. A failure (another routerd on the
    /// socket, say) is logged, and nothing routes to claude.ai.
    func start(pills: RouterCourierPills, host: CourierHost = CourierHost()) async {
        guard self.host == nil else { return }
        do {
            try await host.start()
        } catch {
            FileHandle.standardError.write(Data("routerd didn't start: \(error)\n".utf8))
            return
        }
        self.host = host
        pills.attach(.host(host))
        let snapshots = host.snapshots
        following = Task { [weak self] in
            for await next in snapshots {
                guard let self else { return }
                self.take(next)
            }
        }
    }

    /// Stops the host: the socket file goes, the database is closed.
    func stop() async {
        following?.cancel(); following = nil
        let host = self.host
        self.host = nil
        await host?.stop()
    }

    /// A snapshot taken in (the host's, or a test's).
    func take(_ next: CourierSnapshot) {
        let moved = next.places != snapshot.places
        snapshot = next
        for w in watchers.values { w.yield(next.health) }
        if moved { placesChanged() }
    }

    /// The project a target names, on the Board as last shared: by name, else by id.
    func place(_ target: RouterCourier.Target) -> CourierPlace? {
        places.first { $0.name == target.project } ?? places.first { $0.id == target.project }
    }

    func thread(_ target: RouterCourier.Target) -> CourierPlace.Thread? {
        guard let id = target.thread else { return nil }
        return place(target)?.threads.first { $0.id == id }
    }

    // MARK: The setup's hooks

    var healthUpdates: AsyncStream<CourierSetupHealth> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(snapshot.health)
            watchers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.watchers[id] = nil } }
        }
    }

    func openTab() { RouterCourierPills.openOutside(.openTab) }
    func openSignIn() { RouterCourierPills.openOutside(.signIn) }
}

/// The engine as the pills see it: what they submit and the updates they follow. The app's is the host's; shots and tests
/// give a fake one.
struct RouterCourierSource {
    var submit: @MainActor (CourierRequest) async -> Int
    var updates: AsyncStream<CourierUpdate>

    static func host(_ host: CourierHost) -> RouterCourierSource {
        RouterCourierSource(submit: { await host.submit($0) }, updates: host.updates)
    }

    /// A fake engine: each request gets the next id and the updates `script` gives for it, `delay` apart (none: all at once).
    /// Its sink lets a test push updates by hand.
    static func fake(script: @escaping (Int, CourierRequest) -> [(CourierState, String?, JSON?)] = { _, _ in [] },
                     delay: Duration? = nil) -> (source: RouterCourierSource, sink: AsyncStream<CourierUpdate>.Continuation) {
        var sink: AsyncStream<CourierUpdate>.Continuation!
        let updates = AsyncStream<CourierUpdate>(bufferingPolicy: .unbounded) { sink = $0 }
        let out = sink!
        var next = 0
        let source = RouterCourierSource(submit: { request in
            next += 1
            let id = next
            let steps = script(id, request)
            if let delay {
                Task {
                    for (state, cause, before) in steps {
                        try? await Task.sleep(for: delay)
                        out.yield(CourierUpdate(intentID: id, state: state, cause: cause, before: before, at: Date()))
                    }
                }
            } else {
                for (state, cause, before) in steps { out.yield(CourierUpdate(intentID: id, state: state, cause: cause, before: before, at: Date())) }
            }
            return id
        }, updates: updates)
        return (source, out)
    }
}

/// The engine's intents over the composer, a pill each, newest nearest the composer. A delivery settles quietly once it's
/// proved; what needs you (a cause, a pause, a grant) stays until it changes or you dismiss it; a change that can be taken
/// back stays with its Revert until you dismiss it or send your next message.
@Observable @MainActor final class RouterCourierPills {
    struct Item: Identifiable, Equatable {
        enum Work: Equatable {
            case send(words: String, project: String, thread: String?)
            /// `reverts`: a Revert's tool, setting back what another one changed.
            case tool(CourierTool, args: [String: JSON], reverts: Bool = false)
        }
        let id: Int
        var work: Work
        var state: CourierState
        var cause: String?
        var before: JSON?
        var at: Date
        /// Why it waits, while it is paused (the engine's code).
        var pause: CourierPause? = nil
        /// You acted on it (Allow, Revert) and the engine hasn't said yet: it shows as under way at once.
        var acting = false
    }

    enum Action: Equatable {
        case signIn, openChrome, showClaudeApp, openTab, openSetup, allow, revert

        var label: String {
            switch self {
            case .signIn: "Sign in"
            case .openChrome: "Open Chrome"
            case .showClaudeApp: "Show the Claude app"
            case .openTab: "Open Fjord's tab"
            case .openSetup: "Check the setup"
            case .allow: "Allow"
            case .revert: "Revert"
            }
        }
    }

    /// What a pill shows: the mark, its words, what it says after them, the engine's cause under them, its one button.
    struct Face: Equatable {
        enum Mark: Equatable { case working, done, quiet, warning, paused, asks }
        var mark: Mark
        var words: String
        var status: String
        /// The engine's sentence, as it said it, on a line of its own.
        var note: String?
        var action: Action?
        /// It may be waved off (×).
        var dismissible: Bool
        /// It leaves by itself a moment after it is shown.
        var settles: Bool
    }

    private(set) var items: [Item] = []
    /// What each intent was, kept after its pill went: a delivery proved late shows again.
    @ObservationIgnored private var works: [Int: Item.Work] = [:]
    /// Updates for intents not yet tracked: the engine may say before `submit` has returned.
    @ObservationIgnored private var early: [Int: CourierUpdate] = [:]
    @ObservationIgnored private var source: RouterCourierSource?
    @ObservationIgnored private var following: Task<Void, Never>?
    /// How long a settled pill stays; nil keeps it (a shot, a test).
    @ObservationIgnored var settleAfter: Duration? = RouterFlights.confirmation
    /// What the pause buttons open outside Fjord; a test records them.
    @ObservationIgnored var open: (Action) -> Void = RouterCourierPills.openOutside

    /// Follows `source`'s updates from now on.
    func attach(_ source: RouterCourierSource) {
        self.source = source
        following?.cancel()
        let updates = source.updates
        following = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.apply(update)
            }
        }
    }

    // MARK: Sending

    /// Hands your words for a claude.ai place to the engine; its pill shows at once.
    @discardableResult
    func send(_ words: String, to target: RouterCourier.Target) async -> Int {
        await submit(.send(words: words, project: target.project, thread: target.thread),
                     work: .send(words: words, project: target.project, thread: target.thread))
    }

    /// One of the Router's tools for claude.ai.
    @discardableResult
    func tool(_ name: CourierTool, args: [String: JSON]) async -> Int {
        await submit(.tool(name: name, args: args), work: .tool(name, args: args))
    }

    private func submit(_ request: CourierRequest, work: Item.Work, replacing old: Int? = nil) async -> Int {
        guard let source else { return 0 }
        let id = await source.submit(request)
        guard id > 0 else {
            if let old, let i = items.firstIndex(where: { $0.id == old }) { items[i].acting = false }
            return 0
        }
        track(id, work, replacing: old)
        return id
    }

    /// The intent `id` is `work`: its pill comes in (in `old`'s place, for a Revert), with what the engine already said.
    func track(_ id: Int, _ work: Item.Work, replacing old: Int? = nil) {
        works[id] = work
        // Your next message: the changes still offering Revert have been seen.
        if old == nil { items.removeAll { $0.id != id && Self.face($0).action == .revert } }
        let item = Item(id: id, work: work, state: .sending, cause: nil, before: nil, at: Date())
        if let old, let i = items.firstIndex(where: { $0.id == old }) { items[i] = item } else if !items.contains(where: { $0.id == id }) { items.append(item) }
        if let update = early.removeValue(forKey: id) { apply(update) }
    }

    // MARK: Following the engine

    func apply(_ update: CourierUpdate) {
        guard let work = works[update.intentID] else {
            early[update.intentID] = update
            return
        }
        var item = items.first { $0.id == update.intentID } ?? Item(id: update.intentID, work: work, state: update.state, at: update.at)
        // A pill waved off comes back only to say a send went after all.
        let shown = items.contains { $0.id == update.intentID }
        guard shown || update.state == .deliveredLate else { return }
        item.state = update.state
        item.cause = update.cause
        item.pause = update.state == .paused ? update.pause : nil
        item.before = update.before ?? item.before
        item.at = update.at
        item.acting = false
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        if Self.face(item).settles { settle(item.id, state: item.state) }
    }

    private func settle(_ id: Int, state: CourierState) {
        guard let settleAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(for: settleAfter)
            guard let self, let item = self.items.first(where: { $0.id == id }), item.state == state else { return }
            self.dismiss(id)
        }
    }

    // MARK: Acting

    func dismiss(_ id: Int) { items.removeAll { $0.id == id } }

    /// The pill's button: a grant allowed, a change taken back, or what lets a paused intent go on.
    func perform(_ action: Action, on id: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .allow:
            items[i].acting = true
            Task { _ = await self.source?.submit(.confirm(intentID: id)) }
        case .revert:
            guard let request = Self.revert(items[i]), case .tool(let name, let args) = request else { return }
            items[i].acting = true
            Task { await self.submit(request, work: .tool(name, args: args, reverts: true), replacing: id) }
        case .signIn, .openChrome, .showClaudeApp, .openTab, .openSetup:
            open(action)
        }
    }

    /// Return with nothing typed: the newest grant waiting is allowed. False when none waits.
    func allowNewest() -> Bool {
        guard let item = items.last(where: { $0.state == .awaiting && !$0.acting }) else { return false }
        perform(.allow, on: item.id)
        return true
    }

    /// The tool that sets back what `item` changed: only a setting whose old value the engine kept.
    static func revert(_ item: Item) -> CourierRequest? {
        guard item.state == .toolDone, item.cause == nil, case .tool(let name, let args, _) = item.work,
              name == .setGoal || name == .setInstructions, let before = item.before?.asString, let project = args["project"] else { return nil }
        return .tool(name: name, args: ["project": project, "text": .string(before)])
    }

    static func openOutside(_ action: Action) {
        let chrome = "com.google.Chrome"
        switch action {
        case .openChrome:
            guard !UnderTest.refuses("Chrome"), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome) else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        case .signIn, .openTab:
            guard !UnderTest.refuses("Chrome"), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome),
                  let url = URL(string: action == .signIn ? "https://claude.ai/login" : "https://claude.ai/code") else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .showClaudeApp:
            guard !UnderTest.refuses("the Claude app"), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Claude.bundleID) else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        case .openSetup, .allow, .revert:
            return  // the setup is in Fjord's Settings: the app's `open` shows it
        }
    }

    // MARK: Faces

    /// "lcu" or "lcu · Fix the login".
    static func place(_ project: String, _ thread: String?) -> String {
        thread.map { "\(project) · \($0)" } ?? project
    }

    static func face(_ item: Item) -> Face {
        switch item.work {
        case .send(let words, let project, let thread): sendFace(item, words: words, to: place(project, thread))
        case .tool(let name, let args, let reverts): toolFace(item, name, args, reverts: reverts)
        }
    }

    private static func sendFace(_ item: Item, words: String, to place: String) -> Face {
        switch item.state {
        case .sending, .taken:
            return Face(mark: .working, words: words, status: "Sending to \(place)", dismissible: false, settles: false)
        case .delivered, .toolDone:
            return Face(mark: .done, words: words, status: "Delivered to \(place)", dismissible: false, settles: true)
        case .deliveredLate:
            return Face(mark: .done, words: words, status: "Delivered to \(place) after all", dismissible: true, settles: true)
        case .failed, .refused, .toolUnconfirmed:
            return Face(mark: .warning, words: words, status: "Not delivered to \(place)", note: item.cause, dismissible: true, settles: false)
        case .paused:
            return Face(mark: .paused, words: words, status: "Waiting to send to \(place)", note: item.cause,
                        action: RouterCourier.action(item.pause), dismissible: false, settles: false)
        case .awaiting:
            return Face(mark: .asks, words: words, status: "Waiting for you", note: item.cause, dismissible: true, settles: false)
        }
    }

    private static func toolFace(_ item: Item, _ name: CourierTool, _ args: [String: JSON], reverts: Bool) -> Face {
        let words = Words(name, args)
        switch item.state {
        case .sending, .taken:
            return Face(mark: .working, words: item.acting ? words.doing : words.asked, status: "on claude.ai", dismissible: false, settles: false)
        case .toolDone, .delivered, .deliveredLate:
            // Said with a cause, it wasn't a plain change ("it was already so"): the cause says what it was.
            if let cause = item.cause {
                return Face(mark: .quiet, words: words.subject, status: cause, dismissible: false, settles: true)
            }
            let revert = revert(item) != nil
            return Face(mark: .done, words: reverts ? words.setBack : words.done, status: "",
                        action: revert ? .revert : nil, dismissible: revert, settles: !revert)
        case .toolUnconfirmed:
            return Face(mark: .warning, words: words.done, status: "done, not confirmed", note: item.cause, dismissible: true, settles: false)
        case .refused, .failed:
            return Face(mark: .warning, words: words.asked, status: "Not done", note: item.cause, dismissible: true, settles: false)
        case .paused:
            return Face(mark: .paused, words: words.asked, status: "Waiting", note: item.cause,
                        action: RouterCourier.action(item.pause), dismissible: false, settles: false)
        case .awaiting:
            return Face(mark: item.acting ? .working : .asks, words: words.asked, status: item.acting ? "Allowing…" : "",
                        note: item.cause, action: item.acting ? nil : .allow, dismissible: !item.acting, settles: false)
        }
    }

    /// A tool's words: asked for, under way, done, set back, and what it is about.
    struct Words {
        var asked: String, doing: String, done: String, setBack: String, subject: String

        init(_ name: CourierTool, _ args: [String: JSON]) {
            let project = args["project"]?.asString ?? "", text = { (key: String) in args[key]?.asString ?? "" }
            switch name {
            case .createProject:
                let n = text("name")
                (asked, doing, done, setBack, subject) = ("Create the project \(n)", "Creating \(n)…", "Project \(n) created", "Project \(n) created", "The project \(n)")
            case .setGoal:
                (asked, doing, done, setBack, subject) = ("Set the goal of \(project)", "Setting the goal…", "Goal set for \(project)",
                                                          "Goal set back for \(project)", "The goal of \(project)")
            case .setInstructions:
                (asked, doing, done, setBack, subject) = ("Set the instructions of \(project)", "Setting the instructions…",
                                                          "Instructions set for \(project)", "Instructions set back for \(project)",
                                                          "The instructions of \(project)")
            case .addRepo:
                let r = text("repo")
                (asked, doing, done, setBack, subject) = ("Add \(r) to \(project)", "Adding \(r)…", "\(r) added to \(project)",
                                                          "\(r) added to \(project)", "\(r) in \(project)")
            case .preapproveFolder:
                let p = text("path")
                (asked, doing, done, setBack, subject) = ("Let \(project) use \(p)", "Allowing \(p)…", "\(project) may use \(p)",
                                                          "\(project) may use \(p)", "\(p) for \(project)")
            }
        }
    }
}

// MARK: - The dispatcher's handoff

extension RouterDispatcher {
    /// A claude.ai target goes to the engine, its pill over the composer taking over from the message's own. Nil: the target is
    /// not one (or the handoff is off), and it goes as it always went.
    func courierHandoff(_ job: Job, to target: String) -> RouterCourier.Target? {
        guard RouterCourier.on, let store, let courier = RouterCourier.Target(target) else { return nil }
        // The pills that address it at the start of your words aren't part of them (the reply path drops them so too).
        let words = Self.courierWords(job.text, pills: job.context.pills)
        Task { await store.routerCourier.send(words, to: courier) }
        store.updateDecision(job.id) {
            // The target the flights read to leave the message's pill to the engine's (`RouterFlights.handedToCourier`).
            $0.decision.targetID = courier.targetID
            $0.add(.sent(to: RouterCourierPills.place(courier.project, courier.thread), text: words, original: words == job.text ? nil : job.text))
            $0.outcome = .done
        }
        return courier
    }

    /// Your words without the address pills they start with; as they are when nothing is left.
    nonisolated static func courierWords(_ text: String, pills: [Range<Int>]) -> String {
        let rest = (Addressing.withoutLeadingPills(text, pills) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? text : rest
    }
}
