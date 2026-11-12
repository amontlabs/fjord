import AppKit
import SwiftUI

// Router v2's dock (docs/design/router-v2/DESIGN.md 1.7 to 1.13), floating at the bottom of the page. From the bottom:
// the composer card (the page's one input), the destination row (the one place that says what Return will do), and the
// status stack: the revert toast, the connection line, a failure line per send that didn't go.

struct RouterV2Dock: View {
    let model: RouterV2Model
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: CDS.Composer.dockGap) {
            if let toast = model.toast {
                // One toast: a new act changes its words in place, it is not another toast.
                RouterV2ToastView(model: model, toast: toast)
                    .transition(.scaleFade(0.96, reduce: reduce))
            }
            if model.connectionLost {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.muted)
                    Text(RouterV2.Copy.reconnecting).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary)
                }
                // Its icon over the failure line's.
                .padding(.leading, 10)
                .frame(height: 20)
                .transition(.opacity)
            }
            ForEach(model.failures) { failure in
                RouterV2FailureLine(model: model, failure: failure)
                    // In once the stack has made room for it.
                    .transition(.asymmetric(
                        insertion: .scaleFade(0.96, reduce: reduce).animation(Motion.spatial.resolved(reduce: reduce)?.delay(0.08)),
                        removal: .scaleFade(0.96, reduce: reduce)))
            }
            if let destination = model.destination {
                RouterV2DestinationRow(model: model, destination: destination)
                    .transition(.scaleFade(0.96, reduce: reduce))
            }
            RouterV2Composer(model: model)
        }
        .motion(.spatial, value: model.toast != nil)
        .motion(.spatial, value: model.failures.count)
        .motion(.spatial, value: model.connectionLost)
        .motion(.spatial, value: model.destination != nil)
    }
}

// MARK: - The @ field

private struct RouterV2ComposerKey: EnvironmentKey {
    static let defaultValue: RouterV2ComposerHost? = nil
}

extension EnvironmentValues {
    /// The store and the text model of the Router's @ field. With it set the composer is a `MentionField` (the @ list over
    /// the caret, pills in the text); without it, and in a still or while the script types, it draws as the demo did.
    var routerV2Composer: RouterV2ComposerHost? {
        get { self[RouterV2ComposerKey.self] }
        set { self[RouterV2ComposerKey.self] = newValue }
    }
}

// MARK: - Composer

/// The Router's composer card, as `RouterComposer` draws it, with no strip above it: the placeholder names what Return
/// does, the destination row says where the words go. A Return that came before the read holds the words: they dim,
/// the send button stays pressed with its glyph in the accent, until the read lands (or you type again).
struct RouterV2Composer: View {
    let model: RouterV2Model
    @FocusState private var focused: Bool
    @State private var hovering = false
    /// The @ field: whether its text view has the keyboard, what asks it to take it, and the @ list's place.
    @State private var fieldFocused = false
    @State private var fieldTick = 0
    @State private var mentionAt: CGPoint?
    @State private var listHeight: CGFloat = 0
    @State private var cardWidth: CGFloat = 0
    @Environment(\.routerV2Composer) private var host
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias C = CDS.Composer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: C.radius, style: .continuous)
        let hot = focused || fieldFocused || hovering || model.scripted
        let ring = contrast == .increased ? CDS.Text.primary.opacity(0.5) : hot ? C.ringHot : C.ring
        ZStack(alignment: .bottomTrailing) {
            field
                .padding(.leading, C.pad + C.textInset)
                .padding(.trailing, C.pad + 6 + C.row)
                .padding(.vertical, C.pad + (C.row - 20) / 2)
                .frame(maxWidth: .infinity, minHeight: C.minHeight, alignment: .topLeading)
            sendButton.padding(C.pad)
        }
        .background(shape.fill(CDS.Surface.s3))
        .overlay(shape.strokeBorder(ring, lineWidth: 1))
        .bakedShadow(focused || fieldFocused || model.scripted ? C.dropFocus : C.drop, .rounded(C.radius), radius: 10, y: 4)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { ask() }
        .onChange(of: model.focusTick) { if !model.scripted { ask() } }
        .onAppear { if !model.scripted, !model.still { ask() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
        // The @ list hangs over the card, so it never pushes the dock about.
        .overlay(alignment: .topLeading) { mentionList }
        .zIndex(1)
        .modifier(RouterV2Pills(model: model, host: viewHost))
    }

    /// The @ field: in a still, or while the script types, the field is the demo's.
    private var viewHost: RouterV2ComposerHost? { model.still || model.scripted ? nil : host }

    private func ask() {
        if viewHost != nil { fieldTick &+= 1 } else { focused = true }
    }

    private var field: some View {
        let d = CDS.Density.compact
        let empty = model.draft.isEmpty
        let ink = model.held ? CDS.Text.muted : CDS.Text.primary
        return ZStack(alignment: .topLeading) {
            // The placeholder changes by a swap (never two at once), and is gone in the frame the first character
            // lands; it comes back after the words have left.
            ZStack(alignment: .topLeading) {
                Text(model.placeholder).cdsText(d.prose, .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    .id(model.placeholder)
                    .transition(.routerV2Swap)
            }
            .motion(.fade, value: model.placeholder)
            .opacity(empty ? 1 : 0)
            .animation(empty ? Motion.fade.resolved(reduce: reduce)?.delay(RouterV2.swapOut) : nil, value: empty)
            .allowsHitTesting(false).accessibilityHidden(true)
            if let taken = model.taken, viewHost == nil {
                // The words the Router took as the new thread's settings: on an accent ground.
                RouterV2TakenUnderlay(draft: model.draft, taken: taken)
                    .transition(.opacity)
            }
            if model.still {
                // A still has no field to type in: its words alone (a field there draws them selected).
                Text(model.draft).font(CDS.sans(d.prose.0)).foregroundStyle(ink).lineLimit(1...8)
            } else if let host = viewHost {
                mentionField(host)
            } else {
                TextField("", text: Binding(get: { model.draft }, set: { model.setDraft($0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CDS.sans(d.prose.0)).foregroundStyle(ink)
                    .lineLimit(1...8)
                    .focused($focused)
                    // While the script types, the field is only shown; its caret is drawn after the words.
                    .allowsHitTesting(!model.scripted)
                    .accessibilityLabel("Message")
            }
            if model.scripted, !model.filterMode {
                // Before the placeholder's first letter while the draft is empty, after the last word once there is one.
                Text(model.draft).font(CDS.sans(d.prose.0)).lineLimit(1).hidden()
                    .overlay(alignment: .trailing) { RouterV2Caret().offset(x: empty ? -1.5 : 2.5).opacity(model.held ? 0 : 1) }
                    .allowsHitTesting(false)
                    // The caret is where the words end, at once: it doesn't slide back across the placeholder.
                    .transaction { $0.animation = nil }
            }
        }
        .frame(minHeight: 20, alignment: .topLeading)
        .motion(.fade, value: model.taken != nil)
        .motion(.fade, value: model.held)
    }

    /// The @ field in the card's text: pills inline, and the words taken as settings on their accent ground (drawn by the
    /// text view itself, so it moves with the text).
    private func mentionField(_ host: RouterV2ComposerHost) -> some View {
        let d = CDS.Density.compact
        let taken = model.taken.map { NSRange($0, in: model.draft) }
        return MentionField(store: host.store, model: host.text, maxHeight: 8 * d.prose.1, editable: true, focusTick: fieldTick,
                            onFocus: { now in
                                fieldFocused = now
                                host.text.composerFocused = now
                            },
                            label: "Message",
                            hint: "Return sends, Option Return queues after the turn, Shift Return starts a new line, @ names a thread or a project",
                            onSelection: { mentionAt = Self.mentionPoint($0) },
                            onEdit: { text, pointers in model.edit(text, marks: RouterV2Mentions.marks(text, pointers: pointers, name: host.store.pointerName),
                                                                  projectName: { RouteTarget.projectName($0, store: host.store) }) },
                            marked: taken, markedFill: NSColor(CDS.Text.accent.opacity(RouterV2.Launch.takenFill)))
            .opacity(model.held ? 0.55 : 1)
            .accessibilityLabel("Message")
    }

    /// The @ list over the caret, as the old composer hung it.
    @ViewBuilder private var mentionList: some View {
        if let host = viewHost {
            let suggestions = host.text.suggestions(host.store)
            if !suggestions.isEmpty {
                let at = mentionAt ?? CGPoint(x: C.pad + C.textInset, y: C.pad + (C.row - 20) / 2)
                let place = MentionList.place(caretX: at.x, available: cardWidth)
                MentionList(suggestions: suggestions, index: host.text.mentionIndex, width: place.width, store: host.store,
                            hover: { host.text.mentionIndex = $0 }) { host.text.pickMention($0) }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    .offset(x: place.x, y: at.y - C.mentionOffset - listHeight)
                    .transition(.opacity)
            }
        }
    }

    /// Where the @ word before the caret starts, in the card: x of its "@", y of its line's top.
    private static func mentionPoint(_ editor: NSTextView) -> CGPoint? {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return nil }
        let text = editor.string as NSString
        let caret = editor.selectedRange().location
        guard caret != NSNotFound, caret <= text.length else { return nil }
        let at = text.range(of: "@", options: .backwards, range: NSRange(location: 0, length: caret))
        let char = at.location == NSNotFound ? max(0, caret - 1) : at.location
        guard text.length > 0 else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: min(char, text.length - 1))
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let shown = editor.visibleRect.origin
        return CGPoint(x: C.pad + C.textInset + rect.minX - shown.x, y: C.pad + (C.row - 20) / 2 + rect.minY - shown.y)
    }

    private var sendButton: some View {
        let held = model.held
        return Button { model.send() } label: {
            Image(systemName: "arrow.turn.down.left").font(.system(size: 14, weight: held ? .semibold : .regular))
                .foregroundStyle(held ? CDS.Text.accent : CDS.Text.primary)
                .frame(width: C.row, height: C.row).contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous),
                                          rest: held ? RouterV2.Surface.pressed : .clear, hover: RouterV2.Surface.hover,
                                          active: RouterV2.Surface.pressed, pressed: RouterV2.Surface.pressed))
        // Lit only when Return would send now; held, it keeps its pressed look.
        .disabled(!model.canSend && !held)
        .motion(.fade, value: held)
        .accessibilityLabel(held ? "Sending once Fjord knows where" : "Send")
        .help("Return sends · ⌥Return queues after this turn · ⇧Return for a new line")
    }
}

/// Keeps the page's draft and the @ field's text the one text. Typing reaches the page in the keystroke's own turn
/// (`MentionField.onEdit`); this carries what the field's model gets some other way (a pick from the @ list, an
/// "Open in Router" prefill) to the page, and what the page does to its draft (Return empties it, a failed send or a
/// cancelled queued message puts words back) to the field.
private struct RouterV2Pills: ViewModifier {
    let model: RouterV2Model
    let host: RouterV2ComposerHost?

    func body(content: Content) -> some View {
        content
            .onAppear { pull() }
            .onChange(of: model.draft) { pull() }
            .onChange(of: host?.text.draft) { push() }
            .onChange(of: host?.text.pointers) { push() }
    }

    private func push() {
        guard let host else { return }
        let text = host.text
        guard text.draft != model.draft else { return }
        model.edit(text.draft, marks: RouterV2Mentions.marks(text.draft, pointers: text.pointers, name: host.store.pointerName),
                   projectName: { RouteTarget.projectName($0, store: host.store) })
    }

    private func pull() {
        guard let host, host.text.draft != model.draft else { return }
        // Words from the page carry no pills.
        host.text.pointers = []
        host.text.draft = model.draft.replacingOccurrences(of: MentionText.markString, with: "")
    }
}

// MARK: - Destination row

/// A place as its line shows it: the thread's mark, its page name, its project pill.
struct RouterV2PlaceView: View {
    let model: RouterV2Model
    let place: RouterV2Place
    var weight: CDS.Weight = .medium
    /// Its project pill after the name (left out of the unsure row's other places when the row is short of room).
    var project = true
    /// The name's ink: a place that isn't the lit one of several is a step quieter.
    var ink: Color = CDS.Text.primary

    var body: some View {
        HStack(spacing: 5) {
            switch place {
            case .thread(let id):
                if let t = model.thread(id) {
                    RouterV2Mark(look: t.look, paused: t.paused)
                    Text(t.name).font(CDS.sans(13, weight)).foregroundStyle(ink).lineLimit(1)
                    if project, let name = t.project { RouterV2ProjectBadge(project: name) }
                }
            case .newThread, .here:
                Text(model.name(place)).font(CDS.sans(13, weight)).foregroundStyle(ink).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// The row has no ground of its own: a line of words over the composer, its arrow on the composer's text edge. Only
/// what can be chosen in it has one (the lit place of several, a new thread's settings).
struct RouterV2DestinationRow: View {
    let model: RouterV2Model
    let destination: RouterV2Destination
    /// The lit place's ground slides between the places; one namespace a layout (`ViewThatFits` builds both).
    @Namespace private var light
    @Namespace private var lightNarrow

    var body: some View {
        HStack(spacing: 7) {
            lead
            content
        }
        // The arrow's own edge on the composer's words.
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: RouterV2.Dock.rowHeight)
        .motion(.fade, value: destination)
        .motion(.fade, value: model.rowNote)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The row's first glyph: the arrow, and in its place Fjord's mark while the Router's model reads the draft.
    private var lead: some View {
        ZStack {
            if model.reading {
                RouterV2Thinking(tint: CDS.Text.accent, size: RouterV2.Thinking.row, label: "Reading where it goes")
                    .transition(.opacity)
            } else {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.accent)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(width: RouterV2.Thinking.row, height: RouterV2.Thinking.row)
        .motion(.fade, value: model.reading)
    }

    private var label: String {
        switch destination {
        case .picked(let id, let words): "Return answers \(model.thread(id)?.name ?? "") with \(words)"
        case .place(.newThread(let project), _): "Starts a new thread in \(project) with \(model.words(model.launch))"
        case .place(let place, let mode): "Goes to \(model.name(place)). \(mode)"
        case .prior(let id): "Goes to \(model.thread(id)?.name ?? "")"
        case .reading: model.held ? "Held: it goes when Fjord knows where" : "Reading where it goes"
        case .unsure(let places, let lit, _, let mode): "Not sure. Return sends to \(model.name(places[lit])). \(mode)"
        case .noGuess: RouterV2.Copy.pickAPlace
        }
    }

    @ViewBuilder private var content: some View {
        let note = model.rowNote
        switch destination {
        case .picked(let id, let words):
            RouterV2PlaceView(model: model, place: .thread(id))
            Text("“\(words)”").font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                .id(words).transition(.routerV2Swap)
            // A form with questions left (Return goes to the next one), or T3 away.
            if let note { self.words("· " + note) }
        case .place(let place, let mode):
            RouterV2PlaceView(model: model, place: place)
            // T3 away: Return keeps the words. A new thread: what it starts with. A thread that exists: what the words
            // do there.
            if let note { words(note) } else if case .newThread = place { RouterV2LaunchChips(model: model) } else if !mode.isEmpty { words(mode) }
        case .prior(let id):
            RouterV2PlaceView(model: model, place: .thread(id))
            if let note { words(note) }
        case .reading:
            // The first read of a draft with nothing selected: the mark in the arrow's slot, and where the place will be.
            let bar = RoundedRectangle(cornerRadius: RouterV2.Dock.skeleton.height / 2, style: .continuous)
            bar.fill(CDS.alpha(0.06))
                .frame(width: RouterV2.Dock.skeleton.width, height: RouterV2.Dock.skeleton.height)
                .overlay { RouterV2Sheen(color: RouterV2Sheen.skeleton).mask { bar } }
                .accessibilityHidden(true)
        case .unsure(let places, let lit, let mine, let mode):
            // Every place with its project pill when the row has the room; else only the lit one keeps its pill.
            ViewThatFits(in: .horizontal) {
                unsure(places, lit: lit, mine: mine, mode: note ?? mode, pills: true, light: light)
                unsure(places, lit: lit, mine: mine, mode: note ?? mode, pills: false, light: lightNarrow)
            }
        case .noGuess:
            Text(RouterV2.Copy.pickAPlace).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
            // Tab opens the places from the keyboard.
            RouterV2KeyHint(keys: ["tab"])
            chevron
        }
    }

    /// The unsure row: up to three places, each keeping its width whichever is lit, so the light is all that moves: one
    /// ground that slides from place to place. What Return does at the lit place is said once, after the places. A new
    /// thread you lit yourself shows its settings: the other places fold into the menu (⌘1–3 still light them, Esc
    /// brings them back).
    private func unsure(_ places: [RouterV2Place], lit: Int, mine: Bool, mode: String, pills: Bool, light: Namespace.ID) -> some View {
        let launching = model.launchShown
        return HStack(spacing: 2) {
            ForEach(Array(places.prefix(3).enumerated()), id: \.offset) { n, place in
                if !launching || n == lit {
                    RouterV2Button(model: model, hit: .place(n), action: { model.light(n) }) { hot, pressed in
                        chip(place, n: n, lit: n == lit, mine: mine, hot: hot, pressed: pressed, pill: pills, light: light)
                    }
                    .accessibilityLabel((n == lit ? "Sends to " : "Or ") + model.name(place))
                    .transition(.opacity)
                }
            }
            if launching {
                RouterV2LaunchChips(model: model).padding(.leading, 5).padding(.trailing, 4)
            } else if !mode.isEmpty {
                words(mode).padding(.leading, 5)
            }
            chevron
        }
        .motion(.glass, value: lit)
        .motion(.fade, value: mine)
    }

    /// The mode words: muted, swapping as they change (⌥ held flips "steer now" to "queue after this turn").
    private func words(_ mode: String) -> some View {
        Text(mode).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            .id(mode).transition(.routerV2Swap)
    }

    /// A place among several: its mark, name, pill and key, on no ground until it is the lit one. Lit: the chosen
    /// fill when it is Fjord's guess, the accent's tint once you picked it yourself (it came from you, and no later
    /// read moves it). No outline either way.
    private func chip(_ place: RouterV2Place, n: Int, lit: Bool, mine: Bool, hot: Bool, pressed: Bool, pill: Bool,
                      light: Namespace.ID) -> some View {
        let s = RouterV2.Surface.self
        let shape = RoundedRectangle(cornerRadius: s.control, style: .continuous)
        return HStack(spacing: 6) {
            // One weight, lit or not: the places keep their widths as the light moves.
            RouterV2PlaceView(model: model, place: place, project: pill, ink: lit || hot ? CDS.Text.primary : CDS.Text.secondary)
            RouterV2KeyHint(keys: ["cmd", "\(n + 1)"])
        }
        .padding(.horizontal, RouterV2.Dock.placePadX)
        .frame(height: RouterV2.Dock.place)
        .background {
            ZStack {
                shape.fill(lit ? .clear : pressed ? s.pressed : hot ? s.hover : .clear).hoverMotion(hot)
                if lit {
                    shape.fill(mine ? CDS.Text.accent.opacity(s.tintStrong) : s.chosen)
                        .matchedGeometryEffect(id: "light", in: light)
                }
            }
        }
    }

    private var chevron: some View {
        RouterV2Button(model: model, hit: .places, action: { model.openPlaces() }) { hot, _ in
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                .foregroundStyle(hot ? CDS.Text.primary : CDS.Text.muted)
                .frame(width: 14, height: RouterV2.Dock.rowHeight)
        }
        .accessibilityLabel("Other places")
    }
}

/// The row's menu: the read's places, then a new thread in each project. A click on the chevron opens it, and so does
/// Tab from the words when the row asks for a place: ↑↓ move, Return picks, Esc closes.
struct RouterV2PlacesMenu: View {
    let model: RouterV2Model

    var body: some View {
        let m = CDS.Menu.self
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.menuPlaces.enumerated()), id: \.offset) { n, place in
                RouterV2Button(model: model, hit: .placeChoice(n), action: { model.choose(place) }) { hot, pressed in
                    RouterV2PlaceView(model: model, place: place, weight: .regular)
                        .padding(.horizontal, m.itemPadX)
                        .frame(maxWidth: .infinity, minHeight: m.item, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: m.itemRadius, style: .continuous)
                            .fill(pressed ? RouterV2.Surface.pressed : hot || n == model.placesIndex ? RouterV2.Surface.hover : .clear))
                }
                .accessibilityAddTraits(n == model.placesIndex ? .isSelected : [])
            }
        }
        .padding(m.pad)
        .frame(width: 260)
        .routerV2Floating()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }
}

// MARK: - Status stack

/// A send that didn't go: your words, why, Edit and Send again. It takes the keyboard when it appears (the ring is on
/// Send again, which is what Return presses; ⌘⌫ is Edit), and enters with one short shake once it is fully there.
struct RouterV2FailureLine: View {
    let model: RouterV2Model
    let failure: RouterV2Failure
    @State private var shake: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RouterV2.Surface.row, style: .continuous)
        let focused = model.selection == .failure(failure.id)
        let name = model.thread(failure.thread)?.name ?? ""
        // "T3 Code isn't reachable" is said only while it isn't.
        let why = failure.offline && !model.connectionLost ? "." : ": \(failure.reason)"
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.Text.danger)
            (Text("“\(failure.words)”").foregroundColor(CDS.Text.primary)
                + Text(" didn't go to \(name)\(why)").foregroundColor(CDS.Text.secondary))
                .font(CDS.sans(13)).lineLimit(1).truncationMode(.tail)
                .contentTransition(.identity)
            Spacer(minLength: 8)
            RouterV2PushButton(model: model, hit: .failureEdit(failure.id), title: "Edit", variant: .ghost,
                               keys: focused ? ["cmd", "backspace"] : []) { model.edit(failure.id) }
            RouterV2PushButton(model: model, hit: .failureAgain(failure.id), title: "Send again", keys: focused ? ["enter"] : [],
                               ringed: focused) {
                model.sendAgain(failure.id)
            }
        }
        // Room for the button's ring inside the line.
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: RouterV2.Dock.failureHeight)
        // The danger ink's tint, as the Stopped card's reason: a ground, no ring.
        .background(shape.fill(RouterV2.dangerFill))
        .modifier(RouterV2Shake(progress: shake))
        .onAppear {
            guard !model.still else { return }
            // Once it is there: a line still fading in doesn't shake.
            let once = Animation.linear(duration: RouterV2.shake.duration).delay(0.2).resolved(reduce: reduce)
            withAnimation(once) { shake = 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("“\(failure.words)” didn't go to \(name)\(why)")
    }
}

/// The revert toast: the act, the thread's name, Revert and ⌘Z. One slot and one view: a new act swaps its words and
/// the toast's width follows.
struct RouterV2ToastView: View {
    let model: RouterV2Model
    let toast: RouterV2Toast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RouterV2.Surface.row, style: .continuous)
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                (Text(toast.before + " ").foregroundColor(CDS.Text.secondary)
                    + Text(toast.name).foregroundColor(CDS.Text.primary)
                    + Text(toast.after.isEmpty ? "" : " " + toast.after).foregroundColor(CDS.Text.secondary))
                    .font(CDS.sans(13)).lineLimit(1).fixedSize()
                    .id(toast.id)
                    .transition(.routerV2Swap)
            }
            RouterV2Button(model: model, hit: .revert, action: { model.revert(toast.id) }) { hot, pressed in
                HStack(spacing: 5) {
                    Text("Revert").font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.accent)
                        .underline(hot, color: CDS.Text.accent.opacity(0.6))
                    RouterV2KeyHint(keys: ["cmd", "Z"])
                }
                .opacity(pressed ? 0.7 : 1)
            }
            .accessibilityLabel("Revert")
        }
        .padding(.horizontal, 10)
        .frame(height: RouterV2.Dock.toastHeight)
        // A status line by the composer, on the dock's own ground: a quiet fill, no edge and no shadow (it floats over
        // nothing).
        .background(shape.fill(RouterV2.Surface.chosen))
        .motion(.spatial, value: toast.id)
        .routerV2Target(model, .toast)
        .accessibilityElement(children: .contain)
    }
}
