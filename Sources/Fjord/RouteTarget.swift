import Foundation

/// Where a message can go among T3's threads, as an id the history, a pill and an ask-back's buttons carry:
/// `t3-thread:<thread id>` (the thread gets the words) or `new_thread:<project id>` (`RouterAskBack.newThread`: a new thread in
/// that project starts with them). T3's ids are opaque and never hold a newline. `new_folder:<path>` (a folder T3 has no
/// project for) is the launcher's and isn't a `RouteTarget`.
enum RouteTarget: Equatable, Hashable, Sendable {
    case thread(String)
    case newThread(project: String)

    init?(_ targetID: String) {
        if targetID.hasPrefix("t3-thread:") {
            let id = String(targetID.dropFirst("t3-thread:".count))
            guard !id.isEmpty else { return nil }
            self = .thread(id)
        } else if targetID.hasPrefix(RouterAskBack.newThread) {
            let id = String(targetID.dropFirst(RouterAskBack.newThread.count))
            guard !id.isEmpty else { return nil }
            self = .newThread(project: id)
        } else {
            return nil
        }
    }

    var targetID: String {
        switch self {
        case .thread(let id): "t3-thread:\(id)"
        case .newThread(let project): RouterAskBack.newThread + project
        }
    }

    /// The thread, when it is one.
    var threadID: String? { if case .thread(let id) = self { id } else { nil } }
}

@MainActor extension RouteTarget {
    /// The project's name as the app shows it.
    static func projectName(_ id: String, store: Store) -> String {
        store.t3.store.shell.projects[id]?.title.nonEmpty ?? store.threads.values.first { $0.projectID == id }?.folderName ?? "Project"
    }

    /// Whether it can be sent to now: T3 lists the thread (or the project, for a new thread).
    func eligible(store: Store) -> Bool {
        switch self {
        case .thread(let id): store.threads[id] != nil
        case .newThread(let project): store.t3.store.shell.projects[project].map { $0.archivedAt == nil } ?? false
        }
    }

    /// The thread's project and id as a brief target.
    func briefTarget(store: Store) -> ThreadTarget? {
        guard case .thread(let id) = self, let t = store.threads[id] else { return nil }
        return ThreadTarget(project: t.projectID, thread: id)
    }

    /// A target as a button: the thread's title in its project, or "New thread in <project>".
    func option(store: Store) -> RouterAskBack.Option? {
        guard eligible(store: store) else { return nil }
        switch self {
        case .thread(let id):
            guard let t = store.threads[id] else { return nil }
            let project = Self.projectName(t.projectID, store: store)
            let state = t.running ? (t.waitsForYou ? "waiting on you" : "running") : t.waitsForYou ? "waiting on you" : "finished"
            return .init(target: targetID, title: t.title.isEmpty ? "Untitled thread" : RouterPointers.inert(t.title, 60),
                         detail: "\(project) · \(state)")
        case .newThread(let project):
            return .init(target: targetID, title: "New thread in \(Self.projectName(project, store: store))", detail: "in T3")
        }
    }

    /// In words, for the log: `thread “Fix the login” in fjord`, `a new thread in fjord`.
    func describe(store: Store) -> String {
        switch self {
        case .thread(let id):
            guard let t = store.threads[id] else { return "thread" }
            let title = t.title.isEmpty ? "Untitled thread" : RouterPointers.inert(t.title, 60)
            return "thread “\(title)” in \(Self.projectName(t.projectID, store: store))"
        case .newThread(let project):
            return "a new thread in \(Self.projectName(project, store: store))"
        }
    }
}
