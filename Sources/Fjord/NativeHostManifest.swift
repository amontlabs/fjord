import Foundation

/// Registers `Fjord --native-host` with Chrome: the host manifest Chrome reads, and the tiny launcher it points at (Chrome
/// runs the manifest's `path` with the caller's origin as an argument; the launcher drops it and execs the app's binary).
enum NativeHostManifest {
    /// The launcher: in Fjord's folder, so it is the app's to rewrite.
    static func launcherURL(support: URL = AppIdentity.supportDirectory()) -> URL {
        support.appendingPathComponent("native-host", isDirectory: false)
    }

    static func manifestURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(NativeHost.name).json")
    }

    static func launcherScript(executable: String) -> String {
        "#!/bin/sh\nexec \"\(executable)\" --native-host\n"
    }

    static func manifestJSON(launcher: URL) -> Data {
        let manifest: [String: Any] = [
            "name": NativeHost.name,
            "description": "Fjord: relays the claude.ai page's events to the Router.",
            "path": launcher.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(NativeHost.extensionID)/"],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Off until the Router's delivery engine listens on `NativeHost.socketPath()`: until then the Python POC owns the host name,
    /// and an installed app taking it would leave the extension relaying to a socket nobody serves.
    static let enabled = false

    /// Only from the app bundle: a debug binary or a test run must not point Chrome at itself.
    static func isBundle(_ bundlePath: String = Bundle.main.bundlePath) -> Bool { bundlePath.hasSuffix(".app") }

    /// Writes the launcher and the manifest, each only when its content differs. Returns whether it wrote anything.
    @discardableResult
    static func install(bundlePath: String = Bundle.main.bundlePath, executable: String? = Bundle.main.executablePath,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        support: URL = AppIdentity.supportDirectory()) -> Bool {
        guard isBundle(bundlePath), let executable else { return false }
        let launcher = launcherURL(support: support)
        var wrote = write(Data(launcherScript(executable: executable).utf8), to: launcher, mode: 0o755)
        wrote = write(manifestJSON(launcher: launcher), to: manifestURL(home: home), mode: 0o644) || wrote
        return wrote
    }

    private static func write(_ data: Data, to url: URL, mode: Int) -> Bool {
        if let current = try? Data(contentsOf: url), current == data { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
