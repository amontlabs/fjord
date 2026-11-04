import SwiftUI

// The Router's window as a sibling of Claude's Code tab: the Router's page (its history, what works on its own, what needs
// you; see RouterPage.swift) over the composer, in the app window's detail area. Built on `RouterModel` and the
// form and plan logic of RouterView.swift; only the presentation is Claude's.

struct RouterCodeView: View {
    let store: Store
    @Bindable var model: RouterModel
    var close: () -> Void = {}
    var checksClaudeCode = true
    /// Inside the app window the detail area sets the size (and the window's top is the window's job); alone it has its own.
    var embedded = false
    /// Room the window's buttons take at the header's start (when the sidebar is a rail).
    var leadingInset: CGFloat = 0

    static let column: CGFloat = 768

    var body: some View {
        RouterMain(store: store, model: model, leadingInset: leadingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In the app window before macOS 26, the header shows the window's top bar.
            .background { CDS.Surface.s1.padding(.top, embedded ? AppContent.groundTop : 0) }
        .frame(minWidth: embedded ? 0 : 760, minHeight: embedded ? 0 : 520)
        .foregroundStyle(Theme.text)
        .modifier(Brand.Scheme())
        // Inside the app window, the window's tip space draws the tips: a second one would only measure the page again.
        .tipSpace(!embedded)
        .task { if checksClaudeCode { await model.checkClaudeCode(store) } }
    }
}

// MARK: - Main column

struct RouterMain: View {
    let store: Store
    @Bindable var model: RouterModel
    var leadingInset: CGFloat = 0

    var body: some View {
        let flights = model.flights
        page
            // Your messages in flight, from over the composer to where each went (`RouterFlights`).
            .overlay {
                FlightLayer(store: store, flights: flights)
            }
            .coordinateSpace(.named(FlightSpace.name))
            .onPreferenceChange(FlightFramesKey.self) { flights.frames = $0 }
            .environment(flights)
            .onChange(of: model.layout, initial: true) {
                flights.landedInHistory = { [weak model] in model?.show(.history) }
                flights.resolvePlace = model.layout == .canvas ? { [weak model, weak store, weak flights] key, fallback in
                    guard let model, let store, let flights else { return nil }
                    return model.canvasFlightPlace(key, frames: flights.frames, fallback: fallback, store: store)
                } : nil
                flights.didLand = model.layout == .canvas ? { [weak model] flight in
                    model?.canvas.flightLanded(flight)
                } : { _ in }
            }
    }

    @ViewBuilder private var page: some View {
        if #available(macOS 26, *) {
            // The page runs under its top bar (glass-plan §5.3): in a wide window the history, Now's
            // column with a hard edge under its own bar (see `NowColumn`). The composer floats over the page's bottom
            // (§5.4): its height is the page's bottom inset, so the last line still lands above it and earlier ones scroll
            // under it, fading out under a soft edge down to the window's bottom, as under Claude's composer.
            VStack(spacing: 0) {
                RouterSetupNotice(store: store, model: model)
                // The brief (RouterBriefView.swift); the Now and canvas pages stay compiled, unused.
                RouterBriefView(store: store, model: model)
                    .frame(maxHeight: .infinity)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                composer
                    .frame(maxWidth: .infinity)
                    // The page's ground from the composer's middle down, so no line shows below it or through its glass. On
                    // the canvas, nothing: the composer and your messages float over its ground, which goes on round them.
                    .background {
                        LinearGradient(colors: [CDS.Surface.s1.opacity(0), CDS.Surface.s1], startPoint: .top, endPoint: .center)
                            .allowsHitTesting(false)
                    }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .top, spacing: 0) { topBar }
            .scrollEdgeEffectHidden(true, for: .top)
        } else {
            VStack(spacing: 0) {
                topBar
                RouterSetupNotice(store: store, model: model)
                RouterBriefView(store: store, model: model)
                    .frame(maxHeight: .infinity)
                composer
            }
        }
    }

    /// The composer, and under it the history's drawer (RouterDrawer.swift).
    private var composer: some View {
        VStack(spacing: 6) {
            RouterComposer(store: store, model: model)
            RouterDrawer(store: store)
        }
        .frame(maxWidth: RouterCodeView.column)
        .padding(.horizontal, 32)
        .padding(.bottom, 10)
    }

    /// §3: a 48pt header holding the 32pt session bar: the title (13pt, wght 460, primary), and on the Brief when it was
    /// written, muted, as the other pages' subtitles. On the inbox's column, as the inbox's header is, so the title and the
    /// palette's trigger don't move going from one to the other; the page under it keeps the window's width.
    private var topBar: some View {
        HeaderInsets(column: AppPage<EmptyView, EmptyView>.inboxColumn, leadingInset: leadingInset) {
            HStack(spacing: 8) {
                Text("Router")
                    .font(CDS.sans(CDS.Density.compact.body.0, .medium))
                    .foregroundStyle(CDS.Text.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 24)
                // The palette's trigger, where the Router's own search field was.
                PaletteTrigger()
            }
        }
        .frame(height: CDS.TitleBar.bar)
        .frame(height: CDS.TitleBar.header)
        .frame(maxWidth: .infinity)
        .onChange(of: model.search.query) { model.searchChanged(store: store) }
        // The page's ground behind its title line, so nothing scrolled under it shows through the title.
        .background(CDS.Surface.s1)
    }
}

/// The project chip beside the title (§3; classes untraced, MEASURED: 17 tall, white 10%, 12pt secondary).
struct ProjectChip: View {
    let name: String
    var body: some View {
        Text(name).font(CDS.sans(CDS.Density.compact.footnote.0)).foregroundStyle(CDS.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, CDS.TitleBar.chipPadding).frame(height: CDS.TitleBar.chipHeight)
            .background(RoundedRectangle(cornerRadius: CDS.TitleBar.chipRadius, style: .continuous).fill(CDS.TitleBar.chipFill))
    }
}
