import AppKit

// Show me's demo (RouterShowMe.swift), for the `v2-show-*` shots and `--demo`: explainers on the demo's threads, in the
// engine's own type. Their posters are held frames of two real explainers (docs/design/router-visuals/explainer/cases2,
// 1-claude-token and 8-lastdrop-different), cropped to the stage, in Resources/ShowMeDemo. Nothing is made: the demo has
// no engine (`RouterModel.explainers` is nil), and a demo never gets a web view (`ExplainerStage.mode`).

@MainActor
enum RouterShowMeDemo {
    private typealias ID = RouterDemo.ID

    static let token = "why-token", lastdrop = "lastdrop-empty", restore = "restore", chalet = "chalet", guide = "guide-forks"

    /// The five explainers of the open dock: one ready and selected, one being made, one queued, two watched.
    static func explainers(at now: Date) -> [ExplainerItem] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func item(_ id: String, _ title: String, _ source: String, since: Date, stage: ExplainerItem.Stage, answer: String = "",
                  captions: [String] = [], length: Int = 0, poster: String? = nil) -> ExplainerItem {
            ExplainerItem(id: id, title: title, thread: "", source: source, answer: answer, captions: captions, since: since,
                          stage: stage, length: length, page: nil, posterLight: poster.map { file($0, dark: false) },
                          posterDark: poster.map { file($0, dark: true) })
        }
        return [
            item(token, "Why the token", ID.settings, since: ago(4), stage: .ready,
                 answer: "Making the video means running Claude, and they want that run billed to your account, not theirs.",
                 captions: ["A release starts their action. It needs your token.",
                            "Their action runs Claude. Your subscription pays.",
                            "On PRs, their plugin rides your @claude session.",
                            "They host the result on bisque.today.",
                            "@v1 can change. Your token could go anywhere."],
                 length: 27, poster: "token"),
            item(lastdrop, "Why subagents look empty", ID.tab, since: ago(1), stage: .making(draft: 2, fixing: "label overlaps the arrow"),
                 answer: "A native subagent's steps are written into your session; lastdrop's run elsewhere, so T3 only gets the final report.",
                 captions: ["Native: each step is written, and T3 shows it.",
                            "lastdrop: the hook hands the work to another process.",
                            "Live thinking streams, but T3 throws it away.",
                            "At the end, one step is written: the final report."],
                 length: 23, poster: "lastdrop"),
            item(restore, "How restore finds a snapshot", ID.snapshot, since: ago(0), stage: .queued),
            item(chalet, "What five costs over four", ID.valCenis, since: ago(52), stage: .ready, length: 19),
            item(guide, "Where the install forks", ID.guide, since: ago(180), stage: .ready, length: 24),
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
        first.stage = queued ? .queued : .making(draft: 1, fixing: "")
        all.insert(first, at: 0)
        model.showMe = RouterShowMeState(explainers: all)
    }

    // MARK: Posters

    private static func file(_ name: String, dark: Bool) -> URL {
        folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").jpg")
    }

    /// The app bundle's Resources/ShowMeDemo, or the repository's when run from `swift build`.
    private static var folder: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ShowMeDemo"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/ShowMeDemo")
    }
}
