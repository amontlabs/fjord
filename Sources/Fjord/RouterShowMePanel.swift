import AppKit
import SwiftUI

// The Show me dock open (RouterShowMe.swift): a floating panel over the page, its bottom right on the dock's, above the
// destination row so what Return does stays in sight; in a wide page with a pane, the panel sits at the pane's bottom
// instead (`RouterWidePage`). The explainers first, then the selected one's player. While one plays the list folds to its
// row and "N more". The panel has no field: a follow-up is typed in the composer, whose row then targets the explainer.
//
// The player is native but for its stage: the answer, the caption, play, the scene bar, the time and Sources are SwiftUI,
// and only the picture is the page (ExplainerPlayer.swift). It grows to fill the page (⌥⌘Return) or, the stage alone, the
// window (⇧⌘Return); Esc steps back. The same web view moves between them, so the film keeps its time.

struct RouterShowMePanel: View {
    let model: RouterModel
    let state: RouterShowMeState
    var width: CGFloat = RouterShowMeLayout.panelWidth
    /// At the pane's bottom: the pane's ground, no shadow. Else it floats.
    var docked = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.card, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            list
            // One place in the tree whatever the list does.
            if let e = state.chosen {
                RouterExplainerPlayer(model: model, explainer: e, state: state, size: .panel)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: width)
        .background { if docked { shape.fill(CDS.Surface.s2) } }
        .overlay { if docked { shape.strokeBorder(CDS.border, lineWidth: 1).allowsHitTesting(false) } }
        .modifier(Floating(on: !docked))
        .background { RouterShield(model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Explainers")
    }

    private struct Floating: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.routerFloating(radius: Router.Surface.card) } else { content }
        }
    }

    @ViewBuilder private var list: some View {
        VStack(spacing: 0) {
            if state.playing, !state.expanded, let e = state.chosen {
                RouterExplainerRow(model: model, explainer: e, selected: true)
                if state.explainers.count > 1 {
                    RouterExplainerMore(model: model, count: state.explainers.count - 1)
                }
            } else {
                ForEach(state.explainers) { e in
                    RouterExplainerRow(model: model, explainer: e, selected: e.id == state.selected)
                }
            }
        }
    }
}

/// The player bigger than its panel: filling the page under the title line (`.page`), or the stage alone filling the
/// window with the controls over its bottom (`.window`). RouterScreen draws it over the page.
struct RouterShowMeBig: View {
    let model: RouterModel
    let state: RouterShowMeState

    var body: some View {
        if let e = state.chosen {
            Group {
                if state.size == .window {
                    RouterExplainerPlayer(model: model, explainer: e, state: state, size: .window)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    RouterExplainerPlayer(model: model, explainer: e, state: state, size: .page)
                        .frame(maxWidth: RouterShowMeLayout.pageMaxWidth, maxHeight: .infinity)
                        .padding(.horizontal, Router.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, Router.Dock.bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(CDS.Surface.s1)
                }
            }
            .background { RouterShield(model: model, big: true, fullScreen: state.size == .window) }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(e.title)
        }
    }
}

/// Where Show me's panel (or its player grown bigger) is, for the rows under it: AppKit's tracking areas and the rows' own
/// hosting views don't know a SwiftUI overlay covers them, so the panel says where it is. The rows' slots refuse clicks
/// inside it (`RouterGlideView.shielded`) and the page keeps rows under it unlit (`RouterModel.shieldHover`). Drawn behind
/// the panel; never hit itself.
struct RouterShield: NSViewRepresentable {
    let model: RouterModel
    /// The player bigger than the panel: when it goes, the composer gets the keyboard back.
    var big = false
    /// The stage alone: the window goes native full screen while it shows (and back, if it wasn't before).
    var fullScreen = false

    /// Each window's shields, in its base coordinates.
    @MainActor private static var rects: [ObjectIdentifier: [ObjectIdentifier: CGRect]] = [:]

    @MainActor static func covers(_ point: CGPoint, in window: NSWindow) -> Bool {
        rects[ObjectIdentifier(window)]?.values.contains { $0.contains(point) } == true
    }

    final class View: NSView {
        weak var model: RouterModel?
        var big = false
        var fullScreen = false
        private var entered = false
        private var madeFullScreen = false
        private weak var registered: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
            if let window, fullScreen, model?.still == false, !window.styleMask.contains(.fullScreen) {
                madeFullScreen = true
                window.toggleFullScreen(nil)
            }
        }

        override func viewWillMove(toWindow new: NSWindow?) {
            if new == nil, let window {
                forget()
                if entered { entered = false; model?.shieldHover(false) }
                if big, window.firstResponder is ExplainerPlayerWebView, let field = window.contentView.flatMap(RouterKeys.composerField) {
                    window.makeFirstResponder(field)
                }
                if madeFullScreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                madeFullScreen = false
            }
            super.viewWillMove(toWindow: new)
        }

        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); report() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); report() }
        override func layout() { super.layout(); report() }

        func report() {
            guard let window else { forget(); return }
            if registered !== window { forget() }
            registered = window
            RouterShield.rects[ObjectIdentifier(window), default: [:]][ObjectIdentifier(self)] = convert(bounds, to: nil)
        }

        private func forget() {
            guard let registered else { return }
            RouterShield.rects[ObjectIdentifier(registered)]?[ObjectIdentifier(self)] = nil
            self.registered = nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { entered = true; model?.shieldHover(true) }
        override func mouseExited(with event: NSEvent) { entered = false; model?.shieldHover(false) }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.model = model
        view.big = big
        view.fullScreen = fullScreen
        view.report()
    }
}

/// An explainer in the list: its state's glyph, its title, the thread it explains (named as its line names it), then
/// its state's words and its age. The selected one on the chosen ground.
private struct RouterExplainerRow: View {
    let model: RouterModel
    let explainer: ExplainerItem
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous)
        RouterButton(model: model, hit: .showMe("row-" + explainer.id), action: { model.selectExplainer(explainer.id) }) { hot, _ in
            HStack(spacing: 8) {
                glyph.frame(width: 14, height: 14)
                Text(explainer.title).font(CDS.sans(13, selected ? .medium : .regular)).foregroundStyle(CDS.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
                RouterExplainerSource(model: model, explainer: explainer)
                Spacer(minLength: 8)
                words
                Text(BriefAge.short(model.now.timeIntervalSince(explainer.since)))
                    .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                    .frame(minWidth: Router.Line.ageWidth, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: RouterShowMeLayout.rowHeight)
            .background { shape.fill(selected ? Router.Surface.chosen : hot ? Router.Surface.hover : .clear).hoverMotion(hot) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var glyph: some View {
        switch explainer.stage {
        case .making:
            RouterThinking(tint: CDS.Text.secondary, size: Router.Thinking.line, label: "Making")
        case .queued:
            Image(systemName: "clock").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted)
        case .ready:
            Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(explainer.unseen ? CDS.Text.accent : CDS.Text.muted)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.muted)
        }
    }

    @ViewBuilder private var words: some View {
        let font = CDS.sans(12)
        switch explainer.stage {
        case .making(let draft, _):
            Text(draft == 0 ? "Making" : "Making · draft \(draft)").font(font).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        case .queued:
            Text("Queued").font(font).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        case .ready:
            Text(RouterExplainerPlayer.clock(explainer.length)).font(font).monospacedDigit().foregroundStyle(CDS.Text.muted).fixedSize()
        case .failed:
            Text("Didn't finish").font(font).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        }
    }
}

/// Under the playing one's row: the rest of the list, folded. A click shows it whole.
private struct RouterExplainerMore: View {
    let model: RouterModel
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous)
        RouterButton(model: model, hit: .showMe("more"), action: { model.showMe?.expanded = true }) { hot, _ in
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                    .frame(width: 14, height: 14)
                Text("\(count) more").font(CDS.sans(12)).foregroundStyle(hot ? CDS.Text.primary : CDS.Text.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: RouterShowMeLayout.rowHeight - 4)
            .background { shape.fill(hot ? Router.Surface.hover : .clear).hoverMotion(hot) }
        }
        .accessibilityLabel("\(count) more explainers")
    }
}

/// The thread an explainer explains: its name on its state's tint, as its line's name; a grey Done on the quiet ground.
/// A thread that has no line now keeps T3's title, quiet.
private struct RouterExplainerSource: View {
    let model: RouterModel
    let explainer: ExplainerItem

    var body: some View {
        let t = model.thread(explainer.source)
        let name = t?.name ?? explainer.thread
        if !name.isEmpty {
            let look = t?.look
            let ground = look?.ground == true
            Text(name).font(CDS.sans(CDS.Badge.font, .medium))
                .foregroundStyle(ground ? look!.tint : CDS.Badge.ink)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, CDS.Badge.padX)
                .frame(height: CDS.Badge.height)
                .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                    .fill(ground ? look!.tint.opacity(Router.Line.ground) : Router.Surface.quiet))
        }
    }
}

/// The selected explainer's player, in every size. Ready: the answer, the stage, the scene's caption (and its source with
/// Sources on), then play, the scene bar, the time and the controls; with a web view these drive the page, else (a demo, a
/// shot, a page that crashed twice) they picture its bar. Being made, queued or failed: the stage and one quiet line.
struct RouterExplainerPlayer: View {
    let model: RouterModel
    let explainer: ExplainerItem
    let state: RouterShowMeState
    let size: RouterShowMeState.Size
    @Environment(\.controlActiveState) private var active

    private var ready: Bool { explainer.stage == .ready }
    private var draft: Int? {
        if case .making(let n, _) = explainer.stage { return n > 0 ? n : nil }
        return nil
    }
    /// The web view, when this one plays in it.
    private var host: ExplainerWebHost? {
        guard ready, explainer.page != nil else { return nil }
        return model.showMeHost()
    }
    private var radius: CGFloat { size == .window ? 0 : Router.Surface.card }

    var body: some View {
        content
            // Watched: shown selected, finished, with the window key.
            .task(id: Watch(id: explainer.id, unseen: explainer.unseen && ready, key: active == .key)) {
                guard active == .key, explainer.unseen, ready else { return }
                model.explainers?.watched(explainer.id)
            }
    }

    private struct Watch: Equatable { var id: String; var unseen: Bool; var key: Bool }

    @ViewBuilder private var content: some View {
        let stage = ExplainerStage(page: explainer.page, posterLight: explainer.posterLight, posterDark: explainer.posterDark,
                                   draft: draft, ready: ready, host: host, radius: radius)
        switch size {
        case .window:
            ZStack(alignment: .bottom) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                if ready {
                    VStack(alignment: .leading, spacing: 8) {
                        caption
                        controls
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 760)
                    .routerFloating(radius: Router.Surface.card)
                    .padding(.bottom, 24).padding(.horizontal, 24)
                }
            }
        case .page:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(explainer.title).font(CDS.sans(15, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                    RouterExplainerSource(model: model, explainer: explainer)
                    Spacer(minLength: 8)
                }
                .frame(height: 28)
                .padding(.bottom, 8)
                answer.padding(.bottom, 12)
                // As big as the room left over the caption and controls allows, which stay right under it.
                stage.frame(maxWidth: .infinity)
                below.padding(.top, 12)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        case .panel:
            VStack(alignment: .leading, spacing: 0) {
                answer.padding(.bottom, 10)
                stage
                below.padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var answer: some View {
        if !explainer.answer.isEmpty {
            Text(explainer.answer).font(CDS.sans(size == .page ? 17 : 14, .semibold)).foregroundStyle(CDS.Text.primary)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under the stage: a ready one's caption and controls; else one quiet line and Open in T3.
    @ViewBuilder private var below: some View {
        if ready {
            VStack(alignment: .leading, spacing: 8) {
                caption
                controls
            }
        } else {
            status
        }
    }

    private var playback: ExplainerPlayback.State? { host?.playback.state }

    /// The scene's caption (the last one's for a held frame), and its source with Sources on.
    @ViewBuilder private var caption: some View {
        let scene = playback.map { $0.scenes[min($0.scene, $0.scenes.count - 1)] }
        VStack(alignment: .leading, spacing: 3) {
            Text(scene?.caption ?? explainer.captions.last ?? "")
                .font(CDS.sans(size == .panel ? 13 : 15, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(2)
                .frame(minHeight: 20, alignment: .leading)
                .contentTransition(.opacity)
            if state.sources, let source = scene?.source, !source.isEmpty {
                Text("“\(source)”").font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(2)
            }
        }
        .motion(.fade, value: scene?.caption)
    }

    private var controls: some View {
        RouterExplainerControls(model: model, explainer: explainer, host: host, state: state, size: size)
    }

    /// Being made, queued or failed: what's happening, when the row and the stage's tag don't already say it, and Open in T3.
    private var status: some View {
        HStack(spacing: 10) {
            Group {
                switch explainer.stage {
                case .making(let n, let fixing):
                    if n == 0 {
                        Text("Writing the first draft").foregroundColor(CDS.Text.muted)
                    } else if !fixing.isEmpty {
                        Text("Fixing: ").foregroundColor(CDS.Text.muted) + Text(fixing).foregroundColor(CDS.Text.secondary)
                    }
                case .queued:
                    Text("Starts when \(model.threadName(explainer)) answers").foregroundColor(CDS.Text.muted)
                case .failed(let why):
                    Text(why).foregroundColor(CDS.Text.secondary)
                case .ready:
                    EmptyView()
                }
            }
            .font(CDS.sans(13)).lineLimit(2)
            Spacer(minLength: 0)
            if explainer.launched {
                RouterTextButton(model: model, hit: .showMe("open"), title: "Open in T3") { model.explainers?.open(explainer: explainer.id) }
            }
        }
        .frame(minHeight: 24)
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
    static func clock(_ seconds: Double) -> String { clock(Int(seconds.isFinite ? max(0, seconds) : 0)) }
}

/// Play, the scene bar, the time, Sources, Open in T3 and the size controls. With the page's state they drive it: a press on
/// a scene plays it from its start, a drag scrubs. Without (a held frame), the bar is whole and the time is the length.
private struct RouterExplainerControls: View {
    let model: RouterModel
    let explainer: ExplainerItem
    let host: ExplainerWebHost?
    let state: RouterShowMeState
    let size: RouterShowMeState.Size

    var body: some View {
        let film = host?.playback.state
        HStack(spacing: 10) {
            play(film)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: film?.playing != true)) { context in
                let t = host?.playback.time(context.date) ?? 0
                HStack(spacing: 10) {
                    RouterSceneBar(film: film, count: max(explainer.captions.count, 1), t: t) { host?.send($0) }
                    Text(film.map { RouterExplainerPlayer.clock(t) + " / " + RouterExplainerPlayer.clock($0.total) }
                         ?? RouterExplainerPlayer.clock(explainer.length))
                        .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).fixedSize()
                }
            }
            if film?.scenes.contains(where: { !$0.source.isEmpty }) == true {
                icon(state.sources ? "quote.bubble.fill" : "quote.bubble", hit: "sources",
                     help: state.sources ? "Hide sources" : "Show sources", on: state.sources) { model.showMe?.sources.toggle() }
            }
            if explainer.launched {
                RouterTextButton(model: model, hit: .showMe("open"), title: "Open in T3") { model.explainers?.open(explainer: explainer.id) }
            }
            if size != .window {
                icon(size == .page ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", hit: "page",
                     help: size == .page ? "Back to the panel (⌥⌘⏎ or esc)" : "Fill the page (⌥⌘⏎)") { model.toggleShowMePage() }
            }
            icon(size == .window ? "arrow.down.right.and.arrow.up.left.rectangle" : "rectangle.inset.filled", hit: "window",
                 help: size == .window ? "Exit full screen (⇧⌘⏎ or esc)" : "Full screen (⇧⌘⏎)") { model.toggleShowMeWindow() }
        }
        .frame(height: 26)
    }

    private func play(_ film: ExplainerPlayback.State?) -> some View {
        let ended = film.map { !$0.playing && $0.t >= $0.total - 0.05 } ?? false
        let symbol = film?.playing == true ? "pause.fill" : ended ? "arrow.counterclockwise" : "play.fill"
        return RouterButton(model: model, hit: .showMe("play"), action: { host?.send(.toggle) }) { hot, pressed in
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(film == nil ? CDS.Text.muted : CDS.Text.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(pressed ? Router.Surface.pressed : hot && film != nil ? Router.Surface.chosenHover : Router.Surface.chosen))
                .hoverMotion(hot)
        }
        .disabled(film == nil)
        .accessibilityLabel(film?.playing == true ? "Pause" : ended ? "Replay" : "Play")
    }

    private func icon(_ symbol: String, hit: String, help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous)
        return RouterButton(model: model, hit: .showMe(hit), action: action) { hot, pressed in
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? CDS.Text.primary : hot ? CDS.Text.primary : CDS.Text.muted)
                .frame(width: 24, height: 24)
                .background(shape.fill(pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear).hoverMotion(hot))
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One segment per scene, each filling as its scene plays. A press plays a scene from its start; a drag scrubs (the film
/// pauses under it and plays on after if it was playing).
private struct RouterSceneBar: View {
    let film: ExplainerPlayback.State?
    let count: Int
    let t: Double
    let send: (ExplainerWebHost.Command) -> Void
    @State private var drag: (moved: Bool, playing: Bool)?
    @State private var hot = false

    var body: some View {
        let n = film?.scenes.count ?? count
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(0..<n, id: \.self) { i in
                    let fill = film.map { $0.progress(i, at: t) } ?? 1
                    ZStack(alignment: .leading) {
                        Capsule().fill(CDS.alpha(0.12))
                        Capsule().fill(CDS.Text.secondary).scaleEffect(x: fill, y: 1, anchor: .leading)
                    }
                    .frame(height: hot ? 6 : 4)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let film else { return }
                if drag == nil { drag = (false, film.playing) }
                guard drag?.moved == true || abs(value.translation.width) >= 4 else { return }
                if drag?.moved == false { drag?.moved = true; send(.pause) }
                send(.seek(min(film.time(along: value.location.x / max(proxy.size.width, 1)), film.total - 0.02)))
            }.onEnded { value in
                guard let film, let was = drag else { drag = nil; return }
                drag = nil
                if !was.moved {
                    let i = Int((value.location.x / max(proxy.size.width, 1)) * Double(film.scenes.count))
                    send(.scene(min(max(i, 0), film.scenes.count - 1)))
                } else if was.playing {
                    send(.play)
                }
            })
            .onHover { hot = $0 && film != nil }
            .motion(.fade, value: hot)
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(n) scenes")
        .accessibilityValue(film.map { "Scene \($0.scene + 1)" } ?? "")
    }
}
