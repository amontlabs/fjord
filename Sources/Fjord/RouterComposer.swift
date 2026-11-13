import AppKit
import SwiftUI

/// Where you write to the Router, drawn as the Claude Code tab's composer (docs/design/spec/composer-overlays.md): the
/// context strip over the input box (the thread the message replies to, with its ×; Backspace at the start takes it off) and
/// the input box (Return sends, ⇧Return starts a new line, see `RouterKeys`). Typing @ suggests projects, sessions,
/// notifications and categories over the caret (↑↓, Return or Tab picks, Esc dismisses); a pick is a pill in the text where
/// the @ was (see `MentionField`, `RouterPointer`). Stop while the Router works. On macOS 26 it floats over the page (glass-plan
/// §5.4): the card and the strip are Regular glass (their field and chips as they are), or `s3` where the chrome is opaque.
struct RouterComposer: View {
    let store: Store
    @Bindable var model: RouterModel
    /// Mirrors the text view's first responder; `focusTick` asks it for the keyboard.
    @State private var focused = false
    @State private var focusTick = 0
    /// The suggestions' height, to hang them over the caret.
    @State private var listHeight: CGFloat = 0
    /// Where the field is in its window: tells its text view from every other one.
    @State private var anchor = FieldAnchor()
    /// The @ word's first character in the card (x from its leading edge, y of its line's top from its top), once known.
    @State private var mentionAt: CGPoint?
    @State private var windowHeight: CGFloat = 0
    /// The card's width: the suggestions stay inside it.
    @State private var cardWidth: CGFloat = 0
    @State private var hovering = false
    @State private var overButton = false
    @Environment(\.colorSchemeContrast) private var contrast
    /// The window's chrome: none outside the app window (a test's composer alone), which draws as opaque.
    @Environment(Chrome.self) private var chrome: Chrome?

    private typealias C = CDS.Composer

    /// Over the page (macOS 26), where something moves under it.
    private var floats: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Glass rather than the opaque fill.
    private var glass: Bool { floats && chrome?.mode == .glass }

    var body: some View {
        let working = store.routerDispatcher.isBusy
        let on = model.canSend(store)
        let suggestions = model.suggestions(store)
        VStack(alignment: .leading, spacing: 0) {
            // A message of yours waiting for you to say where it goes.
            if let ask = store.routerDispatcher.askBacks.last {
                RouterAskPill(store: store, ask: ask).padding(.bottom, C.dockGap).transition(.opacity)
            }
            // Who your words go to, as the Code tab's strip over its composer: the thread you reply to.
            if store.routerBriefs.focused != nil {
                strip.padding(.bottom, C.dockGap)
            } else if store.routerPreview.visible {
                // Where the draft will go: Fjord's decision for it, its guesses when it isn't sure, or the place you picked.
                RouterPreviewChip(store: store).padding(.bottom, C.dockGap).transition(.opacity)
            }
            card(on: on, working: working)
                // Over the card, so it never pushes the chat about.
                .overlay(alignment: .topLeading) {
                    if !suggestions.isEmpty {
                        let at = mentionAt ?? CGPoint(x: 0, y: C.pad + (C.row - 20) / 2)
                        let place = MentionList.place(caretX: at.x, available: cardWidth)
                        MentionList(suggestions: suggestions, index: model.mentionIndex, width: place.width, store: store,
                                    hover: { model.mentionIndex = $0 }) { model.pickMention($0) }
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                            .offset(x: place.x, y: at.y - C.mentionOffset - listHeight)
                            .transition(.opacity)
                    }
                }
                .zIndex(1)
        }
        .motion(.fade, value: suggestions.map(\.id))
        .motion(.fade, value: store.routerPreview.highlighted)
        // The preview follows the draft as it will be sent (never waiting on it: a read runs after a pause, cancelled by the
        // next keystroke).
        .onChange(of: model.draft) { model.previewDraft(store: store) }
        .onChange(of: model.pointers) { model.previewDraft(store: store) }
        .onChange(of: store.routerBriefs.focused) { model.previewDraft(store: store) }
        .onAppear {
            if on { requestFocus() }
        }
        .onChange(of: model.focusRequest) { requestFocus() }
        .onDisappear {
            focused = false
            model.composerFocused = false
        }
        // The @ suggestions follow the caret, wherever it is in the text.
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
            // Only the composer's own editor, while it edits: in its window, where its field is (not another window's, nor a
            // form's "Other…"), and still the window's first responder (ending its editing, when the composer loses the
            // keyboard, moves the editor's selection; that isn't the caret moving).
            guard let editor = note.object as? NSTextView, anchor.owns(editor), editor.window?.firstResponder === editor
            else { return }
            model.followCaret(editor)
            mentionAt = mentionPoint(editor)
        }
        .onChange(of: model.caretRequest) { _, request in
            guard request != nil else { return }
            // After the field has the new text.
            DispatchQueue.main.async { placeCaret() }
        }
    }

    /// Puts the caret where the model asked (`caretRequest`) once the composer's text view has the keyboard: at once when
    /// it has it, else as it takes it (a notification's "Open in Router" prefilled before the Router's page showed).
    private func placeCaret() {
        guard let request = model.caretRequest,
              let editor = model.editor ?? (NSApp.keyWindow?.firstResponder as? NSTextView),
              editor.window?.firstResponder === editor,
              // While an input method composes, the field places it once the composition ends (`MentionField`).
              !editor.hasMarkedText() else { return }
        model.caretRequest = nil
        let at = min(request, (editor.string as NSString).length)
        editor.setSelectedRange(NSRange(location: at, length: 0))
        model.followCaret(editor)
        mentionAt = mentionPoint(editor)
    }

    // MARK: Strip

    /// The thread the message replies to, removable.
    private var strip: some View {
        FlowLayout(spacing: C.stripGap) {
            // The threads your words go to.
            ForEach(store.routerBriefs.mentioned, id: \.self) { target in
                let title = store.routerBriefs.title(target)
                // What Return does to it: starts or continues it ("send to"), steers the turn under way, or (an agent that
                // can't take words while it works) queues behind it. ⌥Return queues instead.
                let line = store.pickLine(store.routerBriefs.threadID(target), title: title)
                ComposerChip(symbol: line.steering ? "arrow.triangle.turn.up.right.diamond" : "arrow.right", text: line.text,
                             tint: line.steering ? CDS.Text.accent : CDS.Text.warning,
                             removeLabel: "Stop replying to \(title)") { store.routerBriefs.unmention(target) }
                    .help(line.steering ? "Steers it now and interrupts the tool it is running. ⌥Return waits for the turn instead." : "")
            }
        }
        .padding(CDS.Density.compact.pad.md)
        .frame(maxWidth: .infinity, minHeight: C.stripHeight, alignment: .leading)
        .modifier(ComposerMaterial(shape: RoundedRectangle(cornerRadius: C.stripRadius, style: .continuous), glass: glass,
                                   fill: floats ? CDS.Surface.s3 : CDS.alpha(0.05)))
    }

    // MARK: Card

    private func card(on: Bool, working: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: C.radius, style: .continuous)
        let hot = focused || (hovering && !overButton)
        // On glass, the material draws its own edge: the ring only says the card is hot.
        let ring = contrast == .increased ? CDS.Text.primary.opacity(0.5) : hot ? C.ringHot : glass ? .clear : C.ring
        return ZStack(alignment: .bottomTrailing) {
            field(on: on)
                .padding(.leading, C.pad + C.textInset)
                // The actions' `pl-1.5` and their 28 pt cell.
                .padding(.trailing, C.pad + 6 + C.row)
                .padding(.vertical, C.pad + (C.row - 20) / 2)
                .frame(maxWidth: .infinity, minHeight: C.minHeight, alignment: .topLeading)
            action(on: on, working: working)
                .onHover { overButton = $0 }
                .padding(C.pad)
        }
        .modifier(ComposerMaterial(shape: shape, glass: glass, fill: CDS.Surface.s3))
        .background(AnchorView(anchor: anchor) { windowHeight = $0 })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
        .overlay(shape.strokeBorder(ring, lineWidth: 1))
        // Glass has a shadow of its own.
        .bakedShadow(glass ? .clear : focused ? C.dropFocus : C.drop, .rounded(C.radius), radius: 10, y: 4)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { if on { focusTick &+= 1 } }
        .motion(.easeOut(duration: 0.2), value: hot)
    }

    private func field(on: Bool) -> some View {
        // `min(24rem, 40svh)` less the card's padding, in 20 pt lines.
        let limit = min(C.maxHeight, windowHeight > 0 ? windowHeight * C.maxHeightShare : C.maxHeight)
        let lines = max(1, Int((limit - 2 * C.pad - (C.row - 20)) / 20))
        let mentions = store.routerBriefs.mentioned.count
        let placeholder = mentions > 1 ? "Reply to these \(mentions) threads" : mentions == 1 ? "Reply to this thread" : "Tell the Router what to pass on, or ask"
        // Told on every change of the text view's first responder, not on a change of `focused`: the kept composer given the
        // keyboard again after a close may still read focused, and the model must hear it has the keyboard again.
        return MentionField(store: store, model: model, maxHeight: CGFloat(lines) * 20, editable: on, focusTick: focusTick) { now in
            focused = now
            model.composerFocused = now
            if now {
                DispatchQueue.main.async {
                    placeCaret()
                    typePendingKeys()
                }
            }
        }
        .frame(minHeight: 20)
        .background(alignment: .topLeading) {
            if model.draft.isEmpty {
                Text(placeholder).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    /// Claude's ghost icon button: send (ArrowReturn) or, while the Router works, stop (StopCircle).
    @ViewBuilder private func action(on: Bool, working: Bool) -> some View {
        if working {
            GhostIcon(symbol: "stop.circle", label: "Stop") { store.routerDispatcher.stopAll() }
                .accessibilityHint("Stops the Router's runs")
                .tip("Stop", "Stops the Router's runs")
        } else {
            let empty = !on || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            GhostIcon(symbol: "arrow.turn.down.left", label: "Send") { model.send(store: store) }
                .disabled(empty)
                .tip("Send", model.sendRefused ?? "Return · ⌥Return to wait for the turn under way · ⇧Return for a new line")
        }
    }

    // MARK: Caret

    /// Where the @ word before the caret starts, in the card: x of its "@", y of its line's top.
    private func mentionPoint(_ editor: NSTextView) -> CGPoint? {
        guard let view = anchor.view, let window = editor.window else { return nil }
        let text = editor.string as NSString
        let caret = editor.selectedRange().location
        guard caret != NSNotFound, caret <= text.length else { return nil }
        let at = text.range(of: "@", options: .backwards, range: NSRange(location: 0, length: caret))
        let range = at.location == NSNotFound ? NSRange(location: caret, length: 0) : NSRange(location: at.location, length: 1)
        let screen = editor.firstRect(forCharacterRange: range, actualRange: nil)
        guard screen != .zero else { return nil }
        let local = view.convert(window.convertPoint(fromScreen: CGPoint(x: screen.minX, y: screen.maxY)), from: nil)
        let top = view.isFlipped ? local.y : view.bounds.height - local.y
        return CGPoint(x: local.x, y: top)
    }

    private func requestFocus() {
        DispatchQueue.main.async {
            focusTick &+= 1
            DispatchQueue.main.async { typePendingKeys() }
        }
    }

    /// The keys that sent the focus here (typing with no field focused), typed into the composer in order.
    private func typePendingKeys() {
        guard !model.pendingKeys.isEmpty,
              let editor = (model.pendingKeys.first?.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView else { return }
        let keys = model.pendingKeys
        model.pendingKeys = []
        editor.moveToEndOfDocument(nil)
        keys.forEach(editor.keyDown(with:))
    }
}

/// The composer's ground: Regular glass in `shape` (macOS 26, glass chrome), else `fill`. The same views either way, so
/// a switch of the chrome (Reduce Transparency) keeps the field and its focus. While the window is captured for the morph,
/// glass draws `fill` instead (`GlassCapture`).
struct ComposerMaterial<S: Shape>: ViewModifier {
    let shape: S
    let glass: Bool
    let fill: Color
    @Environment(\.glassCapture) private var capture

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            let look = GlassLook.of(glass: glass, capturing: capture?.on == true)
            content
                .background(shape.fill(fill).opacity(look.fill ? 1 : 0))
                .glassEffect(look.glass ? .regular : .identity, in: shape)
        } else {
            content.background(shape.fill(fill))
        }
    }
}

/// CDS's ghost icon-only Button in the composer's 28 pt row: transparent, white 7.5% on hover, radius 6, a 16 pt glyph in
/// the primary ink; 40% when disabled.
private struct GhostIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(CDS.Text.primary)
                .frame(width: CDS.Composer.row, height: CDS.Composer.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous),
                                          rest: .clear, hover: CDS.Fill.ghostHover, active: CDS.Fill.ghostSelected,
                                          pressed: CDS.Fill.ghostSelected))
        .accessibilityLabel(label)
    }
}

/// A chip in the strip over the composer, as the Code tab's diff chip (24 pt, radius 6, white 10%, `shadow-field`): what
/// goes with the message, in the strip's mono 13 muted, and a ghost × to take it off.
struct ComposerChip: View {
    let symbol: String?
    let text: String
    let tint: Color
    let removeLabel: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(text).font(CDS.mono(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
            ChipClose(label: removeLabel, action: remove)
        }
        .padding(.leading, CDS.Density.compact.pad.md)
        .padding(.trailing, 3)
        .frame(height: CDS.Density.compact.control)
        .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous).fill(CDS.Fill.secondary)
            .shadow(color: CDS.fieldShadow, radius: 1, y: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }
}

/// The chip's ×: ghost, muted, primary and white 7.5% on hover.
struct ChipClose: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                .foregroundStyle(hovering ? CDS.Text.primary : CDS.Text.muted)
                .frame(width: CDS.Density.compact.controlNested, height: CDS.Density.compact.controlNested)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hovering ? CDS.Fill.ghostHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// The composer field's place on screen, kept by an empty AppKit view behind it: a text view is the composer's when it is in
/// the same window and what it shows is inside the field (SwiftUI doesn't hand out the field's own text view): the part of
/// its text in view, not the whole of a long draft scrolled in it, which reaches far out of the field. It also tells its window's
/// height, for the field's `min(24rem, 40svh)`.
final class FieldAnchor {
    weak var view: NSView?

    func owns(_ editor: NSTextView) -> Bool {
        guard let view, let window = view.window, editor.window === window else { return false }
        let field = view.convert(view.bounds, to: nil)
        let shown = editor.visibleRect
        guard !shown.isEmpty else { return false }
        let text = editor.convert(shown, to: nil)
        return field.contains(CGPoint(x: text.midX, y: text.midY))
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: FieldAnchor
    var windowHeight: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowWatcher {
        let view = WindowWatcher()
        view.report = windowHeight
        anchor.view = view
        return view
    }

    func updateNSView(_ view: WindowWatcher, context: Context) {
        anchor.view = view
        view.report = windowHeight
    }

    final class WindowWatcher: NSView {
        var report: (CGFloat) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            send(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                              queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.send(window) }
            }
        }

        private func send(_ window: NSWindow) {
            let height = window.contentLayoutRect.height
            DispatchQueue.main.async { [report] in report(height) }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// "Where should this go?" over the composer: your words, why it asks, and the places to pick (⌘1–⌘4 by key position), or
/// Dismiss: nothing is sent until you pick.
struct RouterAskPill: View {
    let store: Store
    let ask: RouterAskBack

    var body: some View {
        let dispatcher = store.routerDispatcher
        let options = ask.options.filter { dispatcher.eligible($0.target, store: store) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.warning)
                    .frame(width: 14, height: 14)
                Text(ask.message).cdsText((13, 18), .regular, CDS.Text.primary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Text(ask.note ?? "Where should this go?").cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1)
                Spacer(minLength: 0)
                ChipClose(label: "Dismiss") { dispatcher.dismiss(ask.id) }
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(options.prefix(RouterKeys.pickKeys.count).enumerated()), id: \.element.id) { i, option in
                    ClaudeButton(option.title, variant: option.target == ask.suggestion ? .primary : .secondary, size: .sm,
                                 shortcut: ["cmd", "\(i + 1)"]) {
                        _ = dispatcher.pick(ask.id, target: option.target)
                    }
                    .help(option.detail)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(CDS.Surface.s1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CDS.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where should “\(ask.message)” go?")
    }
}

/// Where the draft goes, over the composer: "→ <thread>" (or "→ new thread in <project>") when Fjord is sure; its best guess
/// highlighted and up to 2 alternatives when it isn't (Return sends to the highlighted one, a click picks another); "finding
/// where it goes" while a Return waits for the decision. The chevron opens the menu (its places, then a new thread); the × waves
/// the highlighted place off (as Esc does) or takes a pick back.
struct RouterPreviewChip: View {
    let store: Store

    var body: some View {
        let preview = store.routerPreview
        let d = CDS.Density.compact
        let options = preview.destination.map { $0.sure ? Array($0.options.prefix(1)) : $0.options } ?? []
        let sure = preview.destination?.sure == true && preview.pinned == nil
        HStack(spacing: 4) {
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
                .foregroundStyle(CDS.Text.accent).accessibilityHidden(true)
            if preview.deciding && preview.destination == nil {
                Text("finding where it goes…").font(CDS.sans(d.body.0)).foregroundStyle(CDS.Text.muted)
            } else if preview.destination?.answer == true, preview.pinned == nil {
                Text("Fjord answers here").font(CDS.sans(d.body.0, .medium)).foregroundStyle(CDS.Text.primary)
            } else if sure, let target = options.first {
                Text(Self.name(target, store: store) ?? "").font(CDS.sans(d.body.0, .medium)).foregroundStyle(CDS.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
            } else if let pinned = preview.pinned, !options.contains(pinned) {
                Text(Self.name(pinned, store: store) ?? preview.pinnedTitle ?? "").font(CDS.sans(d.body.0, .medium))
                    .foregroundStyle(CDS.Text.primary).lineLimit(1)
            } else if options.isEmpty {
                Text("not sure where it goes: pick a place").font(CDS.sans(d.body.0)).foregroundStyle(CDS.Text.muted)
            } else {
                // Not sure: the guess highlighted (where Return sends), the alternatives beside it.
                ForEach(options, id: \.self) { target in
                    let on = target == preview.highlighted
                    Button { preview.pick(target, store: store) } label: {
                        Text(Self.name(target, store: store) ?? "").font(CDS.sans(d.body.0, on ? .medium : .regular))
                            .foregroundStyle(on ? CDS.Text.primary : CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 6).frame(height: d.control - 6)
                            .background(RoundedRectangle(cornerRadius: d.radius - 2, style: .continuous)
                                .fill(on ? CDS.Fill.ghostSelected : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: d.radius - 2, style: .continuous)
                                .strokeBorder(on ? CDS.Text.accent.opacity(0.6) : CDS.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Return sends it here" : "Send it here instead")
                    .accessibilityLabel((on ? "Sends to " : "Or ") + (Self.name(target, store: store) ?? ""))
                }
            }
            if !(preview.deciding && preview.destination == nil) {
                Button { preview.menuOpen.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                        .frame(width: 16, height: d.control).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Other places, or a new thread")
                .accessibilityLabel("Other places")
                .popover(isPresented: Binding(get: { preview.menuOpen }, set: { preview.menuOpen = $0 }), arrowEdge: .top) {
                    RouterPreviewMenu(store: store)
                }
                ChipClose(label: preview.pinned == nil ? "Not there" : "Unpick") {
                    if preview.pinned == nil { preview.dismiss() } else { preview.unpin() }
                }
            }
        }
        .padding(.leading, CDS.Density.compact.pad.md)
        .padding(.trailing, 3)
        .frame(height: CDS.Density.compact.control)
        .background(RoundedRectangle(cornerRadius: d.radius, style: .continuous).fill(CDS.Fill.secondary)
            .shadow(color: CDS.fieldShadow, radius: 1, y: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.highlighted.flatMap { Self.name($0, store: store) }.map { "Goes to \($0)" } ?? "Where it goes")
    }
}

extension RouterPreviewChip {
    /// A place's name as the page shows it: the brief's highlight words for a thread its brief names, else the place's title.
    static func name(_ target: String, store: Store) -> String? {
        if let t = RouteTarget(target)?.briefTarget(store: store), let words = store.routerBriefs.highlightName(t) { return words }
        if case .newThread(let p)? = RouteTarget(target) { return "new thread in \(RouteTarget.projectName(p, store: store))" }
        return store.routerDispatcher.option(target, store: store)?.title
    }
}

/// The preview's menu: its places, best first, then a new thread in their projects; a click picks one.
private struct RouterPreviewMenu: View {
    let store: Store

    var body: some View {
        let d = CDS.Density.compact
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.routerPreview.menu(store: store)) { option in
                Button { store.routerPreview.pick(option.target, store: store) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: d.gap.xs) {
                        Text(option.title).font(CDS.sans(d.body.0)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                        Text(option.detail).font(CDS.sans(d.caption.0)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, d.pad.md)
                    .frame(height: d.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(d.pad.xs)
        .frame(width: 320)
    }
}
