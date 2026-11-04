import AppKit
import Foundation
import Observation

// A message or a tool for a claude.ai project goes to the Swift delivery engine (`CourierHost`), not through a session:
// the dispatcher hands it over here, and its pill over the composer follows the engine's updates (docs/design/
// router-swift-port.md, "The seam"). The pill says only what the engine said: its causes are plain sentences, shown as
// they are. Nothing routes here until `enabled`, once the fuzz gate is green.

enum RouterCourier {
    /// The dispatcher hands claude.ai targets to the engine. Off: no target is one, and local targets go as they always went.
    static let enabled = false

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

    /// Why a paused intent waits, as the engine words it (`CourierDo.blocked`, `appClosed`), and the one thing that lets it go
    /// on. Matched on the engine's own sentences, never on words in them: a cause it doesn't list gets no button.
    enum Pause: Equatable {
        case chromeNotRunning, chromeNotConnected, signedOut, tabAway, pageUnreadable, claudeApp

        init?(_ cause: String?) {
            guard let cause else { return nil }
            switch cause {
            case "Chrome isn't running": self = .chromeNotRunning
            case CourierDo.chromeOpen: self = .chromeNotConnected
            case "signed out of claude.ai": self = .signedOut
            case "Fjord's tab has left the Claude Code page": self = .tabAway
            case "the page can't be read": self = .pageUnreadable
            default:
                // The engine starts the app's wait with this and may say more after it (`CourierCore.recheckPauses`).
                guard cause.hasPrefix(CourierDo.appClosed) else { return nil }
                self = .claudeApp
            }
        }

        var action: RouterCourierPills.Action {
            switch self {
            case .chromeNotRunning, .chromeNotConnected: .openChrome
            case .signedOut: .signIn
            case .tabAway, .pageUnreadable: .openTab
            case .claudeApp: .showClaudeApp
            }
        }
    }
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
        /// You acted on it (Allow, Revert) and the engine hasn't said yet: it shows as under way at once.
        var acting = false
    }

    enum Action: Equatable {
        case signIn, openChrome, showClaudeApp, openTab, allow, revert

        var label: String {
            switch self {
            case .signIn: "Sign in"
            case .openChrome: "Open Chrome"
            case .showClaudeApp: "Show the Claude app"
            case .openTab: "Open Fjord's tab"
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
        case .signIn, .openChrome, .showClaudeApp, .openTab:
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
        case .allow, .revert:
            return
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
                        action: RouterCourier.Pause(item.cause)?.action, dismissible: false, settles: false)
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
                        action: RouterCourier.Pause(item.cause)?.action, dismissible: false, settles: false)
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
        guard RouterCourier.enabled, let store, let courier = RouterCourier.Target(target) else { return nil }
        Task { await store.routerCourier.send(job.text, to: courier) }
        store.updateDecision(job.id) {
            $0.add(.sent(to: RouterCourierPills.place(courier.project, courier.thread), text: job.text, original: nil))
            $0.outcome = .done
        }
        return courier
    }
}
