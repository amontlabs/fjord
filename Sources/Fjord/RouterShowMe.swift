import AppKit
import SwiftUI

// "Show me" (a proposal on demo data only, nothing wired): a short animated explainer of an agent's answer, made by a
// separate explainer thread once the answer's turn ends. The composer's toggle and ⌘Return ask for one with the words;
// a Done card's "Show me" asks for one of its reply. Explainers wait in a dock at the page's bottom right: a pill beside
// the composer, and a panel over the page when it is open. Follow-ups go through the composer, as everything else.

/// One explainer, as the dock lists it.
struct RouterExplainer: Identifiable, Equatable {
    enum Stage: Equatable {
        /// Being made: its latest draft on the stage, what the agent is fixing in it.
        case making(draft: Int, fixing: String)
        /// Waiting for its thread's turn to end.
        case queued
        case ready
    }

    let id: String
    var title: String
    /// The thread whose answer it explains.
    var thread: String
    var since: Date
    var stage: Stage
    /// The answer in one sentence, over the stage.
    var answer: String
    var captions: [String]
    /// The scene on the stage, and where the player is in the whole (seconds).
    var scene: Int
    var elapsed: Int
    var length: Int
    /// Its stage picture in `Resources/ShowMeDemo` (`<picture>-light.jpg`, `-dark.jpg`): a still of the web view.
    var picture: String
    /// Finished and not watched yet.
    var unseen = false
}

/// The page's Show me state (demo only).
struct RouterShowMeState: Equatable {
    /// The composer's toggle: Return sends, then Show me.
    var armed = false
    /// The dock's panel is open.
    var open = false
    var selected: String?
    var explainers: [RouterExplainer] = []

    var chosen: RouterExplainer? { explainers.first { $0.id == selected } }
    var making: RouterExplainer? { explainers.first { if case .making = $0.stage { true } else { false } } }
    var queued: RouterExplainer? { explainers.first { $0.stage == .queued } }
    var unseen: Bool { explainers.contains(where: \.unseen) }
}

enum RouterShowMeLayout {
    /// The dock's glyph: the toggle's, the destination row's, the pill's.
    static let symbol = "play.rectangle"
    /// The composer's toggle, beside Return.
    static let toggle: CGFloat = 112
    /// The panel over the page.
    static let panelWidth: CGFloat = 600
    static let panelGap: CGFloat = 8
    static let rowHeight: CGFloat = 30
    /// ⌘Return: send, then Show me; on a Done card with nothing typed, Show me its reply.
    static let keys = ["cmd", "enter"]
}

// MARK: - The composer's toggle

/// Show me at the composer's trailing edge, next to Return: off, quiet words; on, the accent's tint (it came from you).
struct RouterShowMeToggle: View {
    let model: RouterModel
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
        RouterButton(model: model, hit: .showMe("toggle"), action: { model.showMe?.armed.toggle() }) { hot, pressed in
            HStack(spacing: 5) {
                Image(systemName: RouterShowMeLayout.symbol).font(.system(size: 11, weight: .medium))
                Text("Show me").font(CDS.sans(12, on ? .medium : .regular)).lineLimit(1).fixedSize()
                RouterKeyHint(keys: RouterShowMeLayout.keys, ink: on ? CDS.Text.accent.opacity(0.6) : Router.Surface.keyInk)
            }
            .foregroundStyle(on ? CDS.Text.accent : hot ? CDS.Text.primary : CDS.Text.muted)
            .frame(width: RouterShowMeLayout.toggle, height: CDS.Composer.row)
            .background {
                shape.fill(on ? CDS.Text.accent.opacity(hot ? Router.Surface.tintStrong : Router.Surface.tint)
                              : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                    .hoverMotion(hot)
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

/// The destination row while the panel has an explainer: Return makes a new version of it with the words.
struct RouterShowMeDestination: View {
    let explainer: RouterExplainer

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
            Text("makes a new version").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: Router.Dock.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Return makes a new version of the explainer \(explainer.title)")
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
        RouterButton(model: model, hit: .showMe("dock"), action: { model.showMe?.open.toggle() }) { hot, pressed in
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
            Text("After \(model.thread(queued.thread)?.name ?? "its thread") answers").foregroundStyle(CDS.Text.secondary)
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
