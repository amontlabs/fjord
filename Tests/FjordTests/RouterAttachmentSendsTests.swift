import AppKit
import Foundation
import Testing
@testable import Fjord

/// Pasted pictures and files across a split and the draft's life: each part of a split carries the pills it says, where
/// it says them; a pill the Router left out goes with the part before it; one upload serves every thread it goes to (T3
/// copies a pending upload into each thread that claims it); and a pill that leaves the draft unsent (cleared, cut,
/// replaced) has its upload deleted once, while a sent one never is. On stubs: nothing reaches T3.
@MainActor
@Suite struct RouterAttachmentSendsTests {
    private typealias ID = RouterDemo.ID

    /// An uploader that answers at once ("att-1", "att-2", …) and counts its uploads and deletes.
    @MainActor final class Counted {
        var uploads = 0
        var deletes: [String] = []
        var uploader: RouterAttachments.Uploader {
            RouterAttachments.Uploader(upload: { [unowned self] _, minted in
                uploads += 1
                let id = "att-\(uploads)"
                minted(id)
                return id
            }, delete: { [unowned self] id in deletes.append(id) })
        }
    }

    /// Until the work the attachments started (an upload, a delete) has run: a few turns of the main actor.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func png() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        return image.testPNG
    }

    // MARK: A split

    /// "keep the sidebar icons. val cenis: see <pill> please": the picture sits in the second part.
    private func splitWithAPicture(_ parts: [String]) -> (RouterModel, RouterModelTests.Recorder, RouterAttachments, String) {
        let attachments = RouterAttachments()
        let pointer = attachments.add(name: "shot.png", mimeType: "image/png", data: png())
        let id = pointer.attachment!
        let model = RouterDemo.records()
        model.attachments = attachments
        model.select(nil)
        let mark = MentionText.markString
        let text = "keep the sidebar icons. val cenis: see " + mark + " please"
        model.edit(text, marks: RouterMentions.marks(text, pointers: [pointer], name: { _ in "shot.png" }))
        let sends = [RouterSend(places: [.thread(ID.settings)], words: parts[0]),
                     RouterSend(places: [.thread(ID.valCenis)], words: parts[1], item: "i1")]
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [sends[0].place], sure: true, sends: sends)))
        model.finishTurn()
        let source = RouterModelTests.Recorder()
        model.source = source
        return (model, source, attachments, id)
    }

    @Test func aSplitsPictureGoesOnlyWithThePartThatSaysItWhereItSays() throws {
        let (model, source, attachments, id) = splitWithAPicture(["keep the sidebar icons", "see [image: shot.png] please"])
        #expect(model.plainDraft == "keep the sidebar icons. val cenis: see [image: shot.png] please")
        model.send()
        let val = try #require(source.sends.first { $0.thread == ID.valCenis })
        #expect(val.words == "see [image: shot.png] please")
        #expect(val.attached == [RouterMention(range: 4..<21, pointer: .attachment(id), name: "shot.png")])
        let settings = try #require(source.sends.first { $0.thread == ID.settings })
        #expect(settings.attached.isEmpty)
        // In flight: the send to its thread keeps it under its own key (sent once T3 takes it), so the draft emptying
        // deletes nothing.
        #expect(val.hold.map { attachments.held(by: $0) } == [id])
        #expect(settings.hold == nil)
    }

    /// The split of `splitWithAPicture` with a counting uploader, the picture uploaded before Return.
    private func countedSplit(_ parts: [String], second: RouterPlace = .thread(ID.valCenis)) async
        -> (RouterModel, RouterModelTests.Recorder, RouterAttachments, String, Counted) {
        let counted = Counted()
        let attachments = RouterAttachments(uploader: counted.uploader)
        let pointer = attachments.add(name: "shot.png", mimeType: "image/png", data: png())
        let id = pointer.attachment!
        _ = try? await attachments.uploads([id])
        let model = RouterDemo.records()
        model.attachments = attachments
        model.select(nil)
        let text = "keep the sidebar icons. val cenis: see " + MentionText.markString + " please"
        model.edit(text, marks: RouterMentions.marks(text, pointers: [pointer], name: { _ in "shot.png" }))
        let sends = [RouterSend(places: [.thread(ID.settings)], words: parts[0]), RouterSend(places: [second], words: parts[1])]
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [sends[0].place], sure: true, sends: sends)))
        model.finishTurn()
        let source = RouterModelTests.Recorder()
        model.source = source
        return (model, source, attachments, id, counted)
    }

    @Test func aPictureNoPartSaysGoesWithThePartBeforeIt() throws {
        let (model, source, _, id) = splitWithAPicture(["keep the sidebar icons", "see please"])
        model.send()
        let val = try #require(source.sends.first { $0.thread == ID.valCenis })
        #expect(val.words == "see please [image: shot.png]")
        #expect(val.attached.map(\.pointer) == [.attachment(id)])
        #expect(source.sends.first { $0.thread == ID.settings }?.attached.isEmpty == true)
    }

    @Test func thePartBeforeAPillIsTheOneWhoseWordsComeLastBeforeIt() {
        let pill = RouterMention(range: 6..<23, pointer: .attachment("image_a"), name: "shot.png")
        let draft = "first [image: shot.png] then second"
        #expect(RouterAttachments.placed(["first", "then second"], draft: draft, pills: [pill])
            == ["first [image: shot.png]", "then second"])
        // Said by a part already: nothing moves.
        #expect(RouterAttachments.placed(["first", "then [image: shot.png]"], draft: draft, pills: [pill])
            == ["first", "then [image: shot.png]"])
    }

    @Test func aPartFindsEachOfTwoPicturesByItsOwnName() {
        let attachments = RouterAttachments()
        let a = attachments.add(name: "image.png", mimeType: "image/png", data: png())
        let b = attachments.add(name: "image.png", mimeType: "image/png", data: png())
        // Two screenshots pasted with one name read apart, so a part says which one it carries.
        #expect(attachments.items[a.attachment!]?.name == "image.png")
        #expect(attachments.items[b.attachment!]?.name == "image 2.png")
        let pills = [RouterMention(range: 0..<1, pointer: a, name: "image.png"),
                     RouterMention(range: 2..<3, pointer: b, name: "image 2.png")]
        let found = RouterAttachments.pills(in: "and [image: image 2.png] too", of: pills)
        #expect(found == [RouterMention(range: 4..<24, pointer: b, name: "image 2.png")])
    }

    @Test func onePictureForTwoThreadsIsOneUploadBoundInEach() async throws {
        let counted = Counted()
        let attachments = RouterAttachments(uploader: counted.uploader)
        let id = attachments.add(name: "shot.png", mimeType: "image/png", data: png()).attachment!
        // Part 1 sends it, then part 2: T3 copies the pending upload into each thread, so the same one serves both.
        let first = try await attachments.uploads([id])
        let second = try await attachments.uploads([id])
        #expect(first[id]?.id == "att-1" && second[id]?.id == "att-1")
        #expect(counted.uploads == 1)
        let s = Store.reading([T3Fixture.shell("t1")])
        let pill = RouterMention(range: 4..<21, pointer: .attachment(id), name: "shot.png")
        for uploads in [first, second] {
            let words = try RouterPointers.threadMessage("see [image: shot.png]", pills: [], mentions: [pill], store: s, uploads: uploads)
            #expect(words.attachments.map(\.id) == ["att-1"])
            #expect(words.text == "see ![shot.png](t3-context://v1/image/\(id))")
        }
    }

    // MARK: The draft's pills and their uploads

    @Test func clearingTheDraftDeletesItsUploadsOnceAndAnUndoUploadsAgain() async {
        let counted = Counted()
        let attachments = RouterAttachments(uploader: counted.uploader)
        let composer = RouterComposerModel()
        composer.attachments = attachments
        let id = attachments.add(name: "shot.png", mimeType: "image/png", data: png()).attachment!
        composer.pointers = [.attachment(id)]
        await settle()
        #expect(attachments.states[id] == .ready("att-1"))
        // Esc, a clear, Return taking other words: the draft empties, the upload goes.
        composer.pointers = []
        composer.pointers = []
        await settle()
        #expect(counted.deletes == ["att-1"])
        // The pill back (⌘Z): uploaded again; cleared again, that upload goes too.
        composer.pointers = [.attachment(id)]
        await settle()
        #expect(attachments.states[id] == .ready("att-2"))
        // A prefill replacing the draft (here one with no words): its pill goes, and that upload with it.
        composer.prefill([.project("/code/fjord")])
        #expect(composer.pointers == [.project("/code/fjord")])
        await settle()
        #expect(counted.deletes == ["att-1", "att-2"])
    }

    @Test func aSentPictureIsNeverDeleted() async throws {
        let counted = Counted()
        let attachments = RouterAttachments(uploader: counted.uploader)
        let composer = RouterComposerModel()
        composer.attachments = attachments
        let pointer = attachments.add(name: "shot.png", mimeType: "image/png", data: png())
        let id = pointer.attachment!
        composer.pointers = [pointer]
        await settle()
        // Return on the page: the words go with the picture, then the composer empties.
        let model = RouterDemo.records()
        model.attachments = attachments
        model.select(nil)
        let text = "fix " + MentionText.markString + " now"
        model.edit(text, marks: RouterMentions.marks(text, pointers: [pointer], name: { _ in "shot.png" }))
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.bar)], sure: true)))
        let source = RouterModelTests.Recorder()
        model.source = source
        model.send()
        #expect(source.sends.first?.attached.map(\.pointer) == [pointer])
        composer.pointers = []
        _ = try await attachments.uploads([id])
        await settle()
        #expect(counted.deletes.isEmpty)
        // T3 took it (`RouterActs`): sent, and nothing deletes it now.
        attachments.sent([id], by: source.sends.first?.hold)
        attachments.remove(id)
        await settle()
        #expect(counted.deletes.isEmpty)
    }

    // MARK: One Return, one holder; each send its own

    @Test func aPictureInASplitsLaterPartIsNeverLetGoBetweenTheParts() async throws {
        let (model, source, attachments, id, counted) = await countedSplit(["keep the sidebar icons", "see [image: shot.png] please"])
        model.send()
        await settle()
        // The first part emptied the draft; the Return held the picture until the second part's send held it.
        #expect(counted.deletes.isEmpty && counted.uploads == 1)
        let val = try #require(source.sends.first { $0.thread == ID.valCenis })
        #expect(val.hold.map { attachments.held(by: $0) } == [id] && attachments.states[id] == .ready("att-1"))
    }

    @Test func aPictureInAPartTheRouterAnswersItselfGoesWithTheSendingPartBeforeIt() async throws {
        let (model, source, attachments, id, counted) = await countedSplit(["keep the sidebar icons", "see [image: shot.png] please"],
                                                                           second: .here)
        model.send()
        await settle()
        let settings = try #require(source.sends.first { $0.thread == ID.settings })
        #expect(settings.words == "keep the sidebar icons [image: shot.png]")
        #expect(settings.attached.map(\.pointer) == [.attachment(id)])
        #expect(counted.deletes.isEmpty && settings.hold.map { attachments.held(by: $0) } == [id])
    }

    @Test func twoSendsToOneThreadEachKeepTheirOwnPicturesWhenOneIsRefused() async throws {
        let attachments = RouterAttachments()
        let a = attachments.add(name: "a.png", mimeType: "image/png", data: png()).attachment!
        let b = attachments.add(name: "b.png", mimeType: "image/png", data: png()).attachment!
        let model = RouterDemo.records()
        model.attachments = attachments
        let source = RouterModelTests.Recorder()
        model.source = source
        let pillA = RouterMention(range: 4..<18, pointer: .attachment(a), name: "a.png")
        let pillB = RouterMention(range: 4..<18, pointer: .attachment(b), name: "b.png")
        model.dispatch("see [image: a.png]", to: try #require(model.thread(ID.bar)), kind: .words, attached: [pillA])
        model.dispatch("see [image: b.png]", to: try #require(model.thread(ID.bar)), kind: .words, attached: [pillB])
        let (first, second) = (source.sends[0], source.sends[1])
        #expect(first.hold != nil && second.hold != nil && first.hold != second.hold)
        // The first is refused after the second went: its failure line is its own, words and picture, and only its upload.
        model.apply(.refused(ID.bar, reason: "T3 refused it", offline: false, hold: first.hold))
        let failure = try #require(model.failures.first)
        #expect(failure.words == "see [image: a.png]" && failure.attached == [pillA])
        #expect(attachments.held(by: RouterModel.failing(failure.id)) == [a])
        #expect(attachments.held(by: second.hold!) == [b])
    }

    // MARK: What is kept, and for how long

    @Test func aSentPictureAnotherSendStillCarriesIsKeptUntilThatOneIsTakenToo() {
        let attachments = RouterAttachments()
        let id = attachments.add(name: "shot.png", mimeType: "image/png", data: png()).attachment!
        attachments.holds([id], by: "send:1")
        attachments.holds([id], by: "send:2")
        attachments.sent([id], by: "send:1")
        // The second part, still in flight, may need the bytes (a re-upload near T3's sweep).
        #expect(attachments.items[id]?.data != nil)
        attachments.sent([id], by: "send:2")
        #expect(attachments.items[id] == nil && attachments.states[id] == nil)
    }

    @Test func aReturnThatEmptiesTheDraftLetsGoTheBytesOfWhatWasTakenOutBefore() async throws {
        let counted = Counted()
        let attachments = RouterAttachments(uploader: counted.uploader)
        let model = RouterDemo.records()
        model.attachments = attachments
        model.select(nil)
        let taken = attachments.add(name: "shot.png", mimeType: "image/png", data: png())
        let text = "fix " + MentionText.markString + " now"
        model.edit(text, marks: RouterMentions.marks(text, pointers: [taken], name: { _ in "shot.png" }))
        await settle()
        // Taken out: its upload goes, its bytes stay for an undo.
        model.edit("fix it now", marks: [])
        await settle()
        #expect(counted.deletes == ["att-1"] && attachments.items[taken.attachment!]?.data != nil)
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.bar)], sure: true)))
        model.source = RouterModelTests.Recorder()
        model.send()
        // The Return emptied the draft: no undo brings it back now, and nothing of it is kept.
        #expect(attachments.items[taken.attachment!] == nil)
        // Its name is free again.
        let again = attachments.add(name: "shot.png", mimeType: "image/png", data: png()).attachment!
        #expect(attachments.items[again]?.name == "shot.png")
    }
}
