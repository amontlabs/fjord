import AppKit
import SwiftUI

// The Show me dock open (RouterShowMe.swift): a floating panel over the page, its bottom right on the dock's, above the
// destination row so what Return does stays in sight. The explainers first, then the selected one's player. The panel
// has no field: a follow-up is typed in the composer, whose row then targets the explainer.

struct RouterShowMePanel: View {
    let model: RouterModel
    let state: RouterShowMeState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(state.explainers) { e in
                    RouterExplainerRow(model: model, explainer: e, selected: e.id == state.selected)
                }
            }
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
    }
}

/// An explainer in the list: its state's glyph, its title, the thread it explains (named as its line names it), then
/// its state's words and its age. The selected one on the chosen ground.
private struct RouterExplainerRow: View {
    let model: RouterModel
    let explainer: RouterExplainer
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous)
        RouterButton(model: model, hit: .showMe("row-" + explainer.id), action: { model.showMe?.selected = explainer.id }) { hot, _ in
            HStack(spacing: 8) {
                glyph.frame(width: 14, height: 14)
                Text(explainer.title).font(CDS.sans(13, selected ? .medium : .regular)).foregroundStyle(CDS.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
                RouterExplainerSource(model: model, thread: explainer.thread)
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
            ZStack(alignment: .topTrailing) {
                Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(explainer.unseen ? CDS.Text.accent : CDS.Text.muted)
            }
        }
    }

    @ViewBuilder private var words: some View {
        let font = CDS.sans(12)
        switch explainer.stage {
        case .making(let draft, _):
            Text("Making · draft \(draft)").font(font).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        case .queued:
            Text("Queued").font(font).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        case .ready:
            Text(RouterExplainerPlayer.clock(explainer.length)).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).fixedSize()
        }
    }
}

/// The thread an explainer explains: its name on its state's tint, as its line's name; a grey Done on the quiet ground.
private struct RouterExplainerSource: View {
    let model: RouterModel
    let thread: String

    var body: some View {
        if let t = model.thread(thread) {
            let look = t.look
            Text(t.name).font(CDS.sans(CDS.Badge.font, .medium))
                .foregroundStyle(look.ground ? look.tint : CDS.Badge.ink)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, CDS.Badge.padX)
                .frame(height: CDS.Badge.height)
                .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                    .fill(look.ground ? look.tint.opacity(Router.Line.ground) : Router.Surface.quiet))
        }
    }
}

/// The selected explainer: its answer, the stage, the scene's caption, the controls. While it is made: its latest
/// draft with a tag, and what the agent is fixing in the caption's place.
struct RouterExplainerPlayer: View {
    let model: RouterModel
    let explainer: RouterExplainer
    @Environment(\.colorScheme) private var scheme

    private var fixing: String? {
        if case .making(_, let fixing) = explainer.stage { return fixing }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(explainer.answer).font(CDS.sans(14, .semibold)).foregroundStyle(CDS.Text.primary)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            stage
            caption.padding(.top, 10)
            controls.padding(.top, 8)
        }
    }

    private var stage: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.card, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if let picture = RouterShowMeDemo.picture(explainer.picture, dark: scheme == .dark) {
                Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Rectangle().fill(Router.Surface.quiet).aspectRatio(16 / 9, contentMode: .fit)
            }
            if case .making(let draft, _) = explainer.stage {
                HStack(spacing: 6) {
                    RouterThinking(tint: CDS.Text.secondary, size: 12, label: "Correcting")
                    Text("Draft \(draft) · correcting").font(CDS.sans(12)).foregroundStyle(CDS.Text.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous).fill(CDS.Surface.s3.opacity(0.94)))
                .padding(10)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
        .accessibilityLabel(fixing == nil ? "Scene \(explainer.scene + 1)" : "Draft")
    }

    @ViewBuilder private var caption: some View {
        if let fixing {
            (Text("Fixing: ").foregroundColor(CDS.Text.muted) + Text(fixing).foregroundColor(CDS.Text.secondary))
                .font(CDS.sans(13)).lineLimit(1)
                .frame(height: 20, alignment: .leading)
        } else {
            Text(explainer.captions[min(explainer.scene, explainer.captions.count - 1)])
                .font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(2)
                .frame(minHeight: 20, alignment: .leading)
        }
    }

    private var controls: some View {
        let making = fixing != nil
        return HStack(spacing: 10) {
            RouterButton(model: model, hit: .showMe("play"), action: {}) { hot, pressed in
                Image(systemName: making ? "play.fill" : "pause.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CDS.Text.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(pressed ? Router.Surface.pressed : hot ? Router.Surface.chosenHover : Router.Surface.chosen))
            }
            .accessibilityLabel(making ? "Play the draft" : "Pause")
            segments
            Text(making ? "Draft" : "\(Self.clock(explainer.elapsed)) / \(Self.clock(explainer.length))")
                .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).fixedSize()
            RouterTextButton(model: model, hit: .showMe("sources"), title: "Sources") {}
            RouterTextButton(model: model, hit: .showMe("open"), title: "Open in T3") {}
        }
        .opacity(making ? 0.55 : 1)
        .frame(height: 24)
    }

    /// One segment a scene: watched whole, the current one part way.
    private var segments: some View {
        let n = max(explainer.captions.count, 1)
        let per = Double(explainer.length) / Double(n)
        let into = min(max((Double(explainer.elapsed) - per * Double(explainer.scene)) / per, 0), 1)
        return HStack(spacing: 3) {
            ForEach(0..<n, id: \.self) { i in
                let share = i < explainer.scene ? 1 : i == explainer.scene ? into : 0
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(CDS.alpha(0.12))
                        Capsule().fill(CDS.Text.secondary).frame(width: proxy.size.width * share)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Scene \(explainer.scene + 1) of \(n)")
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}
