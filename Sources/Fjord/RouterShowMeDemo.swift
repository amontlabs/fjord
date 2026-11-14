import AppKit

// Show me's demo (RouterShowMe.swift): explainers on the demo's threads, their stage pictures held frames of two real
// explainers (docs/design/router-visuals/explainer/cases2, 1-claude-token and 8-lastdrop-different), cropped to the
// stage, in Resources/ShowMeDemo.

@MainActor
enum RouterShowMeDemo {
    private typealias ID = RouterDemo.ID

    static let token = "why-token", lastdrop = "lastdrop-empty", restore = "restore", chalet = "chalet", guide = "guide-forks"

    /// The five explainers of the open dock: one ready and selected, one being made, one queued, two watched.
    static func explainers(at now: Date) -> [RouterExplainer] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            RouterExplainer(id: token, title: "Why the token", thread: ID.settings, since: ago(4), stage: .ready,
                            answer: "Making the video means running Claude, and they want that run billed to your account, not theirs.",
                            captions: ["A release starts their action. It needs your token.",
                                       "Their action runs Claude. Your subscription pays.",
                                       "On PRs, their plugin rides your @claude session.",
                                       "They host the result on bisque.today.",
                                       "@v1 can change. Your token could go anywhere."],
                            scene: 2, elapsed: 15, length: 27, picture: "token"),
            RouterExplainer(id: lastdrop, title: "Why subagents look empty", thread: ID.tab, since: ago(1),
                            stage: .making(draft: 2, fixing: "label overlaps the arrow"),
                            answer: "A native subagent's steps are written into your session; lastdrop's run elsewhere, so T3 only gets the final report.",
                            captions: ["Native: each step is written, and T3 shows it.",
                                       "lastdrop: the hook hands the work to another process.",
                                       "Live thinking streams, but T3 throws it away.",
                                       "At the end, one step is written: the final report."],
                            scene: 1, elapsed: 8, length: 23, picture: "lastdrop"),
            RouterExplainer(id: restore, title: "How restore finds a snapshot", thread: ID.snapshot, since: ago(0), stage: .queued,
                            answer: "", captions: [""], scene: 0, elapsed: 0, length: 0, picture: ""),
            RouterExplainer(id: chalet, title: "What five costs over four", thread: ID.valCenis, since: ago(52), stage: .ready,
                            answer: "", captions: [""], scene: 0, elapsed: 0, length: 19, picture: ""),
            RouterExplainer(id: guide, title: "Where the install forks", thread: ID.guide, since: ago(180), stage: .ready,
                            answer: "", captions: [""], scene: 0, elapsed: 0, length: 24, picture: ""),
        ]
    }

    /// The dock with every explainer, the panel open on `selected`.
    static func open(_ model: RouterModel, selected: String) {
        model.showMe = RouterShowMeState(open: true, selected: selected, explainers: explainers(at: model.now))
    }

    /// The dock at rest: ready ones only, `unseen` of them not watched yet.
    static func rest(_ model: RouterModel, unseen: Bool) {
        var all = explainers(at: model.now).filter { $0.stage == .ready }
        if unseen { all[0].unseen = true }
        model.showMe = RouterShowMeState(explainers: all)
    }

    /// The dock while one is being made (`queued`: while one waits for its thread's turn instead).
    static func busy(_ model: RouterModel, queued: Bool) {
        var all = explainers(at: model.now).filter { $0.stage == .ready && $0.id != token }
        var first = explainers(at: model.now)[0]
        if queued {
            first.stage = .queued
        } else {
            first.stage = .making(draft: 1, fixing: "")
        }
        all.insert(first, at: 0)
        model.showMe = RouterShowMeState(explainers: all)
    }

    // MARK: Stage pictures

    private static var pictures: [String: NSImage] = [:]

    static func picture(_ name: String, dark: Bool) -> NSImage? {
        guard !name.isEmpty else { return nil }
        let file = "\(name)-\(dark ? "dark" : "light").jpg"
        if let cached = pictures[file] { return cached }
        let image = NSImage(contentsOf: folder.appendingPathComponent(file))
        pictures[file] = image
        return image
    }

    /// The app bundle's Resources/ShowMeDemo, or the repository's when run from `swift build`.
    private static var folder: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ShowMeDemo"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/ShowMeDemo")
    }
}
