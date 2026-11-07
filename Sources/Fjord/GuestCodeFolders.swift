import Foundation

/// Bounded guest clone discovery. Every path remains a guest string sent to guest.files; host FileManager, realpath,
/// tilde expansion, and URL path normalization never see it.
struct GuestCodeFolders: Sendable {
    struct Result: Equatable, Sendable {
        var repos: [String: [String]] = [:]
        var bare: Set<String> = []
        var cutShort = false
    }

    var client: any GuestClient
    var maxDepth = CodeFolders.maxDepth
    var maxFolders = CodeFolders.maxFolders

    func scan(computer: GuestReference, roots: [String]) async throws -> Result {
        var result = Result()
        var queue: [(String, Int)] = try roots.map { (try GuestFolderPath.validate($0), 0) }
        var cursor = 0
        var seen = Set<String>()
        while cursor < queue.count {
            let (folder, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(folder).inserted else { continue }
            guard seen.count <= maxFolders else { result.cutShort = true; break }
            let entries: [GuestFileEntry]
            do { entries = try await client.filesList(computer: computer, path: folder) }
            catch GuestClientFailure.notFound(_) { continue }
            if isBare(entries) {
                result.repos[folder] = try await remotes(computer: computer, gitDir: folder)
                result.bare.insert(folder)
                continue
            }
            if let marker = entries.first(where: { $0.name == ".git" }) {
                let configDir = try await gitConfigDirectory(computer: computer, folder: folder, marker: marker)
                result.repos[folder] = try await remotes(computer: computer, gitDir: configDir)
                continue
            }
            guard depth < maxDepth else { continue }
            for child in entries where child.type == .directory && !child.name.hasPrefix(".") && !CodeFolders.skipped.contains(child.name) {
                queue.append((GuestFolderPath.join(folder, child.name), depth + 1))
            }
        }
        return result
    }

    private func isBare(_ entries: [GuestFileEntry]) -> Bool {
        let types = Dictionary(entries.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
        return types["HEAD"] == .file && types["config"] == .file && types["objects"] == .directory && types["refs"] == .directory
    }

    private func gitConfigDirectory(computer: GuestReference, folder: String, marker: GuestFileEntry) async throws -> String? {
        let dotGit = GuestFolderPath.join(folder, ".git")
        if marker.type == .directory { return dotGit }
        guard marker.type == .file,
              let contents = try? await client.filesRead(computer: computer, path: dotGit, offset: nil, length: nil),
              let text = String(data: contents.data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = Self.resolveGuest(raw, from: folder)
        let commonPath = GuestFolderPath.join(gitDir, "commondir")
        if let common = try? await client.filesRead(computer: computer, path: commonPath, offset: nil, length: nil),
           let text = String(data: common.data, encoding: .utf8) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return Self.resolveGuest(value, from: gitDir) }
        }
        return gitDir
    }

    private func remotes(computer: GuestReference, gitDir: String?) async throws -> [String] {
        guard let gitDir,
              let read = try? await client.filesRead(computer: computer, path: GuestFolderPath.join(gitDir, "config"), offset: nil, length: nil),
              let config = String(data: read.data, encoding: .utf8) else { return [] }
        return CodeFolders.remotes(config: config)
    }

    /// Resolves only a gitdir/commondir relative string according to POSIX guest path semantics. It performs no I/O,
    /// tilde expansion, symlink lookup, or host filesystem normalization.
    static func resolveGuest(_ path: String, from base: String) -> String {
        let joined = path.hasPrefix("/") ? path : GuestFolderPath.join(base, path)
        var parts: [Substring] = []
        for component in joined.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
