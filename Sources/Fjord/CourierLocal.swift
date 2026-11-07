import AppKit
import Foundation

/// The app's view of the local Claude sessions, as the engine's `local` input (look.py's `read_local`): the session files of
/// the Claude app, Claude Code's registry of live processes, and whether the Claude app runs. Read when a file changes or the
/// app starts or quits (`RouterCourierLink.watchLocal`), never on a timer.
enum CourierLocal {
    static let purposeLength = 600
    static let resultDays = 2.0
    static let tailBytes = 100_000

    struct Places: Sendable {
        var sessions: URL
        var registry: URL
        var transcripts: URL
        var home: String

        static let app = Places(sessions: Claude.root.appendingPathComponent("claude-code-sessions", isDirectory: true),
                                registry: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
                                transcripts: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
                                home: NSHomeDirectory())
    }

    /// `{"sessions": {bridge id: info}, "processes": {cli: alive}, "statuses": {cli: status}, "app": bool}`.
    static func read(_ places: Places = .app, appRunning: Bool = !NSRunningApplication.runningApplications(withBundleIdentifier: Claude.bundleID).isEmpty, now: Double = Date().timeIntervalSince1970,
                     alive: (Int32) -> Bool = FormBridge.processAlive) -> JSON {
        var found = JSONObject(), processes = JSONObject(), statuses = JSONObject()
        let fm = FileManager.default
        if let users = fm.enumerator(at: places.sessions, includingPropertiesForKeys: nil) {
            for case let url as URL in users where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
                guard let data = try? Data(contentsOf: url), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let info = sessionInfo(d, now: now, places: places)
                let spawn = d["remoteControlSpawn"] as? [String: Any]
                var bridges = (d["bridgeSessionIds"] as? [String]) ?? []
                if let ccr = spawn?["ccrSessionId"] as? String { bridges.append(ccr) }
                if bridges.isEmpty { bridges = ["cli:\(d["cliSessionId"] as? String ?? "nil")"] }
                if let info { for b in bridges { found[b.replacingOccurrences(of: "session_", with: "cse_")] = info } }
            }
        }
        let registry = (try? fm.contentsOfDirectory(at: places.registry, includingPropertiesForKeys: nil)) ?? []
        for url in registry where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = d["sessionId"] as? String, let pid = (d["pid"] as? NSNumber)?.int32Value else { continue }
            processes[id] = .bool(alive(pid))
            statuses[id] = JSON(d["status"] as? String)
        }
        return ["sessions": .object(found), "processes": .object(processes), "statuses": .object(statuses), "app": .bool(appRunning)]
    }

    /// No project: no folder, the home folder itself, or a temp folder.
    static func isScratch(_ folder: String?, home: String) -> Bool {
        guard let folder, !folder.isEmpty else { return true }
        let trimmed = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let base = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return trimmed == (home.hasSuffix("/") ? String(home.dropLast()) : home) || base.hasPrefix("scratch-")
            || ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains { folder.hasPrefix($0) }
    }

    /// One session file as the engine sees it, or nil when the Board shouldn't hold it. Project-thread children are kept only to
    /// link to the page.
    static func sessionInfo(_ d: [String: Any], now: Double, places: Places) -> JSON? {
        let spawn = d["remoteControlSpawn"] as? [String: Any]
        let active = ((d["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
        guard d["isArchived"] as? Bool != true, now - active <= CourierLook.freshDays * 86400, let cli = d["cliSessionId"] as? String, !cli.isEmpty else { return nil }
        let anchors = d["gitAnchors"] as? [[String: Any]]
        let folder = (anchors?.first?["gitRoot"] as? String) ?? (d["cwd"] as? String) ?? (spawn?["folder"] as? String)
        let child = (spawn?["projectThreadChild"] as? Bool) == true || (spawn?["projectThreadChild"] as? NSNumber)?.boolValue == true
        if !child && isScratch(folder, home: places.home) { return nil }
        let summary = d["postTurnSummary"] as? [String: Any]
        let interrupted = d["interruptedAwaitingPerson"] as? Bool == true || summary?["interruptedAwaitingPerson"] as? Bool == true
        return [
            "folder": JSON(folder), "title": JSON(d["title"] as? String), "detail": JSON(summary?["status_detail"] as? String),
            "needs": JSON(summary?["needs_action"] as? String), "category": JSON(summary?["status_category"] as? String),
            "interrupted": .bool(interrupted), "active": .double(active), "cli": .string(cli), "child": .bool(child),
            "purpose": .string(child ? "" : purpose(folder)),
            "result": now - active < resultDays * 86400 ? JSON(result(cli, places.transcripts)) : .null,
        ]
    }

    /// What a repo says it is: the README's prose with tags, images and link targets stripped.
    static func purpose(_ folder: String?) -> String {
        guard let folder, let text = try? String(contentsOfFile: folder + "/README.md", encoding: .utf8) else { return "" }
        var kept: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            for (pattern, with) in [(#"!\[[^\]]*\]\([^)]*\)"#, ""), (#"\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"<[^>]*>"#, "")] {
                line = line.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !["#", "|", "```", "-", "!", "["].contains(where: { line.hasPrefix($0) }) { kept.append(line) }
        }
        return String(kept.joined(separator: " ").prefix(purposeLength))
    }

    /// A session's latest assistant text, from the tail of its transcript.
    static func result(_ cli: String, _ transcripts: URL) -> String? {
        let projects = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        for dir in projects {
            guard let handle = try? FileHandle(forReadingFrom: dir.appendingPathComponent("\(cli).jsonl")) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0)
            let lines = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).split(separator: "\n")
            var text: String?
            for line in lines where line.contains("\"type\":\"assistant\"") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                let joined = blocks.filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
                if !joined.isEmpty { text = joined }
            }
            return text.map { String($0.suffix(1500)) }
        }
        return nil
    }
}
