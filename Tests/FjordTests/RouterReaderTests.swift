import Foundation
import Testing
@testable import Fjord

/// Where a draft goes, read for Router v2's page (`RouterReader`): Jev at the typing pause, Sonnet when he isn't sure, a
/// keystroke cancelling both, the same words on the same board reused, a Return that skips the pauses, and the draft's aside
/// about a new thread's settings taken only when the model quoted it exactly.
@MainActor
@Suite struct RouterReaderTests {
    final class Calls {
        var jev: [String] = []
        var decided: [String] = []
        var reused: [Bool] = []
        var selected: [String?] = []
        var tagged: [String?] = []
        var cancelled = 0
        var board = "b1"
        var reads: [RouterRead] = []
        var decisions: [RouterProjectDecision?] = []
        var searched: [String] = []
    }

    /// A sure answer for `thread` (or an unsure one), as the fused path would give it.
    static func answer(_ thread: String, p: Double) -> JevPath.Result {
        let rows = [JevPath.Row(place: .thread(thread), name: thread, jev: p, features: .init(), p: p, running: false),
                    JevPath.Row(place: .newThread(project: "p1"), name: "new", jev: 1 - p, features: .init(new: 1), p: 1 - p, running: false)]
        return JevPath.Result(rows: rows, ans: [:], next: [:], fjord: nil, runningMass: 0, bm25: [:], twins: [], requestHash: "h", key: "k")
    }

    /// Jev at `p` for th-login; Sonnet (when Jev isn't sure) answers `sonnet`.
    func reader(_ calls: Calls, p: Double = 0.95, sonnet: RouterProjectDecision? = nil, pauses: (Int, Int) = (20, 60)) -> RouterReader {
        let r = RouterReader()
        r.jevPause = .milliseconds(pauses.0)
        r.sonnetPause = .milliseconds(pauses.1)
        r.boardKey = { calls.board }
        r.jev = { text, _ in calls.jev.append(text); return Self.answer("th-login", p: p) }
        r.decide = { text, tagged, selected, reuse in
            calls.decided.append(text)
            calls.reused.append(reuse != nil)
            calls.selected.append(selected)
            calls.tagged.append(tagged)
            return sonnet ?? RouterProjectDecision(kind: .ask([]), confidence: 0.5, decider: .sonnet)
        }
        r.search = { text in calls.searched.append(text); return [] }
        r.onRead = { read, decision in calls.reads.append(read); calls.decisions.append(decision) }
        return r
    }

    static func ask(_ places: [RouterProjectDecision.Kind]) -> RouterProjectDecision {
        RouterProjectDecision(kind: .ask(places), confidence: 0.6, decider: .sonnet)
    }

    @Test func jevSureIsOnePlaceAndSonnetIsNotAsked() async {
        let calls = Calls()
        let r = reader(calls)
        r.read("fix the login redirect", selected: nil, mentions: [])
        await waitUntil { !calls.reads.isEmpty }
        #expect(calls.reads == [RouterRead(draft: "fix the login redirect", places: [.thread("th-login")], sure: true)])
        #expect(calls.jev == ["fix the login redirect"] && calls.decided.isEmpty && calls.decisions.first??.decider == .jev)
        #expect(r.asking == nil)
    }

    @Test func notSureSonnetDecidesAfterTheLongerPauseReusingJevAndSeeingTheOpenCard() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5, sonnet: Self.ask([.thread("th-docs"), .thread("th-login"), .newThread(project: "p1"), .newThread(project: "p2")]))
        r.tagged = { _ in "tagged: x" }
        r.read("the readme needs a section", selected: "th-docs", mentions: [])
        await waitUntil { !calls.reads.isEmpty }
        // T3's search runs beside Sonnet's pause, not before the decision: under load it may start after it.
        await waitUntil { !calls.searched.isEmpty }
        #expect(calls.jev.count == 1 && calls.decided == ["the readme needs a section"] && calls.reused == [true])
        #expect(calls.selected == ["th-docs"] && calls.tagged == ["tagged: x"] && calls.searched == ["the readme needs a section"])
        // Three places at most, best first, unsure.
        #expect(calls.reads[0].places == [.thread("th-docs"), .thread("th-login"), .newThread(project: "p1")] && !calls.reads[0].sure)
        #expect(r.searchHits(for: "the readme needs a section").isEmpty)
    }

    @Test func aKeystrokeCancelsTheReadAndOnlyTheLastWordsAreReadAndLanded() async {
        let calls = Calls()
        let r = reader(calls)
        r.read("fix the login red", selected: nil, mentions: [])
        r.read("fix the login redirect", selected: nil, mentions: [])
        await waitUntil { !calls.reads.isEmpty }
        #expect(calls.jev == ["fix the login redirect"] && calls.reads.map(\.draft) == ["fix the login redirect"])
        // The same ask again while it is under way is kept, not started over.
        r.read("fix the login redirect and more", selected: nil, mentions: [])
        r.read("fix the login redirect and more", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.jev.count == 2)
    }

    @Test func aKeystrokeCancelsASonnetCallUnderWayAndItsLateAnswerIsNeverEmitted() async {
        let calls = Calls()
        let gate = Gate()
        let r = reader(calls, p: 0.5)
        r.decide = { text, _, _, _ in
            calls.decided.append(text)
            // Ignores cancellation, as an answer that was already in flight would.
            await gate.wait()
            return Self.ask([.thread("th-docs")])
        }
        r.read("the readme needs a section", selected: nil, mentions: [])
        await waitUntil { calls.decided.count == 1 }
        r.read("the readme needs a section and a table", selected: nil, mentions: [])
        await gate.open()
        await waitUntil { calls.decided.count == 2 }
        // The first answer arrived after the second ask started: it is dropped, only the newer words land.
        await waitUntil { !calls.reads.isEmpty }
        #expect(calls.reads.map(\.draft) == ["the readme needs a section and a table"])
    }

    @Test func theSameWordsOnTheSameBoardReuseTheAnswerAndAnotherBoardAsksAgain() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5, sonnet: Self.ask([.thread("th-docs")]))
        r.read("the readme needs a section", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 1 }
        r.read("the readme needs a section", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.jev.count == 1 && calls.decided.count == 1 && calls.reads[1] == calls.reads[0])
        // Another open card is another request for Sonnet; another board asks Jev again too.
        r.read("the readme needs a section", selected: "th-login", mentions: [])
        await waitUntil { calls.reads.count == 3 }
        #expect(calls.decided.count == 2 && calls.jev.count == 1)
        calls.board = "b2"
        r.read("the readme needs a section", selected: "th-login", mentions: [])
        await waitUntil { calls.reads.count == 4 }
        #expect(calls.jev.count == 2 && calls.decided.count == 3)
    }

    @Test func aReturnBeforeTheReadSkipsThePausesAndDoesNotStartTheCallAgain() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5, sonnet: Self.ask([.thread("th-docs")]), pauses: (60_000, 120_000))
        r.read("the readme needs a section", selected: nil, mentions: [])
        r.now("the readme needs a section")
        await waitUntil { !calls.reads.isEmpty }
        #expect(calls.jev.count == 1 && calls.decided.count == 1)
        // Nothing under way for the words (never read): now reads them at once.
        r.now("and the changelog too please")
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.reads[1].draft == "and the changelog too please")
    }

    @Test func aShortDraftOrNoDeciderIsOnlyThePrior() async {
        let calls = Calls()
        let r = reader(calls)
        r.read("ok do it", selected: "th-docs", mentions: [])
        await waitUntil { calls.reads.count == 1 }
        #expect(calls.reads[0] == RouterRead(draft: "ok do it", places: [.thread("th-docs")], sure: true))
        r.read("ok do it", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.reads[1] == RouterRead(draft: "ok do it", places: [], sure: false))
        #expect(calls.jev.isEmpty && calls.decided.isEmpty)
        // A decider that can't decide: the read still lands, so the row stops reading.
        r.allowed = { false }
        r.read("long enough to be read", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 3 }
        #expect(calls.reads[2].places.isEmpty && calls.jev.isEmpty)
    }

    @Test func aFailedSonnetCallLandsTheOpenCardAsThePlace() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5)
        r.decide = { _, _, _, _ in nil }
        r.read("the readme needs a section", selected: "th-docs", mentions: [])
        await waitUntil { !calls.reads.isEmpty }
        #expect(calls.reads[0].places == [.thread("th-docs")] && calls.decisions[0] == nil)
    }

    // MARK: Decision to read

    @Test func aSurePlaceThatCantBeSentToAnymoreIsNoAnswerAndAnAnswerHereIsHere() {
        let sure = RouterProjectDecision(kind: .thread("th-login"), confidence: 0.95, decider: .sonnet)
        let gone = RouterReader.read("fix it now please", decision: sure, selected: nil, eligible: { _ in false })
        #expect(gone.places.isEmpty && !gone.sure)
        let here = RouterReader.read("what runs now?", decision: RouterProjectDecision(kind: .answer, confidence: 0.9, decider: .sonnet),
                                       selected: "th-login", eligible: { _ in true })
        #expect(here.places == [.here] && here.sure)
        let some = RouterReader.read("fix it now please", decision: Self.ask([.thread("th-login"), .thread("th-docs"), .thread("th-login")]),
                                       selected: nil, eligible: { $0 != RouteTarget.thread("th-docs").targetID })
        #expect(some.places == [.thread("th-login")] && !some.sure)
    }

    /// Holds a call until the test opens the gate.
    actor Gate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async { if opened { return }; await withCheckedContinuation { waiting.append($0) } }
        func open() { opened = true; waiting.forEach { $0.resume() }; waiting = [] }
    }

    // MARK: Sonnet's guards and the typing trace

    @Test func sonnetStartsOnlyAfterTenNewCharactersSinceHisLastStartAndAReturnSkipsTheGuard() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5)
        r.read("the readme needs a section", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 1 }
        #expect(calls.decided.count == 1)
        // Two more characters: Jev reads again, Sonnet is not started, and the page gets the prior alone.
        r.read("the readme needs a section.", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.jev.count == 2 && calls.decided.count == 1 && r.decisions == 1)
        #expect(calls.reads[1].places.isEmpty && !calls.reads[1].sure)
        // Ten more than at his last start: he starts.
        r.read("the readme needs a section for the install steps", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 3 }
        #expect(calls.decided.count == 2)
        // A Return reads at once, whatever the length since.
        r.now("the readme needs a section for the install steps!")
        await waitUntil { calls.reads.count == 4 }
        #expect(calls.decided.count == 3)
    }

    @Test func aDraftShorterThanTwelveCharactersStartsNoModelAndJevSureNeverStartsSonnet() async {
        let calls = Calls()
        let r = reader(calls, p: 0.5)
        r.read("fix the bug", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 1 }
        #expect(calls.jev.isEmpty && calls.decided.isEmpty)
        let sure = reader(calls)
        sure.read("fix the login redirect", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        #expect(calls.decided.isEmpty && sure.decisions == 0)
    }

    @Test func eachPauseStartSkipAndCancelIsLoggedWithTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typing-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DeciderLog(url: url)
        let calls = Calls()
        let r = reader(calls, p: 0.5)
        r.log = log
        r.read("the readme needs a section", selected: nil, mentions: [])
        r.read("the readme needs a section.", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 1 }
        r.read("the readme needs a section..", selected: nil, mentions: [])
        await waitUntil { calls.reads.count == 2 }
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let events = lines.compactMap { $0["event"] as? String }
        #expect(lines.allSatisfy { $0["type"] as? String == "typing" && $0["at"] is String && $0["sinceKeyMs"] is Int })
        #expect(events.contains("cancel") && events.contains("pause") && events.contains("skip"))
        #expect(events.filter { $0 == "start" }.count >= 2)
    }
}
