import Foundation

/// Reads Claude Code's background task files and checks guest process descriptors for live shell outputs. The local
/// process table and the SSH mirror never establish guest task state.
struct GuestBackgroundTasks: Sendable {
    struct Result: Equatable, Sendable {
        var tasks: [BackgroundWork]
        /// False means at least one guest read or descriptor check was inconclusive.
        var certain: Bool
    }

    var client: any GuestClient
    var taskLimit = 256
    var transcriptTailLimit = 256 * 1024
    var recentOutputGrace: TimeInterval = 5

    func read(computer: GuestReference, account: GuestAccount, cliSessionID: String,
              projectFolders: [String], parentTranscript: Data, now: Date = Date()) async -> Result {
        let root = account.operatingSystem == .macos
            ? "/private/tmp/claude-\(account.uid)"
            : "/tmp/claude-\(account.uid)"
        let projectNames = Array(Set(projectFolders.compactMap(Self.projectDirectoryName))).sorted()
        guard !projectNames.isEmpty else { return Result(tasks: [], certain: false) }

        var folders: [String] = []
        for name in projectNames {
            let tasks = GuestRouterPaths.join(GuestRouterPaths.join(GuestRouterPaths.join(root, name), cliSessionID), "tasks")
            do {
                _ = try await client.filesList(computer: computer, path: tasks)
                folders.append(tasks)
            } catch GuestClientFailure.notFound(_) {
                continue
            } catch {
                return Result(tasks: [], certain: false)
            }
        }
        guard !folders.isEmpty else { return Result(tasks: [], certain: true) }

        var outputs: [(folder: String, entry: GuestFileEntry, path: String)] = []
        for folder in folders {
            let entries: [GuestFileEntry]
            do { entries = try await client.filesList(computer: computer, path: folder) }
            catch { return Result(tasks: [], certain: false) }
            for entry in entries.prefix(taskLimit) where entry.name.hasSuffix(".output")
                && (entry.type == .file || entry.type == .link) {
                outputs.append((folder, entry, GuestRouterPaths.join(folder, entry.name)))
            }
        }
        guard outputs.count <= taskLimit else { return Result(tasks: [], certain: false) }

        let commandPaths = Set(outputs.filter { $0.entry.type == .file }.map(\.path))
        var openPaths: Set<String> = []
        var certain = true
        if !commandPaths.isEmpty {
            do {
                let request = Self.openOutputsRequest(computer: computer, account: account, root: root)
                let result = try await client.exec(request)
                guard result.succeeded, let text = String(data: result.stdout, encoding: .utf8) else {
                    return Result(tasks: [], certain: false)
                }
                let prefix = root.hasSuffix("/") ? root : root + "/"
                openPaths = Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix(prefix) })
            } catch {
                return Result(tasks: [], certain: false)
            }
        }

        var tasks: [BackgroundWork] = []
        for output in outputs {
            let id = String(output.entry.name.dropLast(".output".count))
            let since = Date(timeIntervalSince1970: Double(output.entry.mtimeMs) / 1000)
            if Claude.announcesEnd(of: id, in: parentTranscript) { continue }
            if output.entry.type == .file {
                if openPaths.contains(output.path) {
                    let title = Claude.commandTitle(id, in: parentTranscript) ?? "Background command"
                    tasks.append(BackgroundWork(id: id, kind: .command, title: title, since: since))
                } else if now.timeIntervalSince(since) <= recentOutputGrace {
                    certain = false
                }
                continue
            }

            let targetResult: GuestExecResult
            do {
                targetResult = try await client.exec(GuestExecRequest(computer: computer,
                    argv: ["/usr/bin/readlink", output.path], cwd: account.home, timeoutSeconds: 2))
            } catch {
                certain = false
                continue
            }
            guard targetResult.succeeded, let rawTarget = String(data: targetResult.stdout, encoding: .utf8) else {
                certain = false
                continue
            }
            let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isProjectTranscript(target, projectsRoot: GuestRouterPaths.join(account.home, ".claude/projects")) else {
                certain = false
                continue
            }
            let transcriptName = URL(fileURLWithPath: target).lastPathComponent
            guard transcriptName.hasSuffix(".jsonl") else { certain = false; continue }
            let agentID = String(transcriptName.dropLast(".jsonl".count))
            if Claude.announcesEnd(of: id, in: parentTranscript) { continue }
            let directory = URL(fileURLWithPath: target).deletingLastPathComponent().path
            let transcriptRead: GuestTranscriptSnapshot?
            do {
                transcriptRead = try await GuestTranscripts(client: client, tailLimit: transcriptTailLimit)
                    .read(computer: computer, projectsRoot: directory, cliSessionID: agentID)
            } catch {
                certain = false
                continue
            }
            guard let transcript = transcriptRead else { certain = false; continue }
            let title = await agentTitle(computer: computer, transcriptPath: target) ?? "Subagent"
            tasks.append(BackgroundWork(id: id, kind: .agent, title: title, since: since, activity: transcript.activity))
        }
        return Result(tasks: tasks.sorted { $0.since < $1.since }, certain: certain)
    }

    static func openOutputsRequest(computer: GuestReference, account: GuestAccount, root: String) -> GuestExecRequest {
        let script: String
        if account.operatingSystem == .linux {
            script = #"for fd in /proc/[0-9]*/fd/1; do pid=${fd#/proc/}; pid=${pid%%/*}; uid=$(stat -c '%u' "/proc/$pid" 2>/dev/null) || continue; [ "$uid" = "$1" ] || continue; path=$(readlink "$fd" 2>/dev/null) || continue; case "$path" in "$2"/*) printf '%s\n' "$path";; esac; done"#
        } else {
            script = #"/usr/sbin/lsof -nP -a -u "$1" -d 1 -Fn 2>/dev/null | while IFS= read -r field; do case "$field" in n"$2"/*) printf '%s\n' "${field#n}";; esac; done"#
        }
        return GuestExecRequest(computer: computer,
            argv: ["/bin/sh", "-c", script, "fjord", String(account.uid), root], cwd: account.home, timeoutSeconds: 5)
    }

    private func agentTitle(computer: GuestReference, transcriptPath: String) async -> String? {
        let base = String(URL(fileURLWithPath: transcriptPath).lastPathComponent.dropLast(".jsonl".count))
        let meta = GuestRouterPaths.join(URL(fileURLWithPath: transcriptPath).deletingLastPathComponent().path,
                                         base + ".meta.json")
        guard let read = try? await client.filesRead(computer: computer, path: meta, offset: 0, length: 4096),
              let object = try? JSONSerialization.jsonObject(with: read.data) as? [String: Any],
              let description = object["description"] as? String, !description.isEmpty else { return nil }
        return description
    }

    private static func projectDirectoryName(_ path: String) -> String? {
        guard let absolute = try? GuestFolderPath.validate(path), !absolute.contains("/../"), !absolute.hasSuffix("/..") else { return nil }
        return absolute.replacingOccurrences(of: "/", with: "-")
    }

    private static func isProjectTranscript(_ path: String, projectsRoot: String) -> Bool {
        let prefix = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
        return path.hasPrefix(prefix) && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }
}
