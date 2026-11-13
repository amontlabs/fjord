import AppKit
import SwiftUI

// Router v2's thread line (docs/design/router-v2/DESIGN.md 1.4, 1.6, 1.10): the new dot, the state's mark and the name,
// the sentence (the code's line, sheening with Fjord's mark after it while the model reads the thread, then the model's
// words streaming in), the
// project pill and the age; under it the queued row, and the card when the line is selected. And what points at things:
// `RouterButton`, through which the real pointer and the demo's drawn one hover, press and click alike.

// MARK: - Pointing

/// Registers a thing that can be pointed at: where it is (for the peek and the drawn pointer), what a click does, and
/// the real pointer's hover.
private struct RouterTargetModifier: ViewModifier {
    let model: RouterModel
    let hit: RouterHit
    var removes = false
    let action: (() -> Void)?
    /// Off inside a closed card: what is there can't be pointed at.
    @Environment(\.routerLive) private var live
    /// The line whose own hosting view this is in: its frame is in that line's space.
    @Environment(\.routerRow) private var row

    func body(content: Content) -> some View {
        let _ = (model.targets.actions[hit] = live ? action : nil)
        let _ = live ? model.targets.off.remove(hit) : model.targets.off.insert(hit).memberAfterInsert
        let _ = (model.targets.rows[hit] = row)
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(row == nil ? Router.space : Router.rowSpace)) } action: {
                model.targets.laid[hit] = $0
            }
            .onChange(of: live) { _, live in
                if !live { model.hover(hit, false) }
            }
            .onHover { if live { model.realHover(hit, $0) } }
            .onContinuousHover { phase in
                // A button that removes a line arms on a pointer move over it.
                if removes, !model.scripted, case .active(let point) = phase { model.pointerMoved(over: hit, at: point) }
            }
            .onDisappear {
                model.targets.laid[hit] = nil
                model.targets.rows[hit] = nil
                model.targets.off.remove(hit)
                model.targets.actions[hit] = nil
                model.hover(hit, false)
            }
    }
}

extension EnvironmentValues {
    /// Whether the things inside can be pointed at (a closed card's can't).
    @Entry var routerLive = true
    /// Inside a line's own hosting view (`RouterHostedLine`): that line's id.
    @Entry var routerRow: String? = nil
}

extension View {
    func routerTarget(_ model: RouterModel, _ hit: RouterHit, removes: Bool = false, action: (() -> Void)? = nil) -> some View {
        modifier(RouterTargetModifier(model: model, hit: hit, removes: removes, action: action))
    }

    /// The pointing hand over a link or a pill.
    @ViewBuilder func routerLink() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}

/// A button of the page: its label is told whether the pointer is on it and whether it is pressed, read from the model, so
/// the drawn pointer lights and presses it as the real one does. `removes`: it takes a line off the page, so it only
/// fires once the pointer has moved over it since the last removal.
struct RouterButton<Label: View>: View {
    let model: RouterModel
    let hit: RouterHit
    var removes = false
    let action: () -> Void
    @ViewBuilder let label: (_ hot: Bool, _ pressed: Bool) -> Label

    var body: some View {
        Button(action: fire) { EmptyView() }
            .buttonStyle(Style(model: model, hit: hit, label: label))
            .routerTarget(model, hit, removes: removes, action: fire)
    }

    private func fire() {
        if removes, !model.isArmed(hit) { return }
        action()
    }

    private struct Style: ButtonStyle {
        let model: RouterModel
        let hit: RouterHit
        let label: (Bool, Bool) -> Label

        func makeBody(configuration: Configuration) -> some View {
            Styled(model: model, hit: hit, down: configuration.isPressed, label: label)
        }
    }

    private struct Styled: View {
        let model: RouterModel
        let hit: RouterHit
        let down: Bool
        let label: (Bool, Bool) -> Label

        var body: some View {
            // Its own flags: the pointer moving between two things redraws those two.
            let flags = model.flags(hit)
            label(flags.hot, flags.pressed)
                .contentShape(Rectangle())
                .onChange(of: down) { _, down in
                    if down { model.pressed = hit } else if model.pressed == hit { model.pressed = nil }
                }
        }
    }
}

// MARK: - Line

struct RouterLineView: View {
    let model: RouterModel
    /// Its own box: the line redraws when its record or its flags change, and for nothing else.
    let box: RouterLineBox
    /// The card's own height, as laid out: its place opens to it and follows it (a reply growing, a plan opening).
    @State private var cardHeight: CGFloat = 0
    /// How much of the card and its ground shows. A card that opens as a line takes off (you answered: that line goes
    /// to Working and the next card opens) lets the line pass first: its place opens at once, on the move's curve, and
    /// what is in it comes a moment later, so the line in flight never crosses it.
    @State private var shown: Double = 1
    /// The row's width: a name takes up to its share of it (`M.nameShare`).
    @State private var rowWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = Router.Line

    var body: some View {
        let _ = RouterBodies.count("line", box.id)
        let thread = box.head
        let id = box.id
        let selected = box.selected
        let flags = model.flags(.row(id))
        let hot = flags.hot
        let pressed = flags.pressed
        let moving = box.moving
        // A line in flight is its row alone: in the frame it takes off its card's content and the selected surface are
        // gone (nothing half-faded is dragged across the page), while the card's place folds on the move's own curve, so
        // the rows under it close up as the next card opens. It opens again once the line has landed.
        let open = selected && !moving
        VStack(alignment: .leading, spacing: 0) {
            RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                row(thread, hot: hot)
            }
            .background {
                // The row's own ground under the pointer: on and off at once, so no trail follows the pointer down the list.
                RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                    .fill(open || moving ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                    .transaction { $0.animation = nil }
            }
            // Its height, for the list's slot (`RouterHostedLine`).
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.rowHeight = $0 }
            // A line changing section glides there as itself: no plate, no edge, no shadow. What it passes fades out
            // under it and back behind it (the veil), there from the frame it takes off and gone once it has landed in
            // the gap the rows opened for it.
            .background {
                RouterVeil()
                    .opacity(moving ? 1 : 0)
                    .animation(moving ? nil : Motion.fade.resolved(reduce: reduce), value: moving)
            }
            if let queued = thread.queued {
                RouterQueuedRow(model: model, thread: id, words: queued)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.queuedHeight = $0 }
                    .onDisappear { box.queuedHeight = 0 }
                    .transition(.routerFold(reduce: reduce))
            }
            // The card is in its line, closed to no height: it rolls open and shut in place, at full opacity, clipped to
            // the line's surface, on the curve the rows around it move on. Only an open card (or one rolling shut) has a
            // body: a closed one costs nothing.
            ZStack(alignment: .top) {
                if box.built || open {
                    RouterCard(model: model, box: box)
                        .transition(.identity)
                }
            }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    // Grown or shrunk while open (a reply, a plan): the rows under it glide as it does, on the spatial
                    // curve, unless the change that did it has a curve of its own.
                    if open, cardHeight > 0, $0 != cardHeight, model.glides.current == nil {
                        model.glides.began(Motion.spatial.curve(reduce: reduce))
                    }
                    cardHeight = $0
                    box.cardHeight = $0
                }
                .opacity(moving ? 0 : shown)
                .transaction { if moving { $0.animation = nil } }
                .frame(height: open ? (cardHeight > 0 ? cardHeight : nil) : 0, alignment: .top)
                .clipped()
                // Its content grew or shrank while open: the card follows, and the rows under it slide.
                .motion(.spatial, value: cardHeight)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
                .environment(\.routerLive, open)
                // Shut: once its roll has ended, the card's body goes (unless it opened again meanwhile).
                .transaction(value: open) { t in
                    guard !open else { return }
                    t.addAnimationCompletion(criteria: .removed) { [box] in
                        if !box.selected { box.built = false }
                    }
                }
        }
        .background {
            // Selected, the row and its card share one ground (a fill, no outline), which comes and goes with the
            // card's fold.
            RoundedRectangle(cornerRadius: M.selectedRadius, style: .continuous).fill(Router.Surface.quiet)
                .opacity(open ? shown : 0)
                .transaction { if moving { $0.animation = nil } }
        }
        .onChange(of: open) { _, open in
            // Opening while a line is in flight: after it has passed (it is past the card's place within a third of
            // its flight).
            guard open, !model.moving.isEmpty, !model.still, !reduce else { return }
            var none = Transaction()
            none.disablesAnimations = true
            withTransaction(none) { shown = 0 }
            let after = Router.cardAfterFlight
            let reveal = Animation.easeOut(duration: after.fade).delay(after.delay).resolved(reduce: reduce)
            DispatchQueue.main.async { withAnimation(reveal) { shown = 1 } }
        }
        // The line moves as one: what changes in it on the way (its mark, its sentence) arrives with it, not ahead of it.
        .geometryGroup()
        // A line in flight passes over the rows between: it is drawn last.
        .zIndex(moving ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), \(thread.look.label)")
    }

    private func row(_ thread: RouterThread, hot: Bool) -> some View {
        // The line the draft goes to, when it isn't the selected one: the destination row's arrow, in the dot's slot.
        let marked = box.marked
        return HStack(spacing: 0) {
            ZStack {
                Circle().fill(CDS.Fill.accent).opacity(thread.isNew && !marked ? 1 : 0)
                if marked {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.accent)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(width: CDS.Dot.size, height: CDS.Dot.size)
            .padding(.leading, M.reach).padding(.trailing, M.dotGap)
            .motion(.fade, value: marked)
            .accessibilityLabel(marked ? "Your words go here" : thread.isNew ? "New" : "")
            RouterName(model: model, thread: thread, rowHot: hot)
                .modifier(RouterWidthCap(cap: rowWidth > 0 ? rowWidth * M.nameShare : .infinity))
                .layoutPriority(2)
            RouterSentenceView(model: model, box: box)
                // Its subagents, background commands and waits, right after the words (RouterActivityViews.swift).
                .routerActivity(model, thread)
                .padding(.leading, M.sentenceGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let project = thread.project {
                RouterProjectPill(model: model, thread: thread.id, project: project)
                    .padding(.leading, M.pillGap)
                    .opacity(model.project == nil ? 1 : 0)
                    .allowsHitTesting(model.project == nil)
                    .layoutPriority(1)
            }
            RouterAge(model: model, since: thread.since)
                .padding(.leading, M.ageGap).padding(.trailing, M.reach)
                .layoutPriority(1)
        }
        .frame(minHeight: M.minHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // A name being given: the sentence slides to its new start.
        .motion(.spatial, value: thread.name)
    }
}

/// Its content at its own width, never wider than `cap` (a flexible frame would take the whole cap).
struct RouterWidthCap: ViewModifier {
    let cap: CGFloat

    func body(content: Content) -> some View { Cap(cap: cap) { content } }

    private struct Cap: Layout {
        let cap: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let ideal = child.sizeThatFits(.unspecified)
            let width = min(ideal.width, cap, proposal.width ?? .infinity)
            return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// The state's mark and the thread's name: on a ground of the state's tint when it asks something of you or is worth a
/// look, plain otherwise. The pointer on it shows the peek.
struct RouterName: View {
    let model: RouterModel
    let thread: RouterThread
    var rowHot = false

    private typealias M = Router.Line

    var body: some View {
        let look = thread.look
        let shape = RoundedRectangle(cornerRadius: M.nameRadius, style: .continuous)
        HStack(spacing: M.markGap) {
            RouterMark(look: look, paused: thread.paused)
            name(look)
        }
        .padding(.horizontal, M.namePadX).padding(.vertical, M.namePadY)
        .background { shape.fill(look.tint.opacity(look.ground ? (rowHot ? M.groundHover : M.ground) : 0)).hoverMotion(rowHot) }
        .contentShape(shape)
        .routerTarget(model, .name(thread.id))
    }

    private func name(_ look: RouterThread.Look) -> some View {
        ZStack(alignment: .leading) {
            // The name's width at the medium weight, always: the sentence's start doesn't shift when a state gives the
            // name its ground (medium) or takes it back (regular).
            // It takes the width it needs, up to the row's share for a name (`RouterLine.nameShare`), then truncates:
            // T3's whole title stands in until the model's name comes.
            Text(thread.name).font(CDS.sans(14, .medium)).lineLimit(1).hidden().accessibilityHidden(true)
            if thread.naming {
                // Being named: the words sheen until the model's name takes their place. The line's one Fjord mark is
                // after its sentence, so none here.
                let text = Text(thread.name).font(CDS.sans(14, look.ground ? .medium : .regular))
                text.foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    .routerSheen { text.lineLimit(1).truncationMode(.tail) }
                    .transition(.routerSwap)
            } else {
                Text(thread.name).font(CDS.sans(14, look.ground ? .medium : .regular))
                    .foregroundStyle(look.ground ? look.tint : CDS.Text.primary).lineLimit(1).truncationMode(.tail)
                    .id(thread.name)
                    .transition(.routerSwap)
            }
        }
    }
}

/// A state's mark in its box: an SF Symbol, or the working dots.
struct RouterMark: View {
    let look: RouterThread.Look
    var paused = false
    var size: CGFloat = Router.Line.mark

    var body: some View {
        // On Core Animation (`RouterTick`): the old mark goes as the new one comes, when the change is animated.
        RouterTick(key: look.symbol.map { "\($0)|\(look.label)" } ?? "~\(look.label)", style: .replace, always: false, look: "\(paused)") {
            ZStack {
                if let symbol = look.symbol {
                    Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(look.tint)
                } else {
                    RouterWorkingDots(tint: look.tint, paused: paused)
                }
            }
            // Its box inside: the view keeps its frame as one mark takes another's place (a frame that changes makes
            // AppKit walk the window's views for their tracking areas).
            .frame(width: Router.Line.markBox, height: Router.Line.markBox)
        }
        .accessibilityHidden(true)
    }
}

/// The line's sentence. Sent: your words in quotes and the status, sheening, until T3 has them; for a thread started
/// here, what it starts with after them. Otherwise the code's line or the model's: muted with a sheen and Fjord's mark
/// while the thread is read again, the model's words streaming in when they land.
struct RouterSentenceView: View {
    let model: RouterModel
    /// Its line's box: streamed words redraw this view only.
    let box: RouterLineBox
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let _ = RouterBodies.count("sentence", box.id)
        let thread = box.head
        let sentence = box.sentence
        ZStack(alignment: .leading) {
            if let sent = thread.sent, thread.state == .sent {
                HStack(spacing: 6) {
                    Text("“\(sent.words)”").font(CDS.sans(14)).foregroundStyle(CDS.Text.primary).lineLimit(1).truncationMode(.tail)
                    if sent.status != .taken {
                        let status = Text(sent.status == .steering ? Router.Copy.steering : Router.Copy.sending).font(CDS.sans(14))
                        status.foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                            .routerSheen { status.lineLimit(1).fixedSize() }
                            .transition(.opacity)
                    }
                    // A thread started here: the model and effort it starts with, so the one thing the settings are
                    // about can be checked on the line.
                    if let launch = thread.launch {
                        Text(model.brief(launch)).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                            .padding(.leading, 2)
                    }
                }
                .transition(.routerSwap)
            } else {
                let s = sentence
                let reassessing = s.phase == .reassessing
                let words = RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord)
                let tint = reassessing ? CDS.Text.muted : thread.sentenceTint
                let stream = s.stream
                let id = thread.id
                HStack(spacing: Router.Thinking.gap) {
                    RouterStreamedText(words: words, tint: tint, mono: s.mono, arriving: s.phase == .streaming,
                                         complete: box.complete,
                                         prState: words.parts.contains { $0.kind == .link } ? thread.prs.first?.state : nil) {
                        model.streamed(id, stream: stream)
                    }
                    .lineLimit(1).truncationMode(.tail)
                    .overlay(alignment: .leading) {
                        if reassessing {
                            RouterSheen().mask(alignment: .leading) {
                                RouterSentenceText.text(words, tint: .black, mono: s.mono, attributed: false)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            .transition(.opacity)
                        }
                    }
                    // The Router's model is reading the thread: Fjord's mark after the words it is about to replace.
                    if reassessing { RouterThinking().transition(.opacity) }
                }
                // One view per line of words: the old line goes, then the new one is there (the model's words fade
                // in themselves as they stream, from the frame the old line starts to go). Words that grow are the
                // same line: only the ones that arrived fade in.
                .id(box.sentenceID)
                .transition(s.phase == .streaming ? .routerSwapOut : .routerSwap)
            }
        }
        .motion(.fade, value: sentence.phase)
        // A new text taking another's place (`.id` above), not each word that grows: an animation on every streamed
        // word laid the sentence out on every frame while it streamed (the words fade in on their own).
        .motion(.fade, value: box.sentenceID)
    }
}

/// CDS Badge, neutral xs: the thread's project. A click filters the page to it.
struct RouterProjectPill: View {
    let model: RouterModel
    let thread: String
    let project: String

    var body: some View {
        RouterButton(model: model, hit: .pill(thread), action: { model.toggle(project: project) }) { hot, _ in
            RouterProjectBadge(project: project, hot: hot)
        }
        .routerLink()
        .accessibilityLabel("Project \(project)")
        .accessibilityHint("Filters the page to \(project)")
    }
}

struct RouterProjectBadge: View {
    let project: String
    var hot = false

    var body: some View {
        Text(project).font(CDS.sans(CDS.Badge.font, .medium)).foregroundStyle(hot ? CDS.Text.primary : CDS.Badge.ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, CDS.Badge.padX)
            .frame(height: CDS.Badge.height)
            .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                .fill(hot ? Router.Surface.chosen : Router.Surface.quiet))
            .hoverMotion(hot)
    }
}

/// "now", "4m", "2h", "3d": how long it has waited, run, or been finished. It ticks on the page's one minute clock.
struct RouterAge: View {
    let model: RouterModel
    let since: Date
    private static let font = CDS.nsSans(12).monospacedDigits

    var body: some View {
        let _ = model.clock.minute
        let age = BriefAge.short(model.now.timeIntervalSince(since))
        // It ticks as the counts do, on Core Animation (`RouterTick`): never two ages on top of each other.
        RouterTick(key: age, style: .numeric(font: Self.font)) {
            Text(age)
                .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                .lineLimit(1).fixedSize()
                // Its column inside: the view keeps its frame as the age ticks.
                .frame(minWidth: Router.Line.ageWidth, alignment: .trailing)
        }
    }
}

/// Words waiting for the turn under way, inside their thread's line: `Cancel` puts them back in the composer.
struct RouterQueuedRow: View {
    let model: RouterModel
    let thread: String
    let words: String

    var body: some View {
        HStack(spacing: Router.Line.markGap) {
            // In the mark's box, so the words start under the name above.
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                .frame(width: Router.Line.markBox)
            Text("“\(words)”").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary).lineLimit(1)
            Text("· " + Router.Copy.queued).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1)
                .padding(.leading, 2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            RouterTextButton(model: model, hit: .cancelQueued(thread), title: "Cancel") { model.cancelQueued(thread) }
        }
        .frame(height: Router.Line.queuedHeight)
        .padding(.leading, Router.Line.nameLeading + Router.Line.namePadX)
        .padding(.trailing, Router.Line.reach)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A ghost text button: footnote, muted, primary under the pointer; its keys after it as keycaps.
struct RouterTextButton: View {
    let model: RouterModel
    let hit: RouterHit
    let title: String
    var keys: [String] = []
    var removes = false
    let action: () -> Void

    var body: some View {
        RouterButton(model: model, hit: hit, removes: removes, action: action) { hot, pressed in
            HStack(spacing: 5) {
                // A title that changes ("Show all" to "Show less") swaps; it is never two titles at once.
                ZStack(alignment: .leading) {
                    Text(title).cdsText(CDS.Density.compact.footnote, .regular, hot ? CDS.Text.primary : CDS.Text.muted)
                        .lineLimit(1).fixedSize()
                        .id(title).transition(.routerSwap)
                }
                if !keys.isEmpty { RouterKeyHint(keys: keys).id(keys).transition(.routerSwap) }
            }
            .frame(height: 22)
            .opacity(pressed ? 0.7 : 1)
            .hoverMotion(hot)
        }
        .accessibilityLabel(title)
    }
}

// MARK: - Peek

/// The hover peek: read-only, floating by the name. T3's title, the last lines, then by kind as plain text.
struct RouterPeek: View {
    let thread: RouterThread

    var body: some View {
        let d = CDS.Density.compact
        VStack(alignment: .leading, spacing: 8) {
            Text(thread.title).cdsText(d.footnote, .medium, CDS.Text.muted).lineLimit(1)
            if !thread.lastLines.isEmpty {
                Text(RouterInline.text(thread.lastLines, size: d.body.0)).cdsText(d.body, .regular, CDS.Text.secondary).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            kind
            Text(Router.Copy.clickToOpen).cdsText(d.caption, .regular, CDS.Text.muted)
        }
        .modifier(RouterPeekShell())
    }

    @ViewBuilder private var kind: some View {
        let d = CDS.Density.compact
        switch thread.state {
        case .needsYou(.plan):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(thread.plan.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(RouterText.inline(line)).cdsText(d.body, .regular, CDS.Text.secondary).lineLimit(1)
                }
            }
        case .needsYou(.permission):
            if let p = thread.permission {
                Text(p.command).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary).lineLimit(2)
            }
        case .needsYou:
            VStack(alignment: .leading, spacing: 4) {
                if let ask = thread.question { Text(ask).cdsText(d.body, .regular, CDS.Text.primary) }
                ForEach(Array(thread.form.enumerated()), id: \.offset) { q, question in
                    Text(question.title).cdsText(d.body, .medium, CDS.Text.primary)
                    options(question.options, from: thread.form.prefix(q).reduce(0) { $0 + $1.options.count })
                }
                if thread.form.isEmpty { options(thread.options, from: 0) }
            }
        case .stopped:
            if let stop = thread.stop {
                Text(stop.error).font(CDS.mono(12)).foregroundStyle(CDS.Text.danger).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done:
            if !thread.prs.isEmpty {
                HStack(spacing: 6) { ForEach(thread.prs) { RouterPRBadge(pr: $0) } }
            }
        case .working, .sent:
            EmptyView()
        }
    }

    private func options(_ options: [String], from: Int) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { n, option in
            HStack(spacing: 8) {
                Text(verbatim: "\(from + n + 1)").font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                Text(option).cdsText(CDS.Density.compact.body, .regular, CDS.Text.secondary).lineLimit(1)
            }
        }
    }
}

/// The housekeeping line's peek: its threads, each with its project and age. Wider: the names are T3's titles, whole.
struct RouterOlderPeek: View {
    let model: RouterModel
    let older: [RouterOlder]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(older) { o in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.accent)
                    Text(o.name).cdsText(CDS.Density.compact.body, .regular, CDS.Text.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let project = o.project { RouterProjectBadge(project: project) }
                    Text(BriefAge.short(model.now.timeIntervalSince(o.since))).font(CDS.sans(12)).monospacedDigit()
                        .foregroundStyle(CDS.Text.muted).frame(minWidth: 20, alignment: .trailing)
                }
            }
        }
        .modifier(RouterPeekShell(width: Router.Peek.olderWidth))
    }
}

private struct RouterPeekShell: ViewModifier {
    var width: CGFloat = Router.Peek.width

    func body(content: Content) -> some View {
        content
            .padding(Router.Peek.pad)
            .frame(width: width, alignment: .leading)
            // The page's one floating shell, as the menus'.
            .routerFloating(radius: Router.Peek.radius)
            .allowsHitTesting(false)
    }
}

/// CDS Badge, tinted: `#41 open` success, `#41 merged` violet, `#41 closed` danger.
struct RouterPRBadge: View {
    let pr: RouterThread.PR
    @State private var pop: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Text(verbatim: "#\(pr.number) \(pr.state.rawValue)")
            .font(CDS.sans(11, .medium)).foregroundStyle(RouterPRTint.text(pr.state))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous).fill(RouterPRTint.fill(pr.state)))
            .scaleEffect(pop)
            .onChange(of: pr.state) {
                pop = Router.prPopScale
                let spring = Router.prPop.resolved(reduce: reduce)
                DispatchQueue.main.async { withAnimation(spring) { pop = 1 } }
            }
            .accessibilityLabel("Pull request \(pr.number), \(pr.state.rawValue)")
    }
}
