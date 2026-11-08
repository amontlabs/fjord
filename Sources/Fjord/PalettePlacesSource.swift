import AppKit
import Foundation

// The palette's source for places (docs/design/palette/DESIGN.md, Sources): the window's pages, the rows of Settings (each takes
// you to its section), the few commands that hang off no row, the snippets and the projects. Made once when the
// palette opens, from what is on screen now: a tool that is off, or a section Settings doesn't show, has no items.

@MainActor
enum PalettePlacesSource {
    static func make(_ context: PaletteContext) -> PaletteSourceOutput {
        var items: [PaletteItem] = []
        items += pages(context)
        items += commands(context)
        items += settingsRows(context)
        items += snippets(context)
        items += projects(context)
        return PaletteSourceOutput(items: items)
    }

    // MARK: Pages

    /// A page's name in the window's title bar and Go menu (`AppWindowController.title(for:)`), its sidebar symbol and what
    /// else it is called.
    private static func page(_ destination: AppDestination) -> (title: String, symbol: String, keywords: [String])? {
        switch destination {
        case .done: ("Archive", "archivebox", ["done", "finished", "archived", "inbox"])
        case .router: ("Router", Tool.router.symbol, ["claude", "sessions", "chat", "agents"])
        case .snippets: ("Snippets", Snippet.symbol, ["saved prompts", "prompts", "text"])
        case .settings: ("Settings", "gearshape", ["preferences", "options", "configuration"])
        case .categories: ("Inbox categories", "tray.2", ["inbox", "rules", "groups", "sections", "triage"])
        // A category is a Triage item's, reached from its own row.
        case .category: nil
        }
    }

    private static func pages(_ context: PaletteContext) -> [PaletteItem] {
        let store = context.store
        // The Go menu's order (⌘1…⌘9), the categories counting in it though they are Triage's items here.
        let all = AppDestination.all(shown: store.shownCategories.map(\.id), tools: store.tools)
        var items: [PaletteItem] = []
        for (index, destination) in all.enumerated() {
            guard let page = page(destination) else { continue }
            let caps = index < GoMenuModel.slots ? ["⌘", String(index + 1)] : []
            items.append(PaletteItem(
                id: "page:" + destination.token, kind: .page, title: page.title, subtitle: "Page",
                keywords: ["go", "open", "page"] + page.keywords,
                icon: .symbol(page.symbol), weight: 1,
                actions: [PaletteAction(id: "go", title: "Go to \(page.title)", symbol: "arrow.right", caps: caps) {
                    context.go(destination)
                }]))
        }
        return items
    }

    // MARK: Settings

    /// Takes the window to Settings, scrolled to a section. The request goes first: the page takes it when it appears, or at
    /// once when it is open already.
    private static func showSettings(_ context: PaletteContext, section anchor: String) {
        context.hub.settingsScroll = ScrollRequest(id: anchor, seq: (context.hub.settingsScroll?.seq ?? 0) + 1)
        context.go(.settings)
    }

    private struct SettingsRowSpec {
        let slug: String
        let title: String
        var keywords: [String] = []
        /// The anchor to scroll to when it isn't the section's.
        var anchor: String?
    }

    private struct SettingsSectionSpec {
        let anchor: String
        let title: String
        var keywords: [String] = []
        let rows: [SettingsRowSpec]
    }

    /// The sections Settings shows now with the rows each has, in its order: what `SettingsView` draws, under the conditions it
    /// draws it. A row that is only a status or a list's entries is left out.
    private static func settingsSections(_ store: Store) -> [SettingsSectionSpec] {
        var sections: [SettingsSectionSpec] = []
        sections.append(SettingsSectionSpec(anchor: SettingsView.toolsID, title: "Tools", keywords: ["switch", "on", "off", "enable", "disable"], rows: [
            SettingsRowSpec(slug: "triage", title: "Triage", keywords: ["github", "inbox", "tool"]),
            SettingsRowSpec(slug: "router", title: "Router", keywords: ["claude", "sessions", "tool", "hook", "plugin"], anchor: SettingsView.routerID),
        ]))
        if store.triageOn {
            sections.append(SettingsSectionSpec(anchor: SettingsView.githubID, title: "GitHub", keywords: ["account"], rows: [
                SettingsRowSpec(slug: "token", title: "Personal access token",
                                keywords: ["token", "PAT", "GitHub", "sign in", "login", "keychain", "gh", "auth"]),
            ]))
        }
        sections.append(SettingsSectionSpec(anchor: SettingsView.notificationsID, title: "Notifications", rows: [
            SettingsRowSpec(slug: "desktop", title: "Desktop notifications", keywords: ["banner", "banners", "alerts", "notify"]),
            SettingsRowSpec(slug: "snooze", title: "Snooze banners", keywords: ["mute", "pause", "quiet", "alerts", "notifications"]),
        ]))
        if store.routerOn {
            var rows = [
                SettingsRowSpec(slug: "style", title: "How the Router writes to you", keywords: ["router style", "briefs", "summaries", "writing", "tone"]),
                SettingsRowSpec(slug: "muted", title: "Muted folders", keywords: ["mute", "ignore", "projects", "sessions"]),
                SettingsRowSpec(slug: "drafts", title: "Let Jev read what you type", keywords: ["jev", "typesafe", "privacy", "draft", "composer"]),
            ]
            if store.triageOn {
                rows.append(SettingsRowSpec(slug: "comments", title: "Let Jev label new comments", keywords: ["jev", "typesafe", "privacy", "inbox", "noise"]))
            }
            rows.append(SettingsRowSpec(slug: "icons", title: "Icons picked for you", keywords: ["session icons", "jev", "typesafe", "avatars"]))
            // The key's field is under the icons switch: shown only while it is on.
            if store.agents.iconsEnabled {
                rows.append(SettingsRowSpec(slug: "key", title: "TypeSafe API key", keywords: ["key", "api", "jev", "typesafe", "keychain"]))
            }
            sections.append(SettingsSectionSpec(anchor: SettingsView.claudeID, title: "T3 Code", keywords: ["router", "t3", "link"], rows: rows))
        }
        if store.triageOn || store.routerOn {
            var rows = [SettingsRowSpec(slug: "clones", title: "Where your clones are", keywords: ["code folders", "repos", "add folder", "git", "projects", "directories"])]
            if !store.codeFolderRoots.isEmpty {
                rows.append(SettingsRowSpec(slug: "repos", title: "Repos found", keywords: ["rescan", "scan", "clones", "git"]))
            }
            sections.append(SettingsSectionSpec(anchor: SettingsView.codeFoldersID, title: "Code folders", keywords: ["clones", "repos"], rows: rows))
        }
        var shortcuts = ShortcutAction.allCases.filter(store.offers).map {
            SettingsRowSpec(slug: $0.rawValue, title: $0.title, keywords: ["shortcut", "keyboard", "hotkey", "keys", "binding"])
        }
        shortcuts.append(SettingsRowSpec(slug: "all", title: "All shortcuts", keywords: ["shortcut", "keyboard", "restore", "reset", "defaults"]))
        sections.append(SettingsSectionSpec(anchor: SettingsView.shortcutsID, title: "Shortcuts", keywords: ["keyboard"], rows: shortcuts))
        var updates = [SettingsRowSpec(slug: "version", title: "Fjord \(store.updater.current)", keywords: ["version", "update", "release", "about"])]
        if store.updater.isRelease {
            updates.append(SettingsRowSpec(slug: "automatic", title: "Check for updates automatically", keywords: ["update", "upgrade", "release", "version"]))
        }
        sections.append(SettingsSectionSpec(anchor: SettingsView.updatesID, title: "Updates", keywords: ["upgrade", "version"], rows: updates))
        var general: [SettingsRowSpec] = []
        if store.triageOn {
            general.append(SettingsRowSpec(slug: "interval", title: "Check every", keywords: ["poll", "interval", "refresh", "github", "how often"]))
        }
        general += [
            SettingsRowSpec(slug: "login", title: "Launch at login", keywords: ["startup", "boot", "login item", "autostart", "open at login"]),
            SettingsRowSpec(slug: "center", title: "Center the bar on its edge", keywords: ["bar", "pill", "position", "edge", "center"]),
            SettingsRowSpec(slug: "quit", title: "Quit Fjord", keywords: ["exit", "close", "stop"]),
        ]
        sections.append(SettingsSectionSpec(anchor: SettingsView.generalID, title: "General", rows: general))
        return sections
    }

    private static func settingsRows(_ context: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        for section in settingsSections(context.store) {
            for row in section.rows {
                let anchor = row.anchor ?? section.anchor
                items.append(PaletteItem(
                    id: "setting:\(section.anchor).\(row.slug)", kind: .setting, title: row.title,
                    subtitle: "Settings · \(section.title)",
                    keywords: [section.title, "settings"] + section.keywords + row.keywords,
                    icon: .symbol("gearshape"), weight: 0.8,
                    actions: [PaletteAction(id: "show", title: "Show in Settings", symbol: "gearshape") {
                        showSettings(context, section: anchor)
                    }]))
            }
        }
        return items
    }

    // MARK: Commands

    private static func commands(_ context: PaletteContext) -> [PaletteItem] {
        let store = context.store
        var items: [PaletteItem] = []
        func command(_ slug: String, _ title: String, _ subtitle: String, _ symbol: String, keywords: [String],
                     caps: [String] = [], _ run: @escaping @MainActor () -> Void) {
            items.append(PaletteItem(id: "command:" + slug, kind: .command, title: title, subtitle: subtitle, keywords: keywords,
                                     icon: .symbol(symbol), weight: 0.9,
                                     actions: [PaletteAction(id: slug, title: title, symbol: symbol, caps: caps, run: run)]))
        }
        if store.triageOn {
            command("new-category", "New category", "Command", "plus", keywords: ["create", "add", "inbox", "rules", "group"]) {
                store.newCategory(go: context.go)
            }
        }
        if store.triageOn || store.routerOn {
            command("add-code-folder", "Add a code folder", "Command · Settings", "folder.badge.plus",
                    keywords: ["clones", "repos", "projects", "git", "directory", "settings"]) {
                showSettings(context, section: SettingsView.codeFoldersID)
            }
        }
        if store.triageOn {
            command("refresh", "Refresh now", "Command · Check GitHub again", "arrow.clockwise",
                    keywords: ["reload", "sync", "poll", "github", "update", "inbox"], caps: store.shortcut(.refresh).caps) {
                store.refreshNow()
            }
        }
        if store.updater.isRelease {
            command("check-updates", "Check for updates", "Command · Settings", "arrow.down.circle",
                    keywords: ["update", "upgrade", "version", "release", "new version"]) {
                context.hub.showUpdates()
                context.go(.settings)
                Task { await store.updater.update(manual: true) }
            }
        }
        command("tools", "Turn tools on or off", "Command · Settings", "switch.2",
                keywords: ["tools", "triage", "router", "enable", "disable", "switch", "settings"]) {
            showSettings(context, section: SettingsView.toolsID)
        }
        return items
    }

    // MARK: Snippets

    private static func snippets(_ context: PaletteContext) -> [PaletteItem] {
        let store = context.store
        // The snippets serve both text tools, as in the sidebar.
        guard AppDestination.snippets.isOn(store.tools) else { return [] }
        return store.snippets.map { snippet in
            var actions: [PaletteAction] = []
            if store.routerOn {
                actions.append(PaletteAction(id: "use", title: "Use in the Router", symbol: Tool.router.symbol) {
                    context.routerModel.prefill([], text: snippet.text)
                    context.go(.router)
                })
            }
            actions.append(PaletteAction(id: "show", title: "Show snippets", symbol: Snippet.symbol) { context.go(.snippets) })
            actions.append(PaletteAction(id: "copy", title: "Copy text", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.text, forType: .string)
            })
            return PaletteItem(
                id: "snippet:" + snippet.id.uuidString, kind: .snippet, title: snippet.title, subtitle: snippet.preview,
                keywords: ["snippet", "prompt", "saved prompt", String(snippet.text.prefix(200))],
                icon: .symbol(Snippet.symbol), weight: 0.9, actions: actions)
        }
    }

    // MARK: Projects

    private static func projects(_ context: PaletteContext) -> [PaletteItem] {
        let store = context.store
        return store.projectFolders.map { folder in
            var actions: [PaletteAction] = []
            if store.routerOn {
                actions.append(PaletteAction(id: "ask", title: "Ask the Router about it", symbol: Tool.router.symbol) {
                    context.routerModel.prefill([.project(folder)])
                    context.go(.router)
                })
            }
            actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
            })
            let parts = folder.split(separator: "/").map(String.init)
            return PaletteItem(
                id: "project:" + folder, kind: .project, title: store.folderName(folder),
                subtitle: (folder as NSString).abbreviatingWithTildeInPath,
                keywords: ["project", "folder"] + parts,
                icon: .symbol("folder", tint: store.projectColor(folder)), weight: 1, actions: actions)
        }
    }
}
