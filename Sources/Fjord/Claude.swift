import AppKit
import Foundation

/// The Claude desktop app, where Fjord still reaches it: its bundle (the brief's look, the Courier) and its own links.
enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude", isDirectory: true)

    /// Opens the conversation in the app (its own link format, the one it hands out for sessions).
    static func open(_ id: String) {
        guard let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        Link.open(url)
    }
}
