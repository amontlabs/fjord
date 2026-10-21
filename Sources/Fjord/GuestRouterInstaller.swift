import CryptoKit
import Foundation
import Security

/// Installs Router's guest-owned plugin and PermissionRequest bridge using generic guest files and exec. The installed
/// hook invokes the guest's verified Node executable; it never calls Fjord or a controller path.
struct GuestRouterInstaller: Sendable {
    struct Installed: Equatable, Sendable {
        var paths: GuestRouterPaths
        var version: String
        var keyID: String
    }

    enum Failure: LocalizedError, Equatable {
        case invalidAccount
        case command(String, Int32, String)
        case invalidSettings(String)
        case incompatibleSettings(String)
        case settingsKeptChanging(String)
        case prerequisite(String)
        case routerTurnedOff

        var errorDescription: String? {
            switch self {
            case .invalidAccount: "The guest account doesn't have an absolute home and Claude path, or Node provisioning did not produce an absolute executable."
            case .command(let command, let code, let detail): "Guest command \(command) failed (exit \(code)): \(detail)"
            case .invalidSettings(let path): "\(path) isn't valid JSON; Fjord left it alone."
            case .incompatibleSettings(let path): "\(path) has an incompatible hooks.PermissionRequest value; Fjord left it alone."
            case .settingsKeptChanging(let path): "\(path) kept changing while Fjord updated it."
            case .prerequisite(let detail): "Guest Router setup is blocked: \(detail)"
            case .routerTurnedOff: "The Router was switched off while guest setup was running."
            }
        }
    }

    var client: any GuestClient

    func install(computer: GuestReference,
                 activationAllowed: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> Installed {
        var account = try await client.account(for: computer)
        guard account.home.hasPrefix("/"), account.claudeExecutable.hasPrefix("/") else {
            throw Failure.invalidAccount
        }
        try await check(account.claudeExecutable, minimumNodeMajor: nil, computer: computer, cwd: account.home)
        let git = try await client.exec(GuestExecRequest(computer: computer, argv: ["git", "--version"], cwd: account.home, timeoutSeconds: 3))
        guard git.succeeded else { throw Failure.prerequisite("Git is unavailable in the guest PATH") }
        if try await hasSupportedNode(account, computer: computer) == false {
            try await GuestNodeRuntime.provision(client: client, computer: computer, account: account)
            account = try await client.account(for: computer)
        }
        guard account.nodeExecutable.hasPrefix("/") else { throw Failure.invalidAccount }
        try await check(account.nodeExecutable, minimumNodeMajor: 18, computer: computer, cwd: account.home)
        let paths = try GuestRouterPaths(home: account.home)
        let version = ClaudePlugin.version(app: "fjord-guest-3")
        let previous = try? await client.filesRead(computer: computer, path: GuestRouterPaths.join(paths.root, "install-version"), offset: nil, length: nil)
        let alreadyInstalled = String(data: previous?.data ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == version

        try await writeDirectoryMarker(computer: computer, path: paths.forms)
        try await writeDirectoryMarker(computer: computer, path: paths.presence)
        try await writeDirectoryMarker(computer: computer, path: paths.inbox)
        let pluginConfig = try JSONSerialization.data(withJSONObject: [
            "keyPath": paths.key, "presenceDir": paths.presence, "sessionsDir": paths.registry, "inboxDir": paths.inbox,
        ], options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        let pluginFiles: [(String, Data, UInt16)] = [
            (".claude-plugin/plugin.json", Data(ClaudePlugin.pluginJSON(version: version, name: ClaudePlugin.guestName).utf8), 0o644),
            (".claude-plugin/marketplace.json", Data(ClaudePlugin.guestMarketplaceJSON.utf8), 0o644),
            ("hooks/hooks.json", Data(ClaudePlugin.hooksJSON.utf8), 0o644),
            ("hooks/register.ts", Data(ClaudePlugin.register.utf8), 0o644),
            ("config.json", pluginConfig, 0o600),
        ]
        for (relative, data, mode) in pluginFiles {
            try await write(data, computer: computer, path: GuestRouterPaths.join(paths.plugin, relative), mode: mode)
        }
        try await write(GuestRouterArtifacts.formShell(node: account.nodeExecutable, module: paths.formModule),
                        computer: computer, path: paths.hook, mode: 0o755)
        try await write(Data(GuestRouterArtifacts.formModule.utf8), computer: computer, path: paths.formModule, mode: 0o644)

        if !alreadyInstalled {
            try await removeLegacyInstall(account: account, computer: computer)
            let marketplace = try await client.exec(GuestExecRequest(computer: computer,
                argv: [account.claudeExecutable, "plugin", "marketplace", "add", paths.plugin, "--scope", "user"],
                cwd: account.home, timeoutSeconds: 120))
            try requireSuccess(marketplace, command: "claude plugin marketplace add")
            let plugin = try await client.exec(GuestExecRequest(computer: computer,
                argv: [account.claudeExecutable, "plugin", "install", ClaudePlugin.guestID, "--scope", "user"],
                cwd: account.home, timeoutSeconds: 120))
            try requireSuccess(plugin, command: "claude plugin install")
        } else {
            let update = try await client.exec(GuestExecRequest(computer: computer,
                argv: [account.claudeExecutable, "plugin", "update", ClaudePlugin.guestID, "--scope", "user"],
                cwd: account.home, timeoutSeconds: 120))
            // An install version file survives an uninstall. Reinstall if the CLI says update has no installed copy.
            if !update.succeeded {
                let install = try await client.exec(GuestExecRequest(computer: computer,
                    argv: [account.claudeExecutable, "plugin", "install", ClaudePlugin.guestID, "--scope", "user"],
                    cwd: account.home, timeoutSeconds: 120))
                try requireSuccess(install, command: "claude plugin install")
            }
        }
        try await GuestClaudeSettings.installHook(client: client, computer: computer, paths: paths)
        guard await activationAllowed() else {
            try? await disable(computer: computer)
            throw Failure.routerTurnedOff
        }
        let key = try await ensureGuestKey(computer: computer, path: paths.key)
        try await write(Data(version.utf8), computer: computer, path: GuestRouterPaths.join(paths.root, "install-version"), mode: 0o600)
        try await write(Data(), computer: computer, path: GuestRouterPaths.join(paths.forms, FormBridge.marker), mode: 0o600)
        guard await activationAllowed() else {
            try? await disable(computer: computer)
            throw Failure.routerTurnedOff
        }
        return Installed(paths: paths, version: version, keyID: ClaudePlugin.keyID(of: key))
    }

    /// An earlier Fjord installed the guest plugin as `fjord@fjord`, which Claude Desktop's hookless copy of the Mac's
    /// `fjord` plugin shadows. Best effort: either may be absent.
    private func removeLegacyInstall(account: GuestAccount, computer: GuestReference) async throws {
        for argv in [["plugin", "uninstall", ClaudePlugin.legacyGuestID, "--scope", "user"],
                     ["plugin", "marketplace", "remove", ClaudePlugin.legacyGuestMarketplace]] {
            _ = try? await client.exec(GuestExecRequest(computer: computer, argv: [account.claudeExecutable] + argv,
                                                        cwd: account.home, timeoutSeconds: 120))
        }
    }

    func disable(computer: GuestReference) async throws {
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        try await GuestClaudeSettings.removeHook(client: client, computer: computer, paths: paths)
        let presence: [GuestFileEntry]
        do { presence = try await client.filesList(computer: computer, path: paths.presence) }
        catch GuestClientFailure.notFound(_) { presence = [] }
        let revoke = [GuestRouterPaths.join(paths.forms, FormBridge.marker), paths.key]
            + presence.filter { $0.type == .file && !$0.name.hasPrefix(".") }
                .map { GuestRouterPaths.join(paths.presence, $0.name) }
        _ = try await client.filesRemove(computer: computer, paths: revoke)
    }

    private func ensureGuestKey(computer: GuestReference, path: String) async throws -> String {
        if let read = try? await client.filesRead(computer: computer, path: path, offset: nil, length: nil),
           let existing = String(data: read.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.invalidAccount }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        do { try await client.filesWrite(.init(computer: computer, path: path, data: Data((value + "\n").utf8), mode: 0o600,
                                               createParents: true, replace: .never)) }
        catch GuestClientFailure.exists(_) {
            guard let winner = try? await client.filesRead(computer: computer, path: path, offset: nil, length: nil),
                  let text = String(data: winner.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { throw Failure.invalidAccount }
            return text
        }
        return value
    }

    private func writeDirectoryMarker(computer: GuestReference, path: String) async throws {
        try await write(Data(), computer: computer, path: GuestRouterPaths.join(path, ".fjord-directory"), mode: 0o600)
    }

    private func write(_ data: Data, computer: GuestReference, path: String, mode: UInt16) async throws {
        try await client.filesWrite(.init(computer: computer, path: path, data: data, mode: mode, createParents: true))
    }

    private func requireSuccess(_ result: GuestExecResult, command: String) throws {
        guard result.succeeded else {
            let output = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.command(command, result.exitCode, output)
        }
    }

    private func check(_ executable: String, minimumNodeMajor: Int?, computer: GuestReference, cwd: String) async throws {
        let result = try await client.exec(GuestExecRequest(computer: computer, argv: [executable, "--version"], cwd: cwd, timeoutSeconds: 3))
        guard result.succeeded else { throw Failure.prerequisite("\(executable) isn't executable in the guest") }
        guard let minimumNodeMajor else { return }
        let text = String(data: result.stdout.isEmpty ? result.stderr : result.stdout, encoding: .utf8) ?? ""
        guard let match = text.range(of: #"^v?(\d+)"#, options: .regularExpression),
              let major = Int(text[match].drop(while: { !$0.isNumber })), major >= minimumNodeMajor else {
            throw Failure.prerequisite("Node \(minimumNodeMajor) or newer is required in the guest")
        }
    }

    private func hasSupportedNode(_ account: GuestAccount, computer: GuestReference) async throws -> Bool {
        guard account.nodeExecutable.hasPrefix("/") else { return false }
        let result = try await client.exec(GuestExecRequest(computer: computer, argv: [account.nodeExecutable, "--version"],
                                                           cwd: account.home, timeoutSeconds: 3))
        guard result.succeeded else { return false }
        let text = String(data: result.stdout.isEmpty ? result.stderr : result.stdout, encoding: .utf8) ?? ""
        guard let match = text.range(of: #"^v?(\d+)"#, options: .regularExpression),
              let major = Int(text[match].drop(while: { !$0.isNumber })) else { return false }
        return major >= 18
    }
}

/// Guest-side settings CAS. It backs up the first original and merges Fjord's command hook without discarding other hooks.
enum GuestClaudeSettings {
    static let matcher = FormHookInstaller.formMatcher

    static func installHook(client: any GuestClient, computer: GuestReference, paths: GuestRouterPaths) async throws {
        let command = FormHookInstaller.quoted(paths.hook, onlyIfNeeded: true)
        try await modify(client: client, computer: computer, paths: paths) { root in
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            guard root["hooks"] == nil || root["hooks"] is [String: Any],
                  hooks["PermissionRequest"] == nil || hooks["PermissionRequest"] is [Any] else {
                throw GuestRouterInstaller.Failure.incompatibleSettings(paths.settings)
            }
            var entries = hooks["PermissionRequest"] as? [Any] ?? []
            entries = entries.compactMap { entry in
                guard var object = entry as? [String: Any], let nested = object["hooks"] as? [Any] else { return entry }
                let kept = nested.filter {
                    let path = ($0 as? [String: Any])?["command"] as? String
                    return path != command && path != paths.hook
                }
                if kept.count == nested.count { return entry }
                guard !kept.isEmpty else { return nil }
                object["hooks"] = kept
                return object
            }
            if !entries.contains(where: { ($0 as? [String: Any])?["matcher"] as? String == matcher
                && (($0 as? [String: Any])?["hooks"] as? [[String: Any]])?.contains(where: { $0["command"] as? String == command }) == true }) {
                entries.append(["matcher": matcher, "hooks": [["type": "command", "command": command,
                                                                   "timeout": FormHookInstaller.timeout]]] as [String: Any])
            }
            hooks["PermissionRequest"] = entries
            root["hooks"] = hooks
            return true
        }
    }

    static func removeHook(client: any GuestClient, computer: GuestReference, paths: GuestRouterPaths) async throws {
        let command = FormHookInstaller.quoted(paths.hook, onlyIfNeeded: true)
        try await modify(client: client, computer: computer, paths: paths) { root in
            guard var hooks = root["hooks"] as? [String: Any], let entries = hooks["PermissionRequest"] as? [Any] else { return false }
            var removedFjordHook = false
            let kept = entries.compactMap { entry -> Any? in
                guard var object = entry as? [String: Any], let nested = object["hooks"] as? [Any] else { return entry }
                let remaining = nested.filter { (($0 as? [String: Any])?["command"] as? String) != command
                    && (($0 as? [String: Any])?["command"] as? String) != paths.hook }
                if remaining.count != nested.count { removedFjordHook = true }
                if remaining.count == nested.count { return entry }
                if remaining.isEmpty { return nil }
                object["hooks"] = remaining
                return object
            }
            if kept.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = kept }
            if !removedFjordHook { return false }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            return true
        }
        _ = try await client.filesRemove(computer: computer, paths: [paths.hook])
    }

    private static func modify(client: any GuestClient, computer: GuestReference, paths: GuestRouterPaths,
                               change: (inout [String: Any]) throws -> Bool) async throws {
        let backup = paths.settings + ".fjord-backup"
        for _ in 0..<ClaudeSettingsFile.attempts {
            let original = try await readOptional(client: client, computer: computer, path: paths.settings)
            let raw = original?.data
            var root: [String: Any] = [:]
            if let raw {
                guard let value = try? JSONSerialization.jsonObject(with: raw), let object = value as? [String: Any] else {
                    throw GuestRouterInstaller.Failure.invalidSettings(paths.settings)
                }
                root = object
            }
            guard try change(&root) else { return }
            var output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            output.append(0x0a)
            if let raw, try await readOptional(client: client, computer: computer, path: backup) == nil {
                do { try await client.filesWrite(.init(computer: computer, path: backup, data: raw, mode: 0o600, replace: .never)) }
                catch GuestClientFailure.exists(_) { }
            }
            let expected = raw.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            do {
                try await client.filesWrite(.init(computer: computer, path: paths.settings, data: output,
                    mode: original?.mode ?? 0o600, createParents: true, replace: .ifSHA256(expected)))
                return
            } catch GuestClientFailure.changed(_) { continue }
        }
        throw GuestRouterInstaller.Failure.settingsKeptChanging(paths.settings)
    }

    private static func readOptional(client: any GuestClient, computer: GuestReference, path: String) async throws -> GuestFileReadResult? {
        do { return try await client.filesRead(computer: computer, path: path, offset: nil, length: nil) }
        catch GuestClientFailure.notFound(_) { return nil }
    }
}

enum GuestRouterArtifacts {
    static func formShell(node: String, module: String) -> Data {
        let node = FormHookInstaller.quoted(node)
        let module = FormHookInstaller.quoted(module)
        return Data("#!/bin/sh\n[ -x \(node) ] || exit 0\nexec \(node) \(module)\n".utf8)
    }

    static let formModule = #"""
import fs from 'node:fs'
import path from 'node:path'
import { isDeepStrictEqual } from 'node:util'

const ROOT = path.join(process.env.HOME || '', '.local/share/fjord/router')
const FORMS = path.join(ROOT, 'forms')
const MARKER = path.join(FORMS, '.enabled')
const MAX = 8 * 1024 * 1024
const INPUT_TIMEOUT = 30_000
const INTERVAL = 250
const LIMIT = 24 * 60 * 60 * 1000
const rejected = 'The user doesn\'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.'
const rejectedWithNote = 'The user doesn\'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n'
let stopped = false
const stop = () => { stopped = true; process.stdin.destroy() }
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, stop)

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const safe = value => [...value].filter(c => /[\p{L}\p{N}_-]/u.test(c)).join('') || 'unknown'
const readInput = async () => {
  const chunks = []
  let size = 0
  let timedOut = false
  let tooLarge = false
  const timer = setTimeout(() => { timedOut = true; process.stdin.destroy() }, INPUT_TIMEOUT)
  try {
    for await (const chunk of process.stdin) {
      size += chunk.length
      if (size > MAX) { tooLarge = true; process.stdin.destroy(); break }
      chunks.push(chunk)
    }
  } catch {
    return undefined
  } finally {
    clearTimeout(timer)
  }
  if (stopped || timedOut || tooLarge) return undefined
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch { return undefined }
}
const lineObjects = text => text.split('\n').filter(line => line.trim()).flatMap(line => {
  try { return [JSON.parse(line)] } catch { return [] }
})
// A row's content is a string for a plain prompt (the session's first message), not a list of blocks.
const blocks = row => Array.isArray(row.message?.content) ? row.message.content : []
const transcriptState = (file, tool, input, id) => {
  try {
    const stat = fs.statSync(file)
    const from = Math.max(0, stat.size - MAX)
    const fd = fs.openSync(file, 'r')
    const bytes = Buffer.alloc(stat.size - from)
    fs.readSync(fd, bytes, 0, bytes.length, from)
    fs.closeSync(fd)
    const records = lineObjects(bytes.toString('utf8'))
    let match = id
    if (!match) {
      for (const row of records) {
        if (row.type !== 'assistant') continue
        const content = blocks(row)
        for (const part of content) if (part.type === 'tool_use' && part.name === tool && isDeepStrictEqual(part.input, input)) match = part.id
      }
    }
    return { id: match, answered: !!match && records.some(row => row.type === 'user' &&
      blocks(row).some(part => part.type === 'tool_result' && part.tool_use_id === match)) }
  } catch { return { id, answered: false } }
}
const verdict = (tool, input, answer) => {
  if (tool === 'ExitPlanMode') {
    if (typeof answer.plan?.approve !== 'boolean') return undefined
    if (answer.plan.approve) return { behavior: 'allow', updatedInput: input }
    const feedback = String(answer.plan.feedback || '').trim()
    return { behavior: 'deny', message: feedback ? rejectedWithNote + feedback : rejected }
  }
  if (!answer.answers || typeof answer.answers !== 'object') return undefined
  return { behavior: 'allow', updatedInput: { ...input, answers: answer.answers } }
}

const request = await readInput()
if (stopped || request?.hook_event_name !== 'PermissionRequest' || !['AskUserQuestion', 'ExitPlanMode'].includes(request.tool_name) ||
    !request.tool_input || !fs.existsSync(MARKER)) process.exit(0)
const started = Date.now()
const session = String(request.session_id || 'unknown')
const key = `${safe(session)}-${started}-${process.pid}`
const pending = path.join(FORMS, `${key}.json`)
const answerPath = path.join(FORMS, `${key}.answer.json`)
const form = { key, session_id: session, transcript_path: request.transcript_path || '', cwd: request.cwd || '',
  tool_name: request.tool_name, tool_input: request.tool_input, created_at: started, pid: process.pid }
try {
  const fd = fs.openSync(pending, 'wx', 0o600)
  fs.writeFileSync(fd, JSON.stringify(form))
  fs.fsyncSync(fd)
  fs.closeSync(fd)
} catch { process.exit(0) }
let callId
const cleanup = () => { try { fs.unlinkSync(pending) } catch {}; try { fs.unlinkSync(answerPath) } catch {} }
try {
  while (!stopped && Date.now() - started < LIMIT) {
    if (!fs.existsSync(MARKER) || process.ppid <= 1) break
    const result = transcriptState(form.transcript_path, form.tool_name, form.tool_input, callId)
    if (result.id && result.id !== callId) {
      callId = result.id
      form.tool_use_id = callId
      const temp = `${pending}.${process.pid}.tmp`
      fs.writeFileSync(temp, JSON.stringify(form), { mode: 0o600 })
      fs.renameSync(temp, pending)
    }
    if (result.answered) break
    try {
      const answer = JSON.parse(fs.readFileSync(answerPath, 'utf8'))
      const decision = verdict(form.tool_name, form.tool_input, answer)
      if (decision) {
        cleanup()
        process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision } }) + '\n')
        process.exit(0)
      }
    } catch {}
    await sleep(INTERVAL)
  }
} finally { cleanup() }
"""#
}
