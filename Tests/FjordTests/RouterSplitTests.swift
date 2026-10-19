import Foundation
import Testing
@testable import Fjord

/// A message that goes to several places (docs/design/spec/router.md, "Several places"): the tags cut it, a sentence after a
/// tag's first is checked by Jev, tags that don't each open a sentence go to the divider, and each part runs as a message of
/// its own: its words, its tools, its entry. The model, Jev and the sender are stood in for.
@MainActor
@Suite(.serialized) struct RouterSplitTests {
    typealias Fakes = RouterDispatcherTests.Fakes

    /// A store and a dispatcher whose sends are signed as the real ones are (so a part's delivery is known), with each send's
    /// words recorded as the send gate has them: the turn's, with the addressing taken out.
    @MainActor final class World {
        let dir = TempDir()
        let store: Store
        let dispatcher: RouterDispatcher
        let fakes = Fakes()
        /// What each preparation was for: the session, and the words of its turn.
        var said: [(session: String, words: String)] = []
        var cancels: [RouterDecision.Delivered] = []

        init() {
            let s = InboxFixture.store([])
            s.categories = [InboxStore.ci]
            s.router.enabled = true
            s.agents.enabled = true
            s.claudeSessions = [
                "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
                "local_b": ClaudeSession(id: "local_b", title: "Update the docs", folder: "/code/docs", lastActivity: Date().addingTimeInterval(-60)),
                "local_c": ClaudeSession(id: "local_c", title: "Ship it", folder: "/code/ci", lastActivity: Date().addingTimeInterval(-120)),
            ]
            s.router.cards = [RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "Fix the login bug",
                                         folder: "/code/lookout", text: "Which database?", createdAt: Date())]
            store = s
            dispatcher = RouterDispatcher(store: s)
            fakes.install(dispatcher)
            fakes.store = s
            dispatcher.effects.prepare = { [unowned self] tools, session in
                fakes.prepared.append(session)
                let turn = tools.turnText ?? ""
                let words = (try? Addressing.edit(turn, pills: tools.turnPills).text) ?? turn
                said.append((session, words))
                let signed = RelaySigner.sign(body: words, target: "cli-\(session)", key: RelaySigning.key)
                return RouterDispatcher.Delivery(to: "peer-\(session)", text: signed, body: words, original: turn, rephrased: words != turn,
                                                 session: session, newSessionIn: nil)
            }
            dispatcher.effects.abortable = { _ in true }
            dispatcher.effects.cancel = { [unowned self] sent in
                cancels.append(sent)
                return .aborted
            }
            dispatcher.traceLog = RouterTraceLog(url: dir.path("router-trace.jsonl"))
        }

        var f: Fakes { fakes }

        /// The message the composer would send, with its context.
        func message(_ parts: [RouterMessagePart], replyTo: String? = nil, target: String? = nil) -> (text: String, context: RouterContext) {
            let (text, mentions) = store.composeForRouter(parts)
            var context = RouterContext(replyTo: replyTo, target: target)
            context.tag(mentions)
            return (text, context)
        }

        func entry(_ id: UUID?) -> RouterDecision? { store.router.decisions.first { $0.id == id } }
        func record(_ id: UUID?) -> RouterDecision? { id.flatMap { store.router.record($0) } }

        /// The message's run and every part's are over.
        func finishAll(_ id: UUID?) async {
            await waitUntil { id.map { fakes.finished.contains($0) } ?? true }
            for part in entry(id)?.parts.map(\.id) ?? [] where part != id {
                await waitUntil { fakes.finished.contains(part) }
            }
        }

        /// What the parts said, by session, once the run is over.
        func words(of session: String) -> [String] { said.filter { $0.session == session }.map(\.words) }

        func trace() -> [RouterTrace] {
            dispatcher.traceLog.flush()
            guard let url = dispatcher.traceLog.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap { try? decoder.decode(RouterTrace.self, from: Data($0.utf8)) }
        }

        /// A form waiting on the card of the login session: "Yes" or "No".
        func askYesNo() {
            store.claudeSessions["local_a"]?.cliID = "cli-a"
            store.router.cards[0].toolUseID = "call-1"
            store.pendingForms["cli-a"] = PendingForm(id: "f", cliSessionID: "cli-a", transcriptPath: "", questions: [
                .init(question: "Continue?", header: "Go", multiSelect: false,
                      options: [.init(label: "Yes", description: ""), .init(label: "No", description: "")]),
            ], createdAt: Date(), pid: 1, toolUseID: "call-1")
        }
    }

    private let a = RouterMessagePart.pointer(.session("local_a"))
    private let b = RouterMessagePart.pointer(.session("local_b"))
    private let c = RouterMessagePart.pointer(.session("local_c"))

    // MARK: Tags

    @Test func twoSessionTagsAreTwoPartsEachSentWithItsOwnWords() async throws {
        let w = World()
        let (text, context) = w.message([a, .text(" fix the flaky test. "), b, .text(" add the page")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let entry = try #require(w.entry(id))
        #expect(entry.parts.count == 2 && entry.parts.map(\.text) == ["@Fix the login bug fix the flaky test.", "@Update the docs add the page"])
        #expect(w.words(of: "local_a") == ["fix the flaky test."] && w.words(of: "local_b") == ["add the page"])
        #expect(w.f.ranks == 0 && w.f.sameAsked.isEmpty && w.f.divideRequests.isEmpty)
        // Each part has its own delivery, its place, and is your pick.
        for part in entry.parts {
            let record = try #require(w.record(part.id))
            #expect(record.delivered != nil && record.outcome == .done && record.decision.confirmed == true)
            #expect(record.done.contains { if case .sent = $0 { true } else { false } })
        }
        #expect(entry.parts.map(\.place) == ["session:local_a", "session:local_b"] || entry.parts.map(\.place) == ["answer:local_a#w1", "session:local_b"]
            || entry.parts.map(\.place) == ["session:local_a", "answer:local_b#w1"])
        // The log: one decided line, "split", with the places.
        let line = try #require(w.trace().first { $0.id == id && $0.path == "split" })
        #expect(line.action == "split" && line.parts?.count == 2)
        #expect(w.dispatcher.progress.isEmpty && w.dispatcher.flying.isEmpty)
    }

    @Test func tagsSideBySideShareTheWordsAfterThem() async throws {
        let w = World()
        let (text, context) = w.message([a, .text(" "), b, .text(" pull main")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.words(of: "local_a") == ["pull main"] && w.words(of: "local_b") == ["pull main"])
        #expect(w.entry(id)?.parts.count == 2)
        // Across a line break the group's pills are left out of the words.
        let (text2, context2) = w.message([a, .text("\n"), b, .text(" rebase")])
        let id2 = try #require(w.dispatcher.submit(text2, context: context2))
        await w.finishAll(id2)
        #expect(w.entry(id2)?.parts.map(\.text) == ["rebase", "rebase"])
        #expect(w.words(of: "local_a") == ["pull main", "rebase"] && w.words(of: "local_b") == ["pull main", "rebase"])
    }

    @Test func anArmedReplyTakesTheTextNoTagAddressesAndTheRestGoesToTheTag() async throws {
        let w = World()
        w.askYesNo()
        let (text, context) = w.message([.text("yes. "), b, .text(" add the page")], replyTo: "local_a#w1")
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        // "yes." answers the form on its own; docs gets only the rest.
        #expect(w.f.answered.map(\.card) == ["local_a#w1"] && w.f.answered.first?.answers["Continue?"] == "Yes")
        #expect(w.words(of: "local_a").isEmpty && w.words(of: "local_b") == ["add the page"])
        let parts = try #require(w.entry(id)?.parts)
        #expect(parts.map(\.text) == ["yes.", "@Update the docs add the page"])
        #expect(w.record(parts[0].id)?.done.contains(.answered(card: "Fix the login bug")) == true)
        #expect(w.f.ranks == 0 && w.f.divideRequests.isEmpty)
    }

    @Test func aChipsLaterSentenceIsCheckedAgainstItsFirst() async throws {
        let w = World()
        w.askYesNo()
        w.f.same = ["Also mute it.": 0.9]
        let (text, context) = w.message([.text("yes. Also mute it. "), b, .text(" add the page")], replyTo: "local_a#w1")
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.f.sameAsked.map(\.sentence) == ["Also mute it."] && w.f.sameAsked.map(\.tagged) == ["yes."])
        #expect(w.entry(id)?.parts.map(\.text) == ["yes. Also mute it.", "@Update the docs add the page"])
    }

    @Test func aProjectOnlyResultGoesToTheProjectNotToTheArmedReplyOrThePin() async throws {
        let w = World()
        w.askYesNo()
        // The reply is armed on the login card, but the only words are for the project: nothing answers the card.
        let (text, context) = w.message([.pointer(.project("/code/web")), .text(" fix the page")], replyTo: "local_a#w1")
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.f.answered.isEmpty && w.f.prepared.isEmpty && w.f.started.map(\.folder) == ["/code/web"])
        // A pinned session is no more the place of a message that is wholly for a project.
        let (text2, context2) = w.message([.pointer(.project("/code/web")), .text(" fix the page again")], target: "session:local_b")
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(text2, context: context2))
        await w.finishAll(id2)
        #expect(w.f.prepared.isEmpty && w.f.started.map(\.folder) == ["/code/web", "/code/web"])
    }

    @Test func aSentenceThatIsNotForTheTagIsRoutedAsAMessageOfItsOwn() async throws {
        let w = World()
        w.f.same = ["Mute notifications for an hour.": 0.2]
        w.f.ranked = [.init(target: "change_fjord", p: 0.97), .init(target: "unclear", p: 0.03)]
        let (text, context) = w.message([c, .text(" rerun the build. Mute notifications for an hour.")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let entry = try #require(w.entry(id))
        #expect(entry.parts.count == 2 && entry.parts.map(\.text) == ["@Ship it rerun the build.", "Mute notifications for an hour."])
        #expect(w.words(of: "local_c") == ["rerun the build."] && w.f.ranks == 1)
        // The Router's run gets that sentence only: nothing of the rest, nor the message's line in its recent decisions.
        let input = try #require(w.f.runs.first?.input)
        #expect(w.f.runs.count == 1 && w.f.runs[0].intent == .changeFjord)
        #expect(input.hasSuffix("The user's message:\nMute notifications for an hour.") || input.hasSuffix("Mute notifications for an hour."))
        #expect(!input.contains("rerun the build") && !input.contains("Ship it rerun"))
        // Jev placed it, you didn't: no example for the next ones.
        let fjord = try #require(entry.parts.last.flatMap { w.record($0.id) })
        #expect(fjord.decision.confirmed == nil && fjord.decision.targetID == "change_fjord")
    }

    @Test func twoSentencesForFjordMergeIntoAPartThatRunsWithTheToolsAChangeNeeds() async throws {
        let w = World()
        w.f.same = ["Which sessions are waiting?": 0.2, "Mute notifications for an hour.": 0.2]
        let rank = w.dispatcher.effects.rank
        // Jev places the question first and the change second, each sure.
        w.dispatcher.effects.rank = { tools, message, projects in
            var ranking = try await rank(tools, message, projects)
            ranking.scored = [.init(target: message.hasPrefix("Which") ? "question" : "change_fjord", p: 0.97), .init(target: "unclear", p: 0.03)]
            return ranking
        }
        let (text, context) = w.message([c, .text(" rerun the build. Which sessions are waiting? Mute notifications for an hour.")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let entry = try #require(w.entry(id))
        #expect(entry.parts.count == 2 && entry.parts.last?.text == "Which sessions are waiting? Mute notifications for an hour.")
        // One run for the part, with the tools of a change: the question alone couldn't do the second sentence.
        #expect(w.f.runs.count == 1 && w.f.runs[0].intent == .changeFjord)
        #expect(entry.parts.last.flatMap { w.record($0.id) }?.decision.targetID == "change_fjord")
    }

    @Test func aTagWithNoWordsAfterItIsNotSentAsAPartOfItsOwn() async throws {
        let w = World()
        // Docs would be woken with its bare address: it isn't, the words go to the login session as one part.
        let (text, context) = w.message([a, .text(" fix the build. "), b])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.said.map(\.session) == ["local_a"] && w.entry(id)?.parts.count == 1)
        // With another place that has words, the parts are theirs alone.
        let (text2, context2) = w.message([a, .text(" fix the build. "), b, .text(" add the page. "), c])
        let id2 = try #require(w.dispatcher.submit(text2, context: context2))
        await w.finishAll(id2)
        #expect(w.entry(id2)?.parts.map(\.text) == ["@Fix the login bug fix the build.", "@Update the docs add the page."])
        #expect(w.said.map(\.session) == ["local_a", "local_a", "local_b"] && w.words(of: "local_c").isEmpty)
    }

    @Test func aLoneTagWithASecondSentenceForItsPlaceIsOnePartAndAsksNothingElse() async throws {
        let w = World()
        w.f.same = ["Then add a test.": 0.9]
        let (text, context) = w.message([c, .text(" fix the build. Then add a test.")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let entry = try #require(w.entry(id))
        #expect(entry.parts.count == 1 && entry.parts[0].id == entry.id && w.f.ranks == 0)
        #expect(w.f.sameAsked.count == 1 && w.words(of: "local_c") == ["fix the build. Then add a test."])
        #expect(w.record(id)?.decision.confirmed == true && entry.delivered != nil)
    }

    @Test func aLoneTagWithASentenceJevDoesntPlaceAsksListingTheTagFirst() async throws {
        let w = World()
        w.f.same = ["Then add a test.": 0.2]
        w.f.ranked = [.init(target: "unclear", p: 1)]
        let (text, context) = w.message([c, .text(" fix the build. Then add a test.")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let ask = try #require(w.dispatcher.askBacks.first { $0.id == id })
        #expect(ask.options.first?.target == "session:local_c" && w.f.prepared.isEmpty)
        // Your pick sends the whole message there.
        w.f.finished = []
        #expect(w.dispatcher.pick(id, target: "session:local_c"))
        await w.finishAll(id)
        #expect(w.words(of: "local_c") == ["fix the build. Then add a test."])
    }

    @Test func aSentenceJevCantBeAskedAboutStaysWithItsTag() async throws {
        let w = World()
        w.dispatcher.effects.same = { _, _, _, _ in throw RouterTools.Failure("no TypeSafe key is set") }
        let (text, context) = w.message([c, .text(" fix the build. Then add a test.")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.words(of: "local_c") == ["fix the build. Then add a test."] && w.dispatcher.askBacks.isEmpty)
    }

    @Test func aLoneTagOnOneSentenceIsTodaysRouteWithJevNeverAsked() async throws {
        let w = World()
        let (text, context) = w.message([.text("ask "), c, .text(" about the build")])
        #expect(RouterDispatcher.plan(text: text, context: context, store: w.store) != .classify)
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.f.ranks == 0 && w.f.sameAsked.isEmpty && w.f.divideRequests.isEmpty && w.words(of: "local_c") == ["ask @Ship it about the build"])
        #expect(w.entry(id)?.parts.count == 1 && w.record(id)?.decision.confirmed == true)
        #expect(w.trace().contains { $0.id == id && $0.path == "tagged" && $0.action == "send" && $0.target == "session:local_c" })
    }

    @Test func tagsThatDontOpenASentenceGoToTheDividerLimitedToTheirPlaces() async throws {
        let w = World()
        let (text, context) = w.message([.text("tell "), a, .text(" or "), b, .text(" to rebase")])
        // One place from the divider, sure: the message goes there as it is.
        w.f.division = .init(parts: [.init(target: "answer:local_a#w1", text: "rebase", waitsFor: nil)], sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let request = try #require(w.f.divideRequests.first)
        #expect(request.mode == .tags(fixed: ["session:local_a", "session:local_b"]) && request.message == text)
        #expect(w.f.prepared == ["local_a"] && w.entry(id)?.parts.count == 1)
        // Two places: two parts, each with the divider's words.
        w.f.division = .init(parts: [.init(target: "answer:local_a#w1", text: "rebase", waitsFor: nil),
                                     .init(target: "session:local_b", text: "rebase the docs", waitsFor: nil)], sure: true, alternatives: [])
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id2)
        #expect(w.entry(id2)?.parts.map(\.text) == ["rebase", "rebase the docs"] && w.words(of: "local_b") == ["rebase the docs"])
        // Not sure of one place: it asks, that place first, then what the divider thought of.
        w.f.division = .init(parts: [.init(target: "session:local_b", text: "rebase", waitsFor: nil)], sure: false,
                             alternatives: ["answer:local_a#w1"])
        w.f.finished = []
        let id3 = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id3)
        #expect(w.dispatcher.askBacks.first { $0.id == id3 }?.options.map(\.target) == ["session:local_b", "answer:local_a#w1"])
    }

    @Test func aTaggedPlaceTheDestinationLimitLeavesOutIsStillOneOfTheDividersPlaces() async throws {
        let w = World()
        // 25 sessions older than the three: the limit keeps the 20 most recent of the idle ones.
        for n in 0..<25 {
            w.store.claudeSessions["local_old\(n)"] = ClaudeSession(id: "local_old\(n)", title: "Old \(n)", folder: "/code/old\(n)",
                                                                    lastActivity: Date().addingTimeInterval(-1000 - Double(n)))
        }
        let (text, context) = w.message([.text("tell "), .pointer(.session("local_old24")), .text(" or "), b, .text(" to rebase")])
        w.f.division = .init(parts: [.init(target: "session:local_old24", text: "rebase", waitsFor: nil),
                                     .init(target: "session:local_b", text: "rebase", waitsFor: nil)], sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let request = try #require(w.f.divideRequests.first)
        let keys = RouterDivider.keys(request.mode, request.places)
        let fixed = request.places.filter { keys.contains($0.key) }
        #expect(Set(fixed.map(\.target)) == ["session:local_old24", "session:local_b"] || Set(fixed.map(\.target)) == ["session:local_old24", "answer:local_b#w1"])
        #expect(w.entry(id)?.parts.count == 2 && w.words(of: "local_old24") == ["rebase"] && w.words(of: "local_b") == ["rebase"])
    }

    @Test func aDividerThatFailsAsksAmongTheTaggedPlaces() async throws {
        let w = World()
        let (text, context) = w.message([.text("tell "), a, .text(" or "), b, .text(" to rebase")])
        w.f.divideError = RouterTools.Failure("down")
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let options = w.dispatcher.askBacks.first { $0.id == id }?.options.map(\.target) ?? []
        #expect(Set(options) == ["session:local_b", "session:local_a"] || Set(options) == ["session:local_b", "answer:local_a#w1"])
        #expect(w.f.prepared.isEmpty && w.f.ranks == 0)
    }

    @Test func recipientsEachGetTheWholeMessage() async throws {
        let w = World()
        var context = RouterContext()
        context.recipients = ["session:local_a", "session:local_c"]
        let id = try #require(w.dispatcher.submit("heads up: main moved", context: context))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.map(\.text) == ["heads up: main moved", "heads up: main moved"])
        #expect(w.words(of: "local_a") == ["heads up: main moved"] && w.words(of: "local_c") == ["heads up: main moved"])
        #expect(w.f.ranks == 0)
    }

    // MARK: Messages the tags don't divide

    @Test func anActionsMessageIsNeverDivided() async throws {
        let w = World()
        w.f.ranked = [.init(target: "session:local_b", p: 0.97), .init(target: "unclear", p: 0.03)]
        let (text, mentions) = w.store.composeForRouter([a, .text(" fix it. "), b, .text(" add the page")])
        var context = RouterContext()
        context.tag(mentions)
        context.action = RouterActionSource(origin: SessionOrigin(category: "Contributions", thing: "o/lookout#7 Login fails",
                                                                  actionID: "a", runID: "r"),
                                            title: "o/lookout#7 Login fails", model: nil, effort: nil)
        #expect(RouterDispatcher.plan(text: text, context: context, store: w.store) == .classify)
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.f.divideRequests.isEmpty && w.f.sameAsked.isEmpty)
        #expect(w.f.ranks == 1 && w.f.prepared == ["local_b"], "Jev picks among the sessions tagged")
    }

    @Test func aReplyAPinAndALoneProjectAreWhatTheyWereWithoutTags() {
        let w = World()
        let card = RouterContext(replyTo: "local_a#w1")
        #expect(RouterDispatcher.plan(text: "yes", context: card, store: w.store) == .reply(session: "local_a", card: "local_a#w1"))
        let pinned = RouterContext(target: "session:local_b")
        #expect(RouterDispatcher.plan(text: "add a note", context: pinned, store: w.store) == .route("session:local_b"))
        let (text, context) = w.message([.pointer(.project("/code/web")), .text(" add a badge")])
        #expect(RouterDispatcher.plan(text: text, context: context, store: w.store) == .start(folder: "/code/web"))
        // A session tag inside code isn't one.
        var inCode = RouterContext()
        let code = "run `@Update the docs` again"
        inCode.mentions = [RouterMention(range: 5..<22, pointer: .session("local_b"), name: "Update the docs")]
        #expect(RouterDispatcher.plan(text: code, context: inCode, store: w.store) == .classify)
    }

    // MARK: The gates

    /// Jev's read of a message the compound gates fire on: both up, and the pick compound (or `top` when he is vetoed).
    private func gatesUp(_ w: World, top: String = "compound", you: Double = 0) {
        w.f.ranked = [.init(target: top, p: 0.9), .init(target: "session:local_b", p: 0.05), .init(target: "unclear", p: 0.05)]
        w.f.gates = ["gate_compound": 0.9, "gate_compound2": 0.8, "gate_you": you]
        w.f.ungated = .init(ranked: [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)], sure: true, card: nil)
    }

    private let both = "add the page and rerun the build"

    private func parts(_ w: World) -> RouterDivider.Answer {
        .init(parts: [.init(target: "session:local_b", text: "add the page", waitsFor: nil),
                      .init(target: "session:local_c", text: "rerun the build", waitsFor: nil)], sure: false, alternatives: [])
    }

    @Test func gatesUpWithTwoPlacesSendTheDividersPartsWithNoAsk() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = parts(w)
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        let entry = try #require(w.entry(id))
        #expect(entry.parts.map(\.text) == ["add the page", "rerun the build"] && w.dispatcher.askBacks.isEmpty)
        #expect(w.words(of: "local_b") == ["add the page"] && w.words(of: "local_c") == ["rerun the build"])
        // One call to Jev, one to the divider, with every place, and waits_for.
        #expect(w.f.ranks == 1 && w.f.divideRequests.count == 1 && w.f.divideRequests[0].mode == .gates)
        #expect(w.f.divideRequests[0].places.count > 3 && w.f.sameAsked.isEmpty)
        for part in entry.parts {
            let record = try #require(w.record(part.id))
            #expect(record.delivered != nil && record.decision.confirmed == nil, "the divider placed it, you didn't")
        }
        let line = try #require(w.trace().first { $0.id == id && $0.path == "split" })
        #expect(line.parts?.count == 2)
    }

    @Test func aPartForAPlaceGoneWhileTheDividerWasAskedDropsTheDivisionBackToTheUngatedPick() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = parts(w)
        // The docs session is archived while the divider is read: it is no place to send to any more.
        let divide = w.dispatcher.effects.divide
        w.dispatcher.effects.divide = { tools, request in
            let answer = try await divide(tools, request)
            w.store.claudeSessions["local_c"]?.isArchived = true
            return answer
        }
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.words(of: "local_c").isEmpty && w.dispatcher.askBacks.isEmpty)
        // Jev's pick as if the gates hadn't fired: the message as it is, to the one place.
        #expect(w.words(of: "local_b") == [both])
    }

    @Test func aDivisionKeptFromTheDraftIsNotSentToAPlaceGoneSince() async throws {
        let w = World()
        // Five idle sessions: the oldest is outside the latest three the board is read by, so archiving it leaves the board as it was.
        for n in 0..<5 {
            w.store.claudeSessions["local_idle\(n)"] = ClaudeSession(id: "local_idle\(n)", title: "Idle \(n)", folder: "/code/idle\(n)",
                                                                     lastActivity: Date().addingTimeInterval(-300 - Double(n)))
        }
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "session:local_b", text: "add the page", waitsFor: nil),
                                     .init(target: "session:local_idle4", text: "rerun the build", waitsFor: nil)], sure: true, alternatives: [])
        let found = RouterDispatcher.Classification(try await w.dispatcher.effects.rank(w.dispatcher.makeTools(UUID(), both, pills: []), both, []))
        let board = RouterDispatcher.boardRevision(w.store)
        #expect(await w.dispatcher.predictDivision(both, found: found, projects: []) != nil)
        w.store.claudeSessions["local_idle4"]?.isArchived = true
        #expect(RouterDispatcher.boardRevision(w.store) == board, "the board didn't change")
        // Not sent as parts, whatever the kept division says (the divider, asked again, has no answer).
        w.f.division = nil
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.words(of: "local_idle4").isEmpty)
        // Nor shown under the composer: a division with a place that is gone is not a division.
        w.f.division = .init(parts: [.init(target: "session:local_b", text: "add the page", waitsFor: nil),
                                     .init(target: "session:local_idle4", text: "rerun the build", waitsFor: nil)], sure: true, alternatives: [])
        #expect(await w.dispatcher.predictDivision(both + "!", found: found, projects: []) == nil)
    }

    @Test func aPartThatWaitsIsHeldWithWhatItWaitsForAndSendNowSendsIt() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "session:local_c", text: "ask which version", waitsFor: nil),
                                     .init(target: "session:local_b", text: "use it", waitsFor: "session:local_c")], sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit("ask CI which version, then tell docs to use it"))
        await w.finishAll(id)
        let second = try #require(w.entry(id)?.parts.last?.id)
        #expect(w.dispatcher.held[second]?.hasPrefix("waits for session “Ship it”") == true)
        #expect(w.words(of: "local_c") == ["ask which version"] && w.words(of: "local_b").isEmpty)
        w.f.finished = []
        w.dispatcher.sendNow(second)
        await waitUntil { w.record(second)?.outcome == .done }
        #expect(w.words(of: "local_b") == ["use it"])
        // Don't send drops it instead.
        gatesUp(w)
        let id2 = try #require(w.dispatcher.submit("ask CI which version, then tell docs to use it again"))
        await w.finishAll(id2)
        let held = try #require(w.entry(id2)?.parts.last?.id)
        w.dispatcher.dropHeld(held)
        await waitUntil { w.record(held)?.outcome == .done }
        #expect(w.record(held)?.doneLines.last == "failed: wasn't sent: you chose not to send it" && w.words(of: "local_b") == ["use it"])
    }

    @Test func onePlaceWithACompoundPickGoesThereWhenJevAndTheDividerAreSure() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "session:local_c", text: both, waitsFor: nil)], sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.words(of: "local_c") == [both] && w.f.divideRequests.count == 1)
        // The divider unsure: an ask, its place first, the compound pick not among the buttons.
        w.f.division = .init(parts: [.init(target: "session:local_c", text: both, waitsFor: nil)], sure: false, alternatives: [])
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(both + "!"))
        await w.finishAll(id2)
        let options = try #require(w.dispatcher.askBacks.first { $0.id == id2 }?.options.map(\.target))
        #expect(options.first == "session:local_c" && !options.contains("compound") && w.words(of: "local_c") == [both])
    }

    @Test func everyPartWaitingIsTheFirstPartsPlaceAsOnePlace() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "session:local_c", text: "use the version", waitsFor: "session:local_b"),
                                     .init(target: "session:local_b", text: "pick a version", waitsFor: "session:local_c")],
                             sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.words(of: "local_c") == [both] && w.dispatcher.held.isEmpty)
    }

    @Test func aDividerThatFailsOrNamesNoKnownPlaceLeavesTheUngatedPick() async throws {
        let w = World()
        gatesUp(w)
        w.f.divideError = RouterTools.Failure("down")
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 1 && w.words(of: "local_b") == [both] && w.dispatcher.askBacks.isEmpty)
        // An answer whose place isn't one there is: the reading throws, and it is the same.
        w.dispatcher.effects.divide = { [f = w.f] _, request in
            f.divideRequests.append(request)
            return try RouterDivider.read(["parts": [["place": "S99", "text": "x", "waits_for": "none"]], "sure": true, "alternatives": []], request)
        }
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(both + "."))
        await w.finishAll(id2)
        #expect(w.entry(id2)?.parts.count == 1 && w.words(of: "local_b") == [both, both + "."])
        // The ungated pick still compound: not sure, and the ask doesn't list it.
        w.f.ungated = .init(ranked: [.init(target: "compound", p: 0.6), .init(target: "session:local_c", p: 0.4)], sure: true, card: nil)
        w.f.finished = []
        let id3 = try #require(w.dispatcher.submit(both + "?"))
        await w.finishAll(id3)
        #expect(w.dispatcher.askBacks.first { $0.id == id3 }?.options.map(\.target) == ["session:local_c"])
    }

    @Test func theYouGateDoesntStopTheDivider() async throws {
        let w = World()
        gatesUp(w, top: "session:local_a", you: 0.9)
        w.f.division = parts(w)
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.f.divideRequests.count == 1 && w.entry(id)?.parts.count == 2)
        // One place and the pick isn't compound: Jev's pick stands as it was.
        w.f.division = .init(parts: [.init(target: "session:local_c", text: both, waitsFor: nil)], sure: true, alternatives: [])
        w.f.finished = []
        w.f.prepared = []
        let id2 = try #require(w.dispatcher.submit(both + "."))
        await w.finishAll(id2)
        #expect(w.entry(id2)?.parts.count == 1 && w.f.prepared == ["local_a"])
    }

    @Test func gatesDownOrASinglePickShownNeverAskTheDivider() async throws {
        let w = World()
        w.f.ranked = [.init(target: "session:local_b", p: 0.97), .init(target: "unclear", p: 0.03)]
        w.f.gates = ["gate_compound": 0.9, "gate_compound2": 0.2]
        w.f.division = parts(w)
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.f.divideRequests.isEmpty && w.entry(id)?.parts.count == 1 && w.words(of: "local_b") == [both])
        // A pick shown over the composer for these words is sent as it was, gates up or not.
        gatesUp(w)
        var shown = RouterContext()
        shown.shown = "session:local_b"
        var carried = RouterDispatcher.Classification(ranked: [.init(target: "session:local_b", p: 0.97)], sure: true, assisted: true)
        carried.gates = ["gate_compound": 0.9, "gate_compound2": 0.8]
        shown.jev = carried
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(both + ".", context: shown))
        await w.finishAll(id2)
        #expect(w.f.divideRequests.isEmpty && w.entry(id2)?.parts.count == 1 && w.f.ranks == 1)
    }

    @Test func aDivisionShownForTheseWordsIsSentAsShownAskingNothing() async throws {
        let w = World()
        gatesUp(w)
        var context = RouterContext()
        context.division = RouterDivision(text: both, parts: parts(w).parts)
        let id = try #require(w.dispatcher.submit(" " + both + " ", context: context))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.map(\.text) == ["add the page", "rerun the build"])
        #expect(w.f.ranks == 0 && w.f.divideRequests.isEmpty && w.f.checked.isEmpty)
        // Shown for other words: it is read again.
        w.f.division = parts(w)
        w.f.finished = []
        let id2 = try #require(w.dispatcher.submit(both + " now", context: context))
        await w.finishAll(id2)
        #expect(w.f.ranks == 1 && w.f.divideRequests.count == 1)
    }

    @Test func anActionsMessageWithTheGatesUpIsNeverDivided() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = parts(w)
        var context = RouterContext()
        context.action = RouterActionSource(origin: SessionOrigin(category: "Contributions", thing: "o/lookout#7 Login fails",
                                                                  actionID: "a", runID: "r"),
                                            title: "o/lookout#7 Login fails", model: nil, effort: nil)
        let id = try #require(w.dispatcher.submit(both, context: context))
        await w.finishAll(id)
        #expect(w.f.divideRequests.isEmpty && w.entry(id)?.parts.count == 1)
    }

    @Test func theFjordPartOfADivisionRunsWithOnlyItsWords() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "change_fjord", text: "Mute notifications for an hour.", waitsFor: nil),
                                     .init(target: "session:local_b", text: "add the page", waitsFor: nil)], sure: true, alternatives: [])
        let id = try #require(w.dispatcher.submit("Mute notifications for an hour. Then add the page to the docs"))
        await w.finishAll(id)
        let input = try #require(w.f.runs.first?.input)
        #expect(w.f.runs.count == 1 && w.f.runs[0].intent == .changeFjord && w.words(of: "local_b") == ["add the page"])
        #expect(input.hasSuffix("Mute notifications for an hour.") && !input.contains("add the page") && !input.contains("Then add"))
    }

    @Test func aDraftsDivisionIsReadOnceItsGatesAreUpAndKeptForTheSend() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = parts(w)
        let found = RouterDispatcher.Classification(try await w.dispatcher.effects.rank(w.dispatcher.makeTools(UUID(), both, pills: []), both, []))
        let division = await w.dispatcher.predictDivision(both, found: found, projects: [])
        #expect(division?.parts == parts(w).parts && division?.text == both && w.f.divideRequests.count == 1)
        // Again for the same words: kept.
        #expect(await w.dispatcher.predictDivision(both, found: found, projects: []) == division && w.f.divideRequests.count == 1)
        // The send finds it and asks the divider nothing.
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.f.divideRequests.count == 1 && w.entry(id)?.parts.count == 2)
        // Gates down, or one place: no division.
        var down = found
        down.gates = ["gate_compound": 0.9, "gate_compound2": 0.1]
        #expect(await w.dispatcher.predictDivision("something else", found: down, projects: []) == nil && w.f.divideRequests.count == 1)
        w.f.division = .init(parts: [.init(target: "session:local_c", text: both, waitsFor: nil)], sure: true, alternatives: [])
        #expect(await w.dispatcher.predictDivision(both + "!", found: found, projects: []) == nil && w.f.divideRequests.count == 2)
    }

    /// The divider held until the test answers it: the answers' continuations, in the order asked.
    private final class Gate {
        var waiting: [CheckedContinuation<RouterDivider.Answer, Error>] = []
        var tools: [RouterTools] = []
        var turns: [Int] = []
        var cancelled = false
    }

    private func gated(_ w: World) -> Gate {
        let gate = Gate()
        w.dispatcher.effects.divide = { tools, request in
            w.f.divideRequests.append(request)
            gate.tools.append(tools)
            gate.turns.append(tools.turn)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { gate.waiting.append($0) }
            } onCancel: { gate.cancelled = true }
        }
        return gate
    }

    private func readDraft(_ w: World) async throws -> RouterDispatcher.Classification {
        RouterDispatcher.Classification(try await w.dispatcher.effects.rank(w.dispatcher.makeTools(UUID(), both, pills: []), both, []))
    }

    @Test func aDivisionReadOnAnEarlierBoardIsNeitherJoinedNorUsed() async throws {
        let w = World()
        gatesUp(w)
        let gate = gated(w)
        let found = try await readDraft(w)
        let first = Task { await w.dispatcher.predictDivision(both, found: found, projects: []) }
        await waitUntil { gate.waiting.count == 1 }
        // The board changes while it is read: the same words are a new question, not the pending one.
        w.store.claudeSessions["local_new"] = ClaudeSession(id: "local_new", title: "Brand new", folder: "/code/new", lastActivity: Date().addingTimeInterval(10))
        let second = Task { await w.dispatcher.predictDivision(both, found: found, projects: []) }
        await waitUntil { gate.waiting.count == 2 }
        #expect(w.f.divideRequests.count == 2)
        gate.waiting[1].resume(returning: parts(w))
        #expect(await second.value?.parts == parts(w).parts)
        // The first one's answer is for the old board: nothing of it is returned or kept.
        gate.waiting[0].resume(returning: .init(parts: [.init(target: "session:local_c", text: "x", waitsFor: nil),
                                                        .init(target: "session:local_a", text: "y", waitsFor: nil)], sure: true, alternatives: []))
        #expect(await first.value == nil)
        #expect(await w.dispatcher.predictDivision(both, found: found, projects: [])?.parts == parts(w).parts && w.f.divideRequests.count == 2)
    }

    @Test func aCorrectionOrADismissalMakesEveryDivisionReadBeforeItBeReadAgain() async throws {
        let w = World()
        gatesUp(w)
        w.f.division = parts(w)
        let found = try await readDraft(w)
        #expect(await w.dispatcher.predictDivision(both, found: found, projects: [])?.parts == parts(w).parts && w.f.divideRequests.count == 1)
        w.dispatcher.forgetLive()
        // Kept no more: the next read asks the divider again, and so does a send.
        #expect(await w.dispatcher.predictDivision(both, found: found, projects: []) != nil && w.f.divideRequests.count == 2)
        w.dispatcher.forgetLive()
        let id = try #require(w.dispatcher.submit(both))
        await w.finishAll(id)
        #expect(w.f.divideRequests.count == 3 && w.entry(id)?.parts.count == 2)
        // One still being read when it comes never fills the cache.
        let gate = gated(w)
        let reading = Task { await w.dispatcher.predictDivision(both + "?", found: found, projects: []) }
        await waitUntil { gate.waiting.count == 1 }
        w.dispatcher.forgetLive()
        gate.waiting[0].resume(returning: parts(w))
        #expect(await reading.value == nil && w.dispatcher.divisionCache[RouterDispatcher.liveKey(both + "?", [])] == nil)
    }

    @Test func stopAndRouterOffCancelADivisionBeingReadForADraftAndKillItsProgram() async throws {
        for actions in [false, true] {
            let w = World()
            gatesUp(w)
            let gate = gated(w)
            let found = try await readDraft(w)
            let reading = Task { await w.dispatcher.predictDivision(both, found: found, projects: []) }
            await waitUntil { gate.waiting.count == 1 }
            w.dispatcher.stopAll(actions: actions)
            // Its turn ended (the program killed with it) and its task cancelled; nothing it answers is kept.
            #expect(gate.cancelled && gate.tools[0].turn > gate.turns[0] && w.dispatcher.divisionPending.isEmpty)
            gate.waiting[0].resume(returning: parts(w))
            #expect(await reading.value == nil && w.dispatcher.divisionCache.isEmpty)
        }
    }

    // MARK: Held parts

    @Test func aProjectPartTheAppHoldsIsHeldAloneAndDontSendDropsOnlyIt() async throws {
        let w = World()
        w.f.heldStart = SessionStart.Held(waiting: .init(sessionID: "local_late"), title: "add a badge", project: "web",
                                          ready: Prepared(text: "add a badge", original: "add a badge", rephrased: false), settings: nil)
        let (text, context) = w.message([c, .text(" rerun it. "), .pointer(.project("/code/web")), .text(" add a badge")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await waitUntil { w.f.finishHeld != nil }
        await w.finishAll(id)
        let parts = try #require(w.entry(id)?.parts)
        #expect(parts.count == 2 && w.words(of: "local_c") == ["rerun it."])
        let held = try #require(parts.first { $0.place == "project:/code/web" })
        #expect(w.dispatcher.held[held.id] == RouterDispatcher.heldWords && w.dispatcher.held.count == 1)
        #expect(w.record(held.id)?.done == [.started(session: "local_late", project: "web", model: nil, effort: nil)])
        // Stop leaves it be.
        w.dispatcher.stopAll()
        #expect(w.dispatcher.held[held.id] != nil)
        // Don't send: only that part.
        w.dispatcher.dropHeld(held.id)
        w.f.finishHeld?.resume()
        await waitUntil { w.record(held.id)?.outcome == .done }
        #expect(w.record(held.id)?.doneLines.last == "failed: its first message wasn't sent: you chose not to send it")
        let other = try #require(parts.first { $0.id != held.id })
        #expect(w.record(other.id)?.doneLines.contains { $0.hasPrefix("sent to") } == true && w.f.sent.count == 1)
    }

    /// A message divided into two parts by hand, the second waiting for the first's place.
    private func waiting(_ w: World) async throws -> (id: UUID, first: UUID, second: UUID) {
        let text = "ask CI which version, then tell docs to use it"
        let id = w.store.logDecision(RouterDecision(trigger: .you(text), decision: .init(intent: "message")))
        let job = RouterDispatcher.Job(id: id, text: text, context: RouterContext(), tools: w.dispatcher.makeTools(id, text, pills: []))
        w.dispatcher.dispatch(job, parts: [SplitPart(target: "session:local_c", text: "ask which version"),
                                           SplitPart(target: "session:local_b", text: "use it", waitsFor: "session:local_c")])
        w.dispatcher.end(job)
        await w.finishAll(id)
        let parts = try #require(w.entry(id)?.parts)
        return (id, parts[0].id, parts[1].id)
    }

    @Test func aPartThatWaitsIsHeldUntilYouSendItAndStopLeavesItBe() async throws {
        let w = World()
        let (id, first, second) = try await waiting(w)
        #expect(w.f.prepared == ["local_c"] && w.words(of: "local_c") == ["ask which version"])
        let line = try #require(w.dispatcher.held[second])
        #expect(line.hasPrefix("waits for session “Ship it”") && line.contains("dropped after 30 minutes"))
        #expect(w.record(second)?.outcome == .pending && w.entry(id)?.summary == "split in 2: 1 sent, 1 held")
        #expect(w.dispatcher.isBusy == false)
        w.dispatcher.stopAll()
        #expect(w.dispatcher.held[second] != nil && w.f.prepared == ["local_c"])
        // Send now: it goes as a message of its own to its place, with its words only.
        w.f.finished = []
        w.dispatcher.sendNow(second)
        await waitUntil { w.f.finished.contains(second) && w.record(second)?.outcome == .done }
        #expect(w.words(of: "local_b") == ["use it"] && w.dispatcher.held.isEmpty && w.record(second)?.delivered != nil)
        #expect(w.record(first)?.delivered != nil)
    }

    @Test func stopRightAfterSendNowStopsThePartBeforeItGoes() async throws {
        let w = World()
        let (_, _, second) = try await waiting(w)
        // Send now, and Stop before the held part has taken up the release: the part is a run under way already.
        w.dispatcher.sendNow(second)
        w.dispatcher.stopAll()
        await waitUntil { w.record(second)?.outcome == .done }
        #expect(w.words(of: "local_b").isEmpty && w.f.prepared == ["local_c"] && w.record(second)?.delivered == nil)
        #expect(w.record(second)?.doneLines.last?.hasPrefix("failed: wasn't sent") == true)
        #expect(w.dispatcher.held.isEmpty && w.dispatcher.heldTasks.isEmpty && w.dispatcher.heldTools.isEmpty)
    }

    @Test func aHeldPartIsDroppedByDontSendTheTimeRunningOutOrTheRouterSwitchedOff() async throws {
        let w = World()
        let (_, _, second) = try await waiting(w)
        w.dispatcher.dropHeld(second)
        await waitUntil { w.record(second)?.outcome == .done }
        #expect(w.record(second)?.doneLines.last == "failed: wasn't sent: you chose not to send it" && w.f.prepared == ["local_c"])
        #expect(w.dispatcher.held.isEmpty && w.dispatcher.releases.isEmpty)

        w.dispatcher.heldPartWait = 0.05
        let (_, _, late) = try await waiting(w)
        await waitUntil { w.record(late)?.outcome == .done }
        #expect(w.record(late)?.doneLines.last?.hasPrefix("failed: wasn't sent: it waited too long for") == true)

        w.dispatcher.heldPartWait = SessionStart.heldWait
        let (_, _, off) = try await waiting(w)
        w.dispatcher.stopAll(reason: RouterDispatcher.unlinkedWords, actions: true)
        await waitUntil { w.record(off)?.outcome == .done }
        #expect(w.record(off)?.doneLines.last == "failed: wasn't sent: the Router was switched off")
        #expect(w.f.prepared.filter { $0 == "local_b" }.isEmpty)
    }

    // MARK: What acts on a part

    @Test func cancellingAPartTakesBackOnlyThatPart() async throws {
        let w = World()
        let (text, context) = w.message([a, .text(" fix the flaky test. "), b, .text(" add the page")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let parts = try #require(w.entry(id)?.parts)
        let docs = try #require(parts.first { w.record($0.id)?.delivered?.session == "local_b" })
        #expect(await w.dispatcher.cancel(docs.id) == .aborted)
        #expect(w.cancels.map(\.session) == ["local_b"])
        let after = try #require(w.entry(id)?.parts)
        #expect(after.first { $0.id == docs.id }?.delivered?.cancelled == .aborted)
        #expect(after.first { $0.id != docs.id }?.delivered?.cancelled == nil)
        #expect(w.entry(id)?.summary == "split in 2: 1 sent, 1 cancelled")
    }

    @Test func aPartSentElsewhereIsAskedAgainWithOnlyItsWordsAndWithoutItsPlace() async throws {
        let w = World()
        let (text, context) = w.message([a, .text(" fix the flaky test. "), b, .text(" add the page")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let docs = try #require(w.entry(id)?.parts.first { w.record($0.id)?.delivered?.session == "local_b" })
        w.f.ranked = [.init(target: "session:local_b", p: 0.6), .init(target: "session:local_c", p: 0.3), .init(target: "session:local_a", p: 0.1)]
        w.f.finished = []
        w.dispatcher.sendElsewhere(docs.id)
        await w.finishAll(docs.id)
        let ask = try #require(w.dispatcher.askBacks.first { $0.id == docs.id })
        #expect(ask.message == "@Update the docs add the page" && ask.context.notTo == "session:local_b")
        #expect(!ask.options.map(\.target).contains("session:local_b") && w.cancels.map(\.session) == ["local_b"])
        // Picking sends that part's words to the new place, and only that part changes.
        w.f.finished = []
        #expect(w.dispatcher.pick(docs.id, target: "session:local_c"))
        await w.finishAll(docs.id)
        #expect(w.words(of: "local_c") == ["@Update the docs add the page"] && w.entry(id)?.parts.count == 2)
    }

    @Test func aPartsCardsAreJudgedWithTheWordsOfThePartOnly() async throws {
        let w = World()
        w.store.router.cards.append(RouterCard(id: "local_b#t1", sessionID: "local_b", kind: .done, title: "Update the docs",
                                               folder: "/code/docs", text: "Done.", createdAt: Date()))
        let (text, context) = w.message([a, .text(" fix the flaky test. "), b, .text(" add the page")])
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finishAll(id)
        let card = try #require(w.store.router.cards.first { $0.id == "local_b#t1" })
        #expect(card.addressedNote == "@Update the docs add the page")
        let parts = try #require(w.entry(id)?.parts)
        let docs = try #require(parts.first { w.record($0.id)?.delivered?.session == "local_b" })
        #expect(w.record(docs.id)?.done.contains(.resolved(card: "Update the docs", message: "@Update the docs add the page")) == true)
        #expect(parts.filter { $0.id != docs.id }.allSatisfy { part in !part.done.contains { if case .resolved = $0 { true } else { false } } })
    }
}
