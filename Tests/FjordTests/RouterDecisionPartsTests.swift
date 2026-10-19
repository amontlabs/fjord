import Foundation
import Testing
@testable import Fjord

/// A decision entry is a list of parts, one per place the message went to (docs/design/spec/router.md, Several places):
/// one part reads, writes and encodes as the entry always did, several are written one by one through their own ids.
@MainActor
@Suite(.serialized) struct RouterDecisionParts {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        return s
    }

    /// A message divided between two sessions, logged in `s`; returns the entry and its parts' ids.
    @discardableResult
    private func divided(in s: Store, words: String = "tell CI to rerun, and docs to add the page") -> (id: UUID, ci: UUID, docs: UUID) {
        var entry = RouterDecision(at: t0, trigger: .you(words))
        let ids = entry.divide(into: [
            .init(text: "rerun", place: "session:ci", decision: .init(target: "CI", intent: "message")),
            .init(text: "add the page", place: "session:docs", decision: .init(target: "Docs", intent: "message")),
        ])
        s.router.decisions.append(entry)
        return (entry.id, ids[0], ids[1])
    }

    private func json(_ entry: RouterDecision) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }

    // MARK: One part

    @Test func todaysEntryDecodesToOnePartWithItsOwnId() throws {
        let id = UUID()
        let text = """
        {"id":"\(id.uuidString)","at":0,"trigger":{"you":{"_0":"fix it"}},"decision":{"target":"Docs"},"done":[{"sent":{"to":"Docs","text":"fix it"}}],\
        "outcome":{"done":{}},"links":{"sessions":["s"],"cards":[],"changes":[]},"reply":"ok","note":"sent"}
        """
        let entry = try JSONDecoder().decode(RouterDecision.self, from: Data(text.utf8))
        #expect(entry.parts.count == 1 && entry.parts[0].id == id && entry.id == id)
        #expect(entry.decision.target == "Docs" && entry.outcome == .done && entry.links.sessions == ["s"])
        #expect(entry.reply == "ok" && entry.note == "sent" && entry.doneLines == ["sent to Docs: fix it"])
        #expect(entry.places == [entry])
    }

    @Test func aOnePartEntryEncodesTheFlatKeysOfToday() throws {
        var entry = RouterDecision(at: t0, trigger: .you("hi"), decision: .init(target: "Docs", intent: "message"))
        #expect(Set(try json(entry).keys) == ["id", "at", "trigger", "decision", "done", "outcome", "links"])
        entry.reply = "r"
        entry.note = "n"
        entry.delivered = .init(session: "s", cli: "c", nonce: "n", at: t0, turns: 1, busy: false, abortable: true)
        entry.mentions = []
        entry.add(.sent(to: "Docs", text: "hi", original: nil), session: "s")
        let keys = Set(try json(entry).keys)
        #expect(keys == ["id", "at", "trigger", "decision", "done", "outcome", "links", "reply", "note", "delivered", "mentions"])
        #expect(try JSONDecoder().decode(RouterDecision.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func aOnePartEntryReadsAndWritesItsPart() {
        var entry = RouterDecision(trigger: .you("hi"))
        entry.decision.target = "Docs"
        entry.outcome = .done
        entry.note = "n"
        entry.add(.answered(card: "c"), card: "k")
        #expect(entry.parts.count == 1 && entry.parts[0].id == entry.id)
        #expect(entry.parts[0].decision.target == "Docs" && entry.parts[0].outcome == .done && entry.parts[0].note == "n")
        #expect(entry.parts[0].links.cards == ["k"] && entry.projection(entry.parts[0]) == entry)
        let other = UUID()
        entry.id = other
        #expect(entry.parts[0].id == other)
    }

    // MARK: Several parts

    @Test func aDividedEntryRoundTripsWithItsParts() throws {
        let s = store()
        divided(in: s)
        let entry = s.router.decisions[0]
        let keys = Set(try json(entry).keys)
        #expect(keys == ["id", "at", "trigger", "parts"])
        let back = try JSONDecoder().decode(RouterDecision.self, from: JSONEncoder().encode(entry))
        #expect(back == entry && back.parts.map(\.place) == ["session:ci", "session:docs"] && back.parts.map(\.text) == ["rerun", "add the page"])
    }

    @Test func dividingGivesFreshIdsAndNeedsTwoPlaces() {
        var entry = RouterDecision(trigger: .you("x"))
        #expect(entry.divide(into: [.init(text: "x")]).isEmpty && entry.parts.count == 1)
        let ids = entry.divide(into: [.init(text: "a"), .init(text: "b")])
        #expect(ids.count == 2 && Set(ids + [entry.id]).count == 3 && entry.parts.map(\.id) == ids)
        #expect(entry.divide(into: [.init(text: "c"), .init(text: "d")]).isEmpty && entry.parts.map(\.id) == ids)
    }

    @Test func aDividedEntryAddsUpItsParts() {
        let s = store()
        let ids = divided(in: s)
        s.updateDecision(ids.ci) { $0.add(.sent(to: "CI", text: "rerun", original: nil), session: "ci"); $0.outcome = .done }
        var entry = s.router.decisions[0]
        #expect(entry.outcome == .pending)
        s.updateDecision(ids.docs) { $0.add(.failed("no"), session: "docs"); $0.outcome = .done }
        entry = s.router.decisions[0]
        #expect(entry.outcome == .done && entry.links.sessions == ["ci", "docs"] && entry.done.count == 2)
        #expect(entry.decision.label == "split" && entry.decision.intent == "message")
        #expect(entry.reply == nil && entry.note == nil && entry.delivered == nil)
        // Writing the entry's own fields does nothing: a part is written through its id.
        entry.outcome = .reverted
        entry.note = "x"
        entry.add(.failed("y"))
        #expect(entry == s.router.decisions[0])
    }

    @Test func updatingAPartChangesThatPartOnly() {
        let s = store()
        let ids = divided(in: s)
        s.updateDecision(ids.docs) {
            $0.note = "held"
            $0.decision.confirmed = true
            $0.add(.asked(["a"]))
        }
        let entry = s.router.decisions[0]
        #expect(entry.parts[0] == s.router.decisions[0].parts[0] && entry.parts[0].note == nil && entry.parts[0].done.isEmpty)
        #expect(entry.parts[1].note == "held" && entry.parts[1].decision.confirmed == true && entry.parts[1].done == [.asked(["a"])])
        #expect(entry.parts[1].text == "add the page" && entry.parts[1].place == "session:docs")
        // The entry's own id still reaches the entry; an unknown one nothing.
        s.updateDecision(ids.id) { $0.mentions = [] }
        #expect(s.router.decisions[0].mentions == [])
        s.updateDecision(UUID()) { $0.note = "lost" }
        #expect(s.router.decisions.count == 1 && s.router.decisions[0].parts[0].note == nil)
    }

    @Test func aPartIsAnEntryOfItsOwnToWhateverReadsIt() {
        let s = store()
        let ids = divided(in: s)
        let mention = RouterMention(range: 0..<3, pointer: .session("docs"), name: "docs")
        s.updateDecision(ids.docs) { $0.mentions = [mention]; $0.add(.sent(to: "Docs", text: "add the page", original: nil), session: "docs") }
        let part = s.router.record(ids.docs)
        #expect(part?.id == ids.docs && part?.trigger == .you("add the page") && part?.mentions == [mention])
        #expect(part?.done == [.sent(to: "Docs", text: "add the page", original: nil)] && part?.links.sessions == ["docs"])
        #expect(part?.parts.count == 1 && part?.at == t0)
        #expect(s.router.record(ids.id)?.parts.count == 2)
        #expect(s.router.record(UUID()) == nil)
        #expect(s.router.parent(of: ids.ci) == ids.id && s.router.parent(of: ids.id) == nil && s.router.parent(of: UUID()) == nil)
        #expect(s.router.decisions[0].places.map(\.id) == [ids.ci, ids.docs])
        // A part without words of its own is the whole message.
        var whole = RouterDecision(trigger: .you("both of you, rerun"))
        whole.divide(into: [.init(place: "session:ci"), .init(place: "session:docs")])
        #expect(whole.places.map(\.trigger) == [.you("both of you, rerun"), .you("both of you, rerun")])
    }

    @Test func aOnePartEntryIsItsOwnRecordAndHasNoParent() {
        let s = store()
        let id = s.logDecision(RouterDecision(trigger: .you("hi")))
        #expect(s.router.record(id) == s.router.decisions[0] && s.router.parent(of: id) == nil)
    }

    @Test func theLogCapKeepsAnEntryWhosePartHasAnAskUp() {
        var state = RouterState()
        var entry = RouterDecision(trigger: .you("two places"))
        let ids = entry.divide(into: [.init(text: "a"), .init(text: "b")])
        state.log(entry, inUse: [ids[1]])
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)")), inUse: [ids[1]]) }
        #expect(state.decisions.count == RouterDecision.maxKept && state.decisions.first?.id == entry.id)
        state.log(RouterDecision(trigger: .you("more")))
        #expect(state.decisions.first?.trigger == .you("m6"))
    }

    @Test func aQuitSettlesEachPartAndSaysWhatAHeldOneWaitedFor() {
        var state = RouterState()
        state.cards = [RouterCard(id: "ci#t1", sessionID: "ci", kind: .done, title: "Rerun CI", folder: nil, text: "", createdAt: Date())]
        var entry = RouterDecision(trigger: .you("ask CI, then tell docs"))
        entry.divide(into: [
            .init(text: "ask CI", place: "session:ci", outcome: .done),
            .init(text: "tell docs", place: "session:docs", waitsFor: "session:ci"),
            .init(text: "and project", place: "project:/code/lookout"),
        ])
        state.decisions = [entry, RouterDecision(trigger: .you("one"))]
        state.settleInterrupted()
        let parts = state.decisions[0].parts
        #expect(parts[0].done.isEmpty && parts[0].outcome == .done)
        #expect(parts[1].done == [.failed("wasn't sent: Fjord quit while it waited for “Rerun CI”")] && parts[1].outcome == .done)
        #expect(parts[2].done == [.failed("interrupted")] && parts[2].outcome == .done)
        #expect(state.decisions[0].outcome == .done && state.decisions[1].doneLines == ["failed: interrupted"])
    }

    @Test func aQuitDoesNotCallAPartSentNowUnsent() {
        var state = RouterState()
        var entry = RouterDecision(trigger: .you("ask CI, then tell docs"))
        entry.divide(into: [
            .init(text: "ask CI", place: "session:ci", outcome: .done),
            .init(text: "tell docs", place: "session:docs", waitsFor: "session:ci"),
        ])
        // Sent now, delivered, its cards still being judged when Fjord quit.
        entry.parts[1].add(.sent(to: "peer-docs", text: "tell docs", original: nil), session: "docs")
        state.decisions = [entry]
        state.settleInterrupted()
        let docs = state.decisions[0].parts[1]
        #expect(docs.outcome == .done && !docs.done.contains { if case .failed(let why) = $0 { why.hasPrefix("wasn't sent") } else { false } })
    }

    @Test func aChangeLinksThePartThatMadeItAndRevertingSettlesThatPart() {
        let s = store()
        let ids = divided(in: s)
        let change = FjordChange(title: "Changed snooze", patch: .setting(key: "k", before: .on(false), after: .on(true)))
        s.router.changes = [change]
        s.logChange(change, into: ids.docs)
        #expect(s.router.decisions.count == 1 && s.router.decisions[0].parts[0].links.changes.isEmpty)
        #expect(s.router.decisions[0].parts[1].links.changes == [change.id] && s.router.decisions[0].parts[1].done == [.changed(change.id)])
        #expect(s.router.decisions[0].links.changes == [change.id])
        var reverted: [UUID] = []
        s.routerRunReverted = { reverted.append($0) }
        s.router.changes[0].revertedAt = t0
        s.noteReverted(change.id)
        #expect(s.router.decisions[0].parts[1].outcome == .reverted && s.router.decisions[0].parts[0].outcome == .pending)
        #expect(reverted == [ids.docs])
        // Forgotten, a part's change leaves the part and not the entry.
        s.dropChange(change.id)
        #expect(s.router.decisions.count == 1 && s.router.decisions[0].parts[1].done.isEmpty && s.router.decisions[0].links.changes.isEmpty)
    }

    @Test func aPartsDeliveryIsFjordsOwnMessage() {
        func session(_ message: Double) -> ClaudeSession {
            ClaudeSession(id: "local_a", title: "A", folder: "/code/app", completedTurns: 1, lastActivity: at(message), lastFocused: at(-20),
                          lastUserMessage: at(message), running: false, cliID: "cli-local_a")
        }
        func run(_ entry: RouterDecision) -> RouterState {
            var state = RouterState()
            state.enabled = true
            RouterFeed.update(&state, sessions: [session(-10)], activity: [:], muted: [], viewing: nil, now: at(0))
            state.fjordStarted["local_a"] = at(-10)
            state.decisions = [entry]
            RouterFeed.update(&state, sessions: [session(20.1)], activity: [:], muted: [], viewing: "local_a", now: at(21))
            return state
        }
        var entry = RouterDecision(at: at(19.5), trigger: .you("two places"))
        entry.divide(into: [.init(text: "a", place: "session:other"), .init(text: "b", place: "session:local_a")])
        entry.parts[1].delivered = .init(session: "local_a", cli: "cli-local_a", nonce: "n", at: at(20.1), turns: 1, busy: false, abortable: true)
        #expect(run(entry).fjordStarted["local_a"] != nil)
        // Without the delivery the message in the session is yours.
        entry.parts[1].delivered = nil
        #expect(run(entry).fjordStarted["local_a"] == nil)
    }

    @Test func recentDecisionsLeaveOutTheRunAskingAndItsParent() {
        let s = store()
        let ids = divided(in: s)
        s.logDecision(RouterDecision(trigger: .you("other")))
        #expect(s.recentDecisions(excluding: ids.ci).split(separator: "\n").count == 1)
        #expect(s.recentDecisions(excluding: ids.id).split(separator: "\n").count == 1)
        #expect(s.recentDecisions().split(separator: "\n").count == 2)
    }

    // MARK: Words

    @Test func aDividedEntrySaysHowItsPartsStand() {
        let s = store()
        let ids = divided(in: s)
        let entry = { s.router.decisions[0] }
        #expect(entry().summary == "split in 2: 2 working" && entry().symbol == "arrow.triangle.branch")
        s.updateDecision(ids.ci) { $0.add(.sent(to: "CI", text: "rerun", original: nil), session: "ci"); $0.outcome = .done }
        s.updateDecision(ids.docs) { $0.parts[0].waitsFor = "session:ci" }
        #expect(entry().summary == "split in 2: 1 sent, 1 held")
        #expect(entry().triggerText == "tell CI to rerun, and docs to add the page")
    }

    @Test func onlyACancelThatStoppedTheDeliveryCountsAsCancelled() {
        let s = store()
        let ids = divided(in: s)
        let entry = { s.router.decisions[0] }
        let delivered = RouterDecision.Delivered(session: "ci", cli: "cli", nonce: "n", at: t0, turns: 0, busy: false, abortable: true)
        for id in [ids.ci, ids.docs] {
            s.updateDecision(id) { $0.add(.sent(to: "x", text: "go", original: nil), session: "ci"); $0.delivered = delivered; $0.outcome = .done }
        }
        for how in [RouterDecision.Cancelled.tooLate, .together, .unknown] {
            s.updateDecision(ids.ci) { $0.delivered?.cancelled = how; $0.add(.cancelled(how)) }
            #expect(entry().summary == "split in 2: 2 sent", "\(how) stopped nothing")
            s.updateDecision(ids.ci) { $0.done.removeLast() }
        }
        s.updateDecision(ids.ci) { $0.delivered?.cancelled = .aborted; $0.add(.cancelled(.aborted)) }
        #expect(entry().summary == "split in 2: 1 cancelled, 1 sent")
    }

    @Test func aDividedEntrysContextLineHasOneClausePerPart() {
        let s = store()
        let ids = divided(in: s)
        s.updateDecision(ids.ci) { $0.add(.sent(to: "CI", text: "rerun", original: nil), session: "ci"); $0.outcome = .done }
        s.updateDecision(ids.docs) { $0.parts[0].waitsFor = "session:ci" }
        let line = s.router.decisions[0].contextLine(now: t0)
        #expect(line.contains("the user: “tell CI to rerun, and docs to add the page” → split into 2 places: "))
        #expect(line.contains("CI: “rerun” → sent to CI: rerun | Docs: “add the page” (waited for session:ci)"))
        #expect(!line.contains("\n"))
    }
}
