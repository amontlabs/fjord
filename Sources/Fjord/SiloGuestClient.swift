import Foundation

/// Adapts the generated Silo guest methods to the guest filesystem the code-folder scan reads.
actor SiloGuestClient: GuestClient {
    private let engine: SocketEngineClient

    init(engine: SocketEngineClient) { self.engine = engine }

    func filesRead(computer: GuestReference, path: String, offset: Int64?, length: Int?) async throws -> GuestFileReadResult {
        try Self.validate(path)
        let wireOffset: UInt64?
        if let offset {
            guard let value = UInt64(exactly: offset) else { throw GuestClientFailure.invalidPath(path) }
            wireOffset = value
        } else { wireOffset = nil }
        let wireLength: UInt64?
        if let length {
            guard let value = UInt64(exactly: length) else { throw GuestClientFailure.invalidPath(path) }
            wireLength = value
        } else { wireLength = nil }
        let wire = try await engine.guestFilesRead(SiloWireGuestFilesReadParams(computerId: computer.computerId,
            deviceId: computer.deviceId, length: wireLength, offset: wireOffset, path: path))
        guard let mode = UInt16(exactly: wire.mode) else { throw GuestClientFailure.unavailable("Silo returned an invalid guest file mode.") }
        return GuestFileReadResult(data: Self.data(wire.data), size: try Self.int64(wire.size),
            mtimeMs: try Self.int64(wire.mtimeMs), inode: try Self.int64(wire.inode), mode: mode)
    }

    func filesList(computer: GuestReference, path: String) async throws -> [GuestFileEntry] {
        try Self.validate(path)
        let wire = try await engine.guestFilesList(SiloWireGuestFilesListParams(computerId: computer.computerId,
            deviceId: computer.deviceId, path: path))
        return try wire.entries.map { entry in
            GuestFileEntry(name: entry.name, type: Self.entryType(entry.type), size: try Self.int64(entry.size),
                           mtimeMs: try Self.int64(entry.mtimeMs))
        }
    }

    private static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw GuestClientFailure.invalidPath(path) }
    }

    private static func int64(_ value: UInt64) throws -> Int64 {
        guard let value = Int64(exactly: value) else { throw GuestClientFailure.unavailable("Silo returned a guest file value outside Int64.") }
        return value
    }

    private static func data(_ bytes: [Int]) -> Data { Data(bytes.map { UInt8(truncatingIfNeeded: $0) }) }

    private static func entryType(_ value: SiloWireGuestFileKind) -> GuestFileEntryType {
        switch value {
        case .file: .file
        case .dir: .directory
        case .link: .link
        case .other: .other
        }
    }
}
