import Foundation
import Testing
@testable import Fjord

/// Banners on a record's code transition: once per request, plan or run, fresh on first sight, a finish or a stop only
/// while unseen; and once per fingerprint when a verdict finds a step.
@MainActor @Suite struct RouterNotifierTests {
    typealias F = RecordFixture
    private let now = RecordFixture.now

    private func code(_ t: AgentThread, _ d: RouterDetail? = nil) -> RouterCodeState {
        RouterCodeState.make(thread: t, detail: d, now: now)
    }

    private func notifier() -> (RouterNotifier, () -> [ThreadNotice]) {
        let n = RouterNotifier()
        var posted: [ThreadNotice] = []
        n.post = { posted.append($0) }
        n.postMany = { posted += $0 }
        return (n, { n.flush(); defer { posted = [] }; return posted })
    }

    @Test func aNewAskIsToldOnceKeyedOnItsRequestWithT3sWords() {
        let (n, posted) = notifier()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        let working = code(t)
        #expect(n.changed(t, project: "app", from: nil, to: working, request: nil, now: now, told: []) == nil)
        t.status = .waiting
        t.pendingRequest = F.pending("req-9", minutes: 0)
        let request = F.question("Sidebar or tabs?", id: "req-9")
        var d = RouterDetail()
        d.request = request
        let asking = code(t, d)
        #expect(n.changed(t, project: "app", from: working, to: asking, request: request, now: now, told: []) == "ask:req-9")
        let told = posted()
        #expect(told.map(\.kind) == [.needsYou])
        #expect(told.first?.body == "Sidebar or tabs?")
        #expect(told.first?.project == "app")
        // The same ask again (its line changed, say): nothing. Told before (a relaunch): nothing.
        #expect(n.changed(t, project: "app", from: asking, to: asking, request: request, now: now, told: []) == nil)
        let (m, posted2) = notifier()
        #expect(m.changed(t, project: "app", from: working, to: asking, request: request, now: now, told: ["ask:req-9"]) == nil)
        #expect(posted2().isEmpty)
    }

    @Test func aFinishARealStopAndAUsageLimitAreToldWhileUnseen() {
        let (n, posted) = notifier()
        var t = F.thread(minutes: 0)
        t.unseen = true
        t.latestMessage = "Moved the beds.\nMore."
        var was = code(F.thread(status: .running))
        #expect(n.changed(t, project: nil, from: was, to: code(t), request: nil, now: now, told: []) == "done:t1@r1")
        #expect(posted().map(\.body) == ["Moved the beds."])

        var f = F.thread("f", status: .failed, minutes: 0)
        f.unseen = true
        f.lastError = "The connection to Claude dropped"
        was = code(F.thread("f", status: .running))
        _ = n.changed(f, project: nil, from: was, to: code(f), request: nil, now: now, told: [])
        #expect(posted().map(\.kind) == [.failed])

        var limit = F.thread("l", status: .failed, minutes: 0)
        limit.usageLimit = true
        limit.limitStopped = true
        limit.unseen = true
        _ = n.changed(limit, project: nil, from: was, to: code(limit), request: nil, now: now, told: [])
        #expect(posted().map(\.kind) == [.usageLimit])

        // Opened already in T3: no banner for its finish.
        let seen = F.thread("s", minutes: 0)
        #expect(n.changed(seen, project: nil, from: was, to: code(seen), request: nil, now: now, told: []) == nil)
    }

    @Test func aRunYouStoppedIsNotNews() {
        let (n, posted) = notifier()
        var t = F.thread(status: .interrupted, minutes: 0)
        t.stopRequested = true
        t.unseen = true
        #expect(n.changed(t, project: nil, from: code(F.thread(status: .running)), to: code(t), request: nil, now: now, told: []) == nil)
        #expect(posted().isEmpty)
    }

    @Test func onFirstSightOnlyWhatIsFreshIsTold() {
        let (n, posted) = notifier()
        var old = F.thread("old", minutes: 30)
        old.unseen = true
        var fresh = F.thread("fresh", minutes: 2)
        fresh.unseen = true
        #expect(n.changed(old, project: nil, from: nil, to: code(old), request: nil, now: now, told: []) == nil)
        #expect(n.changed(fresh, project: nil, from: nil, to: code(fresh), request: nil, now: now, told: []) != nil)
        #expect(posted().map(\.thread) == ["fresh"])
        // The old one seen again, unchanged: still nothing.
        #expect(n.changed(old, project: nil, from: code(old), to: code(old), request: nil, now: now, told: []) == nil)
    }

    @Test func anOpenItemIsToldOncePerInput() {
        let (n, posted) = notifier()
        let t = F.thread()
        let key = n.item(t, project: nil, input: "turn:r1", sentence: "Merge #41?", told: [])
        #expect(key != nil)
        #expect(posted().map(\.body) == ["Merge #41?"])
        #expect(n.item(t, project: nil, input: "turn:r1", sentence: "Merge #41?", told: [key!]) == nil)
        #expect(n.item(t, project: nil, input: "turn:r2", sentence: "Merge #42?", told: [key!]) != nil)
    }

    @Test func manyAtOnceAreOneBanner() {
        let n = RouterNotifier()
        var each = 0
        var many: [[ThreadNotice]] = []
        n.post = { _ in each += 1 }
        n.postMany = { many.append($0) }
        for i in 0..<5 {
            var t = F.thread("t\(i)", minutes: 1)
            t.unseen = true
            _ = n.changed(t, project: nil, from: nil, to: code(t), request: nil, now: now, told: [])
        }
        n.flush()
        #expect(each == 0)
        #expect(many.map(\.count) == [5])
    }
}
