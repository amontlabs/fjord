import Foundation
import Testing
@testable import Fjord

/// The form hook in Claude Code's settings, in a `~/.claude` of the test's own.
@Suite struct HookInstaller {
    private let exe = "/Applications/Fjord.app/Contents/MacOS/Fjord"

    private func settings(_ dir: TempDir) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.path("settings.json"))) as? [String: Any])
    }

    private func ours(_ installer: FormHookInstaller) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": installer.command, "timeout": 86400]]]
    }

    @Test func anOlderFjordsQuestionsOnlyHookIsOutdatedAndMovesToTheNewMatcher() throws {
        let dir = TempDir()
        let installer = FormHookInstaller(claudeDir: dir.url)
        try installer.install(executable: exe)
        // What Fjord before plans wrote: the same command, for questions only, in an entry shared with a
        // hook of yours.
        let old: [String: Any] = ["hooks": ["PermissionRequest": [
            ["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": "/x/log.sh"],
                                                     ["type": "command", "command": installer.command, "timeout": 86400]]],
        ]]]
        try JSONSerialization.data(withJSONObject: old).write(to: dir.path("settings.json"))
        #expect(installer.status(executable: exe) == .outdated)
        try installer.install(executable: exe)
        let entries = try #require((try settings(dir)["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])
        let yours: [String: Any] = ["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": "/x/log.sh"]]]
        #expect(NSArray(array: entries).isEqual(to: [yours, ours(installer)]))
        #expect(installer.status(executable: exe) == .installed)
    }

    @Test func installingIntoNoSettingsMakesThemAndTheScript() throws {
        let dir = TempDir()
        let installer = FormHookInstaller(claudeDir: dir.url)
        #expect(installer.status(executable: exe) == .notInstalled)
        try installer.install(executable: exe)
        let root = try settings(dir)
        let entries = (root["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any]
        #expect(entries.map { NSArray(array: $0).isEqual(to: [ours(installer)]) } == true)
        let script = try String(contentsOf: installer.script, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n# Fjord's form hook"))
        #expect(script.contains("[ -x '\(exe)' ] || exit 0\nexec '\(exe)' --form-hook\n"))
        #expect(mode(installer.script) == 0o755)
        #expect(installer.status(executable: exe) == .installed)
        #expect(installer.status(executable: "/elsewhere/Fjord") == .outdated)
        // No file before: nothing to back up.
        #expect(!FileManager.default.fileExists(atPath: installer.backup.path))
    }

    @Test func everythingElseInTheSettingsIsKept() throws {
        let dir = TempDir()
        let original = """
        {"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}, "env": {"A": "1"}, "enabled": true, "ratio": 0.5,
         "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
                   "PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/guard.sh"}]}]}}
        """
        try Data(original.utf8).write(to: dir.path("settings.json"))
        let installer = FormHookInstaller(claudeDir: dir.url)
        try installer.install(executable: exe)
        let root = try settings(dir)
        #expect(root["model"] as? String == "opus" && root["enabled"] as? Bool == true && root["ratio"] as? Double == 0.5)
        #expect((root["permissions"] as? [String: [String]])?["allow"] == ["Bash(ls:*)"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [Any])?.count == 1)
        let entries = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        #expect(entries.count == 2 && entries[0]["matcher"] as? String == "Bash")
        // The file as it was is kept once, and only once.
        #expect(try String(contentsOf: installer.backup, encoding: .utf8) == original)
        try installer.install(executable: "/elsewhere/Fjord")
        #expect(try String(contentsOf: installer.backup, encoding: .utf8) == original)

        // Out again: exactly as it was, apart from the formatting.
        try installer.uninstall()
        let after = try settings(dir)
        let before = try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary)
        #expect(NSDictionary(dictionary: after).isEqual(before))
        #expect(!FileManager.default.fileExists(atPath: installer.script.path))
        #expect(installer.status(executable: exe) == .notInstalled)
    }

    @Test func installingTwiceAddsOneEntry() throws {
        let dir = TempDir()
        let installer = FormHookInstaller(claudeDir: dir.url)
        try installer.install(executable: exe)
        let first = try Data(contentsOf: dir.path("settings.json"))
        try installer.install(executable: exe)
        #expect(try Data(contentsOf: dir.path("settings.json")) == first)
        // Another executable rewrites the script, not the settings.
        try installer.install(executable: "/elsewhere/Fjord")
        #expect(try Data(contentsOf: dir.path("settings.json")) == first)
        #expect(installer.status(executable: "/elsewhere/Fjord") == .installed)
    }

    @Test func invalidSettingsAreRefusedAndLeftAlone() throws {
        let dir = TempDir()
        let broken = Data("{\"model\": \"opus\",, }".utf8)
        try broken.write(to: dir.path("settings.json"))
        let installer = FormHookInstaller(claudeDir: dir.url)
        #expect(throws: FormHookInstaller.Failure.invalidSettings(dir.path("settings.json").path)) {
            try installer.install(executable: exe)
        }
        #expect(try Data(contentsOf: dir.path("settings.json")) == broken)
        #expect(!FileManager.default.fileExists(atPath: installer.backup.path))
        #expect(throws: FormHookInstaller.Failure.self) { try installer.uninstall() }

        try Data("[1, 2]".utf8).write(to: dir.path("settings.json"))
        #expect(throws: FormHookInstaller.Failure.notAnObject(dir.path("settings.json").path)) {
            try installer.install(executable: exe)
        }
        let message = FormHookInstaller.Failure.invalidSettings("/x/settings.json").localizedDescription
        #expect(message.contains("/x/settings.json") && message.contains("valid JSON"))
    }

    @Test func uninstallingRemovesOnlyOursAndTheContainersItEmptied() throws {
        let dir = TempDir()
        let installer = FormHookInstaller(claudeDir: dir.url)
        // Ours shares an entry with someone else's hook.
        let shared: [String: Any] = ["hooks": ["PermissionRequest": [
            ["matcher": "*", "hooks": [["type": "command", "command": "/x/log.sh"],
                                                     ["type": "command", "command": installer.command]]],
        ]]]
        try JSONSerialization.data(withJSONObject: shared).write(to: dir.path("settings.json"))
        #expect(installer.status(executable: exe) == .notInstalled)  // No script yet.
        try installer.install(executable: exe)
        #expect(((try settings(dir)["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])?.count == 1)
        try installer.uninstall()
        let entries = (try settings(dir)["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        #expect((entries?.first?["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["/x/log.sh"])

        // Alone, its removal takes the empty containers with it.
        let solo = TempDir()
        try Data("{\"model\":\"opus\"}".utf8).write(to: solo.path("settings.json"))
        let other = FormHookInstaller(claudeDir: solo.url)
        try other.install(executable: exe)
        try other.uninstall()
        #expect(NSDictionary(dictionary: try settings(solo)).isEqual(["model": "opus"]))
        // Nothing of ours left: nothing written.
        let untouched = try Data(contentsOf: solo.path("settings.json"))
        try other.uninstall()
        #expect(try Data(contentsOf: solo.path("settings.json")) == untouched)
    }

    @Test func aSymlinkedSettingsFileStaysALink() throws {
        let dir = TempDir()
        let real = dir.path("dotfiles-settings.json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: real)
        let claude = dir.path("claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("settings.json"), withDestinationURL: real)
        let installer = FormHookInstaller(claudeDir: claude)
        try installer.install(executable: exe)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: claude.appendingPathComponent("settings.json").path)
        #expect(link == real.path)
        #expect(String(decoding: try Data(contentsOf: real), as: UTF8.self).contains("PermissionRequest"))
    }

    @Test func pathsWithSpacesAreQuoted() {
        let installer = FormHookInstaller(claudeDir: URL(fileURLWithPath: "/Users/a b/.claude"))
        #expect(installer.command == "'/Users/a b/.claude/hooks/\(FormHookInstaller.scriptName(development: AppIdentity.isDevelopment()))'")
        #expect(FormHookInstaller(claudeDir: URL(fileURLWithPath: "/Users/ab/.claude")).command == "/Users/ab/.claude/hooks/\(FormHookInstaller.scriptName(development: AppIdentity.isDevelopment()))")
        #expect(installer.scriptText(executable: "/A/it's/Fjord").contains("exec '/A/it'\\''s/Fjord' --form-hook"))
    }

    @Test func aWriteByClaudeCodeMeanwhileIsKept() throws {
        let dir = TempDir()
        let file = dir.path("settings.json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: file)
        var installer = FormHookInstaller(claudeDir: dir.url)
        var writes = 0
        installer.beforeReplace = {
            // Claude Code saves the file between Fjord's read and its write, once.
            guard writes == 0 else { return }
            writes += 1
            try! Data("{\"model\":\"sonnet\",\"theme\":\"dark\"}".utf8).write(to: file)
        }
        try installer.install(executable: exe)
        let root = try settings(dir)
        #expect(root["model"] as? String == "sonnet" && root["theme"] as? String == "dark")
        #expect(((root["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])?.count == 1)
        // The losing attempt's temporary file is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).allSatisfy { !$0.hasSuffix(".tmp") })

        // A file that never stops changing: Fjord gives up and leaves the last write alone.
        var busy = FormHookInstaller(claudeDir: dir.url)
        var n = 0
        busy.beforeReplace = {
            n += 1
            let ours = ["PermissionRequest": [["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": busy.command]]]]]
            try! JSONSerialization.data(withJSONObject: ["model": "m\(n)", "hooks": ours]).write(to: file)
        }
        #expect(throws: FormHookInstaller.Failure.keptChanging(file.path)) { try busy.uninstall() }
        #expect(n == FormHookInstaller.attempts)
        #expect(try settings(dir)["model"] as? String == "m\(n)" && settings(dir)["hooks"] != nil)
    }

    @Test func anEmptyOrUnreadableFileIsRefusedNotOverwritten() throws {
        let dir = TempDir()
        let file = dir.path("settings.json")
        let installer = FormHookInstaller(claudeDir: dir.url)
        for blank in ["", "  \n"] {
            try Data(blank.utf8).write(to: file)
            #expect(throws: FormHookInstaller.Failure.invalidSettings(file.path)) { try installer.install(executable: exe) }
            #expect(try Data(contentsOf: file) == Data(blank.utf8))
        }
        try Data("{}".utf8).write(to: file)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o644) }
        #expect(throws: FormHookInstaller.Failure.self) { try installer.install(executable: exe) }
        chmod(file.path, 0o644)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
        #expect(!FileManager.default.fileExists(atPath: installer.script.path))
        // A folder where the file should be.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: FormHookInstaller.Failure.self) { try installer.install(executable: exe) }
        #expect(installer.status(executable: exe) == .notInstalled)
    }

    @Test func hooksOfAnUnexpectedShapeAreRefusedNotReplaced() throws {
        let dir = TempDir()
        let file = dir.path("settings.json")
        let installer = FormHookInstaller(claudeDir: dir.url)
        let shapes = [("{\"hooks\":[1]}", "hooks"), ("{\"hooks\":null}", "hooks"),
                      ("{\"hooks\":{\"PermissionRequest\":{\"a\":1}}}", "hooks.PermissionRequest")]
        for (text, key) in shapes {
            try Data(text.utf8).write(to: file)
            #expect(throws: FormHookInstaller.Failure.incompatible(file.path, key)) { try installer.install(executable: exe) }
            #expect(try String(contentsOf: file, encoding: .utf8) == text)
            #expect(!FileManager.default.fileExists(atPath: installer.backup.path))
            // Nothing of ours can be in it: uninstalling leaves it too.
            try installer.uninstall()
            #expect(try String(contentsOf: file, encoding: .utf8) == text)
        }
    }
}
