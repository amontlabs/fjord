import Foundation
import SwiftUI

enum CIState: String, Codable {
    case success, failure, pending, none
    /// Stopped before it finished (GitHub's `cancelled`): never passing.
    case cancelled

    var color: Color {
        switch self {
        // Claude's: git-added green, danger red, clay while running (the island design's CI colours).
        case .success: CDS.Git.added
        case .failure: CDS.Text.danger
        case .pending: CDS.clay
        case .none, .cancelled: Theme.tertiary
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.seal.fill"
        case .failure: "xmark.seal.fill"
        case .pending: "clock.fill"
        case .cancelled: "stop.circle.fill"
        case .none: "seal.fill"
        }
    }

    var title: String {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .cancelled: "Cancelled"
        case .none: "No checks"
        }
    }

    var label: String {
        switch self {
        case .success: "passing"
        case .failure: "failing"
        case .pending: "running"
        case .cancelled: "cancelled"
        case .none: "no checks"
        }
    }
}

struct CIStatus: Codable, Hashable {
    var branch: String
    var sha: String?
    var url: URL?
    var checkedAt: Date
    /// Headline of the latest commit on the branch, and when its runs last changed.
    var title: String?
    var updatedAt: Date?
    /// Each workflow on its own (external checks and statuses together are one more).
    var workflows: [Workflow] = []
    /// The commit's Actions runs were not all read (past the pages read): a workflow not among `workflows` may still be
    /// on it, so what was known of the commit's workflows before stays.
    var runsCapped: Bool? = nil

    struct Workflow: Codable, Hashable {
        /// The workflow's id on GitHub; `Store.externalWorkflowID` for external checks.
        var id: String
        var name: String
        var state: CIState
        var failing: [String]
        var url: URL?
        var updatedAt: Date?
        /// Which execution it shows (`Thing.ciRun`), and whether any of it still runs though it already fails.
        var run: String? = nil
        var running: Bool? = nil
    }
}

struct AppSettings: Codable {
    /// Triage's switch (Tools.swift); the Router's is its own state's. Off until switched on.
    var triage: Bool?
    /// The Computers tool's switch (Tools.swift); off until switched on.
    var computers: Bool?
    /// The tools were picked on first launch: until then the window shows the onboarding.
    var toolsPicked: Bool?
    var pollInterval: Double = 60
    var notifications = true
    var snoozeUntil: Date?
    /// Customized shortcuts by ShortcutAction raw value; missing ones use the defaults.
    var shortcuts: [String: Shortcut]?
    /// Look for new releases in the background (default on).
    var checkUpdates: Bool?
    /// A release you chose to skip: not offered again by automatic checks.
    var skippedVersion: String?
    /// Keep the pill at the middle of its edge: dragging only picks the edge (default off).
    var centerPill: Bool?
    /// Jev reads new comments and rates review requests in the inbox (default on, with a TypeSafe key); off, nothing of the
    /// inbox goes to TypeSafe and what Jev said counts for nothing.
    var jevReadsInbox: Bool?
    /// The folders your code is in, looked through for git repos (CodeFolders.swift); nil is none.
    var codeFolders: [String]?
}

struct PersistedState: Codable {
    var settings: AppSettings
    var agents: ThreadsState?
    var router: RouterSaved?
    var categories: [InboxCategory]? = nil
    var groups: [InboxGroup]? = nil
    /// The bar's sections; nil (a file from before them) is GitHub's alone.
    var categorySections: [CategorySection]? = nil
    var things: [String: Thing]? = nil
    var marks: [String: EntryMarks]? = nil
    /// Per category, the rules (by id) whose matches were already noted: a category's first look, or a changed rule set,
    /// announces nothing.
    var categoryBaselines: [UUID: Set<UUID>]? = nil
    var ownedRepos: Set<String>? = nil
    var contributedRepos: Set<String>? = nil
    var reposResolvedAt: Date? = nil
    var myTeams: Set<String>? = nil
    /// The GitHub login last signed in.
    var login: String? = nil
    /// What the things were fetched for (`Store.fetchedFor`); nil (a file from before it) is the categories saved.
    var fetchedFor: Store.FetchedScope? = nil
    /// Rules were edited and not yet taken in by the actions when the app quit.
    var baselinePending: Bool? = nil
    /// The snippets, in order; nil (a file from before them) is none.
    var snippets: [Snippet]? = nil
    /// The project proposals up or waiting when the app quit (RouterProjectProposal.swift); nil: none.
    var routerProposals: [RouterProjectProposal.Saved]? = nil

    init(settings: AppSettings, agents: ThreadsState? = nil, router: RouterSaved? = nil, categories: [InboxCategory]? = nil,
         groups: [InboxGroup]? = nil, categorySections: [CategorySection]? = nil, things: [String: Thing]? = nil,
         marks: [String: EntryMarks]? = nil,
         categoryBaselines: [UUID: Set<UUID>]? = nil, ownedRepos: Set<String>? = nil, contributedRepos: Set<String>? = nil,
         reposResolvedAt: Date? = nil, myTeams: Set<String>? = nil, login: String? = nil,
         fetchedFor: Store.FetchedScope? = nil, baselinePending: Bool? = nil, snippets: [Snippet]? = nil,
         routerProposals: [RouterProjectProposal.Saved]? = nil) {
        self.settings = settings
        self.agents = agents
        self.router = router
        self.categories = categories
        self.groups = groups
        self.categorySections = categorySections
        self.things = things
        self.marks = marks
        self.categoryBaselines = categoryBaselines
        self.ownedRepos = ownedRepos
        self.contributedRepos = contributedRepos
        self.reposResolvedAt = reposResolvedAt
        self.myTeams = myTeams
        self.login = login
        self.fetchedFor = fetchedFor
        self.baselinePending = baselinePending
        self.snippets = snippets
        self.routerProposals = routerProposals
    }

    /// The parts the file had that this build could not read (a damaged file, or one from a build whose parts this one
    /// doesn't know): they are lost when the state is next saved, so the file is kept aside first (see `Store.load`).
    var dropped: [String] = []

    private enum CodingKeys: String, CodingKey {
        /// Saved as `threads`: what was under `agents` (Claude's sessions) is carried over once, on the first read.
        case agents = "threads"
        case settings, router, categories, groups, categorySections, things, marks, categoryBaselines, ownedRepos,
             contributedRepos, reposResolvedAt, myTeams, login, fetchedFor, baselinePending, snippets, routerProposals
    }

    private enum LegacyKeys: String, CodingKey { case agents }

    /// Tolerant: a file from before the categories (repos, items, ci) loses that data and loads the rest; a part that no
    /// longer decodes is lost alone (and named in `dropped`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var dropped: [String] = []
        func part<T: Decodable>(_ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                dropped.append(key.stringValue)
                return nil
            }
        }
        // Element by element: one this build can't read is lost alone, not the whole list (and the file is kept aside).
        func each<T: Decodable>(_ key: CodingKeys) -> [T]? {
            guard let all: [Lossy<T>] = part(key) else { return nil }
            let read = all.compactMap(\.value)
            if read.count < all.count { dropped.append("\(all.count - read.count) of \(key.stringValue)") }
            // None read at all: as if there were none (the default categories, GitHub's section).
            return read.isEmpty && !all.isEmpty ? nil : read
        }
        func eachByKey<T: Decodable>(_ key: CodingKeys) -> [String: T]? {
            guard let all: [String: Lossy<T>] = part(key) else { return nil }
            let read = all.compactMapValues(\.value)
            if read.count < all.count { dropped.append("\(all.count - read.count) of \(key.stringValue)") }
            return read
        }
        settings = part(.settings) ?? AppSettings()
        agents = part(.agents)
        if agents == nil, let old = try? decoder.container(keyedBy: LegacyKeys.self),
           let saved = try? old.decodeIfPresent(ThreadsState.self, forKey: .agents) {
            agents = saved.carriedOver(cliIDs: ThreadsState.desktopCLIIDs())
        }
        router = part(.router)
        // What the Router's state lost on its own (a decision, a change, a map) counts as lost too.
        if let lost = router?.dropped, !lost.isEmpty {
            dropped += lost.map { "router: \($0)" }
            router?.dropped = []
        }
        categories = each(.categories)
        groups = each(.groups)
        categorySections = each(.categorySections)
        things = eachByKey(.things)
        marks = eachByKey(.marks)
        categoryBaselines = part(.categoryBaselines)
        ownedRepos = part(.ownedRepos)
        contributedRepos = part(.contributedRepos)
        reposResolvedAt = part(.reposResolvedAt)
        myTeams = part(.myTeams)
        login = part(.login)
        fetchedFor = part(.fetchedFor)
        baselinePending = part(.baselinePending)
        snippets = each(.snippets)
        routerProposals = each(.routerProposals)
        self.dropped = dropped
    }
}
