import AppKit
import SwiftUI

// A thread's line in a hosting view of its own (docs/design/router-v2/IMPLEMENTATION.md 2.2, "one record changes: one
// line redrawn"). In the page's one SwiftUI tree, a record, a streamed word or a growing reply laid out, hit-tested and
// drew the whole sixty-row page, every frame (`--router-v2-load`: event to commit p95 ~150 ms). Here each line's views
// live in their own `NSHostingView`: a change inside a line lays out, hit-tests and draws that line alone, and the list
// sees a leaf whose height changes only when the card opens or shuts, the queued row comes or goes, or the card's
// content grows. The list keeps what moves lines (their places, the glide between sections, the fold in and out, the
// moving line drawn on top), so the motion is the same.

extension RouterV2 {
    /// A hosted line's own coordinate space: its targets' frames are in it, placed on the page by the line's origin.
    static let rowSpace = "router-v2-row"
}

/// The list's slot for a line: its hosting view, as tall as the line's content.
struct RouterV2HostedLine: View {
    let model: RouterV2Model
    let box: RouterV2LineBox
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerV2Still) private var still
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // What the line's height follows: its card opening or shutting (in the same transaction as the change, so the
        // rows under it slide on the card's own curve), its queued words, its card's content as laid out.
        let _ = (box.selected, box.moving, box.built, box.queued)
        let card = box.cardHeight
        RouterV2LineHost(model: model, box: box, setup: .init(reduce: reduce, still: still, scheme: scheme, arrival: arrival))
            // Its content grew or shrank while open: the slot follows, as the card does inside.
            .motion(.spatial, value: card)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(RouterV2.space)).origin } action: { [model, id = box.id] in
                model.targets.origins[id] = $0
            }
            // A line in flight passes over the rows between: it is drawn last.
            .zIndex(box.moving ? 1 : 0)
    }
}

/// What a line's hosting view takes from the page's environment.
struct RouterV2LineSetup: Equatable {
    var reduce: Bool
    var still: Bool
    var scheme: ColorScheme
    var arrival: WindowArrival?

    static func == (a: Self, b: Self) -> Bool {
        a.reduce == b.reduce && a.still == b.still && a.scheme == b.scheme && a.arrival === b.arrival
    }
}

/// The line's views as its own hosting view's root.
struct RouterV2LineRoot: View {
    let model: RouterV2Model
    let box: RouterV2LineBox
    let setup: RouterV2LineSetup

    var body: some View {
        // Top first: while the slot is taller than the line (its card rolling shut), the line stays at its top.
        let line = RouterV2LineView(model: model, box: box)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(RouterV2.rowSpace))
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerV2Still, setup.still)
            .environment(\.routerV2Row, box.id)
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { line.windowArrival(arrival) } else { line }
    }
}

/// A line's hosting view, measured by its controller (`sizeThatFits(in:)`).
typealias RouterV2LineHosting = NSHostingView<RouterV2LineRoot>

private struct RouterV2LineHost: NSViewRepresentable {
    let model: RouterV2Model
    let box: RouterV2LineBox
    let setup: RouterV2LineSetup

    final class Coordinator {
        var controller: NSHostingController<RouterV2LineRoot>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RouterV2LineHosting {
        let controller = NSHostingController(rootView: RouterV2LineRoot(model: model, box: box, setup: setup))
        // The list sizes it (`sizeThatFits`): no preferred size or constraints to keep up to date on each change, and no
        // safe area of the window's.
        controller.sizingOptions = []
        context.coordinator.controller = controller
        let view = controller.view as! RouterV2LineHosting
        view.sizingOptions = []
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: RouterV2LineHosting, context: Context) {
        // A new root only when what it takes changed: setting one runs the line's whole body again.
        let root = view.rootView
        if root.box !== box || root.model !== model || root.setup != setup {
            view.rootView = RouterV2LineRoot(model: model, box: box, setup: setup)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RouterV2LineHosting, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let controller = context.coordinator.controller else { return nil }
        // A zero height: the root's flexible frame comes back at the line's own height.
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 0))
        return CGSize(width: width, height: size.height)
    }
}
