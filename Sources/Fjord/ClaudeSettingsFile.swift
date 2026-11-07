import Foundation

/// Serializes Fjord's writes to Claude settings with a read/compute/re-read/atomic-replace rule, for the local
/// PermissionRequest hook.
enum ClaudeSettingsFile {
    enum Failure: LocalizedError, Equatable {
        case invalidJSON(String)
        case notAnObject(String)
        case unreadable(String, String)
        case keptChanging(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let path): "\(path) isn't valid JSON, so Fjord left it alone."
            case .notAnObject(let path): "\(path) doesn't hold a JSON object, so Fjord left it alone."
            case .unreadable(let path, let reason): "Fjord couldn't read \(path): \(reason)"
            case .keptChanging(let path): "\(path) kept changing while Fjord was updating it. Try again."
            }
        }
    }

    static let attempts = 3
    private static let lock = NSRecursiveLock()

    static func modify(settings: URL, backup: URL, beforeReplace: (() -> Void)? = nil,
                       change: (inout [String: Any]) throws -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        for _ in 0..<attempts {
            let target = settings.resolvingSymlinksInPath()
            let raw: Data?
            do { raw = try read(settings, targeting: target) }
            catch is TargetChanged { continue }
            var root = try parse(raw, path: settings.path) ?? [:]
            guard try change(&root) else { return }
            var data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(contentsOf: Array("\n".utf8))

            if let raw, !fileManager.fileExists(atPath: backup.path) {
                try PrivateFile.write(raw, to: backup)
            }
            let mode = ((try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let temp = try PrivateFile.prepare(data, for: target, mode: mode_t(mode))
            beforeReplace?()
            let unchanged: Bool
            do { unchanged = try read(settings, targeting: target) == raw }
            catch is TargetChanged {
                unlink(temp.path)
                continue
            }
            catch { unlink(temp.path); throw error }
            guard unchanged else {
                unlink(temp.path)
                continue
            }
            try PrivateFile.commit(temp, to: target)
            return
        }
        throw Failure.keptChanging(settings.path)
    }

    private struct TargetChanged: Error {}

    private static func read(_ settings: URL, targeting target: URL? = nil) throws -> Data? {
        var info = stat()
        guard lstat(settings.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unreadable(settings.path, String(cString: strerror(errno)))
        }
        let resolved = settings.resolvingSymlinksInPath()
        if let target, resolved != target { throw TargetChanged() }
        do {
            let data = try Data(contentsOf: target ?? resolved)
            if let target, settings.resolvingSymlinksInPath() != target { throw TargetChanged() }
            return data
        }
        catch is TargetChanged { throw TargetChanged() }
        catch { throw Failure.unreadable(settings.path, (error as NSError).localizedDescription) }
    }

    private static func parse(_ raw: Data?, path: String) throws -> [String: Any]? {
        guard let raw else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) else {
            throw Failure.invalidJSON(path)
        }
        guard let root = value as? [String: Any] else { throw Failure.notAnObject(path) }
        return root
    }
}
