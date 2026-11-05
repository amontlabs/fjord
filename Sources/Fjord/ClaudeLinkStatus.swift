import SwiftUI

/// The Claude link's state as a dot and a line ("Synced with Claude", "Claude's sessions not found"…).
struct ClaudeLinkStatus: View {
    let store: Store

    var body: some View {
        let (color, text, detail): (Color, String, String) = switch store.claudeLink {
        case .ok where Claude.isRunning: (Theme.green, "Synced with Claude", "Updates as the Claude app writes its session files")
        case .ok, .off: (Theme.tertiary, "Claude isn't running", "Sessions update again when the app is open")
        case .missing: (Theme.red, "Claude's sessions not found", "Open the Claude desktop app once")
        case .unreadable: (Theme.red, "Can't read Claude's sessions", "The app's session format changed")
        }
        Circle().fill(color).frame(width: 6, height: 6)
        Text(text).tip(text, detail)
    }
}
