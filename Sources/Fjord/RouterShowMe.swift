import AppKit
import SwiftUI

// Show me (docs/design/router-visuals/SHOWME.md §6–§8): a short animated explainer of an agent's answer, made by a separate
// explainer thread once the answer's turn ends (ExplainerEngine.swift). The composer's toggle and ⌘Return ask for one with
// the words; a Done card's "Show me" (or ⌘Return on it with nothing typed) asks for one of its reply. Explainers wait in a
// dock at the page's bottom right: a pill beside the composer, and a panel over the page when it's open. Follow-ups go
// through the composer, as everything else: with the panel on an explainer, the destination row says Return makes a new
// version of it.

/// The page's Show me state: the engine's list (`ExplainerItem`, the demo's in shots and `--demo`), and what the page
/// itself holds. nil on the page: the Router is off or T3 has no explainers project yet, and nothing of Show me shows.
struct RouterShowMeState: Equatable {
    /// The composer's toggle: Return sends, then Show me.
    var armed = false
    /// The dock's panel is open.
    var open = false
    var selected: String?
    /// The selected one's version on show (`ExplainerItem.versions`); nil: the newest, which a new one then replaces.
    var version: Int?
    /// While one plays the list is its row and "N more"; this shows the whole list again.
    var expanded = false
    /// Why the words didn't go to the explainer, in the destination row until the draft changes.
    var note: String?
    /// How big the player is: in the panel, filling the page, or the stage alone filling the window.
    var size: Size = .panel
    /// The size the stage-only view goes back to.
    var back: Size = .panel
    /// The player shows each scene's source under its caption.
    var sources = false
    var explainers: [ExplainerItem] = []

    enum Size: Equatable { case panel, page, window }

    var chosen: ExplainerItem? { explainers.first { $0.id == selected } }
    /// The selected one as its version on show plays it.
    var shown: ExplainerItem? { chosen?.version(version) }
    var making: ExplainerItem? { explainers.first { if case .making = $0.stage { true } else { false } } }
    var queued: ExplainerItem? { explainers.first { $0.stage == .queued } }
    var unseen: Bool { explainers.contains(where: \.unseen) }
    /// The selected one plays: the list folds to its row.
    var playing: Bool { open && shown?.stage == .ready }
    /// Where Return sends the words: the panel's explainer, open on one that's made or being made (a thread of its own).
    var target: ExplainerItem? {
        guard open, let chosen else { return nil }
        switch chosen.stage {
        case .ready, .making: return chosen
        case .queued, .failed: return nil
        }
    }

    /// The one the dock opens on (the list is newest first): one being made, else the newest not watched, else the newest.
    var preferred: ExplainerItem? { making ?? explainers.first(where: \.unseen) ?? explainers.first }

    /// The engine's newest list, keeping what the page holds. A selection that left the list goes to the preferred one.
    /// One that finishes while the panel is open is shown, unless a finished one other than it is on the stage.
    mutating func update(_ items: [ExplainerItem]) {
        let before = explainers
        explainers = items
        if let s = selected, !items.contains(where: { $0.id == s }) { selected = preferred?.id; version = nil }
        guard open else { return }
        let finished = items.first { e in
            e.stage == .ready && before.contains { $0.id == e.id && $0.stage != .ready }
        }
        guard let finished, finished.id != selected else { return }
        if let chosen = before.first(where: { $0.id == selected }), chosen.stage == .ready { return }
        selected = finished.id
        version = nil
        expanded = false
    }
}

/// What the page asks of Show me's engine (the store; nil in a demo or a shot, where nothing is made).
@MainActor protocol RouterExplainers: AnyObject {
    /// Show me on a Done card: an explainer of its latest reply.
    func explain(reply thread: String)
    /// The composer's words for an explainer: a new version that answers them.
    func followUp(_ explainer: String, words: String) async throws
    /// The panel showed it selected with the window key.
    func watched(_ explainer: String)
    /// Open in T3: the explainer's own thread.
    func open(explainer: String)
}

enum RouterShowMeLayout {
    /// The dock's glyph: the toggle's, the destination row's, the pill's.
    static let symbol = "play.rectangle"
    /// The composer's toggle, beside Return: its glyph alone.
    static let toggle: CGFloat = CDS.Composer.row
    /// "Show me ⌘⏎" beside the toggle, on hover or while it's on: the room the words keep free for it while on.
    static let hint: CGFloat = 92
    /// The panel over the page.
    static let panelWidth: CGFloat = 600
    static let panelGap: CGFloat = 8
    static let rowHeight: CGFloat = 30
    /// ⌘Return: send, then Show me; on a Done card with nothing typed, Show me its reply.
    static let keys = ["cmd", "enter"]
    /// ⌥⌘Return: the player fills the page, or goes back to the panel. ⇧⌘Return: the stage alone fills the window.
    static let pageKeys = ["alt", "cmd", "enter"]
    static let windowKeys = ["shift", "cmd", "enter"]
    /// The page's room around the player that fills it, and the most it grows to.
    static let pageMaxWidth: CGFloat = 1180
    /// Words a follow-up can't carry.
    static let wordsOnly = "Explainers take words only"
}

// MARK: - The page's acts

extension RouterModel {
    /// Return sends with Show me: the toggle, or ⌘Return for this send.
    var sendsShowMe: Bool { showMe.map { $0.armed || showMeOnce } ?? false }

    /// ⌘Return: the words go, then Show me; with nothing typed on a Done card, Show me its reply.
    func showMeReturn() {
        guard showMe != nil else { return send() }
        if draftEmpty {
            if let t = selectedThread, case .done = t.state { explain(reply: t.id) }
            return
        }
        showMeOnce = true
        send()
    }

    /// Show me on a Done card.
    func explain(reply thread: String) {
        guard showMe != nil, let t = self.thread(thread), case .done = t.state else { return }
        explainers?.explain(reply: thread)
    }

    /// The pill: the panel opens on `preferred`, or closes. The draft is read again for the
    /// threads when the panel no longer targets an explainer.
    func toggleShowMeDock() {
        guard var state = showMe else { return }
        let targeted = state.target != nil
        state.open.toggle()
        state.size = .panel
        if state.open {
            state.expanded = false
            // Never an old one left selected: what's being made, else what's new, else the newest.
            state.selected = state.preferred?.id
            state.version = nil
        }
        state.note = nil
        showMe = state
        if targeted != (state.target != nil) { draftTargetChanged() }
    }

    func selectExplainer(_ id: String) {
        guard var state = showMe else { return }
        let targeted = state.target != nil
        if state.selected != id { state.version = nil }
        state.selected = id
        // Picked from the whole list: it plays, and the list folds again.
        state.expanded = false
        state.note = nil
        showMe = state
        if targeted != (state.target != nil) { draftTargetChanged() }
    }

    /// A version of the selected one, at the player's size; the newest follows the next one made.
    func selectVersion(_ index: Int) {
        guard var state = showMe, let chosen = state.chosen, chosen.versions.indices.contains(index) else { return }
        state.version = index == chosen.versions.count - 1 ? nil : index
        guard state != showMe else { return }
        animate(.fade) { showMe = state }
    }

    /// ⌥⌘← ⌥⌘→: the version before or after. False when there's no other.
    func stepVersion(forward: Bool) -> Bool {
        guard let state = showMe, state.open, let chosen = state.chosen, chosen.versions.count > 1 else { return false }
        let now = state.version ?? chosen.versions.count - 1
        selectVersion(min(max(now + (forward ? 1 : -1), 0), chosen.versions.count - 1))
        return true
    }

    // MARK: The player

    /// The open panel's web view, made when a ready explainer first plays and kept across selections and sizes; nil in a
    /// still (a shot) or a demo, which draw the poster.
    func showMeHost() -> ExplainerWebHost? {
        guard !still, !Store.isDemo, showMe?.open == true else { return nil }
        if let showMePlayer { return showMePlayer }
        let host = ExplainerWebHost()
        showMePlayer = host
        return host
    }

    /// The panel closed or went away: its web view goes.
    func showMeClosed() {
        showMePlayer?.close()
        showMePlayer = nil
    }

    /// The player's size. Bigger, it takes the keyboard (← → Space play it, Esc steps back); back in the panel the composer
    /// has it again.
    func resizeShowMe(_ size: RouterShowMeState.Size) {
        guard var state = showMe, state.open, state.chosen != nil, state.size != size else { return }
        if size == .window { state.back = state.size == .window ? .panel : state.size }
        animate(.spatial) { state.size = size; showMe = state }
        // Bigger, the player takes the keyboard; back in the panel the shield gives it to the composer (`RouterShield`).
        if size != .panel { showMePlayer?.focus() }
    }

    /// ⌥⌘Return or the panel's expand control: the page, or the panel again.
    func toggleShowMePage() {
        guard let state = showMe else { return }
        resizeShowMe(state.size == .page ? .panel : .page)
    }

    /// ⇧⌘Return or the stage control: the stage alone, or back where it came from.
    func toggleShowMeWindow() {
        guard let state = showMe else { return }
        resizeShowMe(state.size == .window ? state.back : .window)
    }

    /// Esc on a bigger player: one step back (the window to where it came from, the page to the panel).
    func shrinkShowMe() -> Bool {
        guard let state = showMe, state.open, state.size != .panel else { return false }
        resizeShowMe(state.size == .window ? state.back : .panel)
        return true
    }

    /// The player has the keyboard when its web view has it, or when it fills the page or the window with nothing typed.
    func showMePlayerKeys(focused: Bool) -> Bool {
        guard let state = showMe, state.open, state.shown?.stage == .ready else { return false }
        return focused || (state.size != .panel && draftEmpty)
    }

    /// Space for the player: play or pause.
    func playerKey(_ command: ExplainerWebHost.Command) {
        showMePlayer?.send(command)
    }

    /// → the next scene; ← this scene's start, or the one before when it has only just begun (as the kit's own keys did).
    func playerStep(forward: Bool) {
        guard let host = showMePlayer, let state = host.playback.state else { return }
        let t = host.playback.time(Date()), i = state.scene(at: t)
        let to = forward ? i + 1 : (t - state.scenes[i].start < 0.8 ? i - 1 : i)
        host.send(.scene(min(max(to, 0), state.scenes.count - 1)))
    }

    /// Return with the panel on an explainer: the words go to its thread, outside the Router (no decider, no log, no
    /// History: the thread is Fjord's own). Pictures, files and pills are refused plainly, not dropped.
    func followUp(_ explainer: ExplainerItem) {
        guard mentions.isEmpty else {
            showMe?.note = RouterShowMeLayout.wordsOnly
            return
        }
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        setDraft("")
        // The version it makes is the newest: the stage shows it as it's made.
        showMe?.version = nil
        guard let explainers else { return }
        Task { @MainActor [weak self] in
            do {
                try await explainers.followUp(explainer.id, words: words)
            } catch {
                guard let self else { return }
                // The words come back, with why.
                if self.draftEmpty { self.setDraft(words) }
                self.showMe?.note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - The composer's toggle

/// Show me at the composer's trailing edge, next to Return: its glyph, quiet off, the accent's tint on (it came from
/// you). "Show me ⌘⏎" shows beside it on hover, and stays while it's on.
struct RouterShowMeToggle: View {
    let model: RouterModel
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
        RouterButton(model: model, hit: .showMe("toggle"), action: { model.showMe?.armed.toggle() }) { hot, pressed in
            HStack(spacing: 2) {
                if on || hot {
                    HStack(spacing: 5) {
                        Text("Show me").font(CDS.sans(12, on ? .medium : .regular)).lineLimit(1).fixedSize()
                        RouterKeyHint(keys: RouterShowMeLayout.keys, ink: on ? CDS.Text.accent.opacity(0.6) : Router.Surface.keyInk)
                    }
                    .foregroundStyle(on ? CDS.Text.accent : CDS.Text.muted)
                    .padding(.horizontal, 6)
                    .frame(height: CDS.Composer.row)
                    // Over the words when it shows on hover: the composer's own ground.
                    .background(CDS.Surface.s3)
                    .transition(.opacity)
                }
                Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? CDS.Text.accent : hot ? CDS.Text.primary : CDS.Text.muted)
                    .frame(width: RouterShowMeLayout.toggle, height: CDS.Composer.row)
                    .background {
                        shape.fill(on ? CDS.Text.accent.opacity(hot ? Router.Surface.tintStrong : Router.Surface.tint)
                                      : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                            .hoverMotion(hot)
                    }
            }
        }
        .accessibilityLabel("Show me")
        .accessibilityValue(on ? "On" : "Off")
        .help("Return sends, then Fjord makes an explainer of the answer · ⌘Return does it once")
    }
}

/// After the destination row's place: Return sends there, then Show me.
struct RouterShowMeTail: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("· then").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
            Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.accent)
            Text("Show me").font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary)
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The destination row while the panel has an explainer: Return makes a new version of it with the words (or why it
/// can't).
struct RouterShowMeDestination: View {
    let explainer: ExplainerItem
    var note: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.accent)
                .frame(width: Router.Thinking.row, height: Router.Thinking.row)
            HStack(spacing: 5) {
                Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.secondary)
                Text(explainer.title).font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                RouterProjectBadge(project: "explainer")
            }
            .fixedSize()
            if let note {
                Text("· " + note).font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary).lineLimit(1)
            } else {
                Text("makes a new version").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: Router.Dock.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.map { "The explainer \(explainer.title): \($0)" }
            ?? "Return makes a new version of the explainer \(explainer.title)")
    }
}

// MARK: - The dock's pill

/// Beside the composer, on its control row: the glyph and a count, a blue dot when a finished one is unwatched; Fjord's
/// mark and what is being made while one is; what it waits for while one is queued. Pressed while the panel is open.
struct RouterShowMePill: View {
    let model: RouterModel
    let state: RouterShowMeState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous)
        RouterButton(model: model, hit: .showMe("dock"), action: { model.toggleShowMeDock() }) { hot, pressed in
            HStack(spacing: 6) {
                content
            }
            .font(CDS.sans(12)).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: 240)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: CDS.Composer.row)
            .background {
                shape.fill(state.open || pressed ? Router.Surface.pressed : hot ? Router.Surface.chosenHover : Router.Surface.quiet)
                    .hoverMotion(hot)
            }
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        if state.open {
            // Open, the panel says the rest: the pill is the glyph and the count, pressed.
            Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.secondary)
            Text("\(state.explainers.count)").monospacedDigit().foregroundStyle(CDS.Text.secondary)
        } else if let making = state.making {
            RouterThinking(tint: CDS.Text.secondary, size: Router.Thinking.row, label: "Making an explainer")
            (Text("Making").foregroundColor(CDS.Text.muted) + Text(" · ").foregroundColor(CDS.Text.muted)
                + Text(making.title).foregroundColor(CDS.Text.secondary))
        } else if let queued = state.queued {
            Image(systemName: "clock").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted)
            Text("After \(model.threadName(queued)) answers").foregroundStyle(CDS.Text.secondary)
        } else {
            Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.secondary)
            Text("\(state.explainers.count)").monospacedDigit().foregroundStyle(CDS.Text.secondary)
            if state.unseen {
                Circle().fill(CDS.Text.accent).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var label: String {
        if let making = state.making { return "Making the explainer \(making.title)" }
        if state.queued != nil { return "An explainer is queued" }
        return "\(state.explainers.count) explainers" + (state.unseen ? ", one not watched" : "")
    }
}

extension RouterModel {
    /// The thread an explainer explains, as its line names it (else T3's title).
    func threadName(_ e: ExplainerItem) -> String {
        thread(e.source)?.name ?? (e.thread.isEmpty ? "its thread" : e.thread)
    }
}

// MARK: - The store's side

extension Store: RouterExplainers {
    /// The engine's list on the page: only with the Router on and T3 holding the explainers project.
    func showMeChanged(_ items: [ExplainerItem], on page: RouterModel? = nil) {
        let page = page ?? routerPage
        guard router.enabled, explainers.ready else {
            if page.showMe != nil { page.showMe = nil }
            return
        }
        var state = page.showMe ?? RouterShowMeState()
        state.update(items)
        if state != page.showMe { page.showMe = state }
    }

    func explain(reply thread: String) { explainers.requested(reply: thread) }

    func followUp(_ explainer: String, words: String) async throws {
        try await explainers.followUp(explainer, words: words)
    }

    func watched(_ explainer: String) { explainers.watched(explainer) }

    func open(explainer: String) { _ = openThread(explainer) }
}
