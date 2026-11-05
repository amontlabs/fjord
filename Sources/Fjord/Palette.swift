import AppKit
import Carbon
import SwiftUI

// The ⌘K palette's shared vocabulary (docs/design/palette/DESIGN.md): what a row is, what it does, and what a source hands
// the palette. The sources (PaletteRouterSource, PaletteTriageSource, PalettePlacesSource) make items; the matcher
// (PaletteMatch.swift) ranks them; the model and views (PaletteModel.swift, PaletteView.swift) list and run them.

enum Palette {
    /// Opens and closes the palette, everywhere in the window. Fixed: the header's trigger shows it as a keycap badge.
    static let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: .command)
}

/// One thing the palette can list: a brief's thread, a session, an inbox item, a place, a setting, a command.
struct PaletteItem: Identifiable {
    enum Kind: String, CaseIterable {
        case thread, session, entry, project, category, computer, snippet, page, setting, command, send
    }

    /// Stable across opens, prefixed with the kind ("thread:<project>/<thread>", "session:<id>", "entry:<thing id>", "page:<token>",
    /// "setting:<anchor>.<row>", "command:<name>"): the usage store remembers picks by it.
    let id: String
    let kind: Kind
    /// What the row says and what the query is matched against first; matched letters are highlighted in it.
    var title: String
    /// The muted line after or under the title: project, repo#12, status, the page it lives on.
    var subtitle: String?
    /// More text the query may match (`#482`, `owner/repo#482`, a URL, a branch, a kind's label, a row's section),
    /// never shown.
    var keywords: [String] = []
    var icon: PaletteIcon
    var dot: PaletteDot?
    /// When it last changed, shown at the row's end as a short time and used to break ties.
    var date: Date?
    /// How much the source vouches for it among equal matches: 1 is plain; what needs you and live sessions above, archived
    /// and history below. Never lifts a weaker match over a stronger one (DESIGN.md, Ranking).
    var weight: Double = 1
    /// What it does: the first is ↩; all of them are its actions page (Tab, ⌥↩). Never empty.
    var actions: [PaletteAction]
}

/// Something a row does. Runs after the palette has closed and given the keyboard back (DESIGN.md, Running).
struct PaletteAction: Identifiable {
    let id: String
    let title: String
    var symbol: String?
    /// The shortcut that does the same outside the palette, as keycaps (`Shortcut.caps`), shown to teach it.
    var caps: [String] = []
    /// Whether it changes or removes something (Archive): drawn in the danger tint on the actions page.
    var destructive = false
    let run: @MainActor () -> Void
}

/// A row's leading glyph.
enum PaletteIcon {
    /// An SF Symbol, optionally tinted (a category's colour).
    case symbol(String, tint: Color? = nil)
    /// A Claude session's own glyph (`SessionGlyph`, from `store.sessionRow(id)`), by session id.
    case session(String)
}

/// The status dot on a row's icon (search-tabs-avatars.md §1, "Status dot on the icon").
enum PaletteDot {
    /// Waits for you, failed, unread: blue.
    case attention
    /// Working: orange.
    case running
}

/// What the sources need from the window to make items whose actions act on it.
@MainActor
struct PaletteContext {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterModel
    let hub: HubState
    /// Goes to a place, resolved against the tools that are on and the categories shown (the window's `openApp`).
    let go: (AppDestination) -> Void
}

/// What one source hands the palette when it opens.
struct PaletteSourceOutput {
    /// For the empty palette's first group, "Needs you", in the order to show (most urgent first).
    var needsYou: [PaletteItem] = []
    /// Everything it can find by typing (the needs-you items included again: the palette drops duplicates by id).
    var items: [PaletteItem] = []
}
