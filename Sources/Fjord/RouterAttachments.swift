import AppKit
import Foundation
import Observation

// A picture or a file put in the Router composer (pasted, dropped): a pill where the caret was, uploaded to T3 at once
// (`attachments.createUploadUrl`, then the bytes posted to the URL it signs), and sent where it sat in your words as T3's
// own composer sends one: an `![name](t3-context://v1/image/<id>)` reference, a context record bound to the upload, and the
// upload in the message's `attachments` (ThreadContext.swift). Taking the pill out deletes the upload; a send waits only
// for the uploads that haven't finished.

/// What was put in the composer, by its id: `image_<hex>` or `file_<hex>`, which is also its T3 context id.
struct RouterAttachment {
    enum Kind: String { case image, file }

    var id: String
    var kind: Kind
    var name: String
    var mimeType: String
    var sizeBytes: Int
    /// The bytes, until a sent message has the upload (then they are let go: nothing will post them again).
    var data: Data?
    /// A picture's small copy, for its pill.
    var thumbnail: NSImage?

    /// The kind its id says (`image_…`, `file_…`).
    static func kind(of id: String) -> Kind { id.hasPrefix(Kind.image.rawValue + "_") ? .image : .file }

    /// What T3 takes as a picture the agent sees (`PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES`).
    static let imageTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/webp"]
    /// T3's limits (`chatAttachment.ts`): a picture, a file, the pictures of one message.
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxFileBytes = 50 * 1024 * 1024
    static let maxImageBytesPerMessage = 80 * 1024 * 1024
    static let maxPerMessage = 100

    /// The attachment as T3's message lists it, once uploaded (`ChatAttachment`).
    func t3(_ attachmentId: String) -> T3Attachment {
        T3Attachment(type: kind.rawValue, id: attachmentId, name: name, mimeType: mimeType, sizeBytes: sizeBytes)
    }
}

/// Where an attachment's upload stands.
enum RouterAttachmentState: Equatable {
    case uploading
    /// T3 has the bytes, under this id.
    case ready(String)
    /// Why it didn't upload; a click on its pill tries again.
    case failed(String)
}

/// The composer's attachments for as long as the app runs (the draft keeps its pills while the window is closed), and
/// their uploads.
@Observable
@MainActor
final class RouterAttachments {
    /// What uploads and deletes: T3's, a test's, or none (a demo: nothing leaves, every upload is done at once).
    struct Uploader {
        /// Asks for an upload, posts the bytes, and returns T3's attachment id; `minted` hears the id as soon as T3 gives
        /// it, so a pill taken out mid-post deletes it.
        var upload: @MainActor (RouterAttachment, _ minted: @escaping @MainActor (String) -> Void) async throws -> String
        var delete: @MainActor (String) async -> Void
    }

    private(set) var items: [String: RouterAttachment] = [:]
    private(set) var states: [String: RouterAttachmentState] = [:]
    /// Bumped when a pill's look changes (its state, its picture): the composer draws its pills again.
    private(set) var revision = 0
    @ObservationIgnored var uploader: Uploader?
    @ObservationIgnored private var tasks: [String: Task<String, Error>] = [:]
    /// Each upload's own token: the end of one superseded (a retry, a removal) changes nothing.
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    /// The id T3 gave an upload still being posted, for a delete.
    @ObservationIgnored private var minted: [String: String] = [:]
    /// Taken out of the draft: their uploads are deleted, their bytes kept for an undo that brings the pill back.
    @ObservationIgnored private var removed: Set<String> = []
    /// What holds each pill now, by holder: the draft (`draftHolds`), a card's typed answers waiting to go.
    @ObservationIgnored private var held: [String: Set<String>] = [:]
    /// Sent with a message (`sent`): their uploads are a thread's now and are never deleted.
    @ObservationIgnored private(set) var sentIDs: Set<String> = []

    init(uploader: Uploader? = nil) { self.uploader = uploader }

    /// A pasted or dropped thing made an attachment, its upload started: the pill's pointer. A picture T3 doesn't take as
    /// one (TIFF, HEIC) is made a PNG first; anything else goes as a file. Too big for T3: the pill shows it failed.
    func add(name: String, mimeType: String, data: Data) -> RouterPointer {
        var name = name
        var mime = mimeType.lowercased()
        var data = data
        let picture = NSImage(data: data)
        if mime.hasPrefix("image/"), !RouterAttachment.imageTypes.contains(mime), let png = picture.flatMap(Self.png) {
            data = png
            mime = "image/png"
            name = (name as NSString).deletingPathExtension + ".png"
        }
        let kind: RouterAttachment.Kind = RouterAttachment.imageTypes.contains(mime) && data.count <= RouterAttachment.maxImageBytes
            ? .image : .file
        let id = kind.rawValue + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        let item = RouterAttachment(id: id, kind: kind, name: unique(Self.cleanName(name, kind: kind)), mimeType: mime.isEmpty ? "application/octet-stream" : mime,
                                    sizeBytes: data.count, data: data,
                                    thumbnail: kind == .image ? picture.flatMap { Self.thumbnail($0) } : nil)
        items[id] = item
        if data.isEmpty || data.count > RouterAttachment.maxFileBytes {
            states[id] = .failed(data.isEmpty ? "It's empty" : "Over T3's 50 MB")
            revision &+= 1
        } else {
            start(id)
        }
        return .attachment(id)
    }

    /// Adds an attachment as it is, its state given: a shot's, a test's.
    func put(_ item: RouterAttachment, state: RouterAttachmentState) {
        items[item.id] = item
        states[item.id] = state
        revision &+= 1
    }

    /// A name no other attachment has ("image.png", then "image 2.png"): each pill reads as its own words
    /// (`RouterPointer.said`), so a split's part says which picture it carries.
    private func unique(_ name: String) -> String {
        let taken = Set(items.values.map(\.name))
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let next = "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
            if !taken.contains(next) { return next }
            n += 1
        }
    }

    // MARK: The one rule: a pill that leaves the draft unsent is deleted on T3

    /// The draft's pills now, whatever changed them (typing, a cut, an undo, Return or Esc emptying it, a prefill
    /// replacing it): a pill gone that wasn't sent has its upload deleted, once; one back (an undo) is uploaded again.
    func draftHolds(_ ids: Set<String>) { holds(ids, by: "draft") }

    /// The pills `holder` keeps now (the draft, answers typed on a card waiting to go). A pill no holder keeps any more
    /// and that wasn't sent has its upload deleted, once; one kept again (an undo) is uploaded again.
    func holds(_ ids: Set<String>, by holder: String) {
        let before = Set(held.values.joined())
        held[holder] = ids.isEmpty ? nil : ids
        let after = Set(held.values.joined())
        for id in before.subtracting(after) where !sentIDs.contains(id) { remove(id) }
        for id in after.subtracting(before) { restore(id) }
    }

    /// Return took these pills with a message: their uploads go to its thread (or threads: T3 copies a pending upload
    /// into each thread it is sent to and keeps it until its own sweep), and nothing deletes them.
    func sent(_ ids: some Sequence<String>) {
        sentIDs.formUnion(ids)
    }

    /// A click on a failed pill: its upload again.
    func retry(_ id: String) {
        guard case .failed? = states[id], items[id]?.data != nil, let size = items[id]?.sizeBytes,
              size > 0, size <= RouterAttachment.maxFileBytes else { return }
        start(id)
    }

    /// The pill was taken out of the draft (typed away, cut): its upload stops and T3 deletes it.
    func remove(_ id: String) {
        guard items[id] != nil, !sentIDs.contains(id), removed.insert(id).inserted else { return }
        tasks.removeValue(forKey: id)?.cancel()
        tokens[id] = nil
        let uploaded: String? = if case .ready(let a)? = states[id] { a } else { minted[id] }
        minted[id] = nil
        states[id] = .failed("Taken out")
        if let uploaded, let uploader { Task { await uploader.delete(uploaded) } }
    }

    /// The pill came back (an undo): uploaded again.
    func restore(_ id: String) {
        guard removed.remove(id) != nil else { return }
        start(id)
    }

    /// The uploads of a message's attachments, by id, once each is done: waits only for those still posting. Throws for
    /// one that failed, was taken out or isn't known, saying which. A sent message's bytes are let go.
    func uploads(_ ids: [String]) async throws -> [String: T3Attachment] {
        var out: [String: T3Attachment] = [:]
        for id in ids where out[id] == nil {
            guard let item = items[id] else { throw ThreadSendFailure("An attachment is gone: nothing was sent") }
            let attachmentId: String
            switch states[id] {
            case .ready(let a)?: attachmentId = a
            case .uploading?:
                guard let task = tasks[id] else { throw ThreadSendFailure("\(item.name) didn't upload: nothing was sent") }
                do { attachmentId = try await task.value } catch {
                    throw ThreadSendFailure("\(item.name) didn't upload: nothing was sent")
                }
            case .failed(let why)?: throw ThreadSendFailure("\(item.name) didn't upload (\(why)): nothing was sent")
            case nil: throw ThreadSendFailure("An attachment is gone: nothing was sent")
            }
            out[id] = item.t3(attachmentId)
        }
        // Sent: nothing posts them again, and only the pill's picture is kept for the history.
        for id in out.keys { items[id]?.data = nil }
        return out
    }

    private func start(_ id: String) {
        guard let item = items[id] else { return }
        tasks[id]?.cancel()
        tokens[id] = nil
        states[id] = .uploading
        revision &+= 1
        guard let uploader else {
            // Nothing to upload to (a demo): done at once, under its own id.
            states[id] = .ready(id)
            revision &+= 1
            return
        }
        // The state lands before the task's value does: a send awaiting it reads where it stands.
        let token = UUID()
        tokens[id] = token
        tasks[id] = Task { @MainActor [weak self] in
            do {
                let attachmentId = try await uploader.upload(item) { minted in
                    // Minted after the pill left (or a retry took over): nothing will use it.
                    guard self?.tokens[id] == token else { Task { await uploader.delete(minted) }; return }
                    self?.minted[id] = minted
                }
                self?.finish(id, token, .ready(attachmentId))
                return attachmentId
            } catch {
                self?.finish(id, token, .failed(Self.words(error)))
                throw error
            }
        }
    }

    /// An upload's end, unless another started since (a retry) or the pill was taken out.
    private func finish(_ id: String, _ token: UUID, _ state: RouterAttachmentState) {
        guard tokens[id] == token else { return }
        tokens[id] = nil
        tasks[id] = nil
        minted[id] = nil
        states[id] = state
        revision &+= 1
    }

    private static func words(_ error: Error) -> String {
        let said = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return said.split(separator: "\n").first.map(String.init) ?? "It didn't upload"
    }

    /// A name T3 takes (one line, at most 255 characters, never empty).
    static func cleanName(_ name: String, kind: RouterAttachment.Kind) -> String {
        let one = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let cut = String(one.prefix(255))
        return cut.isEmpty ? (kind == .image ? "image.png" : "file") : cut
    }

    /// A picture's bytes as a PNG.
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A picture cut to a square of `side` points, drawn once.
    static func thumbnail(_ image: NSImage, side: CGFloat = 28) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = side / min(size.width, size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
            return true
        }
    }
}

// MARK: - Pills in a split's parts

extension RouterAttachments {
    /// The pills of `pills` (a draft's pictures and files) that stand in `words` as they read ("[image: name]"), where
    /// they stand: the Router writes a split's part from the draft's words, the pills' among them. Each at every place
    /// it reads, left to right, none overlapping.
    static func pills(in words: String, of pills: [RouterMention]) -> [RouterMention] {
        let chars = Array(words)
        var found: [RouterMention] = []
        var seen = Set<RouterPointer>()
        for m in pills where m.pointer.attachment != nil && seen.insert(m.pointer).inserted {
            let said = Array(m.pointer.said(m.name))
            guard !said.isEmpty, said.count <= chars.count else { continue }
            var at = 0
            while at + said.count <= chars.count {
                if chars[at..<(at + said.count)].elementsEqual(said) {
                    found.append(RouterMention(range: at..<(at + said.count), pointer: m.pointer, name: m.name))
                    at += said.count
                } else {
                    at += 1
                }
            }
        }
        var end = 0
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }.filter { m in
            guard m.range.lowerBound >= end else { return false }
            end = m.range.upperBound
            return true
        }
    }

    /// A split's parts with every one of the draft's pills in some part: a pill the Router left out of all of them goes
    /// at the end of the part whose words come last before it in the draft (the first part when none does), so nothing
    /// pasted is dropped. `draft`: the words as the Router read them, the pills' ranges in it.
    static func placed(_ parts: [String], draft: String, pills: [RouterMention]) -> [String] {
        var parts = parts
        guard !parts.isEmpty else { return parts }
        let chars = Array(draft)
        // Where each part's words start in the draft: the most of its first words (up to a pill, at most five) found there.
        let starts: [Int?] = parts.map { part in
            let words = part.prefix { $0 != "[" }.split(whereSeparator: \.isWhitespace).prefix(5)
            for n in stride(from: words.count, through: 1, by: -1) {
                if let r = draft.range(of: words.prefix(n).joined(separator: " ")) {
                    return draft.distance(from: draft.startIndex, to: r.lowerBound)
                }
            }
            return nil
        }
        for m in pills where m.pointer.attachment != nil {
            guard !parts.contains(where: { !Self.pills(in: $0, of: [m]).isEmpty }) else { continue }
            let at = m.range.lowerBound <= chars.count ? m.range.lowerBound : chars.count
            let before = starts.indices.filter { (starts[$0] ?? .max) <= at }.max { starts[$0]! < starts[$1]! } ?? 0
            let said = m.pointer.said(m.name)
            parts[before] = parts[before].isEmpty ? said
                : parts[before] + (parts[before].last?.isWhitespace == true ? "" : " ") + said
        }
        return parts
    }
}

// MARK: - T3's uploads

extension RouterAttachments.Uploader {
    /// T3's: `attachments.createUploadUrl` over the socket, the bytes posted to the signed URL on T3's origin (the URL is the
    /// credential, as T3's web client posts it), `attachments.delete` to take one back.
    @MainActor
    static func t3(call: @escaping @MainActor (String, T3JSON) async throws -> T3JSON,
                   origin: @escaping @MainActor () -> URL? = { T3Discovery.origin() },
                   post: @escaping @Sendable (URLRequest, Data) async throws -> Int = RouterAttachments.Uploader.post) -> Self {
        Self(upload: { item, minted in
            guard let data = item.data else { throw ThreadSendFailure("Its bytes are gone") }
            let answer = try await call("attachments.createUploadUrl", uploadRequest(item))
            guard let attachmentId = answer.str("attachmentId"), let relative = answer.str("relativeUrl") else {
                throw ThreadSendFailure("T3 gave no upload address")
            }
            minted(attachmentId)
            guard let origin = origin(), let url = URL(string: relative, relativeTo: origin)?.absoluteURL else {
                throw ThreadSendFailure("No T3 server is running")
            }
            try Task.checkCancellation()
            let status = try await post(postRequest(url: url, mimeType: item.mimeType), data)
            guard (200..<300).contains(status) else { throw ThreadSendFailure("T3 refused the upload (\(status))") }
            return attachmentId
        }, delete: { attachmentId in
            _ = try? await call("attachments.delete", deleteRequest(attachmentId))
        })
    }

    /// `attachments.createUploadUrl`'s input: a picture's has no `type` (T3's default), a file's says so.
    static func uploadRequest(_ item: RouterAttachment) -> T3JSON {
        var j: [String: T3JSON] = ["name": .string(item.name), "mimeType": .string(item.mimeType),
                                   "sizeBytes": .number(Double(item.sizeBytes))]
        if item.kind == .file { j["type"] = "file" }
        return .object(j)
    }

    static func deleteRequest(_ attachmentId: String) -> T3JSON { ["attachmentId": .string(attachmentId)] }

    /// The post of the bytes: the attachment's own type, the body the exact size T3 signed for.
    static func postRequest(url: URL, mimeType: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return r
    }

    static let post: @Sendable (URLRequest, Data) async throws -> Int = { request, data in
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
