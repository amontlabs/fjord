import AppKit
import Observation

// The app window's navigation: where the sidebar can go, the back/forward history, the last place visited, and the "Go" menu
// that mirrors the sidebar (⌘1…⌘9 in order, ⌘[ and ⌘]).

/// One place in the window, a row of its sidebar.
enum AppDestination: Hashable {
    case category(UUID)
    case done
    case router
    case settings
    case categories
    case snippets

    /// A stable text form, for remembering the last place.
    var token: String {
        switch self {
        case .category(let id): "category:" + id.uuidString
        case .done: "done"
        case .router: "router"
        case .settings: "settings"
        case .categories: "categories"
        case .snippets: "snippets"
        }
    }

    init?(token: String) {
        switch token {
        case "done": self = .done
        case "router": self = .router
        case "settings": self = .settings
        case "categories": self = .categories
        case "snippets": self = .snippets
        default:
            guard token.hasPrefix("category:"), let id = UUID(uuidString: String(token.dropFirst("category:".count))) else { return nil }
            self = .category(id)
        }
    }

    init(_ tab: InboxTab) {
        switch tab {
        case .done: self = .done
        case .category(let id): self = .category(id)
        }
    }

    /// The inbox tab this is, if it is one.
    var tab: InboxTab? {
        switch self {
        case .category(let id): .category(id)
        case .done: .done
        default: nil
        }
    }

    /// The tool whose place this is; nil for Settings, which is always there, and for the snippets, which both tools use
    /// (there while either is on).
    var tool: Tool? {
        switch self {
        case .category, .done, .categories: .triage
        case .router: .router
        case .settings, .snippets: nil
        }
    }

    /// Whether this place is there with `tools` on.
    func isOn(_ tools: Set<Tool>) -> Bool {
        if self == .snippets { return !tools.isEmpty }
        return tool.map(tools.contains) ?? true
    }

    /// The sidebar's destinations in order: the categories shown, the archive, the Router, the snippets, Settings, Inbox
    /// categories; those of a tool that is off left out.
    static func all(shown: [UUID], tools: Set<Tool>) -> [AppDestination] {
        (shown.map { .category($0) } + [.done, .router, .snippets, .settings, .categories]).filter { $0.isOn(tools) }
    }

    /// Where this really goes: a category that is gone or hidden lands on the first category shown (the archive when there is none);
    /// a place whose tool is off, on the first place of a tool that is on (Settings when none is).
    func resolved(shown: [UUID], tools: Set<Tool>) -> AppDestination {
        let inbox: AppDestination = shown.first.map { .category($0) } ?? .done
        if !isOn(tools) {
            return tools.contains(.triage) ? inbox : tools.contains(.router) ? .router : .settings
        }
        if case .category(let id) = self, !shown.contains(id) { return inbox }
        return self
    }
}

/// Back and forward through the places visited. Going somewhere new drops what was forward of the current place; going to
/// the place already shown adds nothing.
struct NavigationHistory: Equatable {
    private(set) var stack: [AppDestination]
    private(set) var index: Int

    init(_ start: AppDestination) {
        stack = [start]
        index = 0
    }

    var current: AppDestination { stack[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < stack.count - 1 }

    mutating func visit(_ destination: AppDestination) {
        guard destination != current else { return }
        stack.removeSubrange((index + 1)...)
        stack.append(destination)
        index += 1
        // A long session keeps the last hundred places.
        if stack.count > 100 { stack.removeFirst(stack.count - 100); index = stack.count - 1 }
    }

    @discardableResult mutating func back() -> Bool {
        guard canGoBack else { return false }
        index -= 1
        return true
    }

    @discardableResult mutating func forward() -> Bool {
        guard canGoForward else { return false }
        index += 1
        return true
    }

    /// Takes `gone` out of the history (a category deleted), keeping the current place valid.
    mutating func replace(_ old: AppDestination, with new: AppDestination) {
        let current = self.current
        var out: [AppDestination] = []
        for item in stack {
            let item = item == old ? new : item
            if out.last != item { out.append(item) }
        }
        stack = out
        index = max(0, out.lastIndex(of: current == old ? new : current) ?? 0)
    }
}

/// The window's selection and history. The selection is what the sidebar lights and the content shows.
@Observable
@MainActor
final class AppNavigator {
    static let defaultsKey = "window.destination"
    private(set) var history: NavigationHistory
    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults`: where the last place is remembered (nil: not remembered, for shots and tests).
    init(start: AppDestination, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        history = NavigationHistory(start)
    }

    /// Opens on the place left last, `fallback` the first time.
    convenience init(fallback: AppDestination, defaults: UserDefaults? = .standard) {
        self.init(start: defaults?.string(forKey: Self.defaultsKey).flatMap(AppDestination.init(token:)) ?? fallback,
                  defaults: defaults)
    }

    var selection: AppDestination { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Told when the place shown changes, by whatever changes it (the window's morph takes a fresh picture of it).
    @ObservationIgnored var onChange: (() -> Void)?

    func go(_ destination: AppDestination) {
        let was = selection
        history.visit(destination)
        remember(was)
    }

    func back() {
        let was = selection
        if history.back() { remember(was) }
    }

    func forward() {
        let was = selection
        if history.forward() { remember(was) }
    }

    /// A place that no longer exists is replaced by the one it resolves to, in the history too.
    func settle(shown: [UUID], tools: Set<Tool>) {
        let was = selection
        for item in Set(history.stack) {
            let real = item.resolved(shown: shown, tools: tools)
            if real != item { history.replace(item, with: real) }
        }
        remember(was)
    }

    /// `was`: the place shown before.
    private func remember(_ was: AppDestination) {
        defaults?.set(selection.token, forKey: Self.defaultsKey)
        if selection != was { onChange?() }
    }
}

// MARK: - Go menu

/// The "Go" menu's contents for a given sidebar: one item per destination (⌘1…⌘9 for the first nine), then Back and Forward.
enum GoMenuModel {
    struct Item: Equatable {
        let destination: AppDestination
        let title: String
        /// "1"…"9" for the first nine.
        let key: String?
    }

    static let slots = 9

    static func items(_ destinations: [AppDestination], title: (AppDestination) -> String) -> [Item] {
        destinations.enumerated().map { i, d in Item(destination: d, title: title(d), key: i < slots ? String(i + 1) : nil) }
    }

    /// What ⌘`number` goes to (1-based), nil past the last.
    static func destination(forShortcut number: Int, in destinations: [AppDestination]) -> AppDestination? {
        guard number >= 1, number <= min(slots, destinations.count) else { return nil }
        return destinations[number - 1]
    }
}

/// The main menu's Go menu. Its items are made once (their key equivalents must exist before the menu is ever opened) and
/// retitled, shown and enabled for the open window's sidebar as the menu asks to be validated.
@MainActor
final class GoMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = GoMenu()
    private let menu = NSMenu(title: "Go")
    private var destinationItems: [NSMenuItem] = []
    private let backItem = NSMenuItem(title: "Back", action: #selector(goBack), keyEquivalent: "[")
    private let forwardItem = NSMenuItem(title: "Forward", action: #selector(goForward), keyEquivalent: "]")

    /// The top-level item to put in the main menu.
    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        menu.delegate = self
        menu.autoenablesItems = true
        for backward in [true, false] {
            let it = backward ? backItem : forwardItem
            it.target = self
            it.keyEquivalentModifierMask = .command
            menu.addItem(it)
        }
        menu.addItem(.separator())
        for n in 1...GoMenuModel.slots {
            let it = NSMenuItem(title: "", action: #selector(go(_:)), keyEquivalent: String(n))
            it.keyEquivalentModifierMask = .command
            it.target = self
            it.tag = n
            it.isHidden = true
            destinationItems.append(it)
            menu.addItem(it)
        }
        item.submenu = menu
        return item
    }

    private var window: AppWindowController? { AppWindowController.active }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        refresh()
        guard let window, window.isOpen, !window.paletteIsOpen else { return false }
        if item === backItem { return window.navigator.canGoBack }
        if item === forwardItem { return window.navigator.canGoForward }
        return !item.isHidden
    }

    private func refresh() {
        let items = window.map { $0.goItems } ?? []
        for (i, it) in destinationItems.enumerated() {
            if i < items.count {
                it.title = items[i].title
                it.isHidden = false
                it.state = window?.navigator.selection == items[i].destination ? .on : .off
            } else {
                it.isHidden = true
            }
        }
    }

    @objc private func go(_ sender: NSMenuItem) {
        guard let window, let destination = GoMenuModel.destination(forShortcut: sender.tag, in: window.goItems.map(\.destination))
        else { return }
        window.navigator.go(destination)
    }

    @objc private func goBack() { window?.navigator.back() }
    @objc private func goForward() { window?.navigator.forward() }
}
