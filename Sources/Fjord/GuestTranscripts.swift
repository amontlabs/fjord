import Foundation

/// A bounded, authoritative view of one guest transcript. The local `ssh-<id>` mirror is never consulted for this data.
struct GuestTranscriptSnapshot: Equatable, Sendable {
    var computer: GuestReference
    var cliSessionID: String
    var path: String
    var inode: Int64
    var size: Int64
    var mtimeMs: Int64
    var tail: Data

    var messages: [YourMessages.Message] { YourMessages.messages(in: tail) }
    var activity: ClaudeActivity? { Claude.activity(tail: tail) }
    var finalMessage: String? { Claude.finalMessage(tail: tail) }
    var recentSteps: [Claude.TranscriptStep] { Claude.recentTimedSteps(tail: tail) }
    var earlierTurnEnds: [String] { Array(Claude.turnEnds(tail: tail).dropLast()) }
}

/// Keeps only recent transcript tails. Metadata is checked on every read so append, truncate, and atomic replacement
/// invalidate the cached bytes without downloading the tail again for an unchanged guest file.
actor GuestTranscriptCache {
    private struct Key: Hashable, Sendable {
        var computer: String
        var cliSessionID: String
        var path: String
    }
    private struct Entry: Sendable {
        var snapshot: GuestTranscriptSnapshot
        var used: UInt64
    }

    static let shared = GuestTranscriptCache()
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 32) { self.capacity = max(1, capacity) }

    func snapshot(computer: GuestReference, cliSessionID: String, path: String,
                  inode: Int64, size: Int64, mtimeMs: Int64) -> GuestTranscriptSnapshot? {
        let key = Key(computer: computer.key, cliSessionID: cliSessionID, path: path)
        guard var entry = entries[key], entry.snapshot.inode == inode, entry.snapshot.size == size,
              entry.snapshot.mtimeMs == mtimeMs else { return nil }
        clock &+= 1
        entry.used = clock
        entries[key] = entry
        return entry.snapshot
    }

    func insert(_ snapshot: GuestTranscriptSnapshot) {
        let key = Key(computer: snapshot.computer.key, cliSessionID: snapshot.cliSessionID, path: snapshot.path)
        clock &+= 1
        entries[key] = Entry(snapshot: snapshot, used: clock)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
    }
}

/// Reads guest transcript files by path and metadata through guest.files. No guest path is normalized by the host.
struct GuestTranscripts: Sendable {
    var client: any GuestClient
    var tailLimit = 1 << 20
    var projectLimit = 512
    var cache: GuestTranscriptCache = .shared

    func read(computer: GuestReference, projectsRoot: String, cliSessionID: String) async throws -> GuestTranscriptSnapshot? {
        let projects: [GuestFileEntry]
        do { projects = try await client.filesList(computer: computer, path: projectsRoot) }
        catch GuestClientFailure.notFound(_) { return nil }

        var matches: [(String, GuestFileEntry)] = []
        for project in projects.prefix(projectLimit) where project.type == .directory {
            let directory = GuestRouterPaths.join(projectsRoot, project.name)
            let entries: [GuestFileEntry]
            do { entries = try await client.filesList(computer: computer, path: directory) }
            catch GuestClientFailure.notFound(_) { continue }
            if let file = entries.first(where: { $0.type == .file && $0.name == "\(cliSessionID).jsonl" }) {
                matches.append((directory, file))
            }
        }
        // The CLI id is expected to name one project transcript. Ambiguity is not a reason to read an arbitrary copy.
        guard matches.count == 1, let (directory, entry) = matches.first else { return nil }
        let path = GuestRouterPaths.join(directory, entry.name)
        let metadata = try await client.filesRead(computer: computer, path: path, offset: 0, length: 0)
        guard metadata.data.isEmpty else { return nil }
        if let cached = await cache.snapshot(computer: computer, cliSessionID: cliSessionID, path: path,
            inode: metadata.inode, size: metadata.size, mtimeMs: metadata.mtimeMs) { return cached }
        let offset = max(0, metadata.size - Int64(max(0, tailLimit)))
        let length = Int(min(Int64(max(0, tailLimit)), metadata.size))
        let read = try await client.filesRead(computer: computer, path: path, offset: offset, length: length)
        guard read.inode == metadata.inode, read.size == metadata.size, read.mtimeMs == metadata.mtimeMs,
              offset + Int64(read.data.count) == read.size else { return nil }
        let complete = Self.completeLines(read.data, startsAtFileBeginning: offset == 0)
        let snapshot = GuestTranscriptSnapshot(computer: computer, cliSessionID: cliSessionID, path: path,
            inode: read.inode, size: read.size, mtimeMs: read.mtimeMs, tail: complete)
        await cache.insert(snapshot)
        return snapshot
    }

    /// Drops the leading partial line after a ranged read and the trailing line while a writer may still be appending it.
    static func completeLines(_ data: Data, startsAtFileBeginning: Bool) -> Data {
        var lower = data.startIndex
        if !startsAtFileBeginning {
            guard let firstNewline = data.firstIndex(of: 0x0a) else { return Data() }
            lower = data.index(after: firstNewline)
        }
        guard lower < data.endIndex, let lastNewline = data.lastIndex(of: 0x0a), lastNewline >= lower else { return Data() }
        return Data(data[lower...lastNewline])
    }
}
