import Foundation
import Testing
@testable import Fjord

/// A model that sleeps, counting the project calls and how many run at once.
final class SleepingBriefModel: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var peak = 0
    private(set) var calls = 0
    private(set) var leads = 0
    let delay: Duration

    init(delay: Duration) { self.delay = delay }

    var runner: RouterBriefEngine.Model {
        { [self] _, _, schema in
            if schema == RouterBriefEngine.leadSchema {
                lock.withLock { leads += 1 }
                return #"{"for_you":[],"worth_a_look":[]}"#
            }
            lock.withLock { running += 1; calls += 1; peak = max(peak, running) }
            try? await Task.sleep(for: delay)
            lock.withLock { running -= 1 }
            return #"{"now":["Building."],"needs_you":[],"purpose":""}"#
        }
    }
}

@MainActor @Suite struct RouterBriefParallelTests {
    private func engine(_ names: [String], delay: Duration) async -> (RouterBriefEngine, SleepingBriefModel) {
        let src = FakeBriefSource()
        let model = SleepingBriefModel(delay: delay)
        for p in names { src.setThreads(p, [briefThread("t1", .working)]) }
        let store = MemoryBriefStore()
        for p in names { store.setKey(p, RouterBriefEngine.triggerKey(src.boards[p]!)) }
        let engine = RouterBriefEngine(source: src, store: store, model: model.runner, clock: { 100 })
        for p in names { engine.boardChanged(p) }
        await engine.idle()
        return (engine, model)
    }

    @Test func eightProjectsRewriteInAboutTwoCallTimesAndNeverMoreThanFourAtOnce() async {
        let names = (1...8).map { "p\($0)" }
        let (engine, model) = await engine(names, delay: .milliseconds(300))
        let start = ContinuousClock.now
        engine.rewrite(projects: Set(names))
        #expect(engine.rewriteProgress?.total == 8)
        await engine.idle()
        let took = ContinuousClock.now - start
        #expect(model.calls == 8 && model.leads == 1)
        #expect(model.peak == 4)
        #expect(took < .milliseconds(300 * 4))
        #expect(engine.rewriteProgress == nil && !engine.rewriting)
    }

    @Test func aSecondPressWhileOneRunsQueuesExactlyOneMorePass() async {
        let names = ["a", "b"]
        let (engine, model) = await engine(names, delay: .milliseconds(100))
        engine.rewrite(projects: Set(names))
        try? await Task.sleep(for: .milliseconds(30))
        engine.rewrite(projects: Set(names))
        engine.rewrite(projects: Set(names))
        await engine.idle()
        #expect(model.calls == 4)  // the pass and one more, however many presses came
        #expect(!engine.rewriting)
    }

    @Test func aSkippedCallCountsAsChecked() async {
        let (engine, model) = await engine(["p"], delay: .milliseconds(1))
        #expect(model.calls == 0)
        #expect(engine.lastChecked == 100 && engine.checkedAt["p"] == 100)
    }
}
