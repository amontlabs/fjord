import Foundation

/// Claude's Application Support folder, which only the one-time carry-over of the desktop app's icons and labels reads.
enum Claude {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude", isDirectory: true)
}
