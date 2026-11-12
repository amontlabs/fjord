import AppKit
import SwiftUI

// The list's other rows (a section's header, the sentence or "Reading N threads…" in its place, the housekeeping line)
// and the filter bar, each in a hosting view of its own, as the lines are (`RouterV2HostedLine`). In the page's tree, a
// header's count ticking or a row gliding re-rendered the whole page every frame; here a count ticks in its own small
// view, the rows glide on Core Animation (`RouterV2Glides`), and the page's tree changes only when the order does.

/// The list's slot for a row that isn't a line: its hosting view, as tall as the row.
struct RouterV2HostedRow: View {
    let model: RouterV2Model
    let slot: RouterV2Slot
    let first: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerV2Still) private var still
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RouterV2RowHost(root: RouterV2RowRoot(model: model, slot: slot, first: first,
                                              setup: .init(reduce: reduce, still: still, scheme: scheme, arrival: arrival)),
                        glides: model.glides, id: slot.id)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(RouterV2.space)).origin } action: { [model, id = slot.id] in
                model.targets.origins[id] = $0
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(RouterV2.listSpace)).minY } action: { [glides = model.glides, id = slot.id] in
                glides.placed(id, at: $0)
            }
            .routerV2Glides()
    }
}

/// A row's views as its own hosting view's root, in the row's space (its targets' frames are placed by its origin).
struct RouterV2RowRoot: View, Equatable {
    let model: RouterV2Model
    let slot: RouterV2Slot
    let first: Bool
    let setup: RouterV2LineSetup

    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.slot == b.slot && a.first == b.first && a.setup == b.setup
    }

    var body: some View {
        let row = content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(RouterV2.rowSpace))
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerV2Still, setup.still)
            .environment(\.routerV2Row, slot.id)
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { row.windowArrival(arrival) } else { row }
    }

    // The first row's content (the Needs-you header, or the sentence in its place) swaps in place, on the swap's own
    // fades.
    @ViewBuilder private var content: some View {
        switch slot.kind {
        case .header(let section, let count):
            RouterV2HeaderRow(model: model, section: section, count: count, first: first)
                .transition(.routerV2Swap)
        case .sentence(let words, let clear):
            RouterV2SentenceRow(model: model, words: words, clear: clear)
                .transition(.routerV2Swap)
        case .reading(let count):
            RouterV2ReadingRow(count: count, first: first)
                .transition(.routerV2Swap)
        case .housekeeping(let count):
            RouterV2HousekeepingRow(model: model, count: count)
        case .line:
            EmptyView()
        }
    }
}

/// A hosting view that glides where the list places it (`RouterV2GlideView`).
final class RouterV2RowSlotView<Root: View>: RouterV2GlideView {
    let hosting: NSHostingView<Root>
    /// Room around the slot the hosting view draws in, never hit (the filter bar's ground and the fade under it).
    let overflow: NSEdgeInsets

    init(hosting: NSHostingView<Root>, overflow: NSEdgeInsets = .init()) {
        self.hosting = hosting
        self.overflow = overflow
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Its hosting view follows its size at once: nothing else lays it out (`RouterV2GlideView`).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    func fit() {
        let o = overflow
        let frame = CGRect(x: -o.left, y: -o.top, width: bounds.width + o.left + o.right, height: bounds.height + o.top + o.bottom)
        if hosting.frame != frame {
            hosting.frame = frame
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// A root view in a hosting view of its own, measured by its controller, set again only when it changed.
private struct RouterV2RowHost<Root: View & Equatable>: NSViewRepresentable {
    let root: Root
    let glides: RouterV2Glides?
    var id = ""
    var overflow = NSEdgeInsets()

    final class Coordinator {
        var controller: NSHostingController<Root>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RouterV2RowSlotView<Root> {
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        context.coordinator.controller = controller
        let hosting = controller.view as! NSHostingView<Root>
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let slot = RouterV2RowSlotView(hosting: hosting, overflow: overflow)
        glides?.register(id, slot)
        return slot
    }

    func updateNSView(_ view: RouterV2RowSlotView<Root>, context: Context) {
        if view.hosting.rootView != root { view.hosting.rootView = root }
        view.fit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RouterV2RowSlotView<Root>, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let controller = context.coordinator.controller else { return nil }
        let o = overflow
        let size = controller.sizeThatFits(in: CGSize(width: width + o.left + o.right, height: 0))
        return CGSize(width: width, height: max(0, size.height - o.top - o.bottom))
    }
}

// MARK: - The filter bar

/// The filter bar in a hosting view of its own: its counts tick and its grounds slide without the page's tree.
struct RouterV2HostedBar: View {
    let model: RouterV2Model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerV2Still) private var still
    @Environment(\.colorScheme) private var scheme

    /// The bar's ground reaches past its sides and the fade under it past its bottom.
    static let overflow = NSEdgeInsets(top: 0, left: RouterV2FilterBar.groundReach, bottom: RouterV2.Bar.fade,
                                       right: RouterV2FilterBar.groundReach)

    var body: some View {
        RouterV2RowHost(root: RouterV2BarRoot(model: model, setup: .init(reduce: reduce, still: still, scheme: scheme, arrival: arrival)),
                        glides: nil, overflow: Self.overflow)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(RouterV2.space)).origin } action: { [model] in
                model.targets.origins[RouterV2BarRoot.row] = $0
            }
    }
}

struct RouterV2BarRoot: View, Equatable {
    static let row = "filter-bar"
    let model: RouterV2Model
    let setup: RouterV2LineSetup

    static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.setup == b.setup }

    var body: some View {
        let o = RouterV2HostedBar.overflow
        let bar = RouterV2FilterBar(model: model)
            .coordinateSpace(.named(RouterV2.rowSpace))
            .padding(.leading, o.left).padding(.trailing, o.right).padding(.bottom, o.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerV2Still, setup.still)
            .environment(\.routerV2Row, Self.row)
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { bar.windowArrival(arrival) } else { bar }
    }
}
