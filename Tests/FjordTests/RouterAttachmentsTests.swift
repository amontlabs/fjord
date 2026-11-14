import AppKit
import Foundation
import Testing
@testable import Fjord

/// Pictures and files pasted in the Router composer: what T3 gets for one (its reference where the pill sat, a record bound
/// to the upload, the upload in `attachments`), the upload's requests, a pill taken out deleting its upload, and a send
/// waiting for an upload still posting. All on stubs: nothing reaches T3.
@MainActor
@Suite struct RouterAttachmentsTests {
    typealias F = T3Fixture

    /// Fires once; a wait before or after the fire returns once it has.
    @MainActor final class Signal {
        private var fired = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func fire() {
            fired = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func item(_ id: String, name: String, mime: String, size: Int = 1234) -> RouterAttachment {
        RouterAttachment(id: id, kind: RouterAttachment.kind(of: id), name: name, mimeType: mime, sizeBytes: size, data: Data(count: size))
    }

    private func png() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        return RouterAttachments.png(image)!
    }

    // MARK: What T3 gets

    @Test func aPictureInTheMiddleOfYourWordsGoesWhereItSatBoundToItsUpload() throws {
        let s = Store.reading([F.shell("t1")])
        s.attachments.put(item("image_abc", name: "shot.png", mime: "image/png"), state: .ready("att-1"))
        let draft = "look at " + MentionText.markString + " then fix it"
        let (text, mentions) = RouterPointers.message(draft: draft, pointers: [.attachment("image_abc")], name: s.pointerName)
        #expect(text == "look at [image: shot.png] then fix it")
        #expect(mentions.map(\.name) == ["shot.png"] && mentions.map(\.range) == [8..<25])
        let uploads = ["image_abc": T3Attachment(type: "image", id: "att-1", name: "shot.png", mimeType: "image/png", sizeBytes: 1234)]
        let words = try RouterPointers.threadMessage(text, pills: [], mentions: mentions, store: s, uploads: uploads)
        #expect(words.text == "look at ![shot.png](t3-context://v1/image/image_abc) then fix it")
        #expect(words.words == text)
        #expect(words.records == [[
            "version": 1, "contextId": "image_abc", "kind": "image", "label": "shot.png", "attachmentId": "att-1",
            "name": "shot.png", "mimeType": "image/png", "sizeBytes": 1234,
        ]])
        #expect(words.attachments == [uploads["image_abc"]!])
    }

    @Test func aFileGoesAsALinkWithNoBangAndItsOwnKind() throws {
        let s = Store.reading([F.shell("t1")])
        s.attachments.put(item("file_f1", name: "notes [draft].pdf", mime: "application/pdf"), state: .ready("att-2"))
        let (text, mentions) = RouterPointers.message(draft: MentionText.markString + " read this", pointers: [.attachment("file_f1")],
                                                      name: s.pointerName)
        #expect(text == "[file: notes [draft].pdf] read this")
        let upload = T3Attachment(type: "file", id: "att-2", name: "notes [draft].pdf", mimeType: "application/pdf", sizeBytes: 1234)
        let words = try RouterPointers.threadMessage(text, pills: [], mentions: mentions, store: s, uploads: ["file_f1": upload])
        // T3's label has no brackets; the name stays as it is.
        #expect(words.text == "[notes draft .pdf](t3-context://v1/file/file_f1) read this")
        guard case .object(let record) = words.records.first else { Issue.record("no record"); return }
        #expect(record["kind"] == "file" && record["name"] == "notes [draft].pdf" && record["attachmentId"] == "att-2")
    }

    @Test func theAttachmentsRideTheDispatchWithTheirRecords() async throws {
        let s = Store.reading([F.shell("t1", status: "idle")])
        var sent: [T3Command] = []
        s.requestSender = { command, _ in sent.append(command) }
        let upload = T3Attachment(type: "image", id: "att-1", name: "shot.png", mimeType: "image/png", sizeBytes: 9)
        let (reference, record) = RouterPointers.attachment(id: "image_abc", upload: upload)
        _ = try await s.sendToThread("t1", ThreadMessage(text: "see " + reference, records: [record], attachments: [upload]), mode: .steer)
        guard case .object(let o) = sent.first?.payload(commandId: "c") else { Issue.record("nothing sent"); return }
        #expect(o["attachments"] == .array([upload.json]))
        #expect(o["context"] == ["version": 1, "records": .array([record])])
        #expect(o["text"] == "see ![shot.png](t3-context://v1/image/image_abc)")
    }

    @Test func aNewThreadStartsWithTheAttachments() {
        let upload = T3Attachment(type: "file", id: "att-3", name: "log.txt", mimeType: "text/plain", sizeBytes: 3)
        let message = ThreadMessage(text: "[log.txt](t3-context://v1/file/file_x)", attachments: [upload])
        let request = ThreadLauncher.request(thread: "t9", project: "p1", message: message,
                                             model: ThreadLaunchModel(instanceId: "claudeAgent", model: "claude-opus-5-5"),
                                             runtimeMode: .fullAccess, workspace: .root)
        #expect(request.initialMessage["attachments"] == .array([upload.json]))
        // The title reads the file's name, not its link.
        #expect(request.title == "log.txt")
    }

    @Test func theDispatcherKeepsAnAttachmentsPillOnlyWhereItsWordsAre() {
        let pill = RouterMention(range: 4..<21, pointer: .attachment("image_abc"), name: "shot.png")
        #expect(RouterDispatcher.mentions([pill], in: "see [image: shot.png]") == [pill])
        #expect(RouterDispatcher.mentions([pill], in: "see [image: other.png] ok").isEmpty)
    }

    @Test func aMessagesReferencesReadAsTheirLabels() {
        #expect(RouterPointers.readable("look ![shot.png](t3-context://v1/image/image_a) and [@CI](t3-context://v1/fjord-category/ctx_1).")
                == "look shot.png and @CI.")
        #expect(RouterPointers.readable("a [link](https://x.y) stays") == "a [link](https://x.y) stays")
    }

    // MARK: Uploads

    @Test func theUploadRequestsAreT3sShapes() {
        #expect(RouterAttachments.Uploader.uploadRequest(item("image_a", name: "s.png", mime: "image/png", size: 10))
                == ["name": "s.png", "mimeType": "image/png", "sizeBytes": 10])
        #expect(RouterAttachments.Uploader.uploadRequest(item("file_a", name: "n.pdf", mime: "application/pdf", size: 10))
                == ["type": "file", "name": "n.pdf", "mimeType": "application/pdf", "sizeBytes": 10])
        #expect(RouterAttachments.Uploader.deleteRequest("att-1") == ["attachmentId": "att-1"])
        let post = RouterAttachments.Uploader.postRequest(url: URL(string: "http://127.0.0.1:3773/api/attachments/upload/tok")!,
                                                          mimeType: "image/png")
        #expect(post.httpMethod == "POST" && post.value(forHTTPHeaderField: "Content-Type") == "image/png")
    }

    @Test func anUploadAsksForItsURLThenPostsTheBytesThere() async throws {
        var calls: [(String, T3JSON)] = []
        nonisolated(unsafe) var posted: (URL?, Data)?
        let uploader = RouterAttachments.Uploader.t3(
            call: { tag, payload in
                calls.append((tag, payload))
                return ["attachmentId": "att-7", "relativeUrl": "/api/attachments/upload/signed", "expiresAt": 1]
            },
            origin: { URL(string: "http://127.0.0.1:3773") },
            post: { request, data in posted = (request.url, data); return 204 })
        let attachments = RouterAttachments(uploader: uploader)
        let pointer = attachments.add(name: "dot.png", mimeType: "image/png", data: png())
        guard case .attachment(let id) = pointer else { Issue.record("no pill"); return }
        #expect(id.hasPrefix("image_") && attachments.states[id] == .uploading)
        let uploads = try await attachments.uploads([id])
        #expect(uploads[id]?.id == "att-7" && uploads[id]?.type == "image")
        #expect(calls.map(\.0) == ["attachments.createUploadUrl"])
        #expect(posted?.0?.absoluteString == "http://127.0.0.1:3773/api/attachments/upload/signed")
        #expect(posted?.1.count == attachments.items[id]?.sizeBytes)
    }

    @Test func aPictureT3DoesntTakeIsMadeAPNGAndAnythingElseIsAFile() {
        let attachments = RouterAttachments()
        let tiff = NSImage(data: png())!.tiffRepresentation!
        guard case .attachment(let picture) = attachments.add(name: "Pasted image.tiff", mimeType: "image/tiff", data: tiff),
              case .attachment(let file) = attachments.add(name: "notes.pdf", mimeType: "application/pdf", data: Data(count: 10)) else {
            Issue.record("no pills"); return
        }
        #expect(attachments.items[picture]?.mimeType == "image/png" && attachments.items[picture]?.name == "Pasted image.png")
        #expect(attachments.items[picture]?.thumbnail != nil && picture.hasPrefix("image_"))
        #expect(file.hasPrefix("file_") && attachments.items[file]?.thumbnail == nil)
        // No uploader (a demo): done at once.
        #expect(attachments.states[file] == .ready(file))
    }

    @Test func tooBigFailsAtOnce() {
        let attachments = RouterAttachments()
        guard case .attachment(let id) = attachments.add(name: "big.bin", mimeType: "application/octet-stream",
                                                         data: Data(count: RouterAttachment.maxFileBytes + 1)) else { return }
        #expect(attachments.states[id] == .failed("Over T3's 50 MB"))
    }

    /// An uploader whose post waits for the test, and whose deletes are counted.
    private func gated(open: Signal, minted: Signal, deleted: Signal, deletes: @escaping (String) -> Void,
                       events: @escaping (String) -> Void) -> RouterAttachments.Uploader {
        RouterAttachments.Uploader(upload: { _, mint in
            mint("att-1")
            minted.fire()
            await open.wait()
            try Task.checkCancellation()
            events("posted")
            return "att-1"
        }, delete: { id in
            deletes(id)
            deleted.fire()
        })
    }

    @Test func aSendWaitsForAnUploadStillPosting() async throws {
        let (open, minted, deleted) = (Signal(), Signal(), Signal())
        var events: [String] = []
        let attachments = RouterAttachments(uploader: gated(open: open, minted: minted, deleted: deleted, deletes: { _ in },
                                                            events: { events.append($0) }))
        guard case .attachment(let id) = attachments.add(name: "dot.png", mimeType: "image/png", data: png()) else { return }
        let send = Task { @MainActor in
            let out = try await attachments.uploads([id])
            events.append("sent")
            return out
        }
        await minted.wait()
        #expect(events.isEmpty)
        open.fire()
        let uploads = try await send.value
        #expect(events == ["posted", "sent"])
        #expect(uploads[id]?.id == "att-1")
        // Kept until T3 takes the send (a refused one is sent again); then let go.
        #expect(attachments.items[id]?.data != nil)
        attachments.sent([id])
        #expect(attachments.items[id]?.data == nil)
    }

    @Test func takingThePillOutMidPostDeletesTheUploadAndAnUndoUploadsAgain() async throws {
        let (open, minted, deleted) = (Signal(), Signal(), Signal())
        var deletes: [String] = []
        let attachments = RouterAttachments(uploader: gated(open: open, minted: minted, deleted: deleted,
                                                            deletes: { deletes.append($0) }, events: { _ in }))
        guard case .attachment(let id) = attachments.add(name: "dot.png", mimeType: "image/png", data: png()) else { return }
        await minted.wait()
        attachments.remove(id)
        await deleted.wait()
        #expect(deletes == ["att-1"])
        // Sending it now says why nothing went.
        await #expect(throws: ThreadSendFailure.self) { try await attachments.uploads([id]) }
        // The pill came back (⌘Z): uploaded again.
        attachments.restore(id)
        #expect(attachments.states[id] == .uploading)
        open.fire()
        #expect(try await attachments.uploads([id])[id]?.id == "att-1")
    }

    @Test func aFailedUploadSaysSoAndAClickTriesAgain() async throws {
        var tries = 0
        let attachments = RouterAttachments(uploader: RouterAttachments.Uploader(upload: { _, _ in
            tries += 1
            if tries == 1 { throw ThreadSendFailure("T3 refused the upload (500)") }
            return "att-9"
        }, delete: { _ in }))
        guard case .attachment(let id) = attachments.add(name: "n.txt", mimeType: "text/plain", data: Data("hi".utf8)) else { return }
        await #expect(throws: ThreadSendFailure.self) { try await attachments.uploads([id]) }
        #expect(attachments.states[id] == .failed("T3 refused the upload (500)"))
        #expect(MentionLook.attachment(id, item: attachments.items[id], state: attachments.states[id], name: nil).upload == .failed)
        attachments.retry(id)
        #expect(try await attachments.uploads([id])[id]?.id == "att-9")
    }
}
