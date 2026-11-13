import Foundation

/// A thread of a project: T3's project id and thread id.
struct BriefTarget: Codable, Hashable, Sendable {
    var project: String
    var thread: String

    /// "project/thread": how a decision links it, and an MCP call names it.
    var key: String { project + "/" + thread }

    init(project: String, thread: String) {
        self.project = project
        self.thread = thread
    }

    /// From its `key` (the project's id never holds a slash; a thread's may).
    init?(key: String) {
        guard let slash = key.firstIndex(of: "/"), slash != key.startIndex, key.index(after: slash) != key.endIndex else { return nil }
        project = String(key[..<slash])
        thread = String(key[key.index(after: slash)...])
    }
}
