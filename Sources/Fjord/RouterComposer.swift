import AppKit
import SwiftUI

/// Where you write to the Router, drawn as the Claude Code tab's composer (docs/design/spec/composer-overlays.md): the
/// context strip over the card (the card the message replies to, with its ×; Backspace at the start takes it off) and the
/// card (Return sends, ⇧Return starts a new line, see `RouterKeys`). Typing @ suggests projects, sessions, notifications and
/// categories over the caret (↑↓, Return or Tab picks, Esc dismisses); a pick is a pill in the text where the @ was (see
/// `MentionField`, `RouterPointer`). Once typing pauses, Jev's
/// pick of where the message goes is a ghost chip in the strip, its card or row marked on the page: a click fixes it, Esc
/// waves it off (see `RouterLiveTarget`). Stop while the Router works. On macOS 26 it floats over the page (glass-plan
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
            // Your messages on their way, rising from here until they fly to where they went.
            FlightStack(store: store, flights: model.flights, showsOtherAsks: model.layout == .canvas)
                .padding(.bottom, model.flights.pills.isEmpty && (model.layout != .canvas || store.routerDispatcher.askBacks.isEmpty) ? 0 : C.dockGap)
            // Who your words go to, as the Code tab's strip over its composer: the card's session, the projects you tagged.
            if model.replyTo != nil || model.live.pinned != nil || model.live.prediction != nil || model.editing != nil
                || !model.live.recipients.isEmpty || !model.live.chips.isEmpty || model.live.dividing {
                strip.padding(.bottom, C.dockGap)
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
            // And what it can go to: a chip whose target was addressed, superseded or is gone goes with it.
            LiveTargetWatch(store: store, model: model)
        }
        .motion(.fade, value: suggestions.map(\.id))
        .motion(.fade, value: model.live.shown)
        // Jev's pick follows the draft and what fixes its target; the page marks its card or row while it shows.
        .onChange(of: model.draft) { model.predictTarget(store: store) }
        .onChange(of: model.pointers) { model.predictTarget(store: store) }
        .onChange(of: model.replyTo) { model.predictTarget(store: store) }
        .onChange(of: model.live.pinned) { model.predictTarget(store: store) }
        .onChange(of: model.live.prediction?.mark) { old, new in model.markPrediction(from: old, to: new) }
        .onChange(of: model.highlighted) { _, now in
            if now == nil, let mark = model.live.prediction?.mark { model.highlighted = mark }
        }
        .onAppear {
            if on { requestFocus() }
            // What was pinned or picked before the page was left may be gone since (the watch below only sees changes from
            // now on). A pick still good for the draft as it is stays, and asks Jev nothing: only new words are asked about.
            model.live.revalidate(store: store)
            model.predictTarget(store: store)
            // Its card or row marked again, unless something else is marked for now (it comes back after).
            if model.highlighted == nil, let mark = model.live.prediction?.mark { model.markPrediction(from: nil, to: mark) }
        }
        .onChange(of: model.focusRequest) { requestFocus() }
        .onDisappear {
            focused = false
            model.composerFocused = false
            model.markPrediction(from: model.live.prediction?.mark, to: nil)
            // Nothing of the draft goes to Jev while the composer isn't there.
            model.live.suspend()
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

    /// The card the message replies to, removable.
    private var strip: some View {
        FlowLayout(spacing: C.stripGap) {
            if let editing = model.editing {
                let title = store.claudeSessions[editing.session]?.title ?? "the session"
                ComposerChip(symbol: "pencil", text: "Editing your message to \(title)", tint: CDS.Text.accent,
                             removeLabel: "Stop editing (the draft stays)") { model.editing = nil }
                Text("Sends to a fork from before it; files the agent changed aren't rolled back")
                    .cdsText((12, 16), .regular, CDS.Text.muted)
            }
            if let id = model.replyTo, let card = store.router.cards.first(where: { $0.id == id }) {
                ComposerChip(symbol: "arrow.right", text: card.title, tint: card.kind.color,
                             removeLabel: "Stop replying to \(card.title)") { model.replyTo = nil }
            }
            if model.live.pinned != nil, let title = model.live.pinnedTitle {
                ComposerChip(symbol: "arrow.right", text: title, tint: CDS.Text.accent,
                             removeLabel: "Let the Router decide where this goes") { model.live.reset() }
            }
            // Items ⌘-clicked on the Brief: each gets the whole message.
            ForEach(model.live.recipients, id: \.self) { target in
                let title = RouterFlights.destination(target, store: store) ?? "a session"
                ComposerChip(symbol: "arrow.right", text: title, tint: CDS.Text.accent,
                             removeLabel: "Don't send it to \(title)") { model.live.recipients.removeAll { $0 == target } }
            }
            // While editing, the draft goes to a fork: no pick of Jev's is offered for it.
            if model.editing == nil {
                if !model.live.chips.isEmpty {
                    // Several places: each with its words, in place of the one chip.
                    DivisionChips(chips: model.live.chips)
                } else if model.live.dividing {
                    DividingChip()
                } else if let prediction = model.live.prediction {
                    PredictionChip(prediction: prediction) { model.pinPrediction(store: store) }
                }
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
        .flightFrame("composer")
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
        let placeholder = model.replyTo == nil ? "Tell the Router what to pass on, or ask" : "Reply, or tell the Router"
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
                .tip("Send", model.sendRefused ?? "Return · ⇧Return for a new line")
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

/// Jev's pick while you type: a ghost of the reply chip (dashed, no fill, no ×), muted; a click fixes it as the target.
private struct PredictionChip: View {
    let prediction: RouterLiveTarget.Prediction
    let pin: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
        Button(action: pin) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted)
                    .accessibilityHidden(true)
                Text(prediction.title + (prediction.unsure ? "?" : "")).font(CDS.mono(13)).foregroundStyle(hovering ? CDS.Text.secondary : CDS.Text.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, CDS.Density.compact.pad.md)
            .frame(height: CDS.Density.compact.control)
            .background(shape.fill(hovering ? CDS.Fill.ghostHover : .clear))
            .overlay(shape.strokeBorder(CDS.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip("Jev \(prediction.unsure ? "isn't sure, maybe" : "thinks") this goes to \(prediction.detail)", "Click to fix it, Esc to clear")
        .accessibilityLabel("Jev \(prediction.unsure ? "isn't sure, maybe" : "thinks") this goes to \(prediction.detail)")
        .accessibilityHint("Fixes it as where the message goes")
    }
}

/// The draft divided into several places, while you type: a ghost chip for each part (its place, then its words), not clickable;
/// Return sends them as shown. A part that waits for another place's answer is marked, and is held until you send it.
private struct DivisionChips: View {
    let chips: [RouterLiveTarget.DivisionChip]

    var body: some View {
        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
            let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
            HStack(spacing: 4) {
                Image(systemName: chip.waits ? "pause.circle" : Self.glyph(chip.target)).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CDS.Text.muted).accessibilityHidden(true)
                Text(chip.title).font(CDS.mono(13).weight(.medium)).foregroundStyle(CDS.Text.secondary).lineLimit(1)
                    .layoutPriority(1)
                Text(chip.words).font(CDS.mono(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, CDS.Density.compact.pad.md)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(height: CDS.Density.compact.control)
            .overlay(shape.strokeBorder(CDS.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .tip(chip.waits ? "Held until you send it" : "Jev will send this to \(chip.detail)", chip.words)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(chip.waits ? "Held for" : "Sends to") \(chip.detail): \(chip.words)")
        }
    }

    /// The glyph the history gives a message that went to a place like it.
    static func glyph(_ target: String) -> String {
        if target.hasPrefix("new:") { return "plus.square" }
        if target.hasPrefix("answer:") { return "checkmark" }
        if target.hasPrefix("session:") { return "paperplane" }
        return target == "question" ? "questionmark.bubble" : "slider.horizontal.3"
    }
}

/// The divider being asked of a draft Jev read as for several places: a quiet ghost chip until its parts are in.
private struct DividingChip: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted)
                .accessibilityHidden(true)
            Text("dividing…").font(CDS.mono(13)).foregroundStyle(CDS.Text.muted)
        }
        .padding(.horizontal, CDS.Density.compact.pad.md)
        .frame(height: CDS.Density.compact.control)
        .overlay(shape.strokeBorder(CDS.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jev is dividing this between places")
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

/// The @ suggestions as Claude's MentionDropdown: what the word matches, under its section's heading (projects, sessions,
/// notifications, categories), the one ↑↓ (or the pointer) picked lit.
struct MentionList: View {
    let suggestions: [MentionSuggestion]
    let index: Int
    var width: CGFloat = CDS.Composer.mentionWidth
    var store: Store? = nil
    var hover: ((Int) -> Void)? = nil
    let pick: (MentionSuggestion) -> Void

    /// Where the list goes under a caret at `caretX` in a card `available` wide (0 while that isn't known yet): no wider than
    /// the card, and moved left as far as it takes to end inside it.
    static func place(caretX: CGFloat, available: CGFloat, preferred: CGFloat = CDS.Composer.mentionWidth)
        -> (x: CGFloat, width: CGFloat) {
        guard available > 0 else { return (max(0, caretX), preferred) }
        let width = min(preferred, available)
        return (min(max(0, caretX), available - width), width)
    }

    var body: some View {
        let d = CDS.Density.compact
        let shape = RoundedRectangle(cornerRadius: d.panelRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, row in
                // A section's heading over its first row, when the list holds more than one section.
                if i == 0 ? Set(suggestions.map(\.section)).count > 1 : suggestions[i - 1].section != row.section {
                    Text(row.section.title).font(CDS.sans(d.caption.0, .medium)).foregroundStyle(CDS.Text.muted)
                        .padding(.horizontal, d.pad.md).padding(.top, i == 0 ? 2 : 6).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 2) {
                    Button { pick(row) } label: {
                        HStack(spacing: d.gap.xs) {
                            Image(systemName: row.look.symbol ?? "folder").font(.system(size: 12))
                                .foregroundStyle(row.look.tint ?? CDS.Text.secondary)
                                .frame(width: d.icon, height: d.icon)
                            HStack(alignment: .firstTextBaseline, spacing: d.gap.xs) {
                                Text(row.insertsText ? row.name : "@" + row.name).font(CDS.sans(d.body.0)).foregroundStyle(CDS.Text.primary)
                                    .lineLimit(1).layoutPriority(1)
                                Text(row.detail).font(CDS.sans(d.caption.0)).foregroundStyle(CDS.Text.muted)
                                    .lineLimit(1).truncationMode(row.folder == nil ? .tail : .head)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, d.pad.md)
                        .frame(maxWidth: .infinity)
                        .frame(height: d.control)
                        .background(RoundedRectangle(cornerRadius: d.radius, style: .continuous)
                            .fill(i == index ? CDS.Fill.ghostHover : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { hover?(i) } }
                    if let folder = row.folder, let store {
                        RunsOnProjectMenu(store: store, folder: folder, opensGuestFolderPromptForShot: store.routerPlacementShot)
                            .padding(.trailing, 3)
                    }
                }
                .accessibilityLabel("\(row.section.title.dropLast()) \(row.name), \(row.detail)")
                .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        .padding(d.pad.xs)
        .frame(width: width)
        .background(shape.fill(CDS.Surface.s3))
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
        .shadow(color: CDS.PanelShadow.near.color, radius: CDS.PanelShadow.near.radius, y: CDS.PanelShadow.near.y)
        .shadow(color: CDS.PanelShadow.far.color, radius: CDS.PanelShadow.far.radius, y: CDS.PanelShadow.far.y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    /// `~/code/lookout` rather than the whole path.
    static func shortPath(_ folder: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
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

/// Where a message can go now, watched in a view of its own (the composer doesn't redraw for every session's activity): when
/// it changes, Jev's pick and the target you pinned are checked against it (`RouterModel.revalidateTarget`). Only while
/// there is a pick or a pin to check: with neither, nothing is worked out as the sessions change.
private struct LiveTargetWatch: View {
    let store: Store
    let model: RouterModel

    var body: some View {
        Group {
            if model.live.pinned != nil || model.live.prediction != nil || !model.live.chips.isEmpty || !model.live.recipients.isEmpty {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                    .onChange(of: RouterModel.targets(store, predicted: model.live.prediction?.target,
                                                      watching: model.live.watchedTargets)) {
                        model.revalidateTarget(store: store)
                    }
            }
        }
        // The recipients picked on the Brief fix where the message goes: the pick or the parts shown for it go.
        .onChange(of: model.live.recipients) { model.predictTarget(store: store) }
    }
}

extension RouterModel {
    /// What a pick or a pin can go to, and where the page shows it: the open cards, the working sessions, the sessions kept.
    struct Targets: Equatable {
        var cards: [String]
        var working: Set<String>
        var sessions: Set<String>
        /// The `new:<folder>` targets among the ones the pick, the pin or the parts shown name whose project is still known: a
        /// code-folder scan that drops one changes this.
        var projects: Set<String> = []
        /// The words Jev's pick shows for its target, as they would be now (a session renamed changes them).
        var predicted: String? = nil

        func contains(_ id: String) -> Bool { cards.contains(id) || working.contains(id) || sessions.contains(id) }
    }

    /// The open cards as stored (the page's order doesn't matter here: no sort of every card), the working rows and the
    /// sessions kept as sets.
    static func targets(_ store: Store, predicted: String? = nil, watching: [String] = []) -> Targets {
        let tasks = store.routerTasks
        let words = predicted.flatMap { target in
            store.routerDispatcher.option(target, store: store).map {
                RouterLiveTarget.title(target, $0) + "\n" + store.routerDispatcher.describe(target, store: store)
            }
        }
        // `projectFolders` is what a scan changes and the view sees; Scratch ("") is no folder of it.
        let known = watching.isEmpty ? [] : Set(store.projectFolders)
        let projects = Set(watching.lazy.filter {
            guard $0.hasPrefix("new:") else { return false }
            let folder = String($0.dropFirst(4))
            return known.contains(folder) || store.isProjectFolder(folder)
        })
        return Targets(cards: store.router.cards.filter { $0.isOpen && RouterPage.shows($0, tasks: tasks) }.map(\.id),
                       // The Working rows' sessions, as `routerWorkingRows` picks them, unsorted: a set.
                       working: Set(store.allAgentRows.lazy
                           .filter { ($0.session.running && !$0.waitsForYou) || (!$0.session.running && !$0.tasks.isEmpty) }
                           .map { workingID($0.id) }),
                       sessions: Set(store.claudeSessions.values.lazy.filter { !$0.isArchived }.map(\.id)),
                       projects: projects,
                       predicted: words)
    }

    /// The targets changed: a pick or pin that can't go there any more goes (and Jev is asked again for the draft as it is).
    func revalidateTarget(store: Store) {
        if live.revalidate(store: store) { predictTarget(store: store) }
    }
}
