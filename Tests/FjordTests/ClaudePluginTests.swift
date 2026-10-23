import Foundation
import Testing
@testable import Fjord

/// Claude Code's plugin commands, answered from memory: the marketplaces and plugins added, and every call made. A
/// command can be made to fail, or held until the test lets it go.
final class FakeClaudeCLI: @unchecked Sendable {
    private let lock = NSLock()
    var marketplaces: [String: String] = [:]
    /// id → (folder, version, enabled)
    var plugins: [String: (folder: String, version: String, enabled: Bool)] = [:]
    var calls: [String] = []
    /// The version the folder holds, as `plugin list` reads it.
    var folderVersion = ""
    var failing: String?
    /// Whether `plugin update` refreshes the cache (a CLI that doesn't leaves it stale).
    var updateRefreshes = true
    /// Commands starting with this wait for `release()`.
    var holding: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    var isHolding: Bool { lock.withLock { !held.isEmpty } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = nil
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    var runner: ClaudePluginInstaller.Runner {
        { [self] binary, arguments in
            let line = arguments.joined(separator: " ")
            if lock.withLock({ holding.map { line.hasPrefix($0) } ?? false }) {
                await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
            }
            return lock.withLock { answer(binary, arguments) }
        }
    }

    private func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func answer(_ binary: String, _ a: [String]) -> ClaudePluginInstaller.Output {
        let line = a.joined(separator: " ")
        calls.append(line)
        if let failing, line.hasPrefix(failing) { return .init(status: 1, out: "", err: "boom: \(failing)\n") }
        switch Array(a.prefix(3)) {
        case ["plugin", "list", "--json"]:
            return .init(status: 0, out: json(plugins.map { id, p in
                ["id": id, "version": p.version, "scope": "user", "enabled": p.enabled, "readFromFolder": p.folder,
                 "folderVersion": folderVersion] as [String: Any]
            }), err: "")
        case ["plugin", "marketplace", "list"]:
            return .init(status: 0, out: json(marketplaces.map { ["name": $0.key, "source": "directory", "path": $0.value] }), err: "")
        case ["plugin", "marketplace", "add"]:
            marketplaces[ClaudePlugin.name] = a[3]
        case ["plugin", "marketplace", "remove"]:
            marketplaces[a[3]] = nil
        case ["plugin", "install", ClaudePlugin.id]:
            guard let folder = marketplaces[ClaudePlugin.name] else { return .init(status: 1, out: "", err: "no marketplace") }
            plugins[ClaudePlugin.id] = (folder, folderVersion, true)
        case ["plugin", "update", ClaudePlugin.id]:
            if updateRefreshes { plugins[ClaudePlugin.id]?.version = folderVersion }
        case ["plugin", "enable", ClaudePlugin.id]:
            plugins[ClaudePlugin.id]?.enabled = true
        case ["plugin", "uninstall", ClaudePlugin.id]:
            plugins[ClaudePlugin.id] = nil
        default:
            return .init(status: 1, out: "", err: "unknown command \(line)")
        }
        return .init(status: 0, out: "ok\n", err: "")
    }

    /// The calls that changed something (the lists left out).
    var changes: [String] { lock.withLock { calls.filter { !$0.contains("list") } } }
}

/// Fjord's plugin running in a session, as a test lays it out: Claude Code's registry lists the process (this test
/// process's pid, alive) for the session, the plugin's presence file names it under the key in `support/relay.key`, and
/// the plugin's config says where the registry and the key are.
enum PluginFixture {
    /// The store signs with the key a test wrote (as a switch-on would have read it, off the main thread).
    @MainActor static func useKey(_ s: Store) {
        guard let paths = s.routerFiles else { return }
        s.relayKeyCache = RelayKeyCache.load(paths.relayKey)
    }

    /// `extra` is merged into the presence file (capabilities, a `turn`).
    static func live(_ cli: String, support: URL, claude: URL, pid: Int32 = getpid(), startedAt: Int64 = 1,
                     extra: [String: Any] = [:], registryExtra: [String: Any] = [:]) {
        let fm = FileManager.default
        let registry = claude.appendingPathComponent("sessions", isDirectory: true)
        let presence = support.appendingPathComponent("plugin-sessions", isDirectory: true)
        let plugin = support.appendingPathComponent("claude-plugin", isDirectory: true)
        for dir in [registry, presence, plugin] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func write(_ obj: [String: Any], _ url: URL) { try? JSONSerialization.data(withJSONObject: obj).write(to: url) }
        write(["pid": Int(pid), "sessionId": cli, "startedAt": startedAt].merging(registryExtra) { _, new in new },
              registry.appendingPathComponent("plugin-\(cli).json"))
        let key = support.appendingPathComponent("relay.key")
        let keyID = ClaudePlugin.key(at: key).map(ClaudePlugin.keyID(of:)) ?? "none"
        write(["state": "live", "sessionId": cli, "pid": Int(pid), "startedAt": startedAt, "keyId": keyID,
               "renewedAt": Int64(ClaudePlugin.leaseNow.timeIntervalSince1970 * 1000), "activation": "test"]
            .merging(extra) { _, new in new },
              presence.appendingPathComponent(cli))
        write(["sessionsDir": registry.path, "presenceDir": presence.path, "keyPath": key.path], plugin.appendingPathComponent("config.json"))
    }
}

@Suite struct ClaudePluginFiles {
    /// The repository's copy of the plugin, where `claude plugin test` runs its tests.
    private static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ClaudePlugin")

    @Test func theEmbeddedSourcesAreTheRepositorysOwn() throws {
        func read(_ path: String) throws -> String { try String(contentsOf: Self.source.appendingPathComponent(path), encoding: .utf8) }
        #expect(try read("hooks/register.ts") == ClaudePlugin.register)
        #expect(try read("hooks/hooks.json") == ClaudePlugin.hooksJSON)
        #expect(try read(".claude-plugin/marketplace.json") == ClaudePlugin.marketplaceTemplate)
        let repo = try #require(try JSONSerialization.jsonObject(with: Data(read(".claude-plugin/plugin.json").utf8)) as? NSDictionary)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(ClaudePlugin.pluginJSON(version: "0.0.0-dev", name: ClaudePlugin.pluginName(development: false)).utf8)) as? NSDictionary)
        #expect(written.isEqual(repo))
    }

    @Test func theVersionFollowsTheAppAndTheSources() {
        let release = ClaudePlugin.version(app: "1.4.0")
        #expect(release.hasPrefix("1.4.0"))
        #expect(ClaudePlugin.version(app: "1.4.0") == release && ClaudePlugin.version(app: "1.4.1") != release)
    }

    @Test func theFolderIsWrittenAndTheKeyKeptOutsideIt() throws {
        let dir = TempDir()
        let folder = dir.path("claude-plugin"), presence = dir.path("plugin-sessions"), keyFile = dir.path("relay.key")
        try ClaudePlugin.write(to: folder, version: "1.0.0-rabc", presence: presence, key: keyFile, registry: dir.path("sessions"))
        let fm = FileManager.default
        for path in [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json", "hooks/register.ts", "config.json"] {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent(path).path), "\(path)")
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any]
        #expect(manifest?["version"] as? String == "1.0.0-rabc" && manifest?["name"] as? String == ClaudePlugin.name)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: String]
        #expect(config == ["keyPath": keyFile.path, "presenceDir": presence.path, "sessionsDir": dir.path("sessions").path,
                           "inboxDir": dir.path("relay").path])
        #expect(mode(dir.path("relay")) == 0o700)
        // Writing the folder makes no key; the key is made once, readable by the person alone, never in the folder.
        #expect(ClaudePlugin.key(at: keyFile) == nil)
        let key = try ClaudePlugin.ensureKey(at: keyFile)
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit) && mode(keyFile) == 0o600 && mode(folder) == 0o700)
        #expect(try ClaudePlugin.ensureKey(at: keyFile) == key)
        for path in (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? [] {
            let text = (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? ""
            #expect(!text.contains(key), "\(path)")
        }
        ClaudePlugin.removeKey(at: keyFile)
        #expect(try ClaudePlugin.ensureKey(at: keyFile) != key)
    }
}

/// Which sessions run the plugin: a presence file counts only while its process lives and Claude Code still registers it
/// for that session, started when the file says.
@Suite struct PluginPresence {
    private let key = "k1"

    private func presence(_ dir: TempDir, _ cli: String, pid: Int32, startedAt: Int64, state: String = "live", keyID: String? = nil,
                          renewedAt: Date = ClaudePlugin.leaseNow) throws {
        let obj: [String: Any] = ["state": state, "sessionId": cli, "pid": Int(pid), "startedAt": startedAt,
                                  "keyId": keyID ?? ClaudePlugin.keyID(of: key), "activation": "a",
                                  "renewedAt": Int64(renewedAt.timeIntervalSince1970 * 1000)]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.path(cli))
    }

    private func entry(_ cli: String, _ startedAt: Int64) -> [ClaudePeers.Registered] {
        [ClaudePeers.Registered(sessionID: cli, startedAt: startedAt)]
    }

    @Test func aLiveProcessRegisteredForTheSessionCounts() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-a"])
        try presence(dir, "cli-a", pid: 100, startedAt: 5, state: "ended")
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
    }

    @Test func aCrashOrAResumeWithoutThePluginDoesNotCount() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        // Crashed: the process is gone (its registry file may linger).
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in false }.isEmpty)
        // Resumed in another process that doesn't run the plugin: the session is registered, under another pid.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [200: entry("cli-a", 9)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        // The pid was reused by a new process.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 9)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        // An old plain-text file says nothing about a process.
        try Data("live\n".utf8).write(to: dir.path("cli-b"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-b", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
    }

    @Test func aClearMovesThePresenceToTheNewSession() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        // /clear: the same process now runs a new session id; until the plugin marks it, neither counts.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-new", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        try presence(dir, "cli-new", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-new", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-new"])
    }

    @Test func aFileWrittenUnderAnotherKeyDoesNotCount() throws {
        // The same process and session: the plugin was unloaded while the Router was off, so it never said so under the
        // key made when the Router came back on.
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5, keyID: ClaudePlugin.keyID(of: "old key"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: nil) { _ in true }.isEmpty)
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-a"])
    }

    @Test func aPluginUnloadedWithoutAWordStopsCountingWhenItsLeaseRunsOut() throws {
        // Disabled outside Fjord and reloaded away: no session.end, the same process, session and key. The
        // plugin no longer renews its file.
        let dir = TempDir()
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        try presence(dir, "cli-a", pid: 100, startedAt: 5, renewedAt: t0)
        let registry = [Int32(100): entry("cli-a", 5)], keyID = ClaudePlugin.keyID(of: key)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0.addingTimeInterval(25)) { _ in true } == ["cli-a"])
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0.addingTimeInterval(31)) { _ in true }.isEmpty)
        // A file with no lease at all (an older plugin) never counts.
        try JSONSerialization.data(withJSONObject: ["state": "live", "sessionId": "cli-a", "pid": 100, "startedAt": 5, "keyId": keyID])
            .write(to: dir.path("cli-a"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0) { _ in true }.isEmpty)
    }

    @Test func timestampsAtEitherEndOfInt64AreRefusedNotATrap() throws {
        let dir = TempDir()
        let keyID = ClaudePlugin.keyID(of: key)
        for value in [Int64.min, Int64.max] {
            let obj: [String: Any] = ["state": "live", "sessionId": "cli-a", "pid": 100, "startedAt": value, "keyId": keyID,
                                      "renewedAt": value]
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.path("cli-a"))
            let registry = [Int32(100): [ClaudePeers.Registered(sessionID: "cli-a", startedAt: value)]]
            #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID) { _ in true }.isEmpty)
        }
    }

    @Test func keyIDsAreTheFirstHexDigitsOfTheKeysDigest() {
        // The plugin's tests check the same.
        #expect(ClaudePlugin.keyID(of: RelaySigning.key) == "3248d2f95844d92f")
    }

    @Test func theRegistryIsReadByPid() throws {
        let dir = TempDir()
        try JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "sessionId": "cli-a", "startedAt": 7])
            .write(to: dir.path("\(getpid()).json"))
        try JSONSerialization.data(withJSONObject: ["pid": 99_999, "sessionId": "cli-b"]).write(to: dir.path("99999.json"))
        #expect(ClaudePeers.registry(dir: dir.url) { $0 == getpid() } == [getpid(): [.init(sessionID: "cli-a", startedAt: 7)]])
    }

    @Test func theFolderOnlyFormReadsTheRegistryItsConfigNames() {
        let dir = TempDir()
        let support = dir.path("support")
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")).isEmpty)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? Data("k1\n".utf8).write(to: support.appendingPathComponent("relay.key"))
        PluginFixture.live("cli-a", support: support, claude: dir.path("claude"))
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")) == ["cli-a"])
        // The key changed (the Router was switched off and on): the file no longer counts.
        try? Data("k2\n".utf8).write(to: support.appendingPathComponent("relay.key"))
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")).isEmpty)
    }
}

/// The signer and the plugin's verifier agree: the same vector is checked by `Resources/ClaudePlugin/tests/relay.test.ts`.
@Suite struct RelaySigning {
    static let key = "4c6f6f6b6f75742072656c6179206b657920666f722074657374732e2e2e2e21"
    static let target = "cli-target"
    static let nonce = "123e4567-e89b-12d3-a456-426614174000"
    static let ts: Int64 = 2_000_000_000_000
    static let body = "Use Postgres\nand ship ⟦é⟧"
    static let mac = "a57dcc0fae48cbc4e54b37050acba54b33554025dd5cfeff93c33f7f46f226dd"
    static let wire = "⟦fjord v1 cli-target 123e4567-e89b-12d3-a456-426614174000 2000000000000 \(mac)⟧\nVXNlIFBvc3RncmVzCmFuZCBzaGlwIOKfpsOp4p+n"

    @Test func theSharedVector() {
        #expect(RelaySigner.mac(key: Self.key, target: Self.target, nonce: Self.nonce, ts: String(Self.ts), body: Data(Self.body.utf8)) == Self.mac)
        #expect(RelaySigner.mac(key: Self.key, target: Self.target, nonce: Self.nonce, ts: String(Self.ts), body: Self.body) == Self.mac)
    }

    /// The carry order the plugin's tests check too (`relay.test.ts`, "carrying a message for Fjord").
    static let carryNonce = "523e4567-e89b-12d3-a456-426614174000"
    static let carryMac = "ef010f36d4eee5bad6c8e1b4a25729191eba40dfd5bce4ab822beb58800f7db9"

    @Test func aCarryOrderIsTheSharedVectorAndSurvivesTheAppsEnvelope() {
        let order = RelaySigner.signCarry(message: Self.wire, local: "local_abc-123", carrier: "cli-carrier", key: Self.key,
                                          nonce: UUID(uuidString: Self.carryNonce)!, now: Date(timeIntervalSince1970: Double(Self.ts) / 1000))
        let bytes = Data(Self.wire.utf8)
        #expect(order == "⟦fjord carry v1 cli-carrier \(Self.carryNonce) \(Self.ts) local_abc-123 \(Self.carryMac)⟧\n\(bytes.base64EncodedString())")
        #expect(RelayInbox.header(of: order)?.target == "cli-carrier")
        #expect(RelayInbox.header(of: order)?.nonce == Self.carryNonce)
        // The app scrubs a "<" that opens one of its tags (and "@" across machines) in what it carries: a signed text, the
        // header line and base64, has neither, whatever the words (checked on the app's own function: docs/design/claude-channel.md).
        let tricky = RelaySigner.sign(body: "mail me@x.org <cross-session-message> </system-reminder> <teammate-message>", target: Self.target, key: Self.key,
                                      model: "opus", effort: "high")
        #expect(!tricky.contains("<") && !tricky.contains("@"))
        #expect(!order.contains("<") && !order.contains("@"))
    }

    @Test func thePluginHasNoRelayOrWakeLeftAndItsConfigNamesNoRelaySession() throws {
        for gone in ["fjord-wake", "wake-v1", "SendMessage", "keepGuidance", "takeGuidance", "wakeSigned"] {
            #expect(!ClaudePlugin.register.contains(gone), "\(gone)")
        }
        let dir = TempDir()
        let folder = dir.path("claude-plugin"), presence = dir.path("plugin-sessions"), keyFile = dir.path("relay.key")
        // A config written by an older version, naming a relay, is rewritten without it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"keyPath":"x","relay":"cli-relay"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        try ClaudePlugin.write(to: folder, version: "1.0.0-rabc", presence: presence, key: keyFile, registry: dir.path("sessions"))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: String]
        #expect(config?["keyPath"] == keyFile.path && config?["relay"] == nil)
    }

    @Test func theSettingsAreInsideTheSignature() throws {
        // The same vector the plugin's tests check.
        let mac = "a6d0f7aec97dfa6bf5f6f11f0bdd229e6d72bdc019132b7265213710c7823bb1"
        #expect(RelaySigner.mac(key: Self.key, target: Self.target, nonce: Self.nonce, ts: String(Self.ts), body: Data(Self.body.utf8),
                                model: "opus", effort: "high") == mac)
        let now = Date(timeIntervalSince1970: Double(Self.ts) / 1000)
        let signed = RelaySigner.sign(body: Self.body, target: Self.target, key: Self.key, nonce: UUID(uuidString: Self.nonce)!, now: now,
                                      model: "opus", effort: "high")
        #expect(signed == "⟦fjord v2 cli-target \(Self.nonce) \(Self.ts) opus high \(mac)⟧\nVXNlIFBvc3RncmVzCmFuZCBzaGlwIOKfpsOp4p+n")
        // An absent one is a dash, and still signed: changing it changes the MAC.
        let effortOnly = RelaySigner.sign(body: "x", target: "t", key: Self.key, nonce: UUID(uuidString: Self.nonce)!, now: now, effort: "low")
        #expect(effortOnly.hasPrefix("⟦fjord v2 t \(Self.nonce) \(Self.ts) - low "))
        let modelOnly = RelaySigner.sign(body: "x", target: "t", key: Self.key, nonce: UUID(uuidString: Self.nonce)!, now: now, model: "low")
        #expect(effortOnly.suffix(80) != modelOnly.suffix(80))
        // No settings: the v1 text every plugin reads.
        #expect(RelaySigner.sign(body: Self.body, target: Self.target, key: Self.key, nonce: UUID(uuidString: Self.nonce)!, now: now) == Self.wire)
        // The inbox reads either header.
        #expect(RelayInbox.header(of: signed)?.nonce == Self.nonce && RelayInbox.header(of: signed)?.target == "cli-target")
    }

    @Test func theSettingsAreAllowlistedAndParsedFromWords() {
        #expect(SessionSettings(model: "gpt", effort: "--x") == nil)
        #expect(SessionSettings(model: "sonnet[1m]", effort: "bogus") == SessionSettings(model: "sonnet[1m]", effort: nil))
        #expect(SessionSettings(model: "claude-opus-4-5", effort: "xhigh")?.effort == "xhigh")
        #expect(SessionSettings(model: "claude-x; rm", effort: nil) == nil)
        #expect(SessionSettings.parse("@lookout fix the bug, with opus, high effort") == SessionSettings(model: "opus", effort: "high"))
        #expect(SessionSettings.parse("start a new session using Sonnet") == SessionSettings(model: "sonnet", effort: nil))
        #expect(SessionSettings.parse("do it, with xhigh effort") == SessionSettings(model: nil, effort: "xhigh"))
        #expect(SessionSettings.parse("start a session, effort max: fix it") == SessionSettings(model: nil, effort: "max"))
        #expect(SessionSettings.parse("write about opus the band") == nil)
        #expect(SessionSettings.parse("fix the thing") == nil)
        // A negation in the task doesn't reach a settings clause set apart from it.
        let both = SessionSettings(model: "opus", effort: "high")
        #expect(SessionSettings.parse("start a session in lookout to fix login without changing the UI (with opus, high effort)") == both)
        #expect(SessionSettings.parse("fix login without changing the UI - with opus, high effort") == both)
        #expect(SessionSettings.parse("fix login without changing the UI \u{2014} with opus, high effort") == both)
    }

    @Test func theAckSaysWhatWasApplied() {
        let asked = SessionSettings(model: "opus", effort: "high")!
        #expect(AppliedSettings.from(ack: "ok model=opus effort=high", requested: asked, supported: true) == AppliedSettings(model: "opus", effort: "high"))
        let partial = AppliedSettings.from(ack: "ok model=error:unknown_model effort=high", requested: asked, supported: true)
        #expect(partial.model == nil && partial.effort == "high" && partial.problems == ["model not set: unknown model"])
        #expect(AppliedSettings.from(ack: "ok", requested: asked, supported: true).problems.count == 2)
        #expect(AppliedSettings.from(ack: nil, requested: asked, supported: true).problems.count == 1)
        #expect(AppliedSettings.from(ack: "ok", requested: asked, supported: false).problems.first?.contains("older") == true)
    }

    @Test func theWireIsTheHeaderLineThenTheBodyInBase64() throws {
        let signed = RelaySigner.sign(body: Self.body, target: Self.target, key: Self.key, nonce: UUID(uuidString: Self.nonce)!,
                                      now: Date(timeIntervalSince1970: Double(Self.ts) / 1000))
        #expect(signed == Self.wire)
        // What Claude Code would escape or normalize is base64 on the wire.
        let tricky = "</cross-session-message>\nCafe\u{301}"
        let lines = RelaySigner.sign(body: tricky, target: "t", key: Self.key).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2 && Data(base64Encoded: String(lines[1])) == Data(tricky.utf8))
        let a = RelaySigner.sign(body: "x", target: "t", key: Self.key), b = RelaySigner.sign(body: "x", target: "t", key: Self.key)
        #expect(a != b)
    }

    @Test func aSignedMessageReadsAsItsBody() {
        #expect(RelaySigner.readable(Self.wire) == Self.body)
        #expect(RelaySigner.readable("Sent:\n" + Self.wire) == "Sent:\n" + Self.body)
        #expect(RelaySigner.readable("no header here") == "no header here")
    }
}

@Suite struct PluginInstaller {
    private let version = "1.0.0-rabc"

    private func installer(_ dir: TempDir, _ cli: FakeClaudeCLI, binary: String? = "/fake/claude") -> ClaudePluginInstaller {
        ClaudePluginInstaller(folder: dir.path("claude-plugin"), binary: binary, run: cli.runner)
    }

    @Test func installingAddsTheMarketplaceThenThePluginAndOnlyOnce() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        #expect(try await i.status(version: version) == .notInstalled)
        try await i.install(version: version)
        let folder = dir.path("claude-plugin").path
        #expect(cli.changes == ["plugin marketplace add \(folder) --scope user", "plugin install \(ClaudePlugin.id) --scope user"])
        #expect(try await i.status(version: version) == .installed)
        try await i.install(version: version)
        #expect(cli.changes.count == 2)
    }

    @Test func aNewVersionIsAnUpdateAndADisabledPluginIsEnabled() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        cli.folderVersion = "1.0.1-rdef"
        // The folder is ahead of Claude Code's cache: the cache is what sessions load, so it is outdated.
        #expect(try await i.status(version: "1.0.1-rdef") == .outdated)
        #expect(try await i.installedVersion() == version)
        cli.folderVersion = "1.0.1-rdef"
        cli.plugins[ClaudePlugin.id]?.enabled = false
        #expect(try await i.status(version: "1.0.1-rdef") == .outdated)
        try await i.install(version: "1.0.1-rdef")
        #expect(Array(cli.changes.suffix(1)) == ["plugin enable \(ClaudePlugin.id) --scope user"])
        #expect(try await i.status(version: "1.0.1-rdef") == .installed)
    }

    @Test func aStaleCacheIsUpdatedAndVerified() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = "0.9.2-rold"
        let i = installer(dir, cli)
        try await i.install(version: "0.9.2-rold")
        cli.folderVersion = "1.0.0-rnew"
        #expect(try await i.status(version: "1.0.0-rnew") == .outdated)
        try await i.install(version: "1.0.0-rnew")
        #expect(Array(cli.changes.suffix(1)) == ["plugin update \(ClaudePlugin.id) --scope user"])
        #expect(try await i.installedVersion() == "1.0.0-rnew")
        #expect(try await i.status(version: "1.0.0-rnew") == .installed)
    }

    @Test func anUpToDateCacheChangesNothing() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        let before = cli.changes
        try await i.install(version: version)
        #expect(cli.changes == before)
        #expect(try await i.status(version: version) == .installed)
    }

    @Test func anUpdateThatLeavesTheCacheStaleFails() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        cli.folderVersion = "1.0.1-rdef"
        cli.updateRefreshes = false
        await #expect(throws: ClaudePluginInstaller.Failure.self) { try await i.install(version: "1.0.1-rdef") }
    }

    @Test func aMovedFolderIsInstalledAfresh() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        cli.marketplaces[ClaudePlugin.name] = "/Old/Fjord/claude-plugin"
        cli.plugins[ClaudePlugin.id] = ("/Old/Fjord/claude-plugin", version, true)
        let i = installer(dir, cli)
        #expect(try await i.status(version: version) == .outdated)
        try await i.install(version: version)
        let folder = dir.path("claude-plugin").path
        #expect(cli.changes == ["plugin uninstall \(ClaudePlugin.id) --scope user", "plugin marketplace remove \(ClaudePlugin.name)",
                                "plugin marketplace add \(folder) --scope user", "plugin install \(ClaudePlugin.id) --scope user"])
    }

    @Test func uninstallingTakesOutOnlyWhatIsThere() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        try await i.uninstall()
        #expect(Array(cli.changes.suffix(2)) == ["plugin uninstall \(ClaudePlugin.id) --scope user", "plugin marketplace remove \(ClaudePlugin.name)"])
        try await i.uninstall()
        #expect(cli.changes.count == 4)
    }

    @Test func theCLIsOwnWordsSayWhyItFailed() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.failing = "plugin install"
        await #expect(throws: ClaudePluginInstaller.Failure(message: "`claude plugin install \(ClaudePlugin.id) --scope user` failed: boom: plugin install")) {
            try await installer(dir, cli).install(version: version)
        }
        let none = installer(dir, cli, binary: nil)
        #expect(try await none.status(version: version) == .noClaudeCode)
        await #expect(throws: ClaudePluginInstaller.Failure.self) { try await none.install(version: version) }
    }
}

/// The real runner (`OneShot`), on scripts of the test's own in a temporary folder.
@Suite struct PluginRunner {
    private func script(_ dir: TempDir, _ body: String) throws -> String {
        let url = dir.path("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url.path
    }

    @Test func itAnswersWithTheProgramsOutputInACleanEnvironment() async throws {
        let dir = TempDir()
        // Something of Fjord's own environment that must not reach the CLI.
        setenv("FJORD_TEST_LEAK", "secret", 1)
        defer { unsetenv("FJORD_TEST_LEAK") }
        let exe = try script(dir, "echo \"$1 [$FJORD_TEST_LEAK]\"")
        let out = try await ClaudePluginInstaller.oneShotRunner(runs: PluginRuns())(exe, ["hi"])
        #expect(out.status == 0 && out.out == "hi []\n")
    }

    @Test func aProgramThatIgnoresSIGTERMIsKilledAtTheDeadline() async throws {
        let dir = TempDir()
        let exe = try script(dir, "trap '' TERM\nsleep 30")
        let started = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            _ = try await ClaudePluginInstaller.oneShotRunner(timeout: 0.5, runs: PluginRuns())(exe, [])
        }
        // Killed at its deadline, not left to run its 30 s (a watchdog bound, generous for a slow runner).
        #expect(Date().timeIntervalSince(started) < 25)
    }

    @Test func aChildHoldingStdoutDoesNotHoldTheAnswer() async throws {
        let dir = TempDir()
        let exe = try script(dir, "sleep 30 &\necho done")
        let started = Date()
        let out = try await ClaudePluginInstaller.oneShotRunner(timeout: 60, runs: PluginRuns())(exe, [])
        // Not held for the child's 30 s (a watchdog bound, generous for a slow runner).
        #expect(out.status == 0 && out.out == "done\n" && Date().timeIntervalSince(started) < 25)
    }

    @Test func quittingStopsTheRunsAndRefusesNewOnes() async throws {
        let dir = TempDir()
        let exe = try script(dir, "trap '' TERM\nsleep 30")
        let runs = PluginRuns()
        let run = Task { try await ClaudePluginInstaller.oneShotRunner(timeout: 60, runs: runs)(exe, []) }
        await waitUntilAnywhere { runs.active > 0 }
        runs.shutdown(within: 60)
        #expect(runs.active == 0)
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        await #expect(throws: CancellationError.self) { _ = try await ClaudePluginInstaller.oneShotRunner(runs: runs)(exe, []) }
    }
}

/// A flag set from another thread.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ v: Bool) { lock.withLock { stored = v } }
}

@MainActor
@Suite struct PluginSwitch {
    private func store(_ dir: TempDir, _ cli: FakeClaudeCLI, version: String = "1.0.0") -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        s.routerPluginRunner = cli.runner
        s.routerClaudeBinary = { "/fake/claude" }
        s.routerAppVersion = version
        return s
    }

    @Test func theRouterSwitchInstallsThePluginAndRemovesIt() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .installed && s.routerPluginError == nil)
        let paths = try #require(s.routerPaths)
        let key = try #require(ClaudePlugin.key(at: paths.relayKey))
        // The switch read the key off the main thread; signing only checks the file is the same.
        #expect(s.relayKeyCache?.key == key)
        let signed = try #require(s.signRelay(body: "hello", target: "cli-a"))
        let lines = signed.split(separator: "\n")
        let header = lines[0].dropFirst().dropLast().split(separator: " ").map(String.init)
        #expect(header.count == 6 && header[2] == "cli-a" && Data(base64Encoded: String(lines[1])) == Data("hello".utf8))
        #expect(RelaySigner.mac(key: key, target: "cli-a", nonce: header[3], ts: header[4], body: "hello") == header[5])
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        #expect(s.sessionsWithPlugin() == ["cli-a"])

        s.setRouterEnabled(false)
        #expect(s.signRelay(body: "hello", target: "cli-a") == nil && s.relayKeyCache == nil)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .notInstalled && cli.marketplaces.isEmpty)
    }

    @Test func switchingOffRevokesTheKeyEvenWhenTheUninstallFails() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        cli.failing = "plugin uninstall"
        s.setRouterEnabled(false)
        // Gone at once, before the CLI is even asked.
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil)
        await s.routerHookWork?.value
        #expect(s.routerPluginError?.contains("boom: plugin uninstall") == true)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && s.signRelay(body: "x", target: "cli-a") == nil)
    }

    @Test func aSwitchOnStillUnderWayCantMakeTheKeyAfterTheSwitchOff() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The CLI hangs before anything (its first list), so the switch-on hasn't reached the key yet when it's switched off.
        cli.holding = "plugin list"
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await waitUntil { cli.isHolding }
        let paths = try #require(s.routerPaths)
        s.setRouterEnabled(false)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil)
        cli.release()
        await s.routerHookWork?.value
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && s.relayKeyCache == nil)
        #expect(s.routerPluginStatus == .notInstalled)
    }

    @Test func aSwitchOnSupersededBeforeItRunsDoesNothing() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The form hook's work runs first; the plugin's switch-on is queued behind it when the Router goes off again.
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && cli.marketplaces.isEmpty && cli.plugins.isEmpty)
    }

    @Test func atLaunchAMissingOrOutdatedPluginIsInstalled() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The Router was on before Fjord had a plugin: launch installs it.
        let migrated = store(dir, cli)
        migrated.router.enabled = true
        migrated.startRouter()
        await migrated.routerHookWork?.value
        #expect(migrated.routerPluginStatus == .installed)
        #expect(cli.changes.contains("plugin install \(ClaudePlugin.id) --scope user"))
        let installs = cli.changes.count
        // Up to date at the next launch: nothing to do.
        let same = store(dir, cli)
        same.router.enabled = true
        same.startRouter()
        await same.routerHookWork?.value
        #expect(cli.changes.count == installs && same.routerPluginStatus == .installed)
        // An update of Fjord: the folder holds the new version, Claude Code is brought to it.
        let updated = store(dir, cli, version: "1.1.0")
        updated.router.enabled = true
        updated.startRouter()
        await updated.routerHookWork?.value
        #expect(cli.changes.last == "plugin update \(ClaudePlugin.id) --scope user")
        let manifest = try String(contentsOf: dir.path("support/claude-plugin/.claude-plugin/plugin.json"), encoding: .utf8)
        #expect(manifest.contains(ClaudePlugin.version(app: "1.1.0")))
    }

    @Test func aSessionThatUnloadedThePluginWhileTheRouterWasOffDoesNotCount() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        let stale = try Data(contentsOf: paths.pluginSessions.appendingPathComponent("cli-a"))
        #expect(s.sessionsWithPlugin() == ["cli-a"])
        // Off: the key and the presence files go at once.
        s.setRouterEnabled(false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.pluginSessions.path).isEmpty)
        await s.routerHookWork?.value
        // On again (a new key); the session's old file, same process and id, under the old key, doesn't count.
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        try stale.write(to: paths.pluginSessions.appendingPathComponent("cli-a"))
        #expect(s.sessionsWithPlugin().isEmpty)
        // Its plugin, still loaded, says so again under the new key.
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        #expect(s.sessionsWithPlugin() == ["cli-a"])
    }

    @Test func theKeyIsReadOffTheMainThreadAndAChangedOneIsReadAgain() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        #expect(s.signRelay(body: "x", target: "t") != nil)
        // The file changed: not signed with what was read before; read again in the background.
        try PrivateFile.write(Data(("22" + String(repeating: "0", count: 62) + "\n").utf8), to: paths.relayKey)
        #expect(s.signRelay(body: "x", target: "t") == nil)
        #expect(await s.reloadRelayKey())
        #expect(s.relayKeyCache?.key.hasPrefix("22") == true && s.signRelay(body: "x", target: "t") != nil)
        // A read that a switch overtakes is dropped.
        s.setRouterEnabled(false)
        #expect(await s.reloadRelayKey() == false && s.relayKeyCache == nil)
    }

    @Test func claudeCodeIsLookedForOffTheMainThread() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        let onMain = OSAllocatedUnfairLockBox()
        s.routerClaudeBinary = { onMain.set(Thread.isMainThread); return "/fake/claude" }
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(onMain.value == false && s.routerPluginStatus == .installed)
    }

    @Test func aFailureIsShownWithTheCLIsReason() async {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.failing = "plugin marketplace add"
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .notInstalled)
        #expect(s.routerPluginError?.contains("boom: plugin marketplace add") == true)
    }
}

/// The direct way: a signed text written to a session's inbox, answered by the plugin's ack.
@Suite struct RelayInboxTests {
    private let key = "k1"

    private func presence(_ dir: TempDir, _ cli: String, capabilities: [String]?) throws {
        var obj: [String: Any] = ["state": "live", "sessionId": cli, "pid": 100, "startedAt": 5, "keyId": ClaudePlugin.keyID(of: key),
                                  "activation": "a", "renewedAt": Int64(ClaudePlugin.leaseNow.timeIntervalSince1970 * 1000)]
        if let capabilities { obj["capabilities"] = capabilities }
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.path(cli))
    }

    /// What the plugin does, in a task: waits for the message (until it is there, with the suite's watchdog, not a guess
    /// at how long a loaded machine takes), answers.
    private func plugin(_ inbox: RelayInbox, session: String, nonce: String, answer: String?) -> Task<String?, Never> {
        Task.detached {
            let folder = inbox.folder(for: session)
            var watchdog = Watchdog()
            while !watchdog.expired() {
                if let text = try? String(contentsOf: folder.appendingPathComponent("\(nonce).msg"), encoding: .utf8) {
                    if let answer { try? Data((answer + "\n").utf8).write(to: folder.appendingPathComponent("\(nonce).ack"), options: .atomic) }
                    return text
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    @Test func settingsAreOnlyForPluginsThatSaySo() throws {
        let dir = TempDir()
        try presence(dir, "cli-v2", capabilities: ["inbox-v1", "settings-v1"])
        try presence(dir, "cli-v1", capabilities: ["inbox-v1"])
        let reg: [Int32: [ClaudePeers.Registered]] = [100: ["cli-v2", "cli-v1"].map { ClaudePeers.Registered(sessionID: $0, startedAt: 5) }]
        let id = ClaudePlugin.keyID(of: key)
        #expect(ClaudePlugin.sessions(with: ClaudePlugin.settingsCapability, in: dir.url, registry: reg, keyID: id) { _ in true } == ["cli-v2"])
        #expect(ClaudePlugin.inboxSessions(in: dir.url, registry: reg, keyID: id) { _ in true } == ["cli-v1", "cli-v2"])
    }

    /// The shape of a real presence file (a desktop session, the CLI id as file name and `sessionId`; Claude Code's registry
    /// has the same id with the desktop one in `hostSessionId`), as `live` must read it.
    @Test func aRealDesktopSessionPresenceIsLiveWithItsCapabilities() throws {
        let dir = TempDir()
        let cli = "5e2e5d8c-a1af-4b40-b288-3657cdb175cf"
        let json = """
        {"state":"live","sessionId":"\(cli)","pid":18278,"startedAt":1791657930802,"keyId":"\(ClaudePlugin.keyID(of: key))",\
        "renewedAt":\(Int64(ClaudePlugin.leaseNow.timeIntervalSince1970 * 1000)),"activation":"5fe4adb1-2fb4-44ff-9d77-f7e32f17b64d",\
        "capabilities":["inbox-v1","settings-v1"]}
        """
        try Data(json.utf8).write(to: dir.path(cli))
        let reg: [Int32: [ClaudePeers.Registered]] = [18278: [.init(sessionID: cli, startedAt: 1791657930802)]]
        let id = ClaudePlugin.keyID(of: key)
        #expect(ClaudePlugin.inboxSessions(in: dir.url, registry: reg, keyID: id) { _ in true } == [cli])
        #expect(ClaudePlugin.sessions(with: ClaudePlugin.settingsCapability, in: dir.url, registry: reg, keyID: id) { _ in true } == [cli])
        // A peer's name is not a session id: it finds nothing.
        #expect(!ClaudePlugin.inboxSessions(in: dir.url, registry: reg, keyID: id) { _ in true }.contains("reply with exactly the word pong"))
    }

    @Test func aSignedTextNamesTheSessionItsInboxIsFoundBy() {
        let cli = "5e2e5d8c-a1af-4b40-b288-3657cdb175cf"
        #expect(RelayInbox.header(of: RelaySigner.sign(body: "hi", target: cli, key: key))?.target == cli)
    }

    @Test func onlyAPluginThatSaysSoIsReachedDirectly() throws {
        let dir = TempDir()
        try presence(dir, "cli-new", capabilities: ["inbox-v1"])
        try presence(dir, "cli-old", capabilities: nil)
        try presence(dir, "cli-other", capabilities: ["something-else"])
        // One process per session, as the registry has it.
        let reg: [Int32: [ClaudePeers.Registered]] = [100: ["cli-new", "cli-old", "cli-other"].map { ClaudePeers.Registered(sessionID: $0, startedAt: 5) }]
        let id = ClaudePlugin.keyID(of: key)
        #expect(ClaudePlugin.inboxSessions(in: dir.url, registry: reg, keyID: id) { _ in true } == ["cli-new"])
        #expect(ClaudePlugin.sessions(in: dir.url, registry: reg, keyID: id) { _ in true } == ["cli-new", "cli-old", "cli-other"])
        // Another key: none.
        #expect(ClaudePlugin.inboxSessions(in: dir.url, registry: reg, keyID: "other") { _ in true }.isEmpty)
    }

    @Test func theSignedTextIsWrittenExactlyAndAnOkAckCompletes() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = waitWatchdog  // a watchdog: the fake plugin answers as soon as it sees the file
        let signed = RelaySigner.sign(body: "Use Postgres\nand ship ⟦é⟧", target: "cli-a", key: key)
        let nonce = try #require(RelayInbox.header(of: signed)?.nonce)
        let fake = plugin(inbox, session: "cli-a", nonce: nonce, answer: "ok")
        try await inbox.deliver(signed, to: "cli-a")
        #expect(await fake.value == signed)
        // Both files are gone after; the folder is private.
        let folder = inbox.folder(for: "cli-a")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(nonce).msg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(nonce).ack").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func aRefusalIsReportedAndNotRetriedElsewhere() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = waitWatchdog  // a watchdog: the fake plugin answers as soon as it sees the file
        let signed = RelaySigner.sign(body: "hi", target: "cli-a", key: key)
        let nonce = try #require(RelayInbox.header(of: signed)?.nonce)
        let fake = plugin(inbox, session: "cli-a", nonce: nonce, answer: "refused: bad signature")
        await #expect(throws: RelayInbox.Failure.refused("bad signature")) { try await inbox.deliver(signed, to: "cli-a") }
        _ = await fake.value
        #expect(!FileManager.default.fileExists(atPath: inbox.folder(for: "cli-a").appendingPathComponent("\(nonce).msg").path))
    }

    @Test func noAnswerWithdrawsTheMessage() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = 0.2
        let signed = RelaySigner.sign(body: "hi", target: "cli-a", key: key)
        let nonce = try #require(RelayInbox.header(of: signed)?.nonce)
        await #expect(throws: RelayInbox.Failure.unanswered) { try await inbox.deliver(signed, to: "cli-a") }
        #expect(!FileManager.default.fileExists(atPath: inbox.folder(for: "cli-a").appendingPathComponent("\(nonce).msg").path))
    }

    @Test func aTextForAnotherSessionOrWithoutAHeaderIsNeverWritten() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let signed = RelaySigner.sign(body: "hi", target: "cli-a", key: key)
        await #expect(throws: (any Error).self) { try await inbox.deliver(signed, to: "cli-b") }
        await #expect(throws: (any Error).self) { try await inbox.deliver("plain words", to: "cli-a") }
        // A session id that is a path is not a folder.
        let sneaky = RelaySigner.sign(body: "hi", target: "../x", key: key)
        await #expect(throws: (any Error).self) { try await inbox.deliver(sneaky, to: "../x") }
        #expect(!FileManager.default.fileExists(atPath: inbox.root.path))
    }

    @MainActor
    @Test func theMessageIsWrittenAsideAndPutWhereThePluginLooksOnlyAsTheGateLetsItGo() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = 0.1
        let folder = inbox.folder(for: "cli-a")
        let signed = RelaySigner.sign(body: "hi", target: "cli-a", key: key)
        var seen: [String] = []
        await #expect(throws: RelayInbox.Failure.refused("Stopped")) {
            try await inbox.deliver(signed, to: "cli-a") {
                seen = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return "Stopped"
            }
        }
        // Written already when the gate was asked, but not as a message; refused, nothing is left.
        #expect(seen.count == 1 && seen[0].hasSuffix(".tmp"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // Let through: it is put in place, as the plugin reads it.
        let nonce = try #require(RelayInbox.header(of: signed)?.nonce)
        inbox.timeout = waitWatchdog  // a watchdog: the fake plugin answers as soon as it sees the file
        let fake = plugin(inbox, session: "cli-a", nonce: nonce, answer: "ok")
        try await inbox.deliver(signed, to: "cli-a") { nil }
        #expect(await fake.value == signed)
    }

    @Test func leftoversAreSweptOnTheNextDelivery() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = 0.1
        let folder = inbox.folder(for: "cli-a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.ack"), fresh = folder.appendingPathComponent("fresh.ack")
        try Data("ok".utf8).write(to: old)
        try Data("ok".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        _ = try? await inbox.deliver(RelaySigner.sign(body: "hi", target: "cli-a", key: key), to: "cli-a")
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
    }
}
