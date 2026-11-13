import Foundation

// Starting new work in T3 (docs/design/t3-port-plan.md, step 11): one `orchestration.launchThread`, no clicks.
//
// `modelSelection`, `runtimeMode`, `interactionMode` and `workspaceStrategy` are required by T3 (OV2:3632); the title, the
// branch and the message are not. The settings are what the Router row's chips (or its `@` pills) set from T3's own lists
// (`RouterLaunchCatalog`, docs/design/router-v2/DESIGN.md 1.9.1); with none given, T3's own default: the project's, else the
// server's (`server.getConfig` settings), else what the project's latest thread ran, else the first ready provider's first model.
// A worktree branch is left out: T3 names it temporarily and renames it from the first message (`ThreadLaunchService`).

/// The provider instance and model a new thread runs on.
struct ThreadLaunchModel: Equatable, Sendable {
    var instanceId: String
    var model: String

    init(instanceId: String, model: String) {
        self.instanceId = instanceId
        self.model = model
    }

    /// A `ModelSelection` (`{instanceId, model}`); nil when it names neither.
    init?(json: T3JSON?) {
        guard let json, let instance = json.str("instanceId"), let model = json.str("model"), !instance.isEmpty, !model.isEmpty else { return nil }
        self.init(instanceId: instance, model: model)
    }
}

/// Where the thread works.
enum ThreadLaunchWorkspace: Equatable, Sendable {
    /// The project's own checkout: for your own messages.
    case root
    /// A worktree of its own off `baseRef`, so unattended work can't collide with your checkout.
    case worktree(baseRef: String)

    var json: T3JSON {
        switch self {
        case .root: ["type": "root"]
        case .worktree(let baseRef): ["type": "worktree", "baseRef": .string(baseRef)]
        }
    }
}

/// What a new thread starts with besides its words, as the Router v2 row showed it (T3's own names and lists).
struct ThreadLaunchSettings: Equatable, Sendable {
    /// T3's model slug; its provider instance is read from the server's config.
    var model: String
    /// The reasoning effort, sent as `modelSelection.options`; nil sends none (the model's default).
    var effort: String?
    var runtimeMode: T3RuntimeMode
    var interactionMode: T3InteractionMode = .default
}

enum ThreadLauncher {
    /// The title the thread starts with; T3 writes the real one from the message (`generateTitle`).
    static func provisionalTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "New thread" }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// The model a new thread in `project` runs on, in the order the header says. `config`: `server.getConfig`'s answer.
    /// `siblings`: the project's threads, latest first.
    static func model(project: T3JSON?, config: T3JSON?, siblings: [T3ThreadShell]) -> ThreadLaunchModel? {
        if let m = ThreadLaunchModel(json: project?["defaultModelSelection"]) { return m }
        if let m = ThreadLaunchModel(json: config?["settings"]?["defaultModelSelection"]) { return m }
        if let t = siblings.first(where: { $0.model != nil && !$0.providerInstanceId.isEmpty }), let model = t.model {
            return ThreadLaunchModel(instanceId: t.providerInstanceId, model: model)
        }
        for provider in config?["providers"]?.array ?? [] where provider.str("status") == "ready" && provider["enabled"]?.bool != false {
            if let instance = provider.str("instanceId"), let model = provider["models"]?.array?.first?.str("slug") ?? provider["models"]?.array?.first?.str("id") {
                return ThreadLaunchModel(instanceId: instance, model: model)
            }
        }
        return nil
    }

    /// The provider instance that runs a model somebody chose by its slug: the project's or the server's default selection
    /// when it names that model, else the first ready provider that lists it, else a sibling thread that ran it.
    static func model(slug: String, project: T3JSON?, config: T3JSON?, siblings: [T3ThreadShell]) -> ThreadLaunchModel? {
        for selection in [project?["defaultModelSelection"], config?["settings"]?["defaultModelSelection"]] {
            if let m = ThreadLaunchModel(json: selection), m.model == slug { return m }
        }
        for provider in config?["providers"]?.array ?? [] where provider.str("status") == "ready" && provider["enabled"]?.bool != false {
            guard let instance = provider.str("instanceId"),
                  provider["models"]?.array?.contains(where: { $0.str("slug") == slug || $0.str("id") == slug }) == true else { continue }
            return ThreadLaunchModel(instanceId: instance, model: slug)
        }
        if let t = siblings.first(where: { $0.model == slug && !$0.providerInstanceId.isEmpty }) {
            return ThreadLaunchModel(instanceId: t.providerInstanceId, model: slug)
        }
        return nil
    }

    /// What an unattended launch may do: the action's choice, else T3's default.
    static func runtimeMode(asked: String?, config: T3JSON?) -> T3RuntimeMode {
        if let asked, !asked.isEmpty { return T3RuntimeMode(rawValue: asked) }
        if let d = config?["settings"]?.str("defaultRuntimeMode"), !d.isEmpty { return T3RuntimeMode(rawValue: d) }
        return .fullAccess
    }

    /// The command for a launch. A worktree only when nobody is there to see it (`unattended`).
    static func request(thread: String, project: String, message: ThreadMessage, model: ThreadLaunchModel, runtimeMode: T3RuntimeMode,
                        interactionMode: T3InteractionMode = .default, options: [T3ModelOption] = [],
                        workspace: ThreadLaunchWorkspace) -> T3LaunchRequest {
        T3LaunchRequest(threadId: thread, projectId: project, title: provisionalTitle(message.text), generateTitle: true,
                        instanceId: model.instanceId, model: model.model, runtimeMode: runtimeMode, interactionMode: interactionMode,
                        options: options, workspaceStrategy: workspace.json, messageId: message.messageID, text: message.text, context: message.records)
    }

    /// The workspace for a launch: unattended work never touches your checkout.
    static func workspace(unattended: Bool, baseRef: String) -> ThreadLaunchWorkspace {
        unattended ? .worktree(baseRef: baseRef) : .root
    }

    /// The `ProjectMutation` that makes a T3 project of a folder.
    static func projectCreate(commandId: String, projectId: String, title: String, root: String) -> T3JSON {
        ["type": "project.create", "commandId": .string(commandId), "projectId": .string(projectId),
         "title": .string(title), "workspaceRoot": .string(root)]
    }

    /// A folder's name, for the project made of it.
    static func projectTitle(root: String) -> String {
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }
}

/// What a launch needs from outside Fjord: T3's configuration, a project made, a repo's default branch. A test stands in for each.
struct ThreadLaunchSupport {
    var config: @MainActor () async throws -> T3JSON
    var createProject: @MainActor (_ title: String, _ root: String) async throws -> T3Project
    var defaultBranch: @MainActor (_ root: String) async -> String
}

struct ThreadLaunchFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A thread a launch started.
struct LaunchedThread: Equatable {
    var thread: String
    var project: String
    var projectTitle: String
    var message: ThreadMessage
    var unattended: Bool
    var change: UUID?
}

extension Store {
    static func liveLaunchSupport(_ store: Store) -> ThreadLaunchSupport {
        ThreadLaunchSupport(
            config: { [weak store] in
                guard let store else { throw ThreadLaunchFailure("Fjord isn't ready") }
                return try await store.t3.store.call(tag: "server.getConfig")
            },
            createProject: { title, root in
                if UnderTest.refuses("T3, making a project") { throw ThreadLaunchFailure("not in a test") }
                guard let origin = T3Discovery.origin(), let token = T3Discovery.keychainToken() else {
                    throw ThreadLaunchFailure("T3 isn't reachable: Fjord can't make the project")
                }
                var request = URLRequest(url: origin.appendingPathComponent("api/projects/mutate"))
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let body = ThreadLauncher.projectCreate(commandId: UUID().uuidString.lowercased(), projectId: UUID().uuidString.lowercased(),
                                                        title: title, root: root)
                request.httpBody = try body.data()
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let json = T3JSON.parse(data) else {
                    let why = T3JSON.parse(data)?.str("message") ?? "T3 refused it"
                    throw ThreadLaunchFailure("Couldn't make the project: \(why)")
                }
                return T3Project(json: json)
            },
            defaultBranch: { root in
                await Task.detached { Self.gitDefaultBranch(root) }.value
            })
    }

    /// The repo's default branch: the remote's `HEAD`, else the checked-out branch, else `HEAD`.
    nonisolated static func gitDefaultBranch(_ root: String) -> String {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let ref = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            return ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
        }
        return git(["symbolic-ref", "--short", "HEAD"]) ?? "HEAD"
    }

    /// The T3 project whose folder is `path`, if there is one.
    func t3Project(forFolder path: String) -> T3Project? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return t3.store.projects.first { $0.archivedAt == nil && URL(fileURLWithPath: $0.workspaceRoot).standardizedFileURL.path == wanted }
    }

    /// A new thread in a T3 project, started with `message`: one `launchThread`, in the project's own checkout for your words
    /// and in a worktree of its own for an action's (`origin`). Logged as a change of Fjord's that Revert archives.
    /// `run`: the Router entry it belongs to. In a demo or a playground nothing is sent.
    /// `thread`: the id the thread will have, when the page minted it already (default: a fresh one). `settings`: the model with
    /// its effort and the runtime and interaction modes the row showed (default: T3's own defaults).
    @discardableResult
    func launchThread(in projectID: String, message: ThreadMessage, origin: SessionOrigin? = nil, run: UUID? = nil,
                      thread minted: String? = nil, settings: ThreadLaunchSettings? = nil,
                      now: Date = Date()) async throws -> LaunchedThread {
        guard let project = t3.store.shell.projects[projectID], project.archivedAt == nil else {
            throw ThreadLaunchFailure("That project isn't in T3 anymore: nothing was started")
        }
        // Never into "No project": T3 would make a scratch folder for every launch.
        let unattended = origin != nil
        let config = try? await launchSupport.config()
        let siblings = t3.store.shell.listedThreads(in: projectID).sorted { ($0.updatedAt?.text ?? "") > ($1.updatedAt?.text ?? "") }
        let chosen: ThreadLaunchModel?
        if let settings {
            chosen = ThreadLauncher.model(slug: settings.model, project: project.raw, config: config, siblings: siblings)
        } else {
            chosen = ThreadLauncher.model(project: project.raw, config: config, siblings: siblings)
        }
        guard let model = chosen else {
            throw ThreadLaunchFailure(settings.map { "T3 doesn't offer the model “\($0.model)”: pick another" }
                                      ?? "T3 has no model set up for new threads: set one in T3's settings")
        }
        let baseRef = unattended ? await launchSupport.defaultBranch(project.workspaceRoot) : ""
        let thread = minted ?? UUID().uuidString.lowercased()
        let request = ThreadLauncher.request(thread: thread, project: projectID, message: message, model: model,
                                             runtimeMode: settings?.runtimeMode ?? ThreadLauncher.runtimeMode(asked: origin?.runtimeMode, config: config),
                                             interactionMode: settings?.interactionMode ?? .default,
                                             options: settings?.effort.map { [T3ModelOption.effort($0)] } ?? [],
                                             workspace: ThreadLauncher.workspace(unattended: unattended, baseRef: baseRef))
        try await dispatch(.launchThread(request), commandId: message.commandID)
        var launched = LaunchedThread(thread: thread, project: projectID, projectTitle: project.title, message: message, unattended: unattended)
        launched.change = recordLaunch(launched, run: run, now: now)
        return launched
    }

    /// The T3 project of a folder, made when there is none (`projects.mutate`). Only for a folder you picked.
    func projectForFolder(_ path: String) async throws -> T3Project {
        if let existing = t3Project(forFolder: path) { return existing }
        let made = try await launchSupport.createProject(ThreadLauncher.projectTitle(root: path), path)
        // The shell stream tells the project in a moment; the launch must not wait for it.
        var shell = t3.store.shell
        shell.projects[made.id] = made
        t3.store.seed(shell, notify: false)
        return made
    }

    private func recordLaunch(_ launched: LaunchedThread, run: UUID?, now: Date) -> UUID {
        let change = FjordChange(date: now, title: "Started a thread in \(launched.projectTitle)",
                                 patch: .threadLaunch(project: launched.project, thread: launched.thread, projectTitle: launched.projectTitle))
        var state = router
        state.changes.append(change)
        state.pruneChanges()
        router = state
        if let run, router.record(run) != nil {
            updateDecision(run) { $0.links.changes.append(change.id) }
        } else {
            logChange(change)
        }
        return change.id
    }

    /// Revert of a launch: the thread is archived. Its words stay in T3 and in your history; archiving is `thread.archive`,
    /// and unarchiving brings it back.
    func archiveLaunchedThread(_ change: UUID, thread: String) {
        Task { @MainActor in
            do {
                try await dispatch(.threadArchive(threadId: thread))
            } catch {
                guard let i = router.changes.firstIndex(where: { $0.id == change }) else { return }
                var state = router
                state.changes[i].revertedAt = nil
                state.changes[i].revertNote = "Couldn't archive the thread: " + (error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "failed")
                router = state
            }
        }
    }
}

extension RouterDispatcher {
    /// "New thread in <project>" (or in a folder T3 has no project for yet): your words start a thread, in one
    /// `launchThread`. An action's message starts it in a worktree of its own with the action's runtime mode. The entry
    /// records the delivery, so queued edits and Revert (which archives the thread) work as for any other send.
    func launchNewThread(_ job: Job, target: String) async throws {
        guard let store else { return }
        let project: T3Project
        if target.hasPrefix(RouterAskBack.newFolder) {
            stage(job, "making a T3 project")
            do { project = try await store.projectForFolder(String(target.dropFirst(RouterAskBack.newFolder.count))) }
            catch { throw RouterTools.Failure(error.localizedDescription) }
        } else if let found = store.t3.store.shell.projects[String(target.dropFirst(RouterAskBack.newThread.count))] {
            project = found
        } else {
            throw RouterTools.Failure("That project isn't in T3 anymore: nothing was started")
        }
        stage(job, "starting a thread")
        let words = try RouterPointers.threadMessage(job.text, pills: job.context.pills, mentions: job.context.mentions, store: store)
        let message = ThreadMessage(text: words.text, records: words.records)
        try job.tools.live(job.tools.ticket())
        let launched: LaunchedThread
        do {
            launched = try await store.launchThread(in: project.id, message: message, origin: job.context.action?.origin, run: job.id,
                                                    thread: job.context.launch?.thread, settings: job.context.launch?.settings)
        } catch {
            throw RouterTools.Failure(error.localizedDescription)
        }
        store.updateDecision(job.id) {
            $0.decision.target = "a new thread in \(project.title)"
            $0.decision.targetID = target
            $0.add(.sent(to: "a new thread in \(project.title)", text: words.words, original: words.rephrased ? words.original : nil),
                   session: nil, thread: BriefTarget(project: project.id, thread: launched.thread))
            $0.delivered = RouterDecision.Delivered(thread: launched.thread, messageID: message.messageID, commandID: message.commandID,
                                                    outcome: .started, note: nil, at: Date())
            if $0.outcome == .pending { $0.outcome = .done }
        }
        report(job.id, .taken)
    }
}
