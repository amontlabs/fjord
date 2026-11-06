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

    func setTurning(_ project: String, _ on: Bool) { lock.withLock { boards[project, default: BriefBoard()].coordinatorTurning = on } }
    func setThreads(_ project: String, _ t: [BriefThread]) { lock.withLock { boards[project, default: BriefBoard()].threads = t } }
    func count(_ project: String) -> Int { lock.withLock { log[project]?.count ?? 0 } }

    func projects() async -> [String] { lock.withLock { Array(Set(log.keys).union(boards.keys)).sorted() } }
    func items(project: String, after cursor: Int) async -> [BriefItem] { lock.withLock { (log[project] ?? []).filter { $0.seq > cursor } } }
    func board(project: String) async -> BriefBoard { lock.withLock { boards[project] ?? BriefBoard() } }
}

/// Canned model: answers by the system prompt's kind, records every context.
final class FakeBriefModel: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var contexts: [String] = []
    private(set) var leadContexts: [String] = []
    var answer: @Sendable (String) -> String = { _ in #"{"now":[],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
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

let askAnswer = #"{"now":["Waiting on you."],"needs_you":[{"thread":"t1","kind":"question","question":"Which one?","options":["wrong","words"]}],"decisions":[],"loose_ends":[]}"#

@MainActor @Suite struct BriefTriggers {
    @Test func theCallGetsTheNewItemsPastTheCursorAndTheCurrentBriefNothingOlder() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .working)])
        model.answer = { _ in #"{"now":["Building."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let engine = makeEngine(src, model)
        src.post("p", id: "m1", kind: .message, thread: "t1", text: "first words")
        engine.itemsChanged("p"); await engine.idle()
        src.post("p", id: "m2", kind: .message, thread: "t1", text: "second words")
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.count == 2)
        #expect(model.contexts[1].contains("second words") && !model.contexts[1].contains("first words"))
        #expect(model.contexts[1].contains("now: Building."))
    }

    @Test func itemsAreRedactedBeforeAnyModel() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.post("p", id: "m1", kind: .message, text: "use sk-abcdefghijklmnopqrstuvwx please")
        let engine = makeEngine(src, model)
        engine.itemsChanged("p"); await engine.idle()
        #expect(!model.contexts[0].contains("sk-abcdef") && model.contexts[0].contains("[redacted]"))
    }

    @Test func theTriggerTable() {
        func item(_ k: BriefItem.Kind, _ s: ThreadState? = nil) -> BriefItem { BriefItem(seq: 1, id: "x", at: 0, kind: k, status: s) }
        typealias E = RouterBriefEngine
        #expect(E.trigger([], coordinatorTurning: false) == .none)
        #expect(E.trigger([item(.status, .needsYou)], coordinatorTurning: true) == .now)
        #expect(E.trigger([item(.card)], coordinatorTurning: true) == .now)
        #expect(E.trigger([item(.stranded)], coordinatorTurning: true) == .now)
        #expect(E.trigger([item(.message)], coordinatorTurning: true) == .wait)
        #expect(E.trigger([item(.coordinator), item(.status, .done)], coordinatorTurning: true) == .wait)
        #expect(E.trigger([item(.message)], coordinatorTurning: false) == .now)
    }

    @Test func otherItemsWaitForTheCoordinatorsTurnAndLandInOneCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let engine = makeEngine(src, model)
        src.setTurning("p", true)
        src.post("p", id: "m1", kind: .message, text: "a")
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.isEmpty)
        src.post("p", id: "c1", kind: .coordinator, text: "b")
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.isEmpty)
        src.setTurning("p", false)
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.count == 1 && model.contexts[0].contains("a") && model.contexts[0].contains("b"))
    }

    @Test func aNeedsYouStatusCallsAtOnceEvenMidTurn() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let engine = makeEngine(src, model)
        src.setTurning("p", true)
        src.post("p", id: "s1", kind: .status, thread: "t1", status: .needsYou)
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.count == 1)
    }

    @Test func itemsDuringACallMarkItDirtyAndOneCallFollows() async {
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
        src.post("p", id: "m1", kind: .message, text: "one")
        engine.itemsChanged("p")
        for await _ in started.stream { break }
        // Three items and three events while the call runs.
        for i in 2...4 {
            src.post("p", id: "m\(i)", kind: .message, text: "w\(i)")
            engine.itemsChanged("p")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.contexts.count == 0 || model.contexts.count == 1)
        release.continuation.yield()
        await engine.idle()
        #expect(model.contexts.count == 2)
        #expect(model.contexts[1].contains("w2") && model.contexts[1].contains("w4") && !model.contexts[1].contains("one"))
    }

    @Test func aQuitMidCallIsRerunAtLaunchFromTheStoredCursor() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let store = MemoryBriefStore()
        src.post("p", id: "m1", kind: .message, text: "kept")
        model.failing = true
        let e1 = makeEngine(src, model, store: store)
        e1.itemsChanged("p"); await e1.idle()
        #expect(store.cursor("p") == 0)  // advances only on a landed answer
        #expect(e1.docs["p"]?.proseStale == true)
        model.failing = false
        let e2 = makeEngine(src, model, store: store)  // a new launch
        e2.start(); await e2.idle()
        #expect(model.contexts.count == 2 && model.contexts[1].contains("kept"))
        #expect(store.cursor("p") == 1 && e2.docs["p"]?.proseStale == false)
        // Nothing past the cursor: a third launch makes no call.
        let e3 = makeEngine(src, model, store: store)
        e3.start(); await e3.idle()
        #expect(model.contexts.count == 2)
    }

    @Test func threeFailuresThenARetryOnlyOnANewItem() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.failing = true
        let engine = makeEngine(src, model)
        for i in 1...3 {
            src.post("p", id: "m\(i)", kind: .message, text: "x\(i)")
            engine.itemsChanged("p"); await engine.idle()
        }
        #expect(model.contexts.count == 3)
        engine.itemsChanged("p"); await engine.idle()  // same items: parked
        #expect(model.contexts.count == 3)
        src.post("p", id: "m4", kind: .message, text: "x4")
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.count == 4)
    }

    @Test func aPlanCardThenTheRowsNeedsIsOneEntryAndOneCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .needsYou)])
        model.answer = { _ in askAnswer }
        let engine = makeEngine(src, model)
        src.post("p", id: "card1", kind: .card, thread: "t1", text: "Which one?", options: ["a", "b"])
        src.post("p", id: "t1:needs", kind: .status, thread: "t1", status: .needsYou)
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.count == 1)
        #expect(engine.docs["p"]?.needsYou.count == 1)
    }
}

final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock(); private var on = true
    func take() -> Bool { lock.withLock { let was = on; on = false; return was } }
}
