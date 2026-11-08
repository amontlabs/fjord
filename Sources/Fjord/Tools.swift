import Foundation

// The app's tools: Triage (the GitHub inbox and CI) and Router (one chat above your Claude Code sessions). Each is switched
// on or off, on first launch (`OnboardingView`) and then in Settings. What a tool adds to the bar, the window's sidebar,
// Settings and the shortcuts, and the work it does in the background, are there only while it is on. Together they do more
// (an inbox action starts a session, the Router reads and changes Triage): that runs only while both are on (`toolsLinked`).

enum Tool: String, CaseIterable, Identifiable {
    case triage, router

    var id: Self { self }

    var name: String {
        switch self {
        case .triage: "Triage"
        case .router: "Router"
        }
    }

    /// What it is, in a line under its name.
    var summary: String {
        switch self {
        case .triage: "Your GitHub inbox and CI, sorted by your rules"
        case .router: "One chat above all your Claude Code sessions"
        }
    }

    var symbol: String {
        switch self {
        case .triage: "tray"
        case .router: "arrow.triangle.branch"
        }
    }
}

extension Store {
    /// Both tools are on: the inbox's actions may start sessions, and the Router may read and change Triage.
    var toolsLinked: Bool { triageOn && routerOn }

    func isOn(_ tool: Tool) -> Bool {
        switch tool {
        case .triage: triageOn
        case .router: routerOn
        }
    }

    /// The tools that are on.
    var tools: Set<Tool> { Set(Tool.allCases.filter(isOn)) }

    /// Where the window opens first: Triage, Router. The Router fallback is resolved to Settings if no tool is on.
    var firstPlace: AppDestination {
        triageOn ? AppDestination(tabNeedingYou) : .router
    }

    func setTool(_ tool: Tool, on: Bool) {
        switch tool {
        case .triage: setTriageEnabled(on)
        case .router: switchRouter(on)
        }
    }

    /// Triage's work is GitHub's polling and the inbox's timer (a rule's "no activity for"): they start and stop with the
    /// switch (a store that doesn't persist polls nothing on its own). What it had (the inbox, the sign-in) stays, out of
    /// sight, for when it is back.
    func setTriageEnabled(_ on: Bool) {
        guard on != triageOn else { return }
        settings.triage = on
        if on {
            if persists { restartPolling() }
        } else {
            stopPolling()
            inboxMemo.timer?.cancel()
            inboxMemo.timer = nil
            // An action's message waiting on you, or its turn, goes nowhere now: its run says why.
            routerDispatcher.unlinked()
        }
    }
}
