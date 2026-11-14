import AppKit
import SwiftUI

// The Show me dock open (RouterShowMe.swift): a floating panel over the page, its bottom right on the dock's, above the
// destination row so what Return does stays in sight. The explainers first, then the selected one's player. While one
// plays the list folds to its row and "N more". The panel has no field: a follow-up is typed in the composer, whose row
// then targets the explainer.

struct RouterShowMePanel: View {
    let model: RouterModel
    let state: RouterShowMeState
    @Environment(\.controlActiveState) private var active

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            list
            // One place in the tree whatever the list does, so the player's web view is kept across selections.
            if let e = state.chosen {
                RouterExplainerPlayer(model: model, explainer: e)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: RouterShowMeLayout.panelWidth)
        .routerFloating(radius: Router.Surface.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Explainers")
        // Watched: shown selected, finished, with the window key.
        .task(id: Watch(id: state.chosen?.id, unseen: state.chosen?.unseen == true && state.chosen?.stage == .ready,
                        key: active == .key)) {
            guard active == .key, let e = state.chosen, e.unseen, e.stage == .ready else { return }
            model.explainers?.watched(e.id)
        }
    }

    private struct Watch: Equatable { var id: String?; var unseen: Bool; var key: Bool }

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

/// The selected explainer. Ready in the app: the page plays in the web view, drawing its own answer, caption, scene bar,
/// time and Sources, with Open in T3 under it. Otherwise the held frame (a demo, a shot, one being made), with the answer
/// over it and, under it, the last scene's caption and the film's length; while it's made, its latest draft with a tag and
/// what the agent is fixing in the caption's place.
struct RouterExplainerPlayer: View {
    let model: RouterModel
    let explainer: ExplainerItem

    private var ready: Bool { explainer.stage == .ready }
    private var draft: Int? {
        if case .making(let n, _) = explainer.stage { return max(n, 1) }
        return nil
    }
    private var web: Bool { ExplainerStage.mode(page: explainer.page, ready: ready) != .still }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !web, !explainer.answer.isEmpty {
                Text(explainer.answer).font(CDS.sans(14, .semibold)).foregroundStyle(CDS.Text.primary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            ExplainerStage(page: explainer.page, posterLight: explainer.posterLight, posterDark: explainer.posterDark,
                           draft: draft, ready: ready)
            if web {
                footer.padding(.top, 8)
            } else {
                caption.padding(.top, 10)
                controls.padding(.top, 8)
            }
        }
    }

    /// Under the playing page: whether it's only a draft, and Open in T3.
    private var footer: some View {
        HStack(spacing: 10) {
            if explainer.draft {
                Text("A draft: it stopped before its final").font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            openButton
        }
        .frame(height: 24)
    }

    private var openButton: some View {
        RouterTextButton(model: model, hit: .showMe("open"), title: "Open in T3") { model.explainers?.open(explainer: explainer.id) }
    }

    @ViewBuilder private var caption: some View {
        switch explainer.stage {
        case .making(let n, let fixing):
            Group {
                if n == 0 {
                    Text("Writing the first draft").foregroundColor(CDS.Text.muted)
                } else if fixing.isEmpty {
                    Text("Checking draft \(n)").foregroundColor(CDS.Text.muted)
                } else {
                    Text("Fixing: ").foregroundColor(CDS.Text.muted) + Text(fixing).foregroundColor(CDS.Text.secondary)
                }
            }
            .font(CDS.sans(13)).lineLimit(1)
            .frame(height: 20, alignment: .leading)
        case .queued:
            Text("Starts when \(model.threadName(explainer)) answers").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
                .frame(height: 20, alignment: .leading)
        case .failed(let why):
            Text(why).font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary).lineLimit(2)
                .frame(minHeight: 20, alignment: .leading)
        case .ready:
            // The held frame is the last scene's.
            Text(explainer.captions.last ?? "").font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(2)
                .frame(minHeight: 20, alignment: .leading)
        }
    }

    /// The held frame's bar: every scene watched, the film's length. A picture of the page's, not controls: only the
    /// page plays.
    @ViewBuilder private var controls: some View {
        switch explainer.stage {
        case .queued, .failed:
            HStack { Spacer(minLength: 0); openButtonIfRun }.frame(height: 24)
        case .making, .ready:
            let making = draft != nil
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CDS.Text.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Router.Surface.chosen))
                    .accessibilityHidden(true)
                segments
                Text(making ? "Draft" : Self.clock(explainer.length))
                    .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).fixedSize()
                openButton
            }
            .opacity(making ? 0.55 : 1)
            .frame(height: 24)
        }
    }

    /// A failed run still has a thread to look at; a queued request has none yet.
    @ViewBuilder private var openButtonIfRun: some View {
        if explainer.launched { openButton }
    }

    private var segments: some View {
        let n = max(explainer.captions.count, 1)
        return HStack(spacing: 3) {
            ForEach(0..<n, id: \.self) { _ in
                Capsule().fill(draft == nil ? CDS.Text.secondary : CDS.alpha(0.12)).frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(n) scenes")
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}
