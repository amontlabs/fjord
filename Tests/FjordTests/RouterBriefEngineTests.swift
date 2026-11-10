import Foundation
import Testing
@testable import Fjord

/// A log that stores each item once by id (a re-read with the same content adds nothing), with a Board per project.
final class FakeBriefSource: BriefSource, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String: [BriefItem]] = [:]
    var boards: [String: BriefBoard] = [:]

    func post(_ project: String, id: String, kind: BriefItem.Kind, thread: String? = nil, text: String = "", options: [String] = [],
              status: ThreadState? = nil) {
        lock.withLock {
            var items = log[project] ?? []
            if items.contains(where: { $0.id == id && $0.text == text && $0.options == options && $0.status == status }) { return }
            items.append(BriefItem(seq: items.count + 1, id: id, at: Double(items.count), kind: kind, thread: thread, text: text, options: options, status: status))
            log[project] = items
        }
    }

    func setThreads(_ project: String, _ t: [BriefThread]) { lock.withLock { boards[project, default: BriefBoard()].threads = t } }
    func count(_ project: String) -> Int { lock.withLock { log[project]?.count ?? 0 } }

    func projects() async -> [String] { lock.withLock { Array(Set(log.keys).union(boards.keys)).sorted() } }
    func board(project: String) async -> BriefBoard { lock.withLock { boards[project] ?? BriefBoard() } }
}

/// Canned model: answers by the system prompt's kind, records every context.
final class FakeBriefModel: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var contexts: [String] = []
    private(set) var leadContexts: [String] = []
    var answer: @Sendable (String) -> String = { _ in #"{"now":[],"needs_you":[],"purpose":""}"# }
    var failing = false
    var gate: (@Sendable () async -> Void)?

    var runner: RouterBriefEngine.Model {
        { [self] system, context, schema in
            if let gate { await gate() }
            if schema == RouterBriefEngine.leadSchema {
                lock.withLock { leadContexts.append(context) }
                return #"{"for_you":"Two things need you.","worth_a_look":""}"#
            }
            lock.withLock { contexts.append(context) }
            if failing { throw RouterTools.Failure("no answer") }
            return answer(context)
        }
    }
}

func briefThread(_ id: String, _ status: ThreadState, title: String = "T") -> BriefThread { BriefThread(id: id, title: title, status: status, age: 0) }

@MainActor func makeEngine(_ src: FakeBriefSource, _ model: FakeBriefModel, store: BriefStore = MemoryBriefStore()) -> RouterBriefEngine {
    RouterBriefEngine(source: src, store: store, model: model.runner, clock: { 100 })
}

let askAnswer = #"{"now":["Waiting on you."],"needs_you":[{"thread":"t1","kind":"question","question":"Which one?","options":["wrong","words"]}],"purpose":""}"#

/// A thread whose facts differ from `base` by its last run's end (a new trigger key, nothing else).
func ran(_ t: BriefThread, at: Double) -> BriefThread { var t = t; t.runEnded = at; return t }

@MainActor @Suite struct BriefTriggers {
    @Test func theCallGetsTheBoardAndNoEarlierBrief() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t1 = briefThread("t1", .working)
        t1.ends = "first words"
        src.setThreads("p", [t1])
        model.answer = { _ in #"{"now":["Building."],"needs_you":[],"purpose":""}"# }
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        t1.ends = "second words"; t1.runEnded = 5
        src.setThreads("p", [t1])
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == 2)
        #expect(model.contexts[0].contains("first words") && model.contexts[1].contains("second words") && !model.contexts[1].contains("first words"))
        #expect(!model.contexts[1].contains("Current brief") && !model.contexts[1].contains("Building."))
    }

    @Test func aChangeInReplyTextAloneMakesNoCallAndNeitherDoesAnUnchangedKey() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t1 = briefThread("t1", .done)
        src.setThreads("p", [t1])
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        t1.ends = "a new reply, same facts"
        src.setThreads("p", [t1])
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == 1)
    }

    @Test func repliesAreRedactedBeforeAnyModel() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t = briefThread("t1", .done)
        t.ends = "use sk-abcdefghijklmnopqrstuvwx please"
        src.setThreads("p", [t])
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        #expect(!model.contexts[0].contains("sk-abcdef") && model.contexts[0].contains("[redacted]"))
    }

    @Test func changesDuringACallMarkItDirtyAndOneCallFollows() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = FirstOnly()
        model.gate = {
            guard first.take() else { return }
            started.continuation.yield()
            for await _ in release.stream { break }
        }
        let engine = makeEngine(src, model)
        src.setThreads("p", [briefThread("t1", .working)])
        engine.boardChanged("p")
        for await _ in started.stream { break }
        for i in 2...4 {
            src.setThreads("p", [ran(briefThread("t1", .working), at: Double(i))])
            engine.boardChanged("p")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.contexts.count == 0 || model.contexts.count == 1)
        release.continuation.yield()
        await engine.idle()
        #expect(model.contexts.count == 2)
        #expect(model.contexts[1].contains("last run ended"))
    }

    @Test func aQuitMidCallIsRerunAtLaunchAndALaunchWithTheSameKeyMakesNoCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let store = MemoryBriefStore()
        src.setThreads("p", [briefThread("t1", .done)])
        model.failing = true
        let e1 = makeEngine(src, model, store: store)
        e1.boardChanged("p"); await e1.idle()
        #expect(store.key("p") == nil)  // kept only for a landed answer
        #expect(e1.docs["p"]?.proseStale == true)
        model.failing = false
        let e2 = makeEngine(src, model, store: store)  // a new launch
        e2.start(); await e2.idle()
        #expect(model.contexts.count == 2 && store.key("p") != nil && e2.docs["p"]?.proseStale == false)
        let e3 = makeEngine(src, model, store: store)
        e3.start(); await e3.idle()
        #expect(model.contexts.count == 2)
    }

    @Test func rewriteCallsEvenWhenTheKeyIsUnchanged() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done)])
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        engine.rewrite(projects: ["p"]); await engine.idle()
        #expect(model.contexts.count == 2)
    }

    @Test func threeFailuresThenARetryOnlyOnAChangedKey() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.failing = true
        src.setThreads("p", [briefThread("t1", .done)])
        let engine = makeEngine(src, model)
        for _ in 1...3 { engine.boardChanged("p"); await engine.idle() }
        #expect(model.contexts.count == 3)
        engine.boardChanged("p"); await engine.idle()  // same facts: parked
        #expect(model.contexts.count == 3)
        src.setThreads("p", [ran(briefThread("t1", .done), at: 4)])
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == 4)
    }

    @Test func aWaitingRequestIsOneEntryWithItsTextAndOptionsInTheContext() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t = briefThread("t1", .needsYou)
        t.ask = "asks: Which one?"; t.askOptions = ["red", "blue"]
        src.setThreads("p", [t])
        src.boards["p", default: BriefBoard()].entries = [BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 1, episode: "rq")]
        model.answer = { _ in askAnswer }
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == 1 && model.contexts[0].contains("Which one?") && model.contexts[0].contains("red / blue"))
        #expect(engine.docs["p"]?.needsYou.count == 1)
    }
}

final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock(); private var on = true
    func take() -> Bool { lock.withLock { let was = on; on = false; return was } }
}
