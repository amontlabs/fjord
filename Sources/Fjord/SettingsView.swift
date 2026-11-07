import SwiftUI
import ApplicationServices

/// Settings, drawn as Claude's own Settings pages are (docs/design/spec/settings.md): titled sections 40 apart, rows of a
/// label, a muted description and a control on the trailing edge, split by faint lines and never boxed; lists in a nest
/// card. Straight on the island's black.
struct SettingsView: View {
    /// The account's picture in the GitHub section (warmed at that size when the hub opens).
    static let accountAvatar: CGFloat = 32
    @Bindable var store: Store
    let hub: HubState
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var launchAtLogin = SystemState.known.launchAtLogin
    @State private var launchError: String?
    @State private var restoreError: String?
    @State private var accessibilityTrusted = SystemState.known.accessibility
    @State private var notificationsBlocked = false

    static let updatesID = "updates"
    /// The Router's row in Tools (shots scroll there).
    static let routerID = "router"
    static let notificationsID = "notifications"
    static let generalID = "general"
    static let toolsID = "tools"
    static let computerDefaultsID = "computer-defaults"
    static let connectedMacsID = "connected-macs"
    static let githubID = "github"
    static let claudeID = "claude"
    static let codeFoldersID = "code-folders"
    static let shortcutsID = "shortcuts"
    /// The claude.ai delivery's setup, under Claude.
    static let courierID = "courier"
    /// Every section's anchor, in page order (the ⌘K palette scrolls to one for each of its rows).
    static let anchors = [toolsID, computerDefaultsID, connectedMacsID, githubID, notificationsID, claudeID, codeFoldersID,
                          shortcutsID, updatesID, generalID]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: CDS.Settings.sectionGap) {
                    tools.id(Self.toolsID)
                    if store.computersOn && store.computersEngineReady { ComputerHostSettings(store: store) }
                    if store.triageOn { account.id(Self.githubID) }
                    notifications.id(Self.notificationsID)
                    // The Router's own sections read the Router's state in views of their own: what changes with every read of
                    // Claude's sessions redraws them, not the whole page.
                    if store.routerOn { RouterSettings(store: store, part: .claude).id(Self.claudeID) }
                    if store.routerOn { RouterCourierSetupView(setup: store.routerCourierLink.setup).id(Self.courierID) }
                    if store.triageOn || store.routerOn { CodeFoldersSettings(store: store).id(Self.codeFoldersID) }
                    shortcuts.id(Self.shortcutsID)
                    updates.id(Self.updatesID)
                    general.id(Self.generalID)
                }
                // The spec's `px-xl pt-2 pb-lg`, kept in the island's narrower panel; 8 more on top, under the hub's header.
                .padding(.horizontal, CDS.Settings.pagePadX)
                .padding(.top, CDS.Settings.pageTop + 8)
                .padding(.bottom, CDS.Settings.pageBottom)
            }
            .scrollIndicators(.never)
            // Check for Updates asked for its section: the page was just opened, or was open and scrolled elsewhere.
            .onAppear { Task { scroll(proxy, animated: false) } }
            .onChange(of: hub.settingsScroll) { scroll(proxy, animated: true) }
        }
        // The page is kept while the window is closed: what the system holds is read again when it is back, and a pasted
        // secret that wasn't saved doesn't wait behind a closed window. A login item that failed to change says so only
        // until then: what the system now holds is what the switch shows (it may have been fixed in System Settings).
        .onAppear { launchError = nil }
        // Asked of the system off the main thread (the login item is an XPC call), after the page shows: it opens on what
        // was last read, and changes only if the system changed since.
        .task {
            let now = await SystemState.read()
            // A switch of yours made while the system was asked stands: the answer is from before it.
            if let launch = now.launchAtLogin, launchAtLogin != launch { launchAtLogin = launch }
            if accessibilityTrusted != now.accessibility { accessibilityTrusted = now.accessibility }
        }
    }

    /// What Settings shows of the system: the login item and Accessibility access, as last read. Read once when first
    /// asked for, then again each time Settings shows (`read`), never as the page's view is made (which is on every redraw
    /// of what holds it).
    @MainActor final class SystemState {
        struct Known: Sendable { var launchAtLogin: Bool; var accessibility: Bool }

        /// The one the app uses. A test makes its own, so what other suites read of the system never lands in it.
        static let shared = SystemState()
        init() {}

        static var known: Known { shared.known }
        static func remember(launchAtLogin on: Bool) { shared.remember(launchAtLogin: on) }
        static func read(ask: @Sendable () async -> Known = SystemState.ask) async -> (launchAtLogin: Bool?, accessibility: Bool) {
            await shared.read(ask: ask)
        }

        private var last: Known?
        private var asking = false

        /// What was last read, never asked on the main thread: before the first answer is in, off and not granted (and the
        /// system is asked, off it), which the page's own read on showing then corrects.
        var known: Known {
            if let last { return last }
            if !asking {
                asking = true
                Task { _ = await read() }
            }
            return Known(launchAtLogin: false, accessibility: false)
        }

        /// The system asked, off the main thread.
        nonisolated static func ask() async -> Known {
            await Task.detached(priority: .userInitiated) {
                Known(launchAtLogin: LaunchAtLogin.isEnabled, accessibility: AXIsProcessTrusted())
            }.value
        }

        /// Bumped by each switch of the login item: an answer asked for before one is older than it.
        private var revision = 0

        func remember(launchAtLogin on: Bool) {
            revision &+= 1
            // Before the system's first answer too: yours is what is known of it (an answer asked for before is older).
            last = Known(launchAtLogin: on, accessibility: last?.accessibility ?? false)
        }

        /// What the system says now; the login item nil when you switched it while it was being asked (the answer is
        /// from before your switch, which stands).
        func read(ask: @Sendable () async -> Known = SystemState.ask) async -> (launchAtLogin: Bool?, accessibility: Bool) {
            let asked = revision
            let now = await ask()
            let current = asked == revision
            last = Known(launchAtLogin: current ? now.launchAtLogin : last?.launchAtLogin ?? now.launchAtLogin,
                         accessibility: now.accessibility)
            return (current ? now.launchAtLogin : nil, now.accessibility)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = hub.settingsScroll?.id else { return }
        hub.settingsScroll = nil
        if animated { withAnimation(Motion.scroll.resolved(reduce: reduce)) { proxy.scrollTo(id, anchor: .top) } }
        else { proxy.scrollTo(id, anchor: .top) }
    }

    private var footnote: (CGFloat, CGFloat) { CDS.Density.comfortable.footnote }

    // MARK: Sections

    /// Each tool's switch: what a tool adds to the app (its sections below included) is there only while it is on.
    private var tools: some View {
        SettingsSection("Tools") {
            SettingsRow("Triage", adornment: Self.toolMark(.triage),
                        info: ("Triage", "Your GitHub inbox: the pull requests, issues and CI that need you, sorted into categories by your rules, with banners and actions. It signs in to GitHub with `gh auth token`, or a token you paste. Off, GitHub isn't checked.")) {
                SettingsSwitch("Triage", isOn: Binding(get: { store.triageOn }, set: { store.setTool(.triage, on: $0) }))
            }
            SettingsDivider()
            RouterSettings(store: store, part: .tool)
            SettingsDivider()
            SettingsRow("Computers", adornment: Self.toolMark(.computers),
                        info: ("Computers", "Manage Linux and macOS computers, lifecycle actions, displays and checkpoints.")) {
                SettingsSwitch("Computers", isOn: Binding(get: { store.computersOn }, set: { store.setTool(.computers, on: $0) }))
            }
        }
    }

    static func toolMark(_ tool: Tool) -> AnyView {
        AnyView(Image(systemName: tool.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.Text.secondary))
    }

    private var account: some View {
        SettingsSection("GitHub") { GitHubSignIn(store: store) }
    }

    /// Turns Launch at login on or off; what the system refused with shows under the toggle, and is said too.
    static func launchFailure(turningOn on: Bool, using set: (Bool) throws -> Void) -> String? {
        do {
            try set(on)
            return nil
        } catch {
            Announce.say("Couldn't turn \(on ? "on" : "off") Launch at login")
            return error.localizedDescription
        }
    }

    private var notifications: some View {
        let blocked = store.settings.notifications && notificationsBlocked
        return SettingsSection("Notifications") {
            SettingsRow("Desktop notifications") {
                SettingsSwitch("Desktop notifications", isOn: $store.settings.notifications)
            }
            SettingsNote("Fjord tells you about your T3 threads, so turn off T3 Code's own desktop notifications to avoid being told twice.")
            if blocked {
                SettingsRow(nil, description: "macOS is blocking Fjord's notifications. Allow them in System Settings › Notifications.",
                            descriptionColor: CDS.Text.warning) {
                    ActionButton("Open Settings") {
                        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)") {
                            Link.open(url)
                        }
                    }
                }
            }
            SettingsDivider()
            SettingsRow("Snooze banners") {
                if store.isSnoozed, let until = store.settings.snoozeUntil {
                    HStack(spacing: 12) {
                        Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                            .cdsText(footnote, .regular, CDS.Text.secondary)
                        ActionButton("Resume") { store.snooze(for: nil) }
                    }
                } else {
                    SettingsSelect(value: "Off") {
                        Button("30 minutes") { store.snooze(for: 1800) }
                        Button("1 hour") { store.snooze(for: 3600) }
                        Button("3 hours") { store.snooze(for: 3 * 3600) }
                        Button("Until tomorrow 9:00") { store.snoozeUntilTomorrow() }
                    }
                    .accessibilityLabel("Snooze banners")
                    .accessibilityValue("Off")
                }
            }
        }
        // What the system says is read when Settings opens and when the app comes back from System Settings, where it changes.
        .task { notificationsBlocked = await Notifier.isBlocked() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationsBlocked = await Notifier.isBlocked() }
        }
        // The notice that appears is said, once.
        .onChange(of: blocked, initial: true) { _, now in
            if now { Announce.say("Notifications are blocked in System Settings") }
        }
    }

    private var shortcuts: some View {
        SettingsSection("Shortcuts",
                        info: ("Shortcuts", "Click one, then press the new keys (Esc cancels, Delete clears). Ones that work from any app also accept a single modifier tapped alone, like right ⌘. In the inbox, ↑↓ or hovering picks the row they act on; on the Router’s Brief, hovering a highlight does.")) {
            let actions = ShortcutAction.allCases.filter(store.offers)
            ForEach(actions) { action in
                if action != actions.first { SettingsDivider() }
                let needsAccess = action.isGlobal && !accessibilityTrusted
                    && (store.shortcut(action).isModifierTap || store.shortcut(action).mouseButton != nil)
                SettingsRow(action.title,
                            adornment: action.isGlobal ? AnyView(Image(systemName: "globe").font(.system(size: 11))
                                .foregroundStyle(CDS.Text.muted).tip("Works from any app")) : nil,
                            below: needsAccess ? AnyView(
                                Text("Needs Accessibility access (System Settings › Privacy & Security)")
                                    .cdsText(footnote, .regular, CDS.Text.warning)
                                    .fixedSize(horizontal: false, vertical: true)) : nil) {
                    ShortcutRecorder(action: action, store: store)
                }
            }
            SettingsDivider()
            SettingsRow("All shortcuts", description: restoreError,
                        descriptionColor: restoreError == nil ? CDS.Text.muted : CDS.Text.warning) {
                ActionButton("Restore defaults") {
                    // Beside the button, and said at each attempt, a repeated one too.
                    restoreError = store.restoreDefaultShortcuts()?.message
                    if let restoreError { Announce.say(restoreError, again: true) }
                }
                .disabled(!store.hasCustomShortcuts)
            }
            .onChange(of: store.hasCustomShortcuts) { restoreError = nil }
        }
        // Granted in System Settings, which Fjord comes back from.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private var updates: some View {
        let updater = store.updater
        return SettingsSection("Updates") {
            Ticking(coarse: true) { now in
                SettingsRow("Fjord \(updater.current)", description: updateStatus(now), descriptionColor: updateStatusColor) {
                    if updater.isRelease { updateButton }
                }
            }
            if updater.isRelease {
                SettingsDivider()
                SettingsRow("Check for updates automatically") {
                    SettingsSwitch("Check for updates automatically", isOn: Binding(
                        get: { store.settings.checkUpdates ?? true },
                        set: { store.settings.checkUpdates = $0 }
                    ))
                }
            }
        }
    }

    @ViewBuilder private var updateButton: some View {
        let updater = store.updater
        switch updater.phase {
        case .available, .failed:
            ActionButton(updater.phase == .available ? "Download & install" : "Try again") { updater.advance() }
        case .ready:
            ActionButton("Restart to update") { updater.install() }
        case .downloading, .installing:
            EmptyView()
        case .idle:
            ActionButton(updater.checking ? "Checking…" : "Check now") {
                store.settings.skippedVersion = nil
                Task { await updater.check(manual: true) }
            }
            .disabled(updater.checking)
        }
    }

    private func updateStatus(_ now: Date) -> String {
        let updater = store.updater
        guard updater.isRelease else { return "Development build: updates come from git" }
        let version = updater.release?.version ?? ""
        switch updater.phase {
        case .available: return "Version \(version) is available"
        case .downloading: return "Downloading \(version)… \(Int(updater.fraction * 100))%"
        case .ready: return "Version \(version) is ready to install"
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle:
            if let error = updater.checkError { return error }
            guard let last = updater.lastCheck else { return "Not checked yet" }
            return "Up to date · checked \(agoPhrase(last, now: now))"
        }
    }

    private var updateStatusColor: Color {
        switch store.updater.phase {
        case .failed: CDS.Text.danger
        case .available, .ready: CDS.Text.accent
        default: store.updater.checkError == nil ? CDS.Text.muted : CDS.Text.danger
        }
    }

    private var general: some View {
        SettingsSection("General") {
            if store.triageOn {
                SettingsRow("Check every") {
                    SettingsSegmented(label: "Check every",
                                      options: [("30s", 30.0), ("1m", 60.0), ("2m", 120.0), ("5m", 300.0)],
                                      selection: $store.settings.pollInterval)
                        .onChange(of: store.settings.pollInterval) { store.restartPolling() }
                }
                SettingsDivider()
            }
            SettingsRow("Launch at login", description: launchError, descriptionColor: CDS.Text.danger) {
                // Your switch changes the login item; the page reading it again from the system (back after a close) doesn't.
                SettingsSwitch("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    launchAtLogin = on
                    launchError = Self.launchFailure(turningOn: on, using: LaunchAtLogin.set)
                    SystemState.remember(launchAtLogin: on)
                }))
            }
            SettingsDivider()
            SettingsRow("Center the bar on its edge") {
                SettingsSwitch("Center the bar on its edge", isOn: Binding(
                    get: { store.settings.centerPill ?? false },
                    set: { store.settings.centerPill = $0 }
                ))
            }
            SettingsDivider()
            // Destructive actions are a secondary button on their row (settings.md §3.5), never red.
            SettingsRow("Quit Fjord",
                        info: ("Quit Fjord", "Stops checking GitHub and takes the bar away until it's opened again")) {
                ActionButton("Quit Fjord") { NSApp.terminate(nil) }
            }
        }
    }

}

/// Settings' Router parts: its switch with how it is doing (in Tools), and the Claude section. What they read of the store
/// (the Router's state, the sessions' folders, the agents' settings) changes with every read of Claude's sessions, so they are
/// views of their own and only they redraw for it.
private struct RouterSettings: View {
    enum Part { case tool, claude }

    @Bindable var store: Store
    let part: Part

    private var footnote: (CGFloat, CGFloat) { CDS.Density.comfortable.footnote }

    var body: some View {
        switch part {
        case .tool: router
        case .claude: claude
        }
    }

    private var claude: some View {
        SettingsSection("T3 Code") {
            T3SettingsRows(store: store)
            SettingsDivider()
            routerStyle
            SettingsDivider()
            mutedFolders
            if store.triageOn {
                SettingsDivider()
                inboxJev
            }
            SettingsDivider()
            sessionIcons
        }
    }

    /// The Router, which reads your Claude Code sessions (never writing to the desktop app's files): its switch, then what it
    /// needs and how each part is doing (the hook, Claude Code, routing).
    @ViewBuilder private var router: some View {
        let needsClaude = !store.router.enabled && !store.t3.installed
        SettingsRow("Router",
                    description: needsClaude ? "Needs T3 Code" : nil,
                    adornment: SettingsView.toolMark(.router),
                    info: ("Router", "Shows what your Claude Code sessions are doing, what is waiting on you and what is done, and answers their questions, permissions and plans here. Each message you send runs on its own: rules first, then Jev (TypeSafe's classifier, if a key is set) picks where it goes, and a short Haiku run only changes Fjord or answers a question. Your words reach a thread as one message to T3: they steer a running thread (⌥Return queues them instead), and you can cancel or edit one that waits. Every run is logged in the Router's history. The Router never acts on GitHub. \(store.shortcut(.router).display) opens it.")) {
            SettingsSwitch("Router", isOn: Binding(get: { store.router.enabled }, set: { store.setTool(.router, on: $0) }))
                .disabled(needsClaude)
        }
        .id(SettingsView.routerID)
        if store.router.enabled {
            SettingsRail {
                VStack(alignment: .leading, spacing: 6) {
                    if let missing = claudeCodeStatus { SettingsStatusLine(text: missing.0, color: missing.1) }
                }
            }
        }
    }

    /// Said only when it is missing: the briefs and the Router's answers run on the `claude` command.
    private var claudeCodeStatus: (String, Color)? {
        store.routerStatus.claudeCode == nil ? ("Claude Code (`claude`) not found: the Router's briefs and answers need it", Theme.amber) : nil
    }

    /// Whether Jev labels the inbox's new comments and rates its review requests (InboxJev.swift), which sends them to TypeSafe.
    private var inboxJev: some View {
        SettingsRow("Let Jev label new comments",
                    info: ("Let Jev label new comments", "With a TypeSafe API key, each refresh sends the inbox's new comments, reviews and thread replies (not yours, from the last two weeks), and the review requests and assignments waiting on you, to TypeSafe (api.typesafe.ai). What goes: the comment's text and its author, the one just before it, the PR or issue's title, number and repo, its author, labels, size and checks, and your part in it; and, when a session's turn ends waiting, the titles, numbers and checks of the PRs and workflows of its repo, for what it waits on. Jev labels each comment (asks you, to do, FYI or noise) and rates how important a request is: a row stands out or is dimmed by them, and a rule of yours can ask for them (a comment labeled, noise or a person, rated at least). They never hide a row or hold back a banner: your rules decide that. Off, nothing of the inbox is sent and nothing is labeled: noise is bots only.")) {
            SettingsSwitch("Let Jev label new comments",
                           isOn: Binding(get: { store.jevReadsInbox }, set: { store.settings.jevReadsInbox = $0 }))
        }
    }

    /// How the cards' briefs and the sessions' summaries are written to you, in your words.
    private var routerStyle: some View {
        SettingsRow("How the Router writes to you",
                    description: "Each card, and each summary of a session, is explained in these words' style.",
                    info: ("How the Router writes to you", "Claude Haiku explains each card in plain words (what it needs from you and why, what it waits on, what is worth knowing, what was done), and writes the Working sessions' summaries. Both follow what you write here, within the Router's own rules: short, no markdown, and what the sessions wrote is only ever data. Haiku runs through Claude Code and reads the card, its turn's final message and the form it stopped on; nothing of it goes to TypeSafe."),
                    below: AnyView(RouterStyleField(store: store))) {
            if store.router.style != nil { ActionButton("Reset") { store.setRouterStyle("") } }
        }
    }

    @ViewBuilder private var sessionIcons: some View {
        SettingsRow("Icons picked for you",
                    info: ("Icons picked for you", "Each session in the Router gets an icon instead of letters. Its title, project name and first message go to TypeSafe (api.typesafe.ai), whose Jev model picks what kind of icon fits (code, debugging, data, people…), then one of that kind not already on screen, from \(SessionIcons.drawableCount ?? SessionIcons.iconCount) in all. Two small requests, about $0.0002 a session. Keys come from console.typesafe.ai.")) {
            SettingsSwitch("Icons picked for you", isOn: Binding(get: { store.agents.iconsEnabled }, set: { store.setIconsEnabled($0) }))
        }
        if store.agents.iconsEnabled {
            SettingsRail {
                TypeSafeKeyField(store: store)
                if let error = store.iconError {
                    SettingsNote(error, color: CDS.Text.warning)
                        .onChange(of: error, initial: true) { _, now in Announce.say(now) }
                }
            }
        }
    }

    /// A list (settings.md §4): the header row with its add control, the folders in a nest card, or a line when none are.
    @ViewBuilder private var mutedFolders: some View {
        let muted = store.agents.mutedFolders
        let unmuted = store.knownFolders.filter { !muted.contains($0) }
        let name = { (folder: String) in
            folder.isEmpty ? "Scratch chats" : store.folderName(folder)
        }
        SettingsRow("Muted folders", info: ("Muted folders", "The Router ignores their sessions: no cards, nothing listed"),
                    below: AnyView(Group {
                        if muted.isEmpty {
                            Text("None").cdsText(footnote, .regular, CDS.Text.secondary)
                        } else {
                            SettingsNest {
                                ForEach(muted, id: \.self) { folder in
                                    SettingsRow(name(folder), description: folder.isEmpty || folder.hasPrefix("guest-project:") ? nil : folder) {
                                        Button("Unmute") { store.setFolderMuted(folder, false) }
                                            .buttonStyle(SettingsButtonStyle(size: .sm))
                                            .accessibilityLabel("Unmute \(name(folder))")
                                    }
                                }
                            }
                        }
                    })) {
            Menu {
                ForEach(unmuted, id: \.self) { folder in
                    Button(name(folder)) { store.setFolderMuted(folder, true) }
                }
            } label: {
                Text("Mute a folder")
            }
            .menuStyle(.button)
            .buttonStyle(SettingsButtonStyle(size: .sm))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Muted folders")
            .accessibilityValue(muted.isEmpty ? "None" : plural(muted.count, "folder"))
            .disabled(unmuted.isEmpty)
        }
    }
}

/// GitHub's sign-in, as Settings and the onboarding show it: who is signed in and with what, then a token to paste.
/// A token pasted and not saved goes with the page.
struct GitHubSignIn: View {
    let store: Store
    @State private var token = ""
    @State private var tokenError: String?

    var body: some View {
        // Rows as the section lays them: one under the other, no gap.
        VStack(alignment: .leading, spacing: 0) {
            // The row's `leading` slot: the avatar, 12 before the text.
            HStack(spacing: 12) {
                Avatar(url: store.me?.avatarUrl, size: SettingsView.accountAvatar)
                SettingsRow(store.me.map { "@\($0.login)" } ?? "Not connected",
                            description: store.unreachable ? "Couldn't reach GitHub"
                                : store.tokenSource.map { "Token from \($0.rawValue)" } ?? (store.authError ?? ""),
                            descriptionColor: store.unreachable ? CDS.Text.warning
                                : store.authError == nil ? CDS.Text.muted : CDS.Text.danger) {
                    HStack(spacing: 8) {
                        if store.authError != nil {
                            ActionButton("Retry") { store.refreshNow() }
                        }
                        if store.tokenSource == .keychain {
                            ActionButton("Use gh CLI") { store.setToken(nil) }
                        }
                    }
                }
            }
            SettingsDivider()
            // The field goes under the row (its `below`): beside the text it would leave the island no room.
            SettingsRow("Personal access token",
                        info: ("Personal access token", "Uses `gh auth token` by default. A pasted token is kept in the Keychain and needs `repo` scope for private repos."),
                        below: AnyView(VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                SettingsTextField(placeholder: "Paste a token (optional)", text: $token, secure: true,
                                                  invalid: tokenError != nil, accessibilityLabel: "GitHub personal access token",
                                                  onSubmit: saveToken)
                                ActionButton("Save", height: CDS.Settings.field, action: saveToken)
                                    .disabled(token.isEmpty)
                            }
                            // A refusal keeps the field and what was typed; it is said where it shows.
                            if let tokenError {
                                Text(tokenError).cdsText(CDS.Density.comfortable.body, .regular, CDS.Text.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }))
        }
        .onDisappear {
            token = ""
            tokenError = nil
        }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        guard store.setToken(token) else {
            tokenError = "Couldn't save the token in the Keychain"
            return
        }
        tokenError = nil
        token = ""
    }
}

/// The TypeSafe API key Jev works with: Remove once the Keychain has one, else a field to paste it. A key pasted and not
/// saved goes with the page.
struct TypeSafeKeyField: View {
    let store: Store
    @State private var key = ""

    var body: some View {
        Group {
            if store.hasTypesafeKey {
                SettingsRow("TypeSafe API key", info: ("TypeSafe API key", "Saved in the Keychain")) {
                    ActionButton("Remove") { store.setTypesafeKey(nil) }
                }
            } else {
                HStack(spacing: 8) {
                    SettingsTextField(placeholder: "Paste a TypeSafe API key", text: $key, secure: true,
                                      accessibilityLabel: "TypeSafe API key", onSubmit: save)
                    ActionButton("Save", height: CDS.Settings.field, action: save)
                        .disabled(key.isEmpty)
                }
            }
        }
        .onDisappear { key = "" }
    }

    /// Cleared only once the Keychain has it; a refusal keeps what was typed.
    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.setTypesafeKey(trimmed) else { return }
        key = ""
    }
}

// MARK: - Claude's settings primitives (settings.md §2–§3, comfortable)

private let comfy = CDS.Density.comfortable

/// A section (§2.1): its title 15/20 at 540, an optional footnote description and a trailing action, 16 above its rows.
/// Rows sit straight on the page, split by `SettingsDivider`s, never boxed.
struct SettingsSection<Content: View, Action: View>: View {
    let title: String
    var description: String?
    /// A tooltip behind a small (i) after the title, for what must stay reachable but needn't be read.
    var info: (String, String)?
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    init(_ title: String, description: String? = nil, info: (String, String)? = nil, @ViewBuilder action: @escaping () -> Action,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.info = info
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CDS.Settings.rowGap) {
                VStack(alignment: .leading, spacing: CDS.Settings.labelGap) {
                    HStack(spacing: 6) {
                        Text(title).cdsText(comfy.heading, .semibold)
                            .accessibilityAddTraits(.isHeader)
                        if let info { SettingsInfo(title: info.0, detail: info.1) }
                    }
                    if let description {
                        Text(.init(description)).cdsText(comfy.footnote, .regular, CDS.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action()
            }
            .padding(.bottom, CDS.Settings.headerGap)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsSection where Action == EmptyView {
    init(_ title: String, description: String? = nil, info: (String, String)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, description: description, info: info, action: { EmptyView() }, content: content)
    }
}

/// The 1pt white-5% line between a group's rows (`.settings-group-dividers`).
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(CDS.Settings.divider).frame(height: 1).accessibilityHidden(true)
    }
}

private struct SettingsRowPaddingKey: EnvironmentKey { static let defaultValue = CDS.Settings.rowPad }

extension EnvironmentValues {
    /// A row's vertical padding: 12, or 0 on a rail (`[&>[role=group]]:!py-0`).
    var settingsRowPadding: CGFloat {
        get { self[SettingsRowPaddingKey.self] }
        set { self[SettingsRowPaddingKey.self] = newValue }
    }
}

/// A setting row (§2.2): label 14/20 primary, description 14/20 muted 4 below, the control 28 to the right, 12 above and
/// below. `below` is extra UI under the row (12 under its main line). No hover fill: only the controls react.
struct SettingsRow<Control: View>: View {
    var label: String?
    var description: String?
    var descriptionColor: Color = CDS.Text.muted
    /// A small mark before the label (the label adornment's `gap-1.5`).
    var adornment: AnyView?
    var info: (String, String)?
    var below: AnyView?
    @ViewBuilder var control: () -> Control
    @Environment(\.settingsRowPadding) private var pad

    init(_ label: String?, description: String? = nil, descriptionColor: Color = CDS.Text.muted, adornment: AnyView? = nil,
         info: (String, String)? = nil, below: AnyView? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.info = info
        self.label = label
        self.description = description
        self.descriptionColor = descriptionColor
        self.adornment = adornment
        self.below = below
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CDS.Settings.rowPad) {
            HStack(alignment: .center, spacing: CDS.Settings.rowGap) {
                VStack(alignment: .leading, spacing: CDS.Settings.labelGap) {
                    if let label {
                        HStack(spacing: 6) {
                            if let adornment { adornment }
                            Text(label).cdsText(comfy.body)
                            if let info { SettingsInfo(title: info.0, detail: info.1) }
                        }
                    }
                    if let description {
                        Text(.init(description)).cdsText(comfy.body, .regular, descriptionColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control().fixedSize()
            }
            if let below { below }
        }
        .padding(.vertical, pad)
    }
}

extension SettingsRow where Control == EmptyView {
    init(_ label: String?, description: String? = nil, descriptionColor: Color = CDS.Text.muted, info: (String, String)? = nil,
         below: AnyView? = nil) {
        self.init(label, description: description, descriptionColor: descriptionColor, info: info, below: below) { EmptyView() }
    }
}

/// A small (i) whose tooltip carries what a label can't: what is sent where, what is installed, what a token needs.
struct SettingsInfo: View {
    let title: String
    let detail: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(CDS.Text.muted)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .tip(title, detail)
            .accessibilityLabel(title)
            .accessibilityHint(detail)
    }
}

/// A line in a group that isn't a row (a status, a help sentence): footnote, 12 above and below.
struct SettingsNote: View {
    let text: String
    var color: Color = CDS.Text.muted
    @Environment(\.settingsRowPadding) private var pad

    init(_ text: String, color: Color = CDS.Text.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(.init(text)).cdsText(comfy.footnote, .regular, color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, pad)
    }
}

/// The nest card (§2.4, `padding:"sm"`): the one boxed container, for a list's items. Radius 12, no fill, a 1pt white-10%
/// ring, 12 × 8 inside; the rows in it keep their 12 and have no lines between them.
struct SettingsNest<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, CDS.Settings.nestPadX)
            .padding(.vertical, CDS.Settings.nestPadY)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: CDS.Settings.nestRadius, style: .continuous)
                .strokeBorder(CDS.border, lineWidth: 1))
    }
}

/// The rail (§2.5): options that hang off the switch above them, behind a 1pt white-20% line, 16 apart, rows unpadded.
struct SettingsRail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CDS.Settings.railGap) { content() }
            .environment(\.settingsRowPadding, 0)
            .padding(.leading, CDS.Settings.railPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(CDS.Settings.railLine).frame(width: 1).accessibilityHidden(true) }
            .padding(.bottom, CDS.Settings.railGap)
    }
}

/// The text input's box (§3.1): 32 tall, radius 8, 12 in, white 5% with a 1pt white-10% ring (20% on hover); focused, a
/// 1pt dark gap, a 1pt accent ring outside and its glow; invalid, a red ring (and the red focus).
struct CDSFieldChrome: ViewModifier {
    var focused: Bool
    var invalid = false
    var leadingPad: CGFloat = CDS.Settings.fieldPad
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous)
        let ring = invalid ? CDS.Fill.danger : hovering && !focused && enabled ? CDS.Settings.fieldRingHover : CDS.Settings.fieldRing
        content
            .textFieldStyle(.plain)
            .font(CDS.sans(comfy.body.0))
            .foregroundStyle(CDS.Text.primary)
            .tint(CDS.Fill.accent)
            .padding(.leading, leadingPad)
            .padding(.trailing, CDS.Settings.fieldPad)
            .frame(height: CDS.Settings.field)
            .background(shape.fill(CDS.Fill.field))
            .overlay(shape.strokeBorder(focused ? CDS.Settings.focusGap : ring, lineWidth: 1))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius + 1, style: .continuous)
                        .strokeBorder(invalid ? CDS.Fill.danger : CDS.Fill.accent, lineWidth: 1)
                        .padding(-1)
                        .bakedShadow(invalid ? CDS.Settings.focusGlowDanger : CDS.Settings.focusGlow,
                                     .ring(CDS.Settings.fieldRadius + 1, lineWidth: 1), radius: 3)
                        .allowsHitTesting(false)
                }
            }
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .hoverMotion(hovering)
            .motion(.easeOut(duration: 0.06), value: focused)
    }
}

extension View {
    func cdsField(focused: Bool, invalid: Bool = false, leadingPad: CGFloat = CDS.Settings.fieldPad) -> some View {
        modifier(CDSFieldChrome(focused: focused, invalid: invalid, leadingPad: leadingPad))
    }
}

extension View {
    /// A placeholder in Claude's muted ink, drawn under the field's text while it's empty (a `prompt`'s colour is ignored).
    func cdsPlaceholder(_ text: String, shown: Bool) -> some View {
        overlay(alignment: .leading) {
            if shown {
                Text(text).font(CDS.sans(14)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// The Router's style, a few lines: kept as you type, saved when you leave it (or press Return), so the Router's state isn't
/// written at every key.
private struct RouterStyleField: View {
    @Bindable var store: Store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        CDSTextArea(placeholder: RouterStyle.defaultText, lines: 2...6, text: $text, onSubmit: save)
            .focused($focused)
            .accessibilityLabel("How the Router writes to you")
            .onAppear { text = store.routerStyle }
            .onChange(of: focused) { if !focused { save() } }
            .onChange(of: store.router.style) { if !focused { text = store.routerStyle } }
            .onDisappear(perform: save)
    }

    private func save() { store.setRouterStyle(text) }
}

/// A text input with its own focus (§3.1), secure or not.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var invalid = false
    let accessibilityLabel: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text)
            } else {
                TextField("", text: $text)
            }
        }
        .cdsPlaceholder(placeholder, shown: text.isEmpty)
        .focused($focused)
        .cdsField(focused: focused, invalid: invalid)
        .accessibilityLabel(accessibilityLabel)
        .onSubmit(onSubmit)
    }
}

/// The switch (§3.3): 36 × 20, a 16pt white knob that travels 16 in 120 ms with an overshoot. Off white 10% (20% on hover),
/// on accent (lighter on hover); disabled at 40%. It reads as the system switch it stands for.
struct CDSSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { CDSSwitch(configuration: configuration) }
}

private struct CDSSwitch: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let on = configuration.isOn
        let hot = hovering && enabled
        let size = CDS.Settings.switchSize
        let travel = size.width - CDS.Settings.knob - 4
        Capsule()
            .fill(on ? (hot ? CDS.Fill.accentHover : CDS.Fill.accent) : (hot ? CDS.Settings.switchTrackHover : CDS.Settings.switchTrack))
            .frame(width: size.width, height: size.height)
            .overlay {
                Circle().fill(.white)
                    .frame(width: CDS.Settings.knob, height: CDS.Settings.knob)
                    .bakedShadow(.black.opacity(0.24), .circle, radius: 2, y: 1)
                    .offset(x: on ? travel / 2 : -travel / 2)
            }
            .animation(reduce ? nil : .timingCurve(0.34, 1.3, 0.64, 1, duration: 0.12), value: on)
            .hoverMotion(hot)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .onHover { hovering = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}

/// A row's switch, labelled by the row.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(CDSSwitchStyle())
    }
}

/// The contained segmented control (§3.4): a 32 white-5% track with 1pt padding; the picked item on a white-10% thumb
/// (radius 7, its 1pt white-10% ring) that slides; items 12 in, 14/20, muted until picked or hovered.
struct SettingsSegmented<Value: Hashable>: View {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    @State private var hovered: Value?
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let picked = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .cdsText(comfy.body, .regular, picked || hovered == option.value ? CDS.Text.primary : CDS.Text.muted)
                        .padding(.horizontal, CDS.Settings.segmentPad)
                        .frame(maxHeight: .infinity)
                        .background {
                            if picked {
                                RoundedRectangle(cornerRadius: CDS.Settings.segmentThumbRadius, style: .continuous)
                                    .fill(CDS.Fill.secondary)
                                    .overlay(RoundedRectangle(cornerRadius: CDS.Settings.segmentThumbRadius, style: .continuous)
                                        .strokeBorder(CDS.border, lineWidth: 1))
                                    .bakedShadow(CDS.fieldShadow, .rounded(CDS.Settings.segmentThumbRadius), radius: 1, y: 1,
                                                 fill: CDS.Fill.secondary)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .animation(reduce ? nil : .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2), value: selection)
        .padding(1)
        .frame(height: CDS.Settings.field)
        .background(RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous).fill(CDS.Fill.field))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The select trigger (§3.2, outline): 32 tall, radius 8, 8 in, white 5% with a 10% ring (20% on hover), the value 14/20
/// and a 16 caret in muted (secondary on hover). Its menu is the system's: a native menu can't be drawn as CDS's popup.
struct SettingsSelect<Items: View>: View {
    let value: String
    var placeholder = false
    var width: CGFloat = CDS.Settings.selectWidth
    @ViewBuilder var items: () -> Items
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous)
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(value).cdsText(comfy.body, .regular, placeholder ? CDS.Text.muted : CDS.Text.primary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? CDS.Text.secondary : CDS.Text.muted)
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: CDS.Settings.field)
            .background(shape.fill(CDS.Fill.field))
            .overlay(shape.strokeBorder(hovering && enabled ? CDS.Settings.fieldRingHover : CDS.Settings.fieldRing, lineWidth: 1))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

/// CDS Button (forms-buttons.md §4), secondary or ghost, in the sizes settings rows use: base 32 (12 in, radius 8), sm 28
/// (10, 7), xxs 20 (6, 5, 12/17 text). Its fill alone squishes to 0.975 on press; disabled at 40%.
struct SettingsButtonStyle: ButtonStyle {
    enum Variant { case secondary, ghost }
    enum Size {
        case xxs, sm, base
        var height: CGFloat { switch self { case .xxs: 20; case .sm: 28; case .base: 32 } }
        var padding: CGFloat { switch self { case .xxs: 6; case .sm: 10; case .base: 12 } }
        var radius: CGFloat { switch self { case .xxs: 5; case .sm: 7; case .base: 8 } }
        var text: (CGFloat, CGFloat) { self == .xxs ? (12, 17) : (14, 20) }
    }

    var variant: Variant = .secondary
    var size: Size = .sm
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, style: self)
    }

    private struct Styled: View {
        let configuration: Configuration
        let style: SettingsButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed && enabled
            let hot = hovering && enabled
            let size = style.size
            let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
            let fill: Color = switch style.variant {
            case .secondary: hot || pressed ? CDS.Fill.secondaryHover : CDS.Fill.secondary
            case .ghost: hot || pressed ? CDS.Fill.ghostHover : .clear
            }
            configuration.label
                .font(CDS.sans(size.text.0))
                .foregroundStyle(CDS.Text.primary)
                .lineLimit(1)
                .padding(.horizontal, style.iconOnly ? 0 : size.padding)
                .frame(width: style.iconOnly ? size.height : nil, height: size.height)
                .background {
                    shape.fill(fill)
                        .bakedShadow(style.variant == .secondary ? CDS.fieldShadow : .clear, .rounded(size.radius), radius: 1, y: 1, fill: fill)
                        .scaleEffect(pressed ? 0.975 : 1)
                        .motion(pressed ? .easeOut(duration: 0.06) : .spring(duration: 0.45, bounce: 0.35), value: pressed)
                }
                .hoverMotion(hot)
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// A row's secondary button (§3.5): sm (28) on rows, base (32) beside a field. Destructive actions are secondary too.
struct ActionButton: View {
    let title: String
    var height: CGFloat = Theme.Metrics.chip
    let action: () -> Void

    init(_ title: String, height: CGFloat = Theme.Metrics.chip, action: @escaping () -> Void) {
        self.title = title
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(SettingsButtonStyle(size: height >= CDS.Settings.field ? .base : .sm))
    }
}

/// A status line with its dot: footnote, the dot in the state's colour, the words in Claude's ink for it.
struct SettingsStatusLine: View {
    let text: String
    let color: Color

    var body: some View {
        let ink = color == Theme.red ? CDS.Text.danger : color == Theme.amber ? CDS.Text.warning : CDS.Text.secondary
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color == Theme.tertiary ? CDS.Text.muted : color).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                .accessibilityHidden(true)
            Text(text).cdsText(comfy.footnote, .regular, ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}
