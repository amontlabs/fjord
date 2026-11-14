import Foundation
import Testing
@testable import Fjord

/// A refused send loses none of its pictures and files: Send again carries the same uploads, Edit puts their pills back,
/// and an upload is marked sent only once T3 takes the send (deleted only when nothing offers to send it again). All on
/// stubs: nothing reaches T3.
@MainActor
@Suite(.serialized) struct RouterAttachmentRefusalsTests {
    typealias F = T3Fixture
    private typealias ID = RouterDemo.ID

    private static let shot = T3Attachment(type: "image", id: "att-1", name: "shot.png", mimeType: "image/png", sizeBytes: 9)
    private static let pill = "[image: shot.png]"

    private func item(_ id: String = "image_a") -> RouterAttachment {
        RouterAttachment(id: id, kind: RouterAttachment.kind(of: id), name: "shot.png", mimeType: "image/png", sizeBytes: 9,
                         data: Data(count: 9))
    }

    // MARK: 2 and 4. Send again, Edit, and when the uploads go

    /// The page, sending to ID.bar through a recorder, with a picture uploaded at once whose deletes are counted.
    private func page() async -> (RouterModel, RouterModelTests.Recorder, RouterAttachments, String, () -> [String]) {
        var deletes: [String] = []
        let attachments = RouterAttachments(uploader: .init(upload: { _, minted in minted("att-1"); return "att-1" },
                                                            delete: { deletes.append($0) }))
        let pointer = attachments.add(name: "shot.png", mimeType: "image/png", data: Data(count: 9))
        let id = pointer.attachment!
        await waitUntil { attachments.states[id] == .ready("att-1") }
        let model = RouterDemo.records()
        model.attachments = attachments
        model.select(nil)
        let composer = RouterComposerModel()
        composer.attachments = attachments
        composer.pointers = [pointer]
        let text = "fix " + MentionText.markString + " now"
        model.edit(text, marks: RouterMentions.marks(text, pointers: [pointer], name: { _ in "shot.png" }))
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.bar)], sure: true)))
        let source = RouterModelTests.Recorder()
        model.source = source
        model.send()
        // The composer's field empties with the draft.
        composer.pointers = []
        return (model, source, attachments, id, { deletes })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func aRefusedSendKeepsItsUploadAndSendAgainCarriesIt() async throws {
        let (model, source, attachments, id, deletes) = await page()
        // Not sent until T3 takes it: the send in flight keeps it.
        #expect(!attachments.sentIDs.contains(id))
        model.apply(.refused(ID.bar, reason: "T3 refused it", offline: false, hold: source.sends.last?.hold))
        let failure = try #require(model.failures.first)
        #expect(failure.attached.map(\.pointer) == [.attachment(id)])
        await settle()
        #expect(deletes().isEmpty && attachments.states[id] == .ready("att-1"))
        model.sendAgain(failure.id)
        #expect(source.sends.count == 2)
        #expect(source.sends.last?.words == "fix " + Self.pill + " now")
        #expect(source.sends.last?.attached.map(\.pointer) == [.attachment(id)])
        // The same upload, still there for it.
        #expect(try await attachments.uploads([id])[id]?.id == "att-1")
        await settle()
        #expect(deletes().isEmpty)
    }

    @Test func editOnARefusedSendPutsThePictureBackInTheDraft() async {
        let (model, source, attachments, id, deletes) = await page()
        model.apply(.refused(ID.bar, reason: "T3 refused it", offline: false, hold: source.sends.last?.hold))
        guard let failure = model.failures.first else { Issue.record("no failure line"); return }
        model.edit(failure.id)
        #expect(model.plainDraft == "fix " + Self.pill + " now")
        #expect(model.mentions.map(\.pointer) == [.attachment(id)])
        await settle()
        #expect(deletes().isEmpty)
        // Taken out of the draft then: nothing keeps it, and its upload goes.
        model.edit("fix now", marks: [])
        await settle()
        #expect(deletes() == ["att-1"] && !attachments.sentIDs.contains(id))
    }

    @Test func t3TakingTheSendMarksItsUploadsSentAndARefusalDoesnt() {
        let f = RouterActsTests.Fake()
        let acts = f.acts()
        var sent: [[String]] = []
        acts.env.sent = { ids, _ in sent.append(ids) }
        let pill = RouterMention(range: 4..<21, pointer: .attachment("image_a"), name: "shot.png")
        acts.send(RouterOutgoing(thread: "t1", words: "see " + Self.pill, kind: .words, steering: false, queue: false, read: nil,
                                 attached: [pill]))
        #expect(sent.isEmpty)
        acts.sendEvent(f.entry!, .refused(reason: "no", offline: false))
        #expect(sent.isEmpty)
        f.entry = UUID()
        acts.send(RouterOutgoing(thread: "t1", words: "see " + Self.pill, kind: .words, steering: false, queue: false, read: nil,
                                 attached: [pill]))
        acts.sendEvent(f.entry!, .taken)
        #expect(sent == [["image_a"]])
    }

    @Test func aSentUploadIsNeverDeletedAndItsBytesGo() async {
        var deletes: [String] = []
        let attachments = RouterAttachments(uploader: .init(upload: { _, _ in "att-1" }, delete: { deletes.append($0) }))
        let id = attachments.add(name: "shot.png", mimeType: "image/png", data: Data(count: 9)).attachment!
        await waitUntil { attachments.states[id] == .ready("att-1") }
        attachments.holds([id], by: "send:1")
        attachments.sent([id], by: "send:1")
        #expect(attachments.items[id] == nil && attachments.held(by: "send:1").isEmpty)
        attachments.holds([], by: "draft")
        attachments.remove(id)
        await settle()
        #expect(deletes.isEmpty)
    }

    @Test func aRefusedAnswersUploadIsKeptForSendAgain() async {
        let (model, source) = (RouterDemo.records(), RouterModelTests.Recorder())
        var deletes: [String] = []
        let attachments = RouterAttachments(uploader: .init(upload: { _, _ in "att-1" }, delete: { deletes.append($0) }))
        model.attachments = attachments
        model.source = source
        let id = attachments.add(name: "shot.png", mimeType: "image/png", data: Data(count: 9)).attachment!
        await waitUntil { attachments.states[id] == .ready("att-1") }
        model.select(.line(ID.settings))
        model.edit("like this " + MentionText.markString, marks: [RouterMention(range: 10..<11, pointer: .attachment(id), name: "shot.png")])
        model.apply(.read(RouterRead(draft: "like this " + Self.pill, places: [.thread(ID.settings)], sure: true)))
        model.send()
        #expect(source.sends.first?.kind == .answer(picks: [:], typed: [0: "like this"], attached: [0: [id]]))
        model.apply(.refused(ID.settings, reason: "That isn't waiting anymore", offline: false, hold: source.sends.last?.hold))
        await settle()
        #expect(deletes.isEmpty && model.failures.count == 1)
        model.sendAgain(model.failures[0].id)
        #expect(source.sends.last?.kind == .answer(picks: [:], typed: [0: "like this"], attached: [0: [id]]))
        await settle()
        #expect(deletes.isEmpty)
    }
}
