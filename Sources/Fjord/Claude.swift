import AppKit
import Foundation

/// The Claude desktop app, where Fjord still reaches it: its bundle (the brief's look, the Courier).
enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude", isDirectory: true)
}
