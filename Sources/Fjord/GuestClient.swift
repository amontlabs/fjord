import Foundation

struct GuestReference: Codable, Equatable, Hashable, Sendable {
    var deviceId: String?
    var computerId: String

    /// The owner of a computer in a dictionary key: `local` for This Mac, otherwise the device id.
    static func ownerKey(_ deviceId: String?) -> String { deviceId ?? "local" }

    var ownerKey: String { Self.ownerKey(deviceId) }
    var key: String { "\(ownerKey)/\(computerId)" }

    /// A computer on This Mac. A computer owned by another device is always addressed with its owner's `deviceId`.
    static func thisMac(_ computerId: String) -> GuestReference { GuestReference(deviceId: nil, computerId: computerId) }
}

enum GuestFileEntryType: String, Codable, Equatable, Sendable { case file, directory = "dir", link, other }

struct GuestFileEntry: Codable, Equatable, Sendable {
    var name: String
    var type: GuestFileEntryType
    var size: Int64
    var mtimeMs: Int64
}

struct GuestFileReadResult: Equatable, Sendable {
    var data: Data
    var size: Int64
    var mtimeMs: Int64
    var inode: Int64
    var mode: UInt16
}

enum GuestFileReplace: Equatable, Sendable {
    case always
    case never
    /// `nil` means the path must not exist.
    case ifSHA256(String?)
}

enum GuestClientFailure: LocalizedError, Equatable {
    case invalidPath(String)
    case notFound(String)
    case notAFile(String)
    case permissionDenied(String)
    case notRunning(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "Guest paths must be absolute: \(path)"
        case .notFound(let path): "Guest file not found: \(path)"
        case .notAFile(let path): "Guest path is not a file: \(path)"
        case .permissionDenied(let path): "Guest permission denied: \(path)"
        case .notRunning(let computer): "The computer isn't running: \(computer)"
        case .unavailable(let message): message
        }
    }
}

/// The guest boundary the code-folder scan reads through. `SiloGuestClient` adapts generated guest methods for production; the
/// mock stays in-process.
protocol GuestClient: Sendable {
    func filesRead(computer: GuestReference, path: String, offset: Int64?, length: Int?) async throws -> GuestFileReadResult
    func filesList(computer: GuestReference, path: String) async throws -> [GuestFileEntry]
}

/// Deterministic guest filesystem for tests and window shots.
actor MockGuestClient: GuestClient {
    private struct File: Sendable {
        var data: Data
        var mode: UInt16
        var mtimeMs: Int64
        var inode: Int64
    }

    private var files: [String: File] = [:]
    private var nextInode: Int64 = 1
    private var nextTime: Int64 = 1_800_000_000_000

    init() {}

    /// Puts a file at an absolute guest path.
    func seed(computer: GuestReference, path: String, data: Data, mode: UInt16 = 0o600) throws {
        let path = try Self.absolute(path)
        nextTime += 1
        files[Self.fileKey(computer, path)] = File(data: data, mode: mode, mtimeMs: nextTime, inode: nextInode)
        nextInode += 1
    }

    func filesRead(computer: GuestReference, path: String, offset: Int64? = nil, length: Int? = nil) throws -> GuestFileReadResult {
        let path = try Self.absolute(path)
        guard let file = files[Self.fileKey(computer, path)] else { throw GuestClientFailure.notFound(path) }
        let start = max(0, min(Int64(file.data.count), offset ?? 0))
        let end = min(Int64(file.data.count), start + Int64(max(0, length ?? file.data.count)))
        return GuestFileReadResult(data: file.data.subdata(in: Int(start)..<Int(end)), size: Int64(file.data.count),
                                   mtimeMs: file.mtimeMs, inode: file.inode, mode: file.mode)
    }

    func filesList(computer: GuestReference, path: String) throws -> [GuestFileEntry] {
        let root = try Self.absolute(path).trimmingTrailingSlash
        let prefix = root == "/" ? "/" : root + "/"
        var entries: [String: GuestFileEntry] = [:]
        for (key, file) in files where key.hasPrefix(computer.key + ":") {
            let filePath = String(key.dropFirst(computer.key.count + 1))
            guard filePath.hasPrefix(prefix) else { continue }
            let remainder = filePath.dropFirst(prefix.count)
            guard !remainder.isEmpty else { continue }
            let name = String(remainder.split(separator: "/", omittingEmptySubsequences: true).first ?? "")
            guard !name.isEmpty else { continue }
            let isDirectory = remainder.contains("/")
            let entry = GuestFileEntry(name: name, type: isDirectory ? .directory : .file,
                                       size: isDirectory ? 0 : Int64(file.data.count), mtimeMs: file.mtimeMs)
            if let existing = entries[name], existing.type == .directory { continue }
            entries[name] = entry
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    private static func absolute(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw GuestClientFailure.invalidPath(path) }
        return path
    }

    private static func fileKey(_ computer: GuestReference, _ path: String) -> String { computer.key + ":" + path }
}

private extension String {
    var trimmingTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
