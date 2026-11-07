import Darwin
import Foundation

/// Small private files: written whole or not at all, readable by you alone.
enum PrivateFile {
    /// A folder for you alone (0700), with its parents, made off the main thread: where the Router's runs of Claude Code
    /// start, made as a message is prepared and delivered.
    static func makeFolder(_ url: URL) async {
        await OffMain.run {
            _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try commit(prepare(data, for: url, mode: mode), to: url)
    }

    /// Writes `data` to a temporary file next to `url`, created with its mode, so it is never readable by others, even for a
    /// moment. `commit` puts it in place.
    static func prepare(_ data: Data, for url: URL, mode: mode_t = 0o600) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path]) }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var done = 0
            while done < buffer.count {
                let n = Darwin.write(fd, base + done, buffer.count - done)
                if n <= 0 { break }
                done += n
            }
            return done
        }
        fchmod(fd, mode)
        close(fd)
        guard written == data.count else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return temp
    }

    static func commit(_ temp: URL, to url: URL) throws {
        guard rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

// MARK: - Pending forms


/// Whether a process id is alive (it may belong to another user).
enum ProcessProbe {
    static func alive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
