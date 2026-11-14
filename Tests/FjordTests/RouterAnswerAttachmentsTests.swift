import Foundation
import Testing
@testable import Fjord

/// Pictures and files pasted with an answer to an agent's question: they go in `runtime-request.respond`'s
/// `attachmentsByQuestionId`, bound to the question they answer, only where it takes a custom answer; a question with only
/// its options, a permission or a plan refuse them plainly. All on stubs: nothing reaches T3.
@MainActor
@Suite struct RouterAnswerAttachmentsTests {
    typealias F = T3Fixture
    private typealias ID = RouterDemo.ID

    private let shot = T3Attachment(type: "image", id: "att-1", name: "shot.png", mimeType: "image/png", sizeBytes: 9)

    private func question(custom: Bool) -> ThreadRequest {
        ThreadRequest(id: "r1", threadID: "t1", body: .question([
            T3Question(demo: "Look", "Which look?", id: "q1", allowCustomAnswer: custom, options: [("Dark", ""), ("Light", "")]),
        ]), live: true)
    }

    private func form() -> ThreadRequest {
        ThreadRequest(id: "r2", threadID: "t1", body: .question([
            T3Question(demo: "Look", "Which look?", id: "q1", options: [("Dark", ""), ("Light", "")]),
            T3Question(demo: "Name", "Its name?", id: "q2", allowCustomAnswer: true, options: [("Fern", "")]),
        ]), live: true)
    }

    // MARK: The payload

    @Test func theAttachmentsGoByQuestionAsT3sWebClientSendsThem() {
        let c = T3Command.respondAnswers(threadId: "t1", requestId: "r1", answers: ["q1": .one("like this")],
                                         attachments: ["q1": [shot], "q2": []])
        #expect(c.payload(commandId: "c1") == [
            "commandId": "c1", "type": "runtime-request.respond", "threadId": "t1", "requestId": "r1",
            "answers": ["q1": "like this"], "attachmentsByQuestionId": ["q1": .array([shot.json])]])
        // None: no key at all.
        #expect(T3Command.respondAnswers(threadId: "t1", requestId: "r1", answers: ["q1": .one("Dark")])
            .payload(commandId: "c1").str("attachmentsByQuestionId") == nil)
        guard case .object(let o) = T3Command.respondAnswers(threadId: "t1", requestId: "r1", answers: ["q1": .one("Dark")])
            .payload(commandId: "c1") else { Issue.record("not an object"); return }
        #expect(o["attachmentsByQuestionId"] == nil)
    }

    // MARK: What the card's answer reads as

    @Test func aCustomAnswersPicturesAreBoundToItsQuestion() throws {
        #expect(try ThreadAnswers.resolve(question(custom: true), picks: [:], typed: [0: "like this"], attached: [0: ["image_a"]])
            == .answers(["q1": .one("like this")], attachments: ["q1": ["image_a"]]))
        // A picture alone answers it (T3 gives the agent its path as the answer).
        #expect(try ThreadAnswers.resolve(question(custom: true), picks: [:], typed: [:], attached: [0: ["image_a"]])
            == .answers([:], attachments: ["q1": ["image_a"]]))
        // In a form, the second question's.
        #expect(try ThreadAnswers.resolve(form(), picks: [0: 1], typed: [1: "Moss"], attached: [1: ["file_b"]])
            == .answers(["q1": .one("Dark"), "q2": .one("Moss")], attachments: ["q2": ["file_b"]]))
    }

    @Test func aQuestionWithOnlyItsOptionsAPermissionAndAPlanRefuseThem() {
        #expect(throws: RequestFailure.optionsOnly) {
            try ThreadAnswers.resolve(question(custom: false), picks: [0: 1], typed: [:], attached: [0: ["image_a"]])
        }
        #expect(throws: RequestFailure.optionsOnly) {
            try ThreadAnswers.resolve(form(), picks: [0: 1], typed: [1: "Moss"], attached: [0: ["image_a"]])
        }
        let permission = ThreadRequest(id: "r3", threadID: "t1", body: .approval(kind: "command", prompt: "rm -rf build",
                                       decisions: [.accept, .decline]), live: true, supportsFeedback: true)
        #expect(throws: RequestFailure.permissionTakesNone) {
            try ThreadAnswers.resolve(permission, picks: [:], typed: [0: "not that"], attached: [0: ["image_a"]])
        }
        #expect(RequestFailure.optionsOnly.errorDescription?.contains("nothing was sent") == true)
    }

    // MARK: The send

    private func store(_ request: ThreadRequest) -> (Store, () -> [T3Command]) {
        let s = Store.reading([F.shell("t1")])
        s.router.enabled = true
        s.requests["t1"] = request
        var sent: [T3Command] = []
        s.requestSender = { command, _ in sent.append(command) }
        return (s, { sent })
    }

    private func item(_ id: String) -> RouterAttachment {
        RouterAttachment(id: id, kind: RouterAttachment.kind(of: id), name: "shot.png", mimeType: "image/png", sizeBytes: 9,
                         data: Data(count: 9))
    }

    @Test func theAnswerCarriesTheUploadBoundToTheRightQuestion() async {
        let (s, sent) = store(form())
        s.attachments.put(item("image_a"), state: .ready("att-1"))
        let result = await s.answerQuestion(form(), ["q1": .one("Dark"), "q2": .one("Moss")], attachments: ["q2": ["image_a"]],
                                            target: ThreadTarget(project: "", thread: "t1"))
        #expect((try? result.get()) != nil)
        #expect(sent() == [.respondAnswers(threadId: "t1", requestId: "r2", answers: ["q1": .one("Dark"), "q2": .one("Moss")],
                                           attachments: ["q2": [shot]])])
    }

    @Test func nothingGoesForANoCustomQuestionOrAFailedUpload() async {
        let (s, sent) = store(question(custom: false))
        s.attachments.put(item("image_a"), state: .ready("att-1"))
        let target = ThreadTarget(project: "", thread: "t1")
        let refused = await s.answerQuestion(question(custom: false), ["q1": .one("Dark")], attachments: ["q1": ["image_a"]],
                                             target: target)
        #expect(throws: RequestFailure.optionsOnly) { try refused.get() }
        s.requests["t1"] = question(custom: true)
        // Failed with no bytes left to upload again: the send can't recover it.
        var gone = item("image_b")
        gone.data = nil
        s.attachments.put(gone, state: .failed("T3 refused the upload (500)"))
        let failed = await s.answerQuestion(question(custom: true), ["q1": .one("this")], attachments: ["q1": ["image_b"]],
                                            target: target)
        #expect(throws: ThreadSendFailure.self) { try failed.get() }
        #expect(sent().isEmpty)
    }

    @Test func theAnswerWaitsForAnUploadStillPosting() async throws {
        let (s, sent) = store(question(custom: true))
        let open = RouterAttachmentsTests.Signal()
        s.attachments = RouterAttachments(uploader: .init(upload: { _, _ in
            await open.wait()
            return "att-1"
        }, delete: { _ in }))
        guard case .attachment(let id) = s.attachments.add(name: "shot.png", mimeType: "image/png", data: Data(count: 9)) else { return }
        let answer = Task { @MainActor in
            await s.answerQuestion(question(custom: true), [:], attachments: ["q1": [id]], target: ThreadTarget(project: "", thread: "t1"))
        }
        await Task.yield()
        #expect(sent().isEmpty)
        open.fire()
        #expect((try? await answer.value.get()) != nil)
        guard case .respondAnswers(_, _, let answers, let attachments)? = sent().first else { Issue.record("nothing sent"); return }
        #expect(answers.isEmpty)
        #expect(attachments["q1"]?.map(\.id) == ["att-1"])
    }

    // MARK: From the composer

    private func recorded() -> (RouterModel, RouterModelTests.Recorder) {
        let model = RouterDemo.records()
        let source = RouterModelTests.Recorder()
        source.model = model
        model.source = source
        return (model, source)
    }

    @Test func wordsWithAPictureToAQuestionsCardGoAsItsCustomAnswerWithIt() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(.line(ID.settings))
            let pill = RouterMention(range: 10..<11, pointer: .attachment("image_a"), name: "shot.png")
            model.edit("like this " + MentionText.markString + " please", marks: [pill])
            let words = "like this [image: shot.png] please"
            model.apply(.read(RouterRead(draft: words, places: [.thread(ID.settings)], sure: true)))
            model.send()
            #expect(source.sends.first?.kind == .answer(picks: [:], typed: [0: "like this please"], attached: [0: ["image_a"]]))
        }
    }

    @Test func aFormsTypedAnswerKeepsItsPictureUntilTheFormGoes() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(.line(ID.updater))
            let pill = RouterMention(range: 0..<1, pointer: .attachment("file_b"), name: "notes.txt")
            model.edit(MentionText.markString + " as here", marks: [pill])
            model.apply(.read(RouterRead(draft: "[file: notes.txt] as here", places: [.thread(ID.updater)], sure: true)))
            model.send()
            #expect(model.typed[ID.updater]?[0] == "as here")
            model.pick(4)
            model.send()
            #expect(source.sends.first?.kind == .answer(picks: [1: 4], typed: [0: "as here"], attached: [0: ["file_b"]]))
        }
    }

    @Test func aFormsAnswerHoldsItsPicturesUploadUntilAnOptionReplacesIt() async {
        let (model, source) = recorded()
        var deletes: [String] = []
        let deleted = RouterAttachmentsTests.Signal()
        let attachments = RouterAttachments(uploader: .init(upload: { _, _ in "att-1" }, delete: { deletes.append($0); deleted.fire() }))
        model.attachments = attachments
        guard case .attachment(let id) = attachments.add(name: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8)) else { return }
        await waitUntil { attachments.states[id] == .ready("att-1") }
        do {
            attachments.draftHolds([id])
            model.select(.line(ID.updater))
            model.edit(MentionText.markString + " as here", marks: [RouterMention(range: 0..<1, pointer: .attachment(id), name: "notes.txt")])
            model.apply(.read(RouterRead(draft: "[file: notes.txt] as here", places: [.thread(ID.updater)], sure: true)))
            model.send()
            // The draft let it go; the card's answer keeps it.
            attachments.draftHolds([])
            #expect(deletes.isEmpty && attachments.states[id] == .ready("att-1"))
            // An option in place of those words: nothing keeps it, and its upload is deleted.
            model.pick(1)
            await deleted.wait()
            #expect(deletes == ["att-1"])
        }
        withExtendedLifetime(source) {}
    }
}
