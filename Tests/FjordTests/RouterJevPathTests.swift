import Foundation
import Testing
@testable import Fjord

/// E5's Jev-led path: the fusion and the BM25 give the Python's numbers (`deciders-t3/e5/fusion.py`, `build.py`, on synthetic
/// rows), the gates send only to an idle thread at P ≥ 0.90 with little route mass on running threads, the decider runs it in
/// first (it sends when sure, else Sonnet decides) and never for an unattended action, the log keeps its answer, and the
/// composer's preview reads a draft once after a pause, drops stale reads and hands its answer to the send. Invented boards only.
@MainActor
@Suite(.serialized) struct RouterJevPathTests {
    // MARK: The math, against the Python

    /// lp fin0 fin1 new nc an nc_lead lx_said
    static func row(_ v: [Double]) -> JevPath.Features {
        JevPath.Features(lp: v[0], fin0: v[1], fin1: v[2], new: v[3], nc: v[4], an: v[5], ncLead: v[6], lxSaid: v[7])
    }

    @Test func theFusionGivesThePythonsProbabilities() {
        let a = JevPath.fuse([Self.row([log(0.6), 1, 0, 0, 0.9, 0.8, 0.7, 1.0]), Self.row([log(0.3), 0, 1, 0, 0.2, 0.1, 0, 0.4]),
                              Self.row([log(0.1), 0, 0, 1, 0, 0, 0, 0])])
        for (got, want) in zip(a, [0.9685965052, 0.0271993427, 0.004204152]) { #expect(abs(got - want) < 1e-9) }
        // Jev's p floored at 0.001 before its log.
        let b = JevPath.fuse([Self.row([log(max(0.0001, JevPath.floor)), 0, 0, 0, 0, 0, 0, 0]), Self.row([log(0.5), 1, 0, 0, 0.5, 0.5, 0.1, 0.2]),
                              Self.row([log(0.5), 0, 0, 1, 0, 0, 0, 0])])
        for (got, want) in zip(b, [0.0014717116, 0.9176789353, 0.0808493532]) { #expect(abs(got - want) < 1e-9) }
        #expect(JevPath.features == ["lp", "fin0", "fin1", "new", "nc", "an", "nc_lead", "lx_said"])
    }

    @Test func wordsAndBM25AreThePythons() {
        #expect(JevPath.words("Fix the Login-redirect, please: café_au_lait 12345 ok ab") == ["fix", "login", "redirect", "café", "lait", "12345"])
        let q = JevPath.words("fix the login redirect on staging")
        let s = JevPath.bm25(q, [("a", JevPath.words("I fixed the login redirect; staging still loops on login.")),
                                 ("b", JevPath.words("The README now explains staging setup.")), ("c", [])])
        #expect(abs(s["a"]! - 2.1315650345) < 1e-9)
        #expect(abs(s["b"]! - 0.4531509095) < 1e-9)
        #expect(s["c"] == 0)
    }

    @Test func aLeadIsOverTheBestOther() {
        #expect(abs(JevPath.lead(["a": 0.9, "b": 0.3, "c": 0.5], "a") - 0.4) < 1e-12)
        #expect(JevPath.lead(["a": 0.9, "b": 0.3], "b") < 0)
        #expect(JevPath.lead(["a": 0.7], "a") == 0.7)
    }

    // MARK: The board and the request

    /// Four idle threads and a running one, newest first: i1, run, i2, i3, i4.
    static func board() -> DeciderBoard {
        var b = DeciderBoard(projects: ["fjord", "silo"], threads: [
            .init(id: "i1", key: "T-i1", project: "fjord", title: "Fix the login redirect", flag: .finished, minutesIdle: 2,
                  said: "I fixed the login redirect; staging still loops.", youSaid: "fix the login", youLatest: true),
            .init(id: "rn", key: "T-run", project: "fjord", title: "Router redesign", flag: .running, minutesIdle: 3, said: "on it"),
            .init(id: "i2", key: "T-i2", project: "silo", title: "Disk quota", flag: .finished, minutesIdle: 30, said: "quota is in"),
            .init(id: "i3", key: "T-i3", project: "silo", title: "Snapshot restore", flag: .waiting, minutesIdle: 60, said: "Which id?",
                  waiting: "Which snapshot id?"),
            .init(id: "i4", key: "T-i4", project: "fjord", title: "Docs pass", flag: .finished, minutesIdle: 90, said: "docs done"),
        ])
        b.projectIDs = ["fjord": "P-fjord", "silo": "P-silo"]
        return b
    }

    @Test func checksGoToTheThreeLatestIdleThreadsAndTheWireIsInOrder() throws {
        let r = JevPath.request("fix the login redirect on staging", Self.board())
        #expect(Set(r.ans.values) == ["T-i1", "T-i2", "T-i3"])
        #expect(Set(r.next.values) == ["T-i1", "T-i2", "T-i3"])
        #expect(r.idleRank["T-i1"] == 0 && r.idleRank["T-i2"] == 1 && r.idleRank["T-run"] == nil)
        #expect(r.order.first == "route" && r.order.last == "fjord")
        #expect(r.options.map(\.place) == [.thread("T-i1"), .thread("T-run"), .thread("T-i2"), .thread("T-i3"), .thread("T-i4"),
                                          .newThread(project: "P-fjord"), .newThread(project: "P-silo")])
        let wire = String(decoding: try JevClient.$model.withValue(JevClient.routingModel) {
            try JevClient.$questionOrder.withValue(r.order) { try JevClient.requestData(r.questions, about: r.state) }
        }, as: UTF8.self)
        #expect(wire.contains("\"model\":\"jev-1.14.0\""))
        // E5's key order: the question before the thread, the kind before the project and the now.
        let ans = try #require(wire.range(of: "\"question\":\"Does `message` reply"))
        let thread = try #require(wire.range(of: "\"thread\":{\"title\":\"Fix the login redirect\",\"status\":\"finished\""))
        #expect(ans.lowerBound < thread.lowerBound)
        #expect(wire.contains("{\"kind\":\"existing thread\",\"project\":\"fjord\",\"now\":\"Fix the login redirect | finished, 2m ago"))
        #expect(wire.contains("(your latest message went to this thread)"))
        #expect(!wire.contains("ordered-"))
    }

    /// Jev answering the request: route probabilities by place, `ans` and `nx_choice` by thread key, "for Fjord itself?".
    static func answers(_ r: JevPath.Request, route: [JevPath.Place: Double], ans: [String: Double] = [:], next: [String: Double] = [:],
                        fjord: Double = 0.01) -> [String: JevClient.Answer] {
        var probs: [String: Double] = [:]
        for o in r.options { probs[o.name] = route[o.place] ?? 0 }
        let best = probs.max { $0.value < $1.value }!
        var out: [String: JevClient.Answer] = ["route": .choice(.init(choice: best.key, confidence: best.value, probabilities: probs)),
                                               "fjord": .noul(fjord)]
        for (q, key) in r.ans { out[q] = .noul(ans[key] ?? 0.05) }
        for (q, key) in r.next {
            let p = next[key] ?? 0.05
            out[q] = .choice(.init(choice: p >= 0.5 ? "yes" : "no", confidence: max(p, 1 - p), probabilities: ["yes": p, "no": 1 - p]))
        }
        return out
    }

    static let message = "fix the login redirect on staging"

    func result(route: [JevPath.Place: Double], ans: [String: Double] = [:], next: [String: Double] = [:], fjord: Double = 0.01) -> JevPath.Result {
        let r = JevPath.request(Self.message, Self.board())
        return JevPath.result(Self.answers(r, route: route, ans: ans, next: next, fjord: fjord), r, message: Self.message)!
    }

    @Test func theFeaturesAreFusionsRows() throws {
        let f = result(route: [.thread("T-i1"): 0.6, .thread("T-i2"): 0.3, .thread("T-run"): 0.05, .newThread(project: "P-fjord"): 0.05],
                       ans: ["T-i1": 0.9], next: ["T-i1": 0.95, "T-i2": 0.25])
        let i1 = try #require(f.rows.first { $0.place == .thread("T-i1") }).features
        #expect(abs(i1.lp - log(0.6)) < 1e-12 && i1.fin0 == 1 && i1.fin1 == 0 && i1.an == 0.9 && i1.nc == 0.95)
        #expect(abs(i1.ncLead - 0.7) < 1e-12)  // 0.95 over the best other of the 3 (0.25, and 0.05 for the third)
        #expect(i1.lxSaid == 1)
        let i2 = try #require(f.rows.first { $0.place == .thread("T-i2") }).features
        #expect(i2.fin1 == 1 && i2.ncLead == 0)
        // The running thread and the fourth idle one get no recency and no checks; a new thread is `new` alone.
        let run = try #require(f.rows.first { $0.place == .thread("T-run") }).features
        #expect(run.fin0 == 0 && run.nc == 0 && run.an == 0)
        let i4 = try #require(f.rows.first { $0.place == .thread("T-i4") }).features
        #expect(i4.lp == log(JevPath.floor) && i4.nc == 0)
        #expect(try #require(f.rows.first { $0.place == .newThread(project: "P-fjord") }).features.new == 1)
        #expect(abs(f.rows.map(\.p).reduce(0, +) - 1) < 1e-9)
        #expect(f.rows.map(\.p) == f.rows.map(\.p).sorted(by: >))
    }

    // MARK: The gates

    static let sure: [JevPath.Place: Double] = [.thread("T-i1"): 0.9, .thread("T-i2"): 0.05, .newThread(project: "P-fjord"): 0.05]

    @Test func itSendsOnlyToAnIdleThreadAtTheBar() {
        let f = result(route: Self.sure, ans: ["T-i1": 0.95], next: ["T-i1": 0.97])
        #expect(f.p >= JevPath.sendBar)
        #expect(f.send() == "T-i1" && f.abstain == nil && f.preview?.place == .thread("T-i1"))
        // A place you waved off is never sent to.
        #expect(f.send(notTo: RouteTarget.thread("T-i1").targetID) == nil)
        // Unsure: nothing sent, nothing previewed.
        let low = result(route: [.thread("T-i1"): 0.4, .thread("T-i2"): 0.35, .newThread(project: "P-fjord"): 0.25])
        #expect(low.abstain == .below && low.preview == nil)
    }

    @Test func runningThreadsAndNewThreadsAndFjordAbstain() {
        // Jev's route mass on running threads at 0.25 or more: Sonnet decides, though the idle pick is sure.
        let mass = result(route: [.thread("T-i1"): 0.7, .thread("T-run"): 0.3], ans: ["T-i1": 0.99], next: ["T-i1": 0.99])
        #expect(mass.top?.place == .thread("T-i1") && mass.p >= 0.9)
        #expect(mass.abstain == .runningMass && mass.send() == nil)
        // A running pick is never sent to, nor shown.
        let run = result(route: [.thread("T-run"): 0.99, .thread("T-i1"): 0.01])
        #expect(run.top?.place == .thread("T-run") && run.abstain == .running && run.preview == nil)
        // A new thread is never sent here.
        let new = result(route: [.newThread(project: "P-silo"): 0.999, .thread("T-i1"): 0.001])
        #expect(new.top?.place == .newThread(project: "P-silo") && new.abstain == .newThread)
        // "For Fjord itself?" at 0.3: Sonnet's.
        let fjord = result(route: Self.sure, ans: ["T-i1": 0.95], next: ["T-i1": 0.97], fjord: 0.3)
        #expect(fjord.abstain == .fjord)
    }

    // MARK: The decider

    final class Calls { var jev = 0; var sonnet = 0; var questions: [[String]] = [] }

    static func jev(_ calls: Calls, route: [JevPath.Place: Double] = sure, ans: [String: Double] = ["T-i1": 0.95],
                    next: [String: Double] = ["T-i1": 0.97]) -> JevAsker {
        { questions, state in
            calls.jev += 1
            calls.questions.append(questions.keys.sorted())
            let r = JevPath.request(state["message"] ?? "", Self.board())
            return Self.answers(r, route: route, ans: ans, next: next)
        }
    }

    static func sonnet(_ calls: Calls, session: String = "T-i2") -> RouterProjectDecider.Sonnet {
        { _ in
            await MainActor.run { calls.sonnet += 1 }
            return RouterContextAnswer(action: "follow_up", project: "silo", session: session, confidence: 0.85)
        }
    }

    /// A context with nothing in it: these tests are about who decides, not what the context says.
    static let ctx = DeciderContext.Built(system: "", blocks: [], ids: [:], live: [], archive: [], key: "k", sizes: [:])

    func decider(_ calls: Calls, sonnet: Bool = true) -> RouterProjectDecider {
        var d = RouterProjectDecider(jev: Self.jev(calls), sonnet: sonnet ? Self.sonnet(calls) : nil)
        d.fusedPath = true
        return d
    }

    @Test func whenItMaySendASureAnswerSkipsSonnet() async throws {
        let calls = Calls()
        let d = try await decider(calls, ).decide(Self.message, in: Self.board(), context: { Self.ctx })
        #expect(d.decider == .jev && d.kind == .thread("T-i1") && d.action == "fused")
        #expect(calls.sonnet == 0)
        // Not sure: Sonnet as today.
        let unsure = Calls()
        var u = RouterProjectDecider(jev: Self.jev(unsure, route: [.thread("T-i1"): 0.4, .thread("T-i2"): 0.6], ans: [:], next: [:]),
                                     sonnet: Self.sonnet(unsure))
        u.fusedPath = true
        let ud = try await u.decide(Self.message, in: Self.board(), context: { Self.ctx })
        #expect(ud.decider == .sonnet && unsure.sonnet == 1)
        // Sonnet decided: the fused answer rides along for the log.
        let ride = try #require(await ud.fused?.value)
        #expect(ride.send() == nil && unsure.jev == 1)
        // A place waved off isn't sent to by the path.
        let off = Calls()
        let od = try await decider(off, ).decide(Self.message, in: Self.board(), context: { Self.ctx }, notTo: RouteTarget.thread("T-i1").targetID)
        #expect(od.decider == .sonnet && off.sonnet == 1)
    }

    @Test func anUnattendedActionNeverTakesThePath() async throws {
        let calls = Calls()
        let action = RouterActionSource(origin: SessionOrigin(category: "PRs", thing: "PR 1", actionID: "a", runID: "r", runtimeMode: nil),
                                        repo: "acme/silo")
        let d = try await decider(calls, ).decide(Self.message, in: Self.board(), context: { Self.ctx }, action: action)
        #expect(d.fused == nil && d.decider == .sonnet && calls.jev == 0)
    }

    @Test func withoutSonnetTheFusedRankingOrdersTheAsk() async throws {
        let calls = Calls()
        var d = RouterProjectDecider(jev: Self.jev(calls, route: [.thread("T-i2"): 0.5, .thread("T-i1"): 0.3, .newThread(project: "P-silo"): 0.2],
                                                   ans: [:], next: [:]), sonnet: nil)
        d.fusedPath = true
        let out = try await d.decide(Self.message, in: Self.board(), context: { Self.ctx })
        guard case .ask(let places) = out.kind else { Issue.record("expected an ask"); return }
        #expect(places.count == 3 && out.decider == .jev)
        #expect(calls.jev == 1)
    }

    @Test func thePreviewsAnswerIsReusedOnTheSameBoardOnly() async throws {
        let first = Calls()
        let shown = try #require(await (try decider(first, ).decide(Self.message, in: Self.board(), context: { Self.ctx })).fused?.value)
        let calls = Calls()
        let d = try await decider(calls, ).decide(Self.message, in: Self.board(), context: { Self.ctx }, reuse: shown)
        #expect(d.decider == .jev && calls.jev == 0 && calls.sonnet == 0)
        #expect(try #require(await d.fused?.value).reused)
        // The board moved on (a new reply): asked again.
        var moved = Self.board()
        moved.threads[0].said += " Now it is fixed."
        let again = Calls()
        _ = try await decider(again, ).decide(Self.message, in: moved, context: { Self.ctx }, reuse: shown)
        #expect(again.jev == 1)
    }

    // MARK: The log

    @Test func theLogKeepsTheFusedAnswerAndAPreviewMiss() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fused-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DeciderLog(url: url)
        let f = result(route: Self.sure, ans: ["T-i1": 0.95], next: ["T-i1": 0.97])
        let decision = RouterProjectDecision(kind: .thread("T-i2"), confidence: 0.85, decider: .sonnet)
        let shown = RouterPreview.Shown(text: Self.message, target: RouteTarget.thread("T-i1").targetID, p: f.p, decider: "jev", sure: true)
        log.decision(id: UUID(), message: Self.message, decision: decision, board: "b", candidates: [], sent: "sent", fused: f,
                     preview: shown, focus: .init(open: "T-i2", lastTold: "T-i1", unseen: ["T-i3"]))
        log.flush()
        let line = try #require(String(contentsOf: url, encoding: .utf8).split(separator: "\n").first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["path"] as? String == "sonnet")
        let fused = try #require(json["fused"] as? [String: Any])
        #expect(fused["agrees"] as? Bool == false && fused["wouldSend"] as? Bool == true)
        #expect(fused["pick"] as? String == "t3-thread:T-i1" && fused["model"] as? String == "jev-1.14.0")
        let rows = try #require(fused["rows"] as? [[String: Any]])
        #expect((rows.first?["features"] as? [String: Double])?["fin0"] == 1)
        #expect((fused["nextChoice"] as? [String: Double])?["T-i1"] == 0.97)
        let preview = try #require(json["preview"] as? [String: Any])
        #expect(preview["miss"] as? Bool == true && preview["forTheseWords"] as? Bool == true)
        #expect((json["focus"] as? [String: Any])?["lastTold"] as? String == "T-i1")
    }

    // MARK: The destination in the composer

    func store() -> Store {
        let s = Store.reading([
            T3Fixture.shell("th-login", title: "Fix the login redirect", project: "p1", minutes: 2),
            T3Fixture.shell("th-docs", title: "Write the README", project: "p1", minutes: 40),
        ], projects: [T3Fixture.project("p1", title: "lookout", root: "/code/lookout")])
        s.router.enabled = true
        return s
    }

    /// A sure answer for `thread` (or an unsure one), as the fused path would give it.
    static func answer(_ thread: String, p: Double) -> JevPath.Result {
        let rows = [JevPath.Row(place: .thread(thread), name: thread, jev: p, features: .init(), p: p, running: false),
                    JevPath.Row(place: .newThread(project: "p1"), name: "new", jev: 1 - p, features: .init(new: 1), p: 1 - p, running: false)]
        return JevPath.Result(rows: rows, ans: [:], next: [:], fjord: nil, runningMass: 0, bm25: [:], twins: [], requestHash: "h", key: "k")
    }

    final class Reads { var words: [String] = []; var decided: [String] = []; var reused: [Bool] = []; var board = "b1" }

    /// Jev at `p` for th-login; Sonnet (when Jev isn't sure) answers `sonnet`.
    func preview(_ reads: Reads, p: Double = 0.95, sonnet: RouterProjectDecision.Kind? = nil) -> RouterPreview {
        let preview = RouterPreview()
        preview.jevDelay = .milliseconds(20)
        preview.sonnetDelay = .milliseconds(60)
        preview.boardKey = { reads.board }
        preview.read = { text, _ in reads.words.append(text); return Self.answer("th-login", p: p) }
        preview.decide = { text, _, _, reuse in
            reads.decided.append(text)
            reads.reused.append(reuse != nil)
            return RouterProjectDecision(kind: sonnet ?? .ask([]), confidence: 0.6, decider: .sonnet)
        }
        return preview
    }

    static let login = RouteTarget.thread("th-login").targetID
    static let docs = RouteTarget.thread("th-docs").targetID
    static let newInP1 = RouteTarget.newThread(project: "p1").targetID

    @Test func jevSureShowsTheThreadAndSonnetIsNotAsked() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads)
        // Too short: nothing read.
        p.update(text: "fix login", context: RouterContext(), store: s)
        #expect(p.asking == nil)
        // Keystrokes inside the pause: only the last words are read.
        p.update(text: "fix the login red", context: RouterContext(), store: s)
        p.update(text: "fix the login redirect", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        #expect(reads.words == ["fix the login redirect"] && reads.decided.isEmpty)
        #expect(p.destination?.sure == true && p.highlighted == Self.login && p.markedThread == "th-login")
        // The same words again: nothing read again.
        p.update(text: "fix the login redirect", context: RouterContext(), store: s)
        #expect(p.asking == nil && reads.words.count == 1)
    }

    @Test func notSureSonnetDecidesAfterTheLongerPauseOnceReusingJev() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads, p: 0.5, sonnet: .ask([.thread("th-docs"), .thread("th-login"), .newThread(project: "p1")]))
        p.update(text: "the readme needs a section", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        #expect(reads.words.count == 1 && reads.decided == ["the readme needs a section"] && reads.reused == [true])
        // The guess highlighted, up to 2 alternatives; Return would send to the guess.
        #expect(p.destination?.sure == false && p.destination?.options == [Self.docs, Self.login, Self.newInP1])
        #expect(p.highlighted == Self.docs)
        // A click picks another; the menu always offers a new thread.
        p.pick(Self.login, store: s)
        #expect(p.highlighted == Self.login)
        #expect(p.menu(store: s).map(\.target).contains(Self.newInP1))
        // Sending carries what was shown, not sure since you picked.
        #expect(p.carried(for: "the readme needs a section")?.sure == false)
    }

    @Test func aKeystrokeCancelsTheDecisionUnderWay() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads, p: 0.5, sonnet: .thread("th-docs"))
        // The first words' decision is held until it is cancelled.
        let decide = p.decide!
        var started: [String] = []
        p.decide = { text, tagged, notTo, reuse in
            started.append(text)
            if text == "the readme needs a section" { try? await Task.sleep(for: .seconds(30)) }
            return await decide(text, tagged, notTo, reuse)
        }
        p.update(text: "the readme needs a section", context: RouterContext(), store: s)
        await waitUntil { started.count == 1 }
        p.update(text: "the readme needs a section on setup", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        #expect(started == ["the readme needs a section", "the readme needs a section on setup"])
        #expect(p.destination?.text == "the readme needs a section on setup" && p.destination?.sure == true)
    }

    @Test func theSameWordsOnTheSameBoardReuseTheAnswer() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads, p: 0.5, sonnet: .thread("th-docs"))
        p.update(text: "the readme needs a section", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        #expect(p.ready(for: "the readme needs a section")?.decision.kind == .thread("th-docs"))
        #expect(p.ready(for: "the readme needs a section!") == nil)
        // The board moved on: no answer to reuse.
        reads.board = "b2"
        #expect(p.ready(for: "the readme needs a section") == nil)
    }

    @Test func returnBeforeAnAnswerWaitsThenSendsWhenSure() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads, p: 0.5, sonnet: .thread("th-docs"))
        p.update(text: "the readme needs a section", context: RouterContext(), store: s)
        var sent = 0
        p.waitAndSend("the readme needs a section", tagged: nil) { sent += 1 }
        #expect(p.deciding && p.waiting == "the readme needs a section")
        await waitUntil { sent == 1 }
        #expect(p.waiting == nil && p.destination?.sure == true && reads.decided.count == 1)
    }

    @Test func returnBeforeAnUnsureAnswerShowsThePlacesAndWaitsForASecondReturnOrAClick() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads, p: 0.5, sonnet: .ask([.thread("th-docs"), .thread("th-login")]))
        var sent = 0
        p.waitAndSend("the readme needs a section", tagged: nil) { sent += 1 }
        await waitUntil { p.destination != nil }
        #expect(sent == 0 && p.waiting == nil && p.highlighted == Self.docs)
        // A second Return finds the answer for these words: the guess.
        #expect(p.ready(for: "the readme needs a section")?.sure == false)
        // Or a click on another place sends the words there.
        #expect(p.clickSends == "the readme needs a section")
        p.pick(Self.login, store: s)
        #expect(sent == 1 && p.pinned == Self.login && p.clickSends == nil)
    }

    @Test func escWavesTheGuessOffAndAPickedPlaceHolds() async throws {
        let s = store()
        let reads = Reads()
        let p = preview(reads)
        p.update(text: "fix the login redirect", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        p.dismiss()
        #expect(p.dismissed == Self.login && p.destination == nil)
        // Cleared draft: starts over.
        p.update(text: "", context: RouterContext(), store: s)
        #expect(p.dismissed == nil)
        // A pick holds: nothing is read again while it is there.
        p.update(text: "fix the login redirect", context: RouterContext(), store: s)
        await waitUntil { p.destination != nil }
        p.pick(Self.docs, store: s)
        p.update(text: "fix the login redirect again", context: RouterContext(target: p.pinned), store: s)
        #expect(p.asking == nil && p.pinned == Self.docs)
    }
}
