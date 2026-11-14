import AppKit
import Foundation
import Testing
@testable import Fjord

/// The attachment path against the owner's real T3 server, opt-in: `FJORD_T3_LIVE=1 swift test --filter T3AttachmentLive`.
/// Not read-only: each case uploads pictures, starts ONE throwaway thread in the scratch "No project" on the cheapest Haiku
/// T3 offers, waits for its reply, titles it "Fjord attachment check — delete me" and archives it. Everything goes through
/// Fjord's own code: `RouterAttachments` with T3's uploader and its `sending` wrapper, the composer's
/// `RouterPointers.message`, `RouterPointers.threadMessage` and `Store.launchThread`.
@Suite("T3 attachment live (writes archived threads)", .serialized, .timeLimit(.minutes(6)))
struct T3AttachmentLiveTests {
    static let title = "Fjord attachment check — delete me"
    static let live = ProcessInfo.processInfo.environment["FJORD_T3_LIVE"] == "1"

    static func json(_ j: T3JSON) -> String { (try? j.data()).map { String(decoding: $0, as: UTF8.self) } ?? "?" }

    /// A picture of `word` in large black letters on white.
    @MainActor static func picture(_ word: String) -> Data {
        let size = NSSize(width: 640, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 88), .foregroundColor: NSColor.black]
            let text = NSAttributedString(string: word, attributes: attributes)
            let s = text.size()
            text.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        return image.testPNG
    }

    /// A store wired to the real T3: its shell, its sends (each dispatch's failure kept), its uploads (each call kept).
    @MainActor final class Harness {
        let client = T3Client.local()
        let store = Store()
        var shell = T3ShellState()
        var calls: [(tag: String, payload: T3JSON, answer: Result<T3JSON, Error>)] = []
        var dispatchFailures: [Error] = []
        let deleted: AsyncStream<Void>
        private let deletedHeard: AsyncStream<Void>.Continuation

        init() {
            (deleted, deletedHeard) = AsyncStream<Void>.makeStream()
        }

        func start() async {
            for await item in await client.subscribeShell() {
                shell.apply(item)
                if case .snapshot = item { break }
            }
            store.persists = false
            store.t3.store.seed(shell, notify: false)
            // A pretend store sends nothing; these stand T3 itself in for the store's link.
            store.requestSender = { [client, weak self] command, commandId in
                do { _ = try await client.dispatch(command, commandId: commandId) } catch {
                    self?.dispatchFailures.append(error)
                    throw error
                }
            }
            store.launchSupport.config = { [client] in try await client.call(tag: "server.getConfig") }
            store.attachments = RouterAttachments(uploader: .t3(call: { [client, weak self] tag, payload in
                do {
                    let answer = try await client.call(tag: tag, payload: payload)
                    self?.calls.append((tag, payload, .success(answer)))
                    if tag == "attachments.delete" { self?.deletedHeard.yield() }
                    return answer
                } catch {
                    self?.calls.append((tag, payload, .failure(error)))
                    if tag == "attachments.delete" { self?.deletedHeard.yield() }
                    throw error
                }
            }))
        }

        func printCalls() {
            for c in calls {
                let answer: String = switch c.answer { case .success(let a): json(a); case .failure(let e): "ERROR \(e)" }
                print("T3 ATTACH LIVE: call \(c.tag) \(json(c.payload)) → \(answer)")
            }
        }

        var uploadCount: Int { calls.filter { $0.tag == "attachments.createUploadUrl" }.count }

        /// The scratch project ("No project", T3's own scratch folder).
        func scratch() throws -> T3Project {
            try #require(shell.projects.values.first { $0.archivedAt == nil && $0.workspaceRoot.hasSuffix("/.t3/scratch") },
                         "no scratch project in T3")
        }

        /// The cheapest model T3 offers: a Haiku on a ready provider.
        func haiku() async throws -> ThreadLaunchSettings {
            let config = try await client.call(tag: "server.getConfig")
            let haiku = (config["providers"]?.array ?? []).filter { $0.str("status") == "ready" && $0["enabled"]?.bool != false }
                .flatMap { p in (p["models"]?.array ?? []).compactMap { m in m.str("slug") ?? m.str("id") } }
                .filter { $0.lowercased().contains("haiku") }
            let slug = try #require(haiku.first, "T3 offers no Haiku")
            print("T3 ATTACH LIVE: model \(slug)")
            return ThreadLaunchSettings(model: slug, effort: nil, runtimeMode: .approvalRequired)
        }

        /// The thread's run followed until it ends (or the agent asks for something, or 4 minutes).
        func follow(_ thread: String) async -> T3Projection? {
            let stream = await client.subscribeThread(thread)
            let watch = Task { @MainActor () -> T3Projection? in
                var projection: T3Projection?
                for await item in stream {
                    switch item {
                    case .snapshot(_, let p): projection = p
                    case .event(let e): projection?.apply(e)
                    case .unknown: break
                    }
                    guard let p = projection else { continue }
                    if !p.pendingRequests.isEmpty { print("T3 ATTACH LIVE: the agent asked for something: \(p.pendingRequests.map(\.kind))"); break }
                    let ended = !p.runs.isEmpty && p.runs.allSatisfy { !$0.status.isLive && $0.status != .idle }
                    if ended, p.messages.contains(where: { $0.role == "assistant" && !$0.streaming && !$0.text.isEmpty }) { break }
                    if ended, p.runs.contains(where: { [.failed, .interrupted, .cancelled].contains($0.status) }) { break }
                }
                return projection
            }
            let timer = Task { try await Task.sleep(for: .seconds(240)); watch.cancel() }
            let final = await watch.value
            timer.cancel()
            return final
        }

        /// Titled as the throwaway it is (after T3's own title, which would overwrite it) and archived, whatever happened.
        func archive(_ thread: String) async {
            do { try await store.dispatch(.threadRename(threadId: thread, title: title)) } catch { print("T3 ATTACH LIVE: rename failed: \(error)") }
            do {
                try await store.dispatch(.threadArchive(threadId: thread))
                print("T3 ATTACH LIVE: archived \(thread) titled \(title)")
            } catch {
                Issue.record("ARCHIVE FAILED for \(thread): \(error)")
            }
        }

        func printThread(_ p: T3Projection) {
            print("T3 ATTACH LIVE: runs \(p.runs.map { "\($0.id)=\($0.status.rawValue)" }) title \(p.thread.title)")
            for m in p.messages { print("T3 ATTACH LIVE: \(m.role) [\(m.creationSource)]: \(m.text)") }
        }
    }

    /// The composer's message with the pill of `id` where the mark is in `draft`, launched into a new scratch thread through
    /// `RouterAttachments.sending`: the uploads are read (and made again if T3 refuses for a gone one) inside it.
    @MainActor static func launch(_ h: Harness, draft: String, id: String, thread: String, settings: ThreadLaunchSettings,
                                  project: T3Project) async throws -> ThreadWords {
        let s = h.store
        let (text, mentions) = RouterPointers.message(draft: draft, pointers: [.attachment(id)], name: s.pointerName)
        var sent: ThreadWords?
        try await s.attachments.sending(mentions.compactMap(\.pointer.attachment)) { uploads in
            let words = try RouterPointers.threadMessage(text, pills: [], mentions: mentions, store: s, uploads: uploads)
            print("T3 ATTACH LIVE: text sent: \(words.text)")
            print("T3 ATTACH LIVE: attachments sent: \(words.attachments.map { json($0.json) })")
            let message = ThreadMessage(text: words.text, records: words.records, attachments: words.attachments)
            _ = try await s.launchThread(in: project.id, message: message, thread: thread, settings: settings)
            sent = words
        }
        print("T3 ATTACH LIVE: launched thread \(thread) in \(project.title)")
        return try #require(sent)
    }

    @MainActor @Test(.enabled(if: live))
    func aPictureInTheMiddleOfAMessageReachesTheAgent() async throws {
        let word = "PELICAN-73"
        let h = Harness()
        await h.start()
        let s = h.store

        // 1–2. Two pictures uploaded; the second taken out of the draft, which deletes its upload.
        let png = Self.picture(word)
        guard case .attachment(let kept) = s.attachments.add(name: "pelican.png", mimeType: "image/png", data: png),
              case .attachment(let dropped) = s.attachments.add(name: "dropped.png", mimeType: "image/png", data: Self.picture("DROPPED"))
        else { Issue.record("no attachment ids"); return }
        let ready = try await s.attachments.uploads([kept, dropped])
        print("T3 ATTACH LIVE: uploaded \(kept) → \(ready[kept]!.id) (\(png.count) bytes), \(dropped) → \(ready[dropped]!.id)")
        s.attachments.draftHolds([kept, dropped])
        s.attachments.draftHolds([kept])
        for await _ in h.deleted { break }
        let deleteCall = try #require(h.calls.first { $0.tag == "attachments.delete" })
        #expect(deleteCall.payload == ["attachmentId": .string(ready[dropped]!.id)])
        if case .failure(let e) = deleteCall.answer { Issue.record("attachments.delete failed: \(e)") }
        #expect(s.attachments.states[dropped] == .failed("Taken out"))

        // 3. The message as the composer makes it: the pill in the middle of the words.
        let draft = "Before the picture " + MentionText.markString
            + " after the picture. Reply with only the word shown in the picture, and say whether the picture came before or after the word 'after'."
        let project = try h.scratch()
        let settings = try await h.haiku()
        let thread = UUID().uuidString.lowercased()
        let words: ThreadWords
        do {
            words = try await Self.launch(h, draft: draft, id: kept, thread: thread, settings: settings, project: project)
        } catch {
            h.printCalls()
            await h.archive(thread)
            await h.client.shutdown()
            throw error
        }

        // 4–5. The run followed to its end, then the thread titled and archived.
        let final = await h.follow(thread)
        await h.archive(thread)
        h.printCalls()
        await h.client.shutdown()

        let p = try #require(final, "no projection of the thread")
        h.printThread(p)
        let reply = p.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n")
        #expect(reply.uppercased().contains(word), "the reply doesn't name the word: \(reply)")
        #expect(reply.lowercased().contains("before"), "the reply doesn't place the picture before 'after': \(reply)")
        let user = try #require(p.messages.first { $0.role == "user" })
        #expect(user.text == words.text)
    }

    /// An upload T3 lost behind Fjord's back (deleted straight on T3; Fjord still holds it ready, bytes and all): the launch
    /// is refused, `sending` recognises T3's refusal, uploads the bytes again and the launch goes through.
    @MainActor @Test(.enabled(if: live))
    func anUploadGoneOnT3IsUploadedAgainAndTheSendGoesThrough() async throws {
        let word = "HERON-41"
        let h = Harness()
        await h.start()
        let s = h.store

        guard case .attachment(let id) = s.attachments.add(name: "heron.png", mimeType: "image/png", data: Self.picture(word))
        else { Issue.record("no attachment id"); return }
        let first = try await s.attachments.uploads([id])
        let gone = try #require(first[id]?.id)
        s.attachments.draftHolds([id])
        print("T3 ATTACH LIVE: uploaded \(id) → \(gone)")
        #expect(h.uploadCount == 1)

        // T3 loses it: its delete called on the client itself, not through RouterAttachments.
        let deleteAnswer = try await h.client.call(tag: "attachments.delete", payload: RouterAttachments.Uploader.deleteRequest(gone))
        print("T3 ATTACH LIVE: deleted \(gone) on T3 directly → \(Self.json(deleteAnswer))")
        #expect(s.attachments.states[id] == .ready(gone), "Fjord should still believe the upload is there")

        let draft = "Here is a picture: " + MentionText.markString + " Reply with only the word shown in the picture."
        let project = try h.scratch()
        let settings = try await h.haiku()
        let thread = UUID().uuidString.lowercased()
        var launchError: Error?
        do {
            _ = try await Self.launch(h, draft: draft, id: id, thread: thread, settings: settings, project: project)
        } catch {
            launchError = error
            print("T3 ATTACH LIVE: the launch failed for good: \(error)")
        }

        // T3's refusal, as Fjord received it.
        for e in h.dispatchFailures {
            let said = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            print("T3 ATTACH LIVE: refusal received: \(String(reflecting: e))")
            print("T3 ATTACH LIVE: refusal localizedDescription: \(said)")
            print("T3 ATTACH LIVE: refusal recognised by uploadGone: \(RouterAttachments.uploadGone(e))")
        }
        let refusal = try #require(h.dispatchFailures.first, "T3 didn't refuse the send of a deleted upload")
        #expect(RouterAttachments.uploadGone(refusal), "Fjord didn't recognise T3's refusal: \(refusal)")
        #expect(h.uploadCount == 2, "no second upload (\(h.uploadCount) uploads)")
        let again: String? = if case .ready(let a)? = s.attachments.states[id] { a } else { nil }
        print("T3 ATTACH LIVE: uploaded again → \(again ?? "none")")
        #expect(again != nil && again != gone)
        #expect(launchError == nil)

        let final = launchError == nil ? await h.follow(thread) : nil
        await h.archive(thread)
        h.printCalls()
        await h.client.shutdown()

        let p = try #require(final, "no projection of the thread")
        h.printThread(p)
        let reply = p.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n")
        #expect(reply.uppercased().contains(word), "the reply doesn't name the word: \(reply)")
    }
}
