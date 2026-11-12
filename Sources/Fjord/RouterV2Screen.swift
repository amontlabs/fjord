import AppKit
import SwiftUI

// Router v2's screen: the page (`RouterV2List`) under its title line, with what floats over it, on the window's ground.
// The page model is made once per app run (`Store.routerPage`) and kept across window opens.

struct RouterV2Screen: View {
    let model: RouterV2Model
    /// The demo's stage (its caption, key caps and drawn pointer), when a script plays.
    var stage: RouterV2Stage?
    /// Room the window's buttons take at the header's start (when the sidebar is a rail).
    var leadingInset: CGFloat = 0

    @State private var width: CGFloat = 0
    @State private var flags = RouterV2FlagsWatch()
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.undoManager) private var undoManager

    /// The column's edges from the page's sides: the title, the headers, the names and the composer share them.
    private var edges: RouterEdges {
        let inset = AppPage<EmptyView, EmptyView>.columnInset((RouterV2.column, RouterV2.gutter), pageWidth: width)
        return RouterEdges(leading: max(inset, leadingInset + 14), trailing: inset)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            RouterV2List(model: model, edges: edges)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CDS.Surface.s1.padding(.top, AppContent.groundTop) }
        .overlay(alignment: .topLeading) { RouterV2Floating(model: model) }
        .overlay(alignment: .topLeading) { if let stage { RouterV2PointerView(stage: stage) } }
        .coordinateSpace(.named(RouterV2.space))
        .onGeometryChange(for: CGSize.self, of: \.size) {
            width = $0.width
            model.targets.viewport = $0
        }
        .foregroundStyle(Theme.text)
        .modifier(Brand.Scheme())
        .environment(\.routerV2Still, model.still)
        .onAppear {
            model.reduce = reduce
            model.undoManager = undoManager
            flags.start(model)
            // The ages tick on one clock while the page shows (a still's stands).
            if !model.still { model.clock.start() }
        }
        .onDisappear {
            flags.stop()
            model.clock.stop()
        }
        .onChange(of: reduce) { _, now in model.reduce = now }
    }

    /// The 48 pt header: the title and, while a script plays, the beat's caption and the keys just pressed.
    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Router")
                .font(CDS.sans(CDS.Density.compact.body.0, .medium))
                .foregroundStyle(CDS.Text.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let stage { RouterV2CaptionView(stage: stage) }
            Spacer(minLength: 24)
            PaletteTrigger()
        }
        .frame(height: CDS.TitleBar.bar)
        .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
        .frame(height: CDS.TitleBar.header)
        .frame(maxWidth: .infinity)
        .background(CDS.Surface.s1)
    }
}

/// ⌥ held flips the destination row's "steer now" to "queue after this turn", live.
@MainActor final class RouterV2FlagsWatch {
    private var monitor: Any?

    func start(_ model: RouterV2Model) {
        guard monitor == nil, !model.still else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak model] event in
            MainActor.assumeIsolated {
                if let model, !model.scripted { model.setOption(event.modifierFlags.contains(.option)) }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
