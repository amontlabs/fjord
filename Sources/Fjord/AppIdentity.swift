import Foundation

/// Which Fjord this process is, for everything that two running Fjords would otherwise share: the support folder (state,
/// forms, plugin, relay key). The installed app keeps `Fjord`; a debug build, or any run started with a test or E2E flag or
/// environment, gets its own so it can never overwrite the installed app's settings.
enum AppIdentity {
    /// Environment that marks a run as development even in a release build.
    static let devEnvironmentKeys = ["FJORD_E2E", "FJORD_SUPPORT_FOLDER"]

    static func isDevelopment(environment: [String: String] = ProcessInfo.processInfo.environment,
                              arguments: [String] = CommandLine.arguments) -> Bool {
        #if DEBUG
        return true
        #else
        if devEnvironmentKeys.contains(where: { environment[$0] != nil }) { return true }
        return arguments.contains { $0 == "--e2e" || $0.hasPrefix("--e2e=") }
        #endif
    }

    /// The folder in Application Support: `Fjord` for the installed app, `Fjord Dev` otherwise (or `FJORD_SUPPORT_FOLDER`).
    static func supportFolderName(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  arguments: [String] = CommandLine.arguments,
                                  development: Bool? = nil) -> String {
        if let custom = environment["FJORD_SUPPORT_FOLDER"], !custom.isEmpty, !custom.contains("/") { return custom }
        let dev = development ?? isDevelopment(environment: environment, arguments: arguments)
        return dev ? "Fjord Dev" : "Fjord"
    }

    static var supportFolderName: String { supportFolderName() }

    /// `~/Library/Application Support/<folder>`.
    static func supportDirectory(base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                                 folder: String = supportFolderName) -> URL {
        base.appendingPathComponent(folder, isDirectory: true)
    }
}
