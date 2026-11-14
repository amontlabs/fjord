import Foundation
import Testing
@testable import Fjord

/// Words with a picture or file to a thread's waiting request, through the dispatcher (a form typed with its card not
/// selected, a split's part), and a plan sent back with them: the picture reaches the thread where it sat, or the send is
/// refused plainly and nothing goes. All on stubs: nothing reaches T3.
@MainActor
@Suite(.serialized) struct RouterAttachmentRepliesTests {
    typealias F = T3Fixture
    private typealias ID = RouterDemo.ID

    private static let shot = T3Attachment(type: "image", id: "att-1", name: "shot.png", mimeType: "image/png", sizeBytes: 9)
    private static let pill = "[image: shot.png]"

    private func item(_ id: String = "image_a") -> RouterAttachment {
        RouterAttachment(id: id, kind: RouterAttachment.kind(of: id), name: "shot.png", mimeType: "image/png", sizeBytes: 9,
                         data: Data(count: 9))
    }

    // MARK: 1. Words with a picture to a waiting request, through the dispatcher

    /// The dispatcher's stand-ins, a picture uploaded as "att-1", and the words `text` (the pill at its "[image: …]")
    /// submitted to th-docs, which holds `request`.
    private func submit(_ text: String, to request: ThreadRequest,
                        asker: JevAsker? = nil) async -> (Store, RouterDispatcherTests.Fakes, [RouterDispatcher.SendEvent]) {
        let (s, d, f) = RouterDispatcherTests().setup()
        s.requests["th-docs"] = request
        s.attachments.put(item(), state: .ready("att-1"))
        d.asker = asker
        var events: [RouterDispatcher.SendEvent] = []
        d.onSend = { _, e in events.append(e) }
        var context = RouterContext(target: RouteTarget.thread("th-docs").targetID)
        let at = Array(text).indices.first { Array(text)[$0...].starts(with: Array(Self.pill)) }!
        context.mentions = [RouterMention(range: at..<(at + Self.pill.count), pointer: .attachment("image_a"), name: "shot.png")]
        let id = d.submit(text, context: context)
        await RouterDispatcherTests().finish(f, id)
        return (s, f, events)
    }

    private func form() -> ThreadRequest {
        ThreadRequest(id: "form", threadID: "th-docs", body: .question([
            T3Question(demo: "Look", "Which look?", id: "q1", options: [("Dark", ""), ("Light", "")]),
            T3Question(demo: "Name", "Its name?", id: "q2", allowCustomAnswer: true, options: [("Fern", ""), ("Moss", "")]),
        ]))
    }

    /// Jev picking the first option of every question, sure of it.
    private static let firstOptions: JevAsker = { questions, _ in
        questions.mapValues { _ in .choice(JevClient.Choice(choice: "o1", confidence: 0.99, probabilities: ["o1": 0.99, "o2": 0.01])) }
    }

    @Test func aFormTypedWithItsCardNotSelectedBindsThePictureToTheQuestionThatTakesIt() async {
        let (_, f, events) = await submit("dark, fern " + Self.pill, to: form(), asker: Self.firstOptions)
        guard case .answers(let answers, let attachments)? = f.answered.first?.answer else {
            Issue.record("not answered: \(f.answered.map(\.answer)) \(f.sent)"); return
        }
        #expect(answers == ["q1": .one("Dark"), "q2": .one("Fern")])
        #expect(attachments == ["q2": ["image_a"]])
        #expect(f.sent.isEmpty && events == [.taken])
    }

    @Test func aSinglesQuestionsCustomAnswerCarriesThePictureWithoutItsName() async {
        let request = ThreadRequest(id: "one", threadID: "th-docs", body: .question([
            T3Question(demo: "Look", "Which look?", id: "q1", allowCustomAnswer: true, options: [("Dark", "")]),
        ]))
        // No Jev: the words are the custom answer, as a split's part answering the question goes.
        let (_, f, _) = await submit("like this " + Self.pill + " please", to: request)
        guard case .answers(let answers, let attachments)? = f.answered.first?.answer else { Issue.record("not answered"); return }
        #expect(answers == ["q1": .one("like this please")])
        #expect(attachments == ["q1": ["image_a"]])
    }

    @Test func aFormWhosePicturesCouldGoWithTwoQuestionsIsRefusedPlainly() throws {
        let questions = [T3Question(demo: "A", "A?", id: "a", allowCustomAnswer: true, options: [("x", "")]),
                         T3Question(demo: "B", "B?", id: "b", allowCustomAnswer: true, options: [("y", "")])]
        #expect(throws: RouterTools.Failure.self) {
            try RouterDispatcher.attachmentsQuestion(questions, answers: ["a": .one("x"), "b": .one("y")])
        }
        // One of them answered in your own words: that one.
        #expect(try RouterDispatcher.attachmentsQuestion(questions, answers: ["a": .one("x"), "b": .one("mine")]) == "b")
        #expect(throws: RouterTools.Failure.self) {
            try RouterDispatcher.attachmentsQuestion([T3Question(demo: "A", "A?", id: "a", options: [("x", "")])], answers: ["a": .one("x")])
        }
    }

    @Test func aPermissionWithAPictureIsRefusedPlainlyAndNothingGoes() async {
        let permission = ThreadRequest(id: "perm", threadID: "th-docs",
                                       body: .approval(kind: "command", prompt: "rm -rf build", decisions: ThreadRequest.fallbackDecisions))
        let (_, f, events) = await submit("not that " + Self.pill, to: permission)
        #expect(f.answered.isEmpty && f.sent.isEmpty)
        guard case .refused(let reason, _)? = events.first else { Issue.record("not refused: \(events)"); return }
        #expect(reason.contains("can't carry pictures or files"))
    }

    @Test func wordsThatAnswerNoneOfAFormGoAsAMessageCarryingThePicture() async {
        // No Jev: the form isn't read, and the words go on as a message, the picture in it.
        let (_, f, _) = await submit("wait, see " + Self.pill, to: form())
        #expect(f.answered.isEmpty)
        #expect(f.sent.first?.message.attachments == [Self.shot])
        #expect(f.sent.first?.message.text.contains("t3-context://v1/image/image_a") == true)
    }

    // MARK: 3. A plan sent back with a picture

    @Test func aPlanIsSentBackWithThePictureWhereItSatAsT3sComposerSendsIt() async {
        let plan = ThreadRequest(id: "plan", threadID: "th-docs", body: .plan(markdown: "# Plan\n\n1. Do it"))
        let (_, f, events) = await submit("not like this " + Self.pill + " but bigger", to: plan)
        guard case .sendBack(let message)? = f.answered.first?.answer else { Issue.record("not sent back"); return }
        #expect(message.text == "not like this ![shot.png](t3-context://v1/image/image_a) but bigger")
        #expect(message.attachments == [Self.shot] && message.records.count == 1)
        #expect(events == [.taken])
    }

    @Test func theSendBackCarriesTheAttachmentsAndTheirRecords() async {
        let s = Store.reading([F.shell("t1")])
        s.router.enabled = true
        let plan = ThreadRequest(id: "plan", threadID: "t1", body: .plan(markdown: "# Plan"))
        s.requests["t1"] = plan
        var sent: [T3Command] = []
        s.requestSender = { command, _ in sent.append(command) }
        let (_, record) = RouterPointers.attachment(id: "image_a", upload: Self.shot)
        let message = ThreadMessage(messageID: "m1", text: "see ![shot.png](t3-context://v1/image/image_a)", records: [record],
                                    attachments: [Self.shot])
        let result = await s.sendBackPlan(plan, message: message, target: ThreadTarget(project: "", thread: "t1"))
        #expect((try? result.get()) != nil)
        #expect(sent == [.messageDispatch(threadId: "t1", messageId: "m1", text: message.text, dispatch: .startImmediately(intent: .auto),
                                          attachments: [Self.shot], context: [record])])
    }

    @Test func wordsWithAPictureToAPlansCardGoAsWordsForTheDispatcher() {
        let model = RouterDemo.records()
        guard var t = model.threads.first else { return }
        t.state = .needsYou(.plan)
        let pill = RouterMention(range: 4..<21, pointer: .attachment("image_a"), name: "shot.png")
        #expect(model.attachedAnswer("see " + Self.pill, to: t, attached: [pill]) == nil)
    }
}
