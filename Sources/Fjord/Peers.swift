import Foundation

/// The Claude Code processes running now, as each registers itself in `~/.claude/sessions/<pid>.json`. A session with one is
/// a peer: the Router can message it by its name.
enum ClaudePeers {
    struct Peer: Hashable {
        /// What `SendMessage` takes as `to`: the session's title.
        var name: String
        var pid: Int32
    }

    /// By the desktop app's session id (`hostSessionId`, `local_…`). Files of processes that are gone are skipped.
    static func read(dir: URL, alive: (Int32) -> Bool = FormBridge.processAlive) -> [String: Peer] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var peers: [String: Peer] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = obj["hostSessionId"] as? String, !host.isEmpty,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value ?? Int32(url.deletingPathExtension().lastPathComponent),
                  alive(pid) else { continue }
            peers[host] = Peer(name: obj["name"] as? String ?? "", pid: pid)
        }
        return peers
    }

    /// One live process as Claude Code registers it: the session it runs now, and when it started.
    struct Registered: Hashable, Sendable {
        var sessionID: String
        var startedAt: Int64?
        /// What started the process (`claude-desktop` for the Claude app's own), whether it is `busy` or `idle`, and when it
        /// last changed (ms since 1970): what picks a session to carry a message (`RouterCarry.carriers`).
        var entrypoint: String? = nil
        var status: String? = nil
        var updatedAt: Int64? = nil
    }

    /// Every live process in the registry, by pid (what Fjord's plugin binds its presence to). A pid has one
    /// entry in Claude Code's own registry; all are kept in case two files name it.
    static func registry(dir: URL, alive: (Int32) -> Bool = FormBridge.processAlive) -> [Int32: [Registered]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var found: [Int32: [Registered]] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, let session = obj["sessionId"] as? String, alive(pid)
            else { continue }
            found[pid, default: []].append(Registered(sessionID: session, startedAt: (obj["startedAt"] as? NSNumber)?.int64Value,
                                                      entrypoint: obj["entrypoint"] as? String, status: obj["status"] as? String,
                                                      updatedAt: (obj["updatedAt"] as? NSNumber)?.int64Value))
        }
        return found
    }

    /// The desktop session (`hostSessionId`) a `SendMessage` `to` stands for, by Claude Code's registry of live processes: the
    /// exact peer name, or "name [ref]" with the ref telling apart peers of the same name. Nil when it matches none, or more
    /// than one.
    nonisolated static func session(named to: String, peers: [String: Peer]) -> String? {
        let exact = peers.filter { $0.value.name == to }
        if exact.count == 1 { return exact.first?.key }
        guard let match = to.range(of: #"^(.*) \[([^\]]+)\]$"#, options: .regularExpression) else { return nil }
        let text = String(to[match])
        guard let open = text.range(of: " [", options: .backwards) else { return nil }
        let name = String(text[..<open.lowerBound])
        let ref = String(text[open.upperBound...].dropLast())
        let named = peers.filter { $0.value.name == name }
        if named.count == 1 { return named.first?.key }
        let narrowed = named.filter { String($0.value.pid) == ref || $0.key == ref || $0.key.hasPrefix(ref) || $0.key.hasSuffix(ref) }
        return narrowed.count == 1 ? narrowed.first?.key : nil
    }
}
