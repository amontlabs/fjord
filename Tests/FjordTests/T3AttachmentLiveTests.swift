import AppKit
import Foundation
import Testing
@testable import Fjord

/// The attachment path against the owner's real T3 server, opt-in: `FJORD_T3_LIVE=1 swift test --filter T3AttachmentLive`.
/// Not read-only: it uploads two pictures (deleting one), starts ONE throwaway thread on the cheapest Haiku T3 offers, waits
/// for its reply and archives it. Everything goes through Fjord's own code: `RouterAttachments` with T3's uploader, the
/// composer's `RouterPointers.message`, `RouterPointers.threadMessage` and `Store.launchThread`.
@Suite("T3 attachment live (writes one archived thread)", .timeLimit(.minutes(6)))
struct T3AttachmentLiveTests {
    static let word = "PELICAN-73"
    static let title = "Fjord attachment check — delete me"

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
        return RouterAttachments.png(image)!
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_T3_LIVE"] == "1"))
    func aPictureInTheMiddleOfAMessageReachesTheAgent() async throws {
        let client = T3Client.local()

        // The shell, as Fjord's store holds it.
        var shell = T3ShellState()
        for await item in await client.subscribeShell() {
            shell.apply(item)
            if case .snapshot = item { break }
        }
        let s = Store()
        s.persists = false
        s.t3.store.seed(shell, notify: false)
        // A pretend store sends nothing; these stand T3 itself in for the store's link.
        s.requestSender = { command, commandId in _ = try await client.dispatch(command, commandId: commandId) }
        s.launchSupport.config = { try await client.call(tag: "server.getConfig") }

        // Every upload call, as T3 answered it.
        var calls: [(tag: String, payload: T3JSON, answer: Result<T3JSON, Error>)] = []
        let (deleted, deletedHeard) = AsyncStream<Void>.makeStream()
        s.attachments = RouterAttachments(uploader: .t3(call: { tag, payload in
            do {
                let answer = try await client.call(tag: tag, payload: payload)
                calls.append((tag, payload, .success(answer)))
                if tag == "attachments.delete" { deletedHeard.yield() }
                return answer
            } catch {
                calls.append((tag, payload, .failure(error)))
                if tag == "attachments.delete" { deletedHeard.yield() }
                throw error
            }
        }))

        // 1–2. Two pictures uploaded; the second taken out of the draft, which deletes its upload.
        let png = Self.picture(Self.word)
        guard case .attachment(let kept) = s.attachments.add(name: "pelican.png", mimeType: "image/png", data: png),
              case .attachment(let dropped) = s.attachments.add(name: "dropped.png", mimeType: "image/png", data: Self.picture("DROPPED"))
        else { Issue.record("no attachment ids"); return }
        let ready = try await s.attachments.uploads([kept, dropped])
        print("T3 ATTACH LIVE: uploaded \(kept) → \(ready[kept]!.id) (\(png.count) bytes), \(dropped) → \(ready[dropped]!.id)")
        s.attachments.draftHolds([kept, dropped])
        s.attachments.draftHolds([kept])
        for await _ in deleted { break }
        for c in calls {
            let answer: String = switch c.answer { case .success(let a): Self.json(a); case .failure(let e): "ERROR \(e)" }
            print("T3 ATTACH LIVE: call \(c.tag) \(Self.json(c.payload)) → \(answer)")
        }
        let deleteCall = try #require(calls.first { $0.tag == "attachments.delete" })
        #expect(deleteCall.payload == ["attachmentId": .string(ready[dropped]!.id)])
        if case .failure(let e) = deleteCall.answer { Issue.record("attachments.delete failed: \(e)") }
        #expect(s.attachments.states[dropped] == .failed("Taken out"))

        // 3. The message as the composer makes it: the pill in the middle of the words.
        let draft = "Before the picture " + MentionText.markString
            + " after the picture. Reply with only the word shown in the picture, and say whether the picture came before or after the word 'after'."
        let (text, mentions) = RouterPointers.message(draft: draft, pointers: [.attachment(kept)], name: s.pointerName)
        let uploads = try await s.attachments.uploads(mentions.compactMap(\.pointer.attachment))
        let words = try RouterPointers.threadMessage(text, pills: [], mentions: mentions, store: s, uploads: uploads)
        print("T3 ATTACH LIVE: text sent: \(words.text)")
        print("T3 ATTACH LIVE: records sent: \(words.records.map { Self.json($0) })")
        print("T3 ATTACH LIVE: attachments sent: \(words.attachments.map { Self.json($0.json) })")
        let message = ThreadMessage(text: words.text, records: words.records, attachments: words.attachments)

        // The scratch project ("No project", T3's own scratch folder), else the one with the fewest threads.
        let open = shell.projects.values.filter { $0.archivedAt == nil }
        let counts = Dictionary(grouping: shell.threads.values, by: \.projectId).mapValues(\.count)
        let project = try #require(open.first { $0.workspaceRoot.hasSuffix("/.t3/scratch") }
            ?? open.min { counts[$0.id, default: 0] < counts[$1.id, default: 0] })
        // The cheapest model T3 offers: a Haiku on a ready provider.
        let config = try await client.call(tag: "server.getConfig")
        let haiku = (config["providers"]?.array ?? []).filter { $0.str("status") == "ready" && $0["enabled"]?.bool != false }
            .flatMap { p in (p["models"]?.array ?? []).compactMap { m in (m.str("slug") ?? m.str("id")).map { (p.str("instanceId") ?? "?", $0) } } }
            .filter { $0.1.lowercased().contains("haiku") }
        print("T3 ATTACH LIVE: project \(project.title) (\(project.id)); haiku models: \(haiku)")
        let slug = try #require(haiku.first?.1, "T3 offers no Haiku")
        let settings = ThreadLaunchSettings(model: slug, effort: nil, runtimeMode: .approvalRequired)
        let thread = UUID().uuidString.lowercased()

        _ = try await s.launchThread(in: project.id, message: message, thread: thread, settings: settings)
        print("T3 ATTACH LIVE: launched thread \(thread) in \(project.title) on \(slug)")

        // 4. The run followed through the thread's events until it ends (or the agent asks for something, or 4 minutes).
        let stream = await client.subscribeThread(thread)
        let watch = Task { @MainActor () -> (T3Projection?, T3JSON?) in
            var projection: T3Projection?
            var userRaw: T3JSON?
            for await item in stream {
                switch item {
                case .snapshot(_, let p): projection = p
                case .event(let e):
                    projection?.apply(e)
                    if e.type == "message.updated", e.payload.str("role") == "user" { userRaw = e.payload }
                case .unknown: break
                }
                guard let p = projection else { continue }
                if !p.pendingRequests.isEmpty { print("T3 ATTACH LIVE: the agent asked for something: \(p.pendingRequests.map(\.kind))"); break }
                let ended = !p.runs.isEmpty && p.runs.allSatisfy { !$0.status.isLive && $0.status != .idle }
                if ended, p.messages.contains(where: { $0.role == "assistant" && !$0.streaming && !$0.text.isEmpty }) { break }
                if ended, p.runs.contains(where: { [.failed, .interrupted, .cancelled].contains($0.status) }) { break }
            }
            return (projection, userRaw)
        }
        let timer = Task { try await Task.sleep(for: .seconds(240)); watch.cancel() }
        let (final, raw) = await watch.value
        timer.cancel()

        // 5. Titled as the throwaway it is (after T3's own title, which would overwrite it) and archived, whatever happened.
        do { try await s.dispatch(.threadRename(threadId: thread, title: Self.title)) } catch { print("T3 ATTACH LIVE: rename failed: \(error)") }
        do {
            try await s.dispatch(.threadArchive(threadId: thread))
            print("T3 ATTACH LIVE: archived \(thread) titled \(Self.title)")
        } catch {
            Issue.record("ARCHIVE FAILED for \(thread): \(error)")
        }
        await client.shutdown()

        let p = try #require(final, "no projection of the thread")
        print("T3 ATTACH LIVE: runs \(p.runs.map { "\($0.id)=\($0.status.rawValue)" }) title \(p.thread.title)")
        for m in p.messages { print("T3 ATTACH LIVE: \(m.role) [\(m.creationSource)]: \(m.text)") }
        if let raw { print("T3 ATTACH LIVE: user message event: \(Self.json(raw))") }
        let reply = p.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n")
        #expect(reply.uppercased().contains(Self.word), "the reply doesn't name the word: \(reply)")
        let user = try #require(p.messages.first { $0.role == "user" })
        #expect(user.text == words.text)
    }
}
