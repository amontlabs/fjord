import AppKit
import Foundation
import ImageIO
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
    /// The bytes, for as long as the attachment is kept: a refused send may upload them again, a send near T3's sweep
    /// too. Once sent and held by nothing (`RouterAttachments.sent`) it is forgotten, bytes and all.
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
    /// The picture's work under way (a conversion, its thumbnail), off the main thread: its upload waits for it.
    @ObservationIgnored private var preparing: [String: Task<Void, Never>] = [:]
    /// Pictures that couldn't be made one T3 takes: they don't upload.
    @ObservationIgnored private var unreadable: Set<String> = []
    /// When each upload finished: T3 sweeps a pending upload a day after it was posted (`PENDING_ATTACHMENT_MAX_AGE_MS`).
    @ObservationIgnored private var uploadedAt: [String: Date] = [:]
    /// The clock the uploads' age is read on (a test's own).
    @ObservationIgnored var now: () -> Date = Date.init

    /// How long T3 keeps an upload no message has claimed yet (`attachmentStore.ts`), and the age past which a send uploads
    /// the bytes again rather than risk the sweep (an hour's margin).
    static let pendingLife: TimeInterval = 24 * 60 * 60
    static let reuploadAge: TimeInterval = pendingLife - 60 * 60

    init(uploader: Uploader? = nil) { self.uploader = uploader }

    /// A pasted or dropped thing made an attachment: the pill's pointer, at once. Only what its type says is worked out
    /// here (what it goes as, its name); the picture's work (a TIFF or HEIC made one T3 takes, its thumbnail) is done off
    /// the main thread, the pill showing it posting meanwhile, and then its upload starts. A picture T3 doesn't take as
    /// one goes as a PNG (a photo, HEIC or HEIF: a JPEG), made smaller if it is over T3's 10 MB; one ImageIO can't read,
    /// and anything else, goes as a file. Too big or empty: the pill shows it failed.
    func add(name: String, mimeType: String, data: Data) -> RouterPointer {
        let given = mimeType.lowercased()
        let target = Self.target(mime: given, data: data)
        let mime = target?.mime ?? (given.isEmpty ? "application/octet-stream" : given)
        let kind: RouterAttachment.Kind = target != nil
            || (RouterAttachment.imageTypes.contains(mime) && data.count <= RouterAttachment.maxImageBytes) ? .image : .file
        let named = target.map { (name as NSString).deletingPathExtension + "." + $0.ext } ?? name
        let id = kind.rawValue + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        items[id] = RouterAttachment(id: id, kind: kind, name: unique(Self.cleanName(named, kind: kind)), mimeType: mime,
                                     sizeBytes: data.count, data: data)
        if kind == .image, !data.isEmpty {
            preparing[id] = Task { @MainActor [weak self] in
                let made = await Task.detached(priority: .userInitiated) {
                    Self.prepare(data, as: target, maxBytes: RouterAttachment.maxImageBytes)
                }.value
                self?.prepared(id, made, converting: target != nil)
            }
        }
        if let why = refusal(id) {
            states[id] = .failed(why)
            revision &+= 1
        } else {
            start(id)
        }
        return .attachment(id)
    }

    /// The picture's work is done: its bytes as T3 takes them, its thumbnail.
    private func prepared(_ id: String, _ made: Prepared, converting: Bool) {
        preparing[id] = nil
        guard items[id] != nil else { return }
        if converting {
            if let data = made.data {
                items[id]?.data = data
                items[id]?.sizeBytes = data.count
            } else {
                unreadable.insert(id)
            }
        }
        items[id]?.thumbnail = made.thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: Self.thumbnailSide, height: Self.thumbnailSide)) }
        revision &+= 1
    }

    /// Why it can't upload, if it can't: empty, over T3's size, a picture that couldn't be made one T3 takes.
    private func refusal(_ id: String) -> String? {
        guard let item = items[id] else { return "It's gone" }
        if unreadable.contains(id) { return "Fjord couldn't read the picture" }
        guard let data = item.data else { return "Its bytes are gone" }
        if data.isEmpty { return "It's empty" }
        if data.count > RouterAttachment.maxFileBytes { return "Over T3's 50 MB" }
        return nil
    }

    /// Adds an attachment as it is, its state given: a shot's, a test's.
    func put(_ item: RouterAttachment, state: RouterAttachmentState) {
        items[item.id] = item
        states[item.id] = state
        if case .ready = state { uploadedAt[item.id] = now() }
        revision &+= 1
    }

    /// A name no other attachment kept has ("image.png", then "image 2.png"): each pill reads as its own words
    /// (`RouterPointer.said`), so a split's part says which picture it carries. Only pills that are, or may come back
    /// (an undo), count: those sent and let go, or forgotten, are no longer `items`.
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

    // MARK: The one rule: what holds a pill keeps it; one nothing holds is deleted on T3, or forgotten once sent

    /// The draft's pills now, whatever changed them (typing, a cut, an undo, Return or Esc emptying it, a prefill
    /// replacing it): a pill gone that wasn't sent has its upload deleted, once; one back (an undo) is uploaded again.
    func draftHolds(_ ids: Set<String>) { holds(ids, by: "draft") }

    /// The pills `holder` keeps now: the draft, answers typed on a card waiting to go, a Return while it sends, a send in
    /// flight, a refused send's failure line. A pill no holder keeps any more: sent, it is forgotten (T3 has it; its bytes
    /// and picture go); unsent, its upload is deleted, once, its bytes kept for an undo that brings it back
    /// (`undoEnded`). One kept again (an undo) is uploaded again.
    func holds(_ ids: Set<String>, by holder: String) {
        let before = Set(held.values.joined())
        held[holder] = ids.isEmpty ? nil : ids
        let after = Set(held.values.joined())
        for id in before.subtracting(after) {
            if sentIDs.contains(id) { forget(id) } else { remove(id) }
        }
        for id in after.subtracting(before) { restore(id) }
    }

    /// The pills `holder` keeps now.
    func held(by holder: String) -> Set<String> { held[holder] ?? [] }

    /// T3 took these pills with the send `holder` is (a message, an answer): their uploads are its thread's (T3 copies a
    /// pending upload into each thread it is sent to and keeps it until its own sweep) and nothing deletes them. That send
    /// lets them go; once nothing else holds them (another part of a split still in flight may), they are forgotten.
    func sent(_ ids: some Sequence<String>, by holder: String?) {
        let ids = Set(ids).filter { items[$0] != nil }
        guard !ids.isEmpty else { return }
        sentIDs.formUnion(ids)
        let unheld = ids.filter { id in !held.values.contains { $0.contains(id) } }
        unheld.forEach(forget)
        if let holder { holds(held(by: holder).subtracting(ids), by: holder) }
    }

    /// The composer's undo can't bring back what was taken out of the draft any more (a send emptied it): the bytes of
    /// those pills go, and nothing of them is kept.
    func undoEnded() {
        let gone = removed
        gone.forEach(forget)
    }

    /// A click on a failed pill: its upload again.
    func retry(_ id: String) {
        guard case .failed? = states[id], !removed.contains(id), canUpload(id) else { return }
        start(id)
    }

    /// The pill was taken out of the draft (typed away, cut): its upload stops and T3 deletes it.
    func remove(_ id: String) {
        guard items[id] != nil, !sentIDs.contains(id), removed.insert(id).inserted else { return }
        tasks.removeValue(forKey: id)?.cancel()
        tokens[id] = nil
        let uploaded: String? = if case .ready(let a)? = states[id] { a } else { minted[id] }
        minted[id] = nil
        uploadedAt[id] = nil
        states[id] = .failed("Taken out")
        if let uploaded, let uploader { Task { await uploader.delete(uploaded) } }
    }

    /// An attachment made for a pill that never went in (the field refused the change): its upload stops, what T3 minted
    /// for it is deleted, and nothing of it is kept. One some holder has is left alone.
    func discard(_ id: String) {
        guard items[id] != nil, !held.values.contains(where: { $0.contains(id) }) else { return }
        remove(id)
        forget(id)
    }

    /// Nothing of it is kept: its bytes, its picture, its state.
    private func forget(_ id: String) {
        preparing.removeValue(forKey: id)?.cancel()
        unreadable.remove(id)
        tasks.removeValue(forKey: id)?.cancel()
        tokens[id] = nil
        minted[id] = nil
        uploadedAt[id] = nil
        removed.remove(id)
        sentIDs.remove(id)
        items[id] = nil
        states[id] = nil
        revision &+= 1
    }

    /// The pill came back (an undo): uploaded again.
    func restore(_ id: String) {
        guard removed.remove(id) != nil else { return }
        start(id)
    }

    /// The uploads of a message's attachments, by id, once each is done: waits only for those still posting. One that
    /// failed and still has its bytes is uploaded again here and waited for (a Send again recovers it). Throws for one
    /// that failed again, was taken out or isn't known, saying which. The bytes stay until T3 takes the send (`sent`): a
    /// refused one may be sent again, or its pill put back and taken out and back again.
    func uploads(_ ids: [String]) async throws -> [String: T3Attachment] {
        try checkLimits(ids)
        var out: [String: T3Attachment] = [:]
        for id in ids where out[id] == nil {
            guard let item = items[id] else { throw ThreadSendFailure("An attachment is gone: nothing was sent") }
            if case .failed(let why)? = states[id] {
                guard !removed.contains(id), canUpload(id) else {
                    throw ThreadSendFailure("\(item.name) didn't upload (\(why)): nothing was sent")
                }
                start(id)
            }
            // Near T3's sweep (or swept: `sending`): the bytes go again, under a new upload; the old one T3 sweeps itself.
            if case .ready? = states[id], let at = uploadedAt[id], now().timeIntervalSince(at) > Self.reuploadAge, canUpload(id) {
                start(id)
            }
            let attachmentId: String
            switch states[id] {
            case .ready(let a)?: attachmentId = a
            case .uploading?:
                guard let task = tasks[id] else { throw ThreadSendFailure("\(item.name) didn't upload: nothing was sent") }
                do { attachmentId = try await task.value } catch {
                    let why = if case .failed(let why)? = states[id] { " (\(why))" } else { "" }
                    throw ThreadSendFailure("\(item.name) didn't upload\(why): nothing was sent")
                }
            case .failed(let why)?: throw ThreadSendFailure("\(item.name) didn't upload (\(why)): nothing was sent")
            case nil: throw ThreadSendFailure("An attachment is gone: nothing was sent")
            }
            out[id] = item.t3(attachmentId)
        }
        return out
    }

    /// A send carrying the uploads of `ids` (`body`, given them by id): when T3 refuses it because an upload is gone (its
    /// sweep took it, or it was deleted: "attachment not found"), the bytes are uploaded again and the send made once more.
    /// The one place every message, answer and new thread with attachments goes through.
    func sending<T>(_ ids: [String], _ body: @MainActor ([String: T3Attachment]) async throws -> T) async throws -> T {
        let uploads = try await self.uploads(ids)
        do {
            return try await body(uploads)
        } catch where !uploads.isEmpty && Self.uploadGone(error) {
            for id in uploads.keys { uploadedAt[id] = .distantPast }
            return try await body(try await self.uploads(ids))
        }
    }

    /// T3's refusal of a send whose upload it doesn't have (`AttachmentClaims`: "Attachment '…' cannot be sent: attachment
    /// not found…").
    static func uploadGone(_ error: Error) -> Bool {
        let said = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return said.lowercased().contains("attachment not found")
    }

    /// T3's limits for one message (`chatAttachment.ts`): at most 100 pictures and files, at most 80 MB of pictures. Over
    /// either, the send is refused before anything waits, saying which.
    func checkLimits(_ ids: [String]) throws {
        let unique = Set(ids)
        if unique.count > RouterAttachment.maxPerMessage {
            throw ThreadSendFailure("Over T3's \(RouterAttachment.maxPerMessage) pictures and files in one message: nothing was sent")
        }
        let imageBytes = unique.compactMap { items[$0] }.filter { $0.kind == .image }.reduce(0) { $0 + $1.sizeBytes }
        if imageBytes > RouterAttachment.maxImageBytesPerMessage {
            throw ThreadSendFailure("Over T3's \(RouterAttachment.maxImageBytesPerMessage / (1024 * 1024)) MB of pictures in one message: nothing was sent")
        }
    }

    /// Its bytes are here and T3 takes their size: an upload can be tried (again).
    private func canUpload(_ id: String) -> Bool { refusal(id) == nil }

    private func start(_ id: String) {
        guard items[id] != nil else { return }
        tasks[id]?.cancel()
        tokens[id] = nil
        states[id] = .uploading
        revision &+= 1
        let picture = preparing[id]
        guard uploader != nil || picture != nil else {
            // Nothing to upload to (a demo): done at once, under its own id.
            states[id] = .ready(id)
            revision &+= 1
            return
        }
        // The state lands before the task's value does: a send awaiting it reads where it stands.
        let token = UUID()
        tokens[id] = token
        tasks[id] = Task { @MainActor [weak self] in
            // The picture's work first (off the main thread): the upload posts the bytes it made.
            await picture?.value
            guard let self, self.tokens[id] == token, let item = self.items[id] else { throw CancellationError() }
            if let why = self.refusal(id) {
                self.finish(id, token, .failed(why))
                throw ThreadSendFailure(why)
            }
            guard let uploader = self.uploader else {
                self.finish(id, token, .ready(id))
                return id
            }
            do {
                let attachmentId = try await uploader.upload(item) { [weak self] minted in
                    // Minted after the pill left (or a retry took over): nothing will use it.
                    guard self?.tokens[id] == token else { Task { await uploader.delete(minted) }; return }
                    self?.minted[id] = minted
                }
                self.finish(id, token, .ready(attachmentId))
                return attachmentId
            } catch {
                self.finish(id, token, .failed(Self.words(error)))
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
        if case .ready = state { uploadedAt[id] = now() } else { uploadedAt[id] = nil }
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

    // MARK: The picture's work, off the main thread

    /// A thumbnail's side, in points (the pill draws it smaller), and in pixels (two a point).
    static let thumbnailSide: CGFloat = 28

    /// What a picture T3 doesn't take is made: a PNG, or a JPEG for a photo.
    struct Target: Equatable, Sendable {
        var type: String
        var mime: String
        var ext: String
        static let png = Target(type: "public.png", mime: "image/png", ext: "png")
        static let jpeg = Target(type: "public.jpeg", mime: "image/jpeg", ext: "jpg")
    }

    /// What a pasted thing of type `mime` is made before it goes: nil when it goes as it is (a picture T3 takes, anything
    /// that isn't a picture, a picture ImageIO can't read). Reads only the bytes' header: cheap on the main thread.
    nonisolated static func target(mime: String, data: Data) -> Target? {
        guard mime.hasPrefix("image/"), !RouterAttachment.imageTypes.contains(mime), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else { return nil }
        return mime == "image/heic" || mime == "image/heif" ? .jpeg : .png
    }

    /// A picture's work, done off the main thread: its bytes made `target`'s (nil: kept as they are), smaller until they
    /// fit `maxBytes`; and a small square thumbnail of its own (no copy of the whole picture is kept).
    struct Prepared: @unchecked Sendable {
        var data: Data?
        var thumbnail: CGImage?
    }

    nonisolated static func prepare(_ data: Data, as target: Target?, maxBytes: Int) -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return Prepared(data: nil, thumbnail: nil)
        }
        return Prepared(data: target.flatMap { encode(source, as: $0, maxBytes: maxBytes) }, thumbnail: thumbnail(source))
    }

    /// The picture as `target`, upright, at its own size or as much smaller as it takes to fit `maxBytes` (a few tries).
    nonisolated static func encode(_ source: CGImageSource, as target: Target, maxBytes: Int) -> Data? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        var side = max(width, height)
        guard side > 0 else { return nil }
        for _ in 0..<5 {
            // Drawn from the source at that size, its orientation applied: the bytes need no EXIF to show upright.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, target.type as CFString, 1, nil) else { return nil }
            let quality: [CFString: Any] = target == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
            CGImageDestinationAddImage(dest, image, quality as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= maxBytes { return out as Data }
            // Smaller by the area it is over, and a tenth more.
            side = Int(Double(side) * (Double(maxBytes) / Double(out.length)).squareRoot() * 0.9)
            guard side > 16 else { return nil }
        }
        return nil
    }

    /// A square of the picture's middle, `thumbnailSide` points at two pixels a point: a bitmap of its own.
    nonisolated static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let pixels = Int(thumbnailSide * 2)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels * 4]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              small.width > 0, small.height > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(pixels) / CGFloat(min(small.width, small.height))
        let drawn = CGSize(width: CGFloat(small.width) * scale, height: CGFloat(small.height) * scale)
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    /// A pill's thumbnail for a picture's bytes, made here (a shot's).
    static func pillPicture(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = thumbnail(source) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: thumbnailSide, height: thumbnailSide))
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
