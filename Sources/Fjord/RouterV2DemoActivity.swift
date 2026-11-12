import Foundation

// The demo's subagents, background commands and waits (docs/design/router-v2/DESIGN.md 6.3, beat 19; shots `v2-activity`,
// `v2-activity-peek`), as T3's projection gives them: subagents with their model, a command left running in the
// background, a wait on a CI run and on a monitor.

extension RouterV2Demo {
    /// Tab handover: two subagents and a dev server; Checkpoint boot: waits on CI and on the boot log; Sidebar glass:
    /// one subagent. Ages count from `now`.
    static func activity(at now: Date) -> [(String, RouterV2Activity)] {
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let tab = RouterV2Activity(
            agents: [.init(id: "tab-a1", name: "Check the handover against T3's composer", model: "claude-sonnet-5-5", since: ago(4)),
                     .init(id: "tab-a2", name: "Review the caret fix", model: "claude-opus-5-5", since: ago(2))],
            processes: [.init(id: "tab-p1", command: "npm run dev -- --port 5174", mono: true, since: ago(11))])
        let checkpoint = RouterV2Activity(
            waits: [.init(id: "cp-w1", kind: .command, what: "gh run watch 4312 --exit-status", mono: true, since: ago(3)),
                    .init(id: "cp-w2", kind: .monitor, what: "the VM's boot log", since: ago(1))])
        let glass = RouterV2Activity(
            agents: [.init(id: "glass-a1", name: "Find where the glass is captured", model: "claude-haiku-5-5", since: ago(1))])
        return [(ID.tab, tab), (ID.checkpoint, checkpoint), (ID.glass, glass)]
    }
}

extension RouterV2Model {
    /// A thread's subagents, background commands and waits change.
    func activity(_ id: String, _ activity: RouterV2Activity) {
        guard var t = thread(id), t.activity != activity else { return }
        t.activity = activity
        apply(.upsert(t))
    }
}
