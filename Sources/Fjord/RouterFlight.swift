import SwiftUI

// Your message on its way, in sight. Sent from the composer, it rises into a pill over the composer, Fjord's loader
// turning while the Router finds where it goes, the destination's name coming in once it is chosen. Once it went, the
// pill flies along a curve into the row of the session it went to (the card it answered, the new session's row, the
// history for the Router's own answer) and that row flashes as it lands: a session that wasn't working comes into
// Working at once, so it has somewhere to land. The Router not sure, the pill unfolds into "Where should this go?"
// where it is; failing, it stays with why and a Retry. A place out of sight (scrolled away, a folded section, the other
// side) is landed on by its section's chip or the Now/History switch; nothing scrolls for it. Under Reduce Motion
// nothing flies: the pill fades, the row flashes.

/// The page's space the pills fly in: the Router's page with its composer (`RouterMain`).
enum FlightSpace {
    static let name = "routerFlight"
}

/// Where each place a message can land is, by key: `session:<id>`, `card:<id>`, `chip:<zone>`, `pane:now`, `pane:history`,
/// `history`, and the page's own (`now`, `composer`, `pill:<run>`).
struct FlightFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Your messages on their way, and the places they land.
@Observable @MainActor final class RouterFlights {
    struct Pill: Identifiable, Equatable {
        enum Phase: Equatable {
            case pending
            /// It ended without going anywhere: why, and whether it is yours to retry (a stop isn't).
            case failed(String, retry: Bool)
            /// Fading out of the stack (dismissed, or stopped and said so).
            case leaving
        }
        var id: UUID
        var text: String
        var phase: Phase = .pending
    }

    struct Flight: Identifiable, Equatable {
        var id: UUID
        var text: String
        var status: String
        var from: CGRect
        var to: CGRect
        /// Where it lands: the key that flashes.
        var target: String
    }

    struct Place: Equatable {
        let target: String
        let rect: CGRect
    }

    /// An alternate layout resolves its targets from the same measured page frames and shares the wait and flight.
    @ObservationIgnored var resolvePlace: ((String, Bool) -> Place?)?
    @ObservationIgnored var didLand: (Flight) -> Void = { _ in }
    /// Offscreen shots hold the shared flight at one point, without completing it.
    @ObservationIgnored var freezeFlight: CGFloat?

    /// Over the composer, oldest first (the newest nearest the composer).
    private(set) var pills: [Pill] = [] {
        didSet { track() }
    }
    private(set) var flights: [Flight] = [] {
        didSet { track() }
    }
    /// Whether the places are measured (`frames`): only while a message is on its way (a pill pending, or flying), so the
    /// page's cards and rows carry no measuring the rest of the time. Written only when it changes.
    private(set) var tracking = false

    private func track() {
        // A pill that failed (waiting for its Retry or dismissal) or is leaving goes nowhere: it measures nothing.
        let on = pills.contains { $0.phase == .pending } || !flights.isEmpty
        if tracking != on { tracking = on }
    }
    /// When each place was last landed on: its flash.
    private(set) var landed: [String: Date] = [:]
    /// The places as last laid out, in `FlightSpace`. Read when a flight starts, never drawn from; a flight waiting for its
    /// place hears of each new layout (`placeWaiters`).
    @ObservationIgnored var frames: [String: CGRect] = [:] {
        didSet { for waiter in Array(placeWaiters.values) { waiter() } }
    }
    @ObservationIgnored private var placeWaiters: [UUID: () -> Void] = [:]
    /// Runs seen, so one dropped from the stack never comes back.
    @ObservationIgnored private var seen: Set<UUID> = []
    /// Flights waiting for their place to be laid out.
    @ObservationIgnored private var launching: Set<UUID> = []
    /// A flight to the history landed (the page shows it in a narrow window).
    @ObservationIgnored var landedInHistory: () -> Void = {}

    /// How long a flight waits for the row it goes to (one coming into Working) before it lands on its section's chip.
    static let waitForPlace: Duration = .milliseconds(450)

    // MARK: Following the runs

    /// Follows the composer's runs (`RouterDispatcher.flying`): new pills, flights once a message went, failures.
    func sync(store: Store) {
        let dispatcher = store.routerDispatcher
        for id in dispatcher.flying where !seen.contains(id) {
            seen.insert(id)
            // A part of a divided message is read as an entry of its own: its words are the pill's.
            guard let entry = store.router.record(id), case .you(let text) = entry.trigger else { continue }
            // The parts take the place of the message's pill, in its order.
            if let parent = store.router.parent(of: id), let at = pills.firstIndex(where: { $0.id == parent }) {
                pills.insert(Pill(id: id, text: text), at: at)
            } else {
                pills.append(Pill(id: id, text: text))
            }
        }
        for pill in pills where pill.phase == .pending && !launching.contains(pill.id) {
            guard let entry = store.router.record(pill.id) else {
                drop(pill.id, store: store)
                continue
            }
            // The message went to several places: each part has a pill, flying to its own place.
            if entry.isDivided {
                drop(pill.id, store: store)
                continue
            }
            let running = dispatcher.progress[pill.id] != nil || dispatcher.held[pill.id] != nil
            let asking = dispatcher.askBacks.contains { $0.id == pill.id }
            // A part held for another place's answer is in the history, with Send now: its pill goes there, not on spinning.
            let holding = dispatcher.held[pill.id] != nil && Self.holds(entry)
            if Self.went(entry) || holding || (!running && !asking && entry.outcome != .pending && entry.reply != nil && !Self.failed(entry)) {
                launch(pill, to: holding ? "history" : Self.landing(entry), store: store)
            } else if !running, !asking, entry.outcome != .pending {
                if let why = Self.failure(entry) {
                    let stopped = why.hasPrefix("Stopped")
                    let relay = store.router.guestRelayDeliveries.last { $0.decisionID == pill.id }
                    let canRetry = relay.map { ($0.state == .inFlight || $0.state == .unconfirmed) && $0.signedPayload != nil
                        && $0.hostSessionID != nil } ?? true
                    set(pill.id, .failed(stopped ? "Stopped · nothing was sent" : why, retry: !stopped && canRetry))
                    if stopped { Task { try? await Task.sleep(for: .seconds(2.4)); self.leave(pill.id, store: store) } }
                } else {
                    // Dismissed, or nothing to show for it.
                    leave(pill.id, store: store)
                }
            }
        }
    }

    /// What a pending pill says after its words: what the Router is at, then where it goes.
    func status(_ id: UUID, store: Store) -> String {
        let dispatcher = store.routerDispatcher
        let entry = store.router.record(id)
        if dispatcher.held[id] != nil { return entry.map(Self.holds) == true ? "held until you send it" : "waiting for Claude to open it" }
        if let title = Self.destination(entry?.decision.targetID, store: store) { return "→ " + title }
        return "finding where it goes"
    }

    func dismiss(_ id: UUID, store: Store) { leave(id, store: store) }

    /// Sends a failed pill's words again, as a new message of yours.
    func retry(_ id: UUID, store: Store) {
        guard let pill = pills.first(where: { $0.id == id }) else { return }
        if let relay = store.router.guestRelayDeliveries.last(where: { $0.decisionID == id }) {
            guard (relay.state == .inFlight || relay.state == .unconfirmed), relay.signedPayload != nil,
                  relay.hostSessionID != nil else { return }
            set(id, .pending)
            store.routerDispatcher.retryGuestDelivery(relay)
            return
        }
        var context = RouterContext()
        context.flies = true
        drop(id, store: store)
        store.routerDispatcher.submit(pill.text, context: context)
    }

    // MARK: Flying

    private func launch(_ pill: Pill, to target: String, store: Store) {
        launching.insert(pill.id)
        let status = self.status(pill.id, store: store)
        wake(target, pill: pill, store: store)
        Task {
            // The row it goes to may be coming into Working now: its place, as soon as a layout has it.
            let to = await self.place(target, within: Self.waitForPlace)
            let landing = to ?? fallback(for: target)
            let from = frames["pill:\(pill.id)"] ?? frames["composer"] ?? .zero
            launching.remove(pill.id)
            pills.removeAll { $0.id == pill.id }
            guard let landing else { return finish(pill.id, store: store) }
            flights.append(Flight(id: pill.id, text: pill.text, status: status, from: from, to: landing.rect, target: landing.target))
        }
    }

    /// The flight reached its place: it flashes there.
    func land(_ id: UUID, store: Store) {
        guard let flight = flights.first(where: { $0.id == id }) else { return }
        flights.removeAll { $0.id == id }
        landed[flight.target] = Date()
        didLand(flight)
        if flight.target == "history" || flight.target == "pane:history" { landedInHistory() }
        finish(id, store: store)
    }

    /// A session your message went to that isn't working (finished, or new) is working now: it comes into Working at once,
    /// before the Claude app's next read says so, so the message has somewhere to land.
    private func wake(_ target: String, pill: Pill, store: Store) {
        guard target.hasPrefix("session:") else { return }
        let id = String(target.dropFirst("session:".count))
        // Already in Working (running, or what it left running): it stays where it is.
        guard !store.routerWorkingRows.contains(where: { $0.id == id }) else { return }
        let now = Date()
        if var session = store.claudeSessions[id] {
            session.running = true
            session.lastUserMessage = now
            session.lastActivity = now
            store.claudeSessions[id] = session
        } else if let entry = store.router.record(pill.id),
                  let new = entry.decision.targetID, new.hasPrefix("new:") {
            var session = ClaudeSession(id: id, title: RouterDispatcher.title(for: pill.text), folder: String(new.dropFirst(4)),
                                        lastActivity: now, running: true)
            session.lastUserMessage = now
            store.claudeSessions[id] = session
            // Listed as the sessions' read would list it on first sight.
            if !store.agents.entries.contains(where: { $0.id == id }) {
                store.agents.entries.append(AgentEntry(id: id, seen: session.activity))
            }
        }
    }

    /// Where `key` is, when enough of it shows: a row or card in Now's view (above the composer), its top line only; a
    /// chip or the switch as it is; the history's newest line.
    private func place(_ key: String) -> Place? {
        if let resolvePlace { return resolvePlace(key, false) }
        guard let rect = frames[key], rect.width > 1, rect.height > 1 else { return nil }
        if key.hasPrefix("chip:") || key.hasPrefix("pane:") { return Place(target: key, rect: rect) }
        let bottom = frames["composer"]?.minY ?? .infinity
        if key == "history" {
            let y = min(rect.maxY, bottom) - 44
            return Place(target: key, rect: CGRect(x: rect.minX + 24, y: y, width: max(120, min(rect.width - 48, 640)), height: 30))
        }
        guard let now = frames["now"] else { return nil }
        // Under Now's chips (and the page's top bar, which Now runs under on macOS 26), over the composer.
        let top = max(now.minY, frames["nowTop"]?.maxY ?? now.minY)
        let view = CGRect(x: now.minX, y: top, width: now.width, height: max(0, min(now.maxY, bottom) - top))
        let line = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, 44))
        return line.intersection(view).height >= line.height * 0.7 ? Place(target: key, rect: line) : nil
    }

    /// `place(key)`, now or from the first layout that has it (each new layout of the places is looked at as it comes,
    /// nothing polls), else nil after `wait`.
    private func place(_ key: String, within wait: Duration) async -> Place? {
        if let rect = place(key) { return rect }
        final class Once { var done = false }
        let once = Once(), id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Place?, Never>) in
            let finish: (Place?) -> Void = { [weak self] rect in
                guard !once.done else { return }
                once.done = true
                self?.placeWaiters[id] = nil
                continuation.resume(returning: rect)
            }
            placeWaiters[id] = { [weak self] in if let rect = self?.place(key) { finish(rect) } }
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                finish(nil)
            }
        }
    }

    /// Where a message lands whose place is out of sight: its section's chip, else the side it is on.
    private func fallback(for key: String) -> Place? {
        if let resolvePlace { return resolvePlace(key, true) }
        let chain = key.hasPrefix("session:") ? ["chip:working", "pane:now"]
            : key.hasPrefix("card:") ? ["chip:needs", "pane:now"]
            : ["pane:history"]
        for key in chain { if let rect = place(key) { return rect } }
        return nil
    }

    private func set(_ id: UUID, _ phase: Pill.Phase) {
        guard let i = pills.firstIndex(where: { $0.id == id }) else { return }
        pills[i].phase = phase
    }

    private func leave(_ id: UUID, store: Store) {
        set(id, .leaving)
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            drop(id, store: store)
        }
    }

    private func drop(_ id: UUID, store: Store) {
        pills.removeAll { $0.id == id }
        finish(id, store: store)
    }

    private func finish(_ id: UUID, store: Store) {
        store.routerDispatcher.forgetFlying(id)
    }

    // MARK: Reading a run

    /// It went somewhere: sent, a session started, a card answered, Fjord changed.
    static func went(_ entry: RouterDecision) -> Bool {
        entry.done.contains {
            switch $0 {
            case .sent, .started, .preparedGuest, .answered, .changed, .resolved, .archived, .stopped, .interrupted: true
            case .asked, .failed, .cancelled: false
            }
        }
    }

    static func failed(_ entry: RouterDecision) -> Bool { failure(entry) != nil }

    /// A part of a divided message that waits for another place's answer and hasn't gone: held for you to send.
    static func holds(_ entry: RouterDecision) -> Bool {
        entry.outcome == .pending && entry.done.isEmpty && entry.parts.first?.waitsFor != nil
    }

    static func failure(_ entry: RouterDecision) -> String? {
        for item in entry.done.reversed() { if case .failed(let why) = item { return why } }
        return nil
    }

    /// The place a run that went lands on.
    static func landing(_ entry: RouterDecision) -> String {
        let target = entry.decision.targetID ?? ""
        if target.hasPrefix("answer:") { return "card:\(entry.links.cards.first ?? String(target.dropFirst(7)))" }
        for item in entry.done { if case .started(let session?, _, _, _) = item { return "session:\(session)" } }
        if let session = entry.links.sessions.first { return "session:\(session)" }
        if target.hasPrefix("session:") { return target }
        return "history"
    }

    /// A destination as the pill names it: the session's or card's title, "New session in lcu", the Router.
    static func destination(_ target: String?, store: Store) -> String? {
        guard let target, !target.isEmpty else { return nil }
        if target.hasPrefix("answer:") {
            let id = String(target.dropFirst(7))
            return store.router.cards.first { $0.id == id }?.title
        }
        if target.hasPrefix("session:") { return store.claudeSessions[String(target.dropFirst(8))]?.title }
        if target.hasPrefix("new:") { return "New session in \(store.folderName(String(target.dropFirst(4))))" }
        switch target {
        case "question": return "the Router"
        case "change_fjord", "compound": return "Fjord"
        default: return nil
        }
    }
}

// MARK: - Places

extension View {
    /// A place a message can land (`RouterFlights`): its frame is known to the flights, and it flashes as one lands (unless
    /// `flashes` is off: what lands there shows on its own). Nil: none.
    func flightTarget(_ key: String?, radius: CGFloat = 10, flashes: Bool = true) -> some View {
        modifier(FlightTarget(key: key, radius: radius, flashes: flashes))
    }

    /// A frame the flights read but nothing lands on (Now's view, the composer, a pill). Measured only while a message is on
    /// its way (`RouterFlights.tracking`).
    func flightFrame(_ key: String) -> some View {
        modifier(FlightFrame(key: key))
    }
}

private struct FlightFrame: ViewModifier {
    let key: String
    @Environment(RouterFlights.self) private var flights: RouterFlights?

    func body(content: Content) -> some View {
        content.background {
            if flights?.tracking == true {
                GeometryReader { geometry in
                    Color.clear.preference(key: FlightFramesKey.self, value: [key: geometry.frame(in: .named(FlightSpace.name))])
                }
            }
        }
    }
}

private struct FlightTarget: ViewModifier {
    let key: String?
    let radius: CGFloat
    let flashes: Bool
    @Environment(RouterFlights.self) private var flights: RouterFlights?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var glow = 0.0

    func body(content: Content) -> some View {
        if let key {
            content
                .flightFrame(key)
                // Only while it flashes: the rest of the time a card carries no shapes for it. Coming and going, the flash
                // fades as a whole (the default transition), as its glow would.
                .overlay {
                    if glow > 0 {
                        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                        shape.fill(CDS.Text.accent.opacity(0.14 * glow))
                            .overlay { shape.strokeBorder(CDS.Text.accent.opacity(0.55 * glow), lineWidth: 1) }
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: flights?.landed[key]) { _, at in
                    guard at != nil, flashes else { return }
                    withAnimation(reduce ? .easeOut(duration: 0.14) : .easeOut(duration: 0.12)) { glow = 1 } completion: {
                        withAnimation(reduce ? .easeOut(duration: 0.4) : .easeOut(duration: 0.6)) { glow = 0 }
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - The stack over the composer

/// Your messages on their way, over the composer: a pill each, or the ask it unfolded into.
struct FlightStack: View {
    let store: Store
    let flights: RouterFlights
    /// The canvas keeps asks from sends outside its composer here too.
    var showsOtherAsks = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let asks = store.routerDispatcher.askBacks
        VStack(alignment: .leading, spacing: 6) {
            ForEach(flights.pills) { pill in
                ZStack(alignment: .bottomLeading) {
                    if pill.phase == .pending, let ask = asks.first(where: { $0.id == pill.id }) {
                        AskBackCard(store: store, ask: ask)
                            .transition(reduce ? .opacity : .scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity))
                    } else {
                        FlightPill(store: store, flights: flights, pill: pill)
                            .transition(.opacity)
                    }
                }
                .flightFrame("pill:\(pill.id)")
                .opacity(pill.phase == .leaving ? 0 : 1)
                // Rises out of the composer; gone at once when it flies (the flying copy takes its place).
                .transition(.asymmetric(insertion: reduce ? .opacity : .offset(y: 26).combined(with: .opacity), removal: .identity))
            }
            if showsOtherAsks {
                ForEach(asks.filter { !store.routerDispatcher.flying.contains($0.id) }) { ask in
                    AskBackCard(store: store, ask: ask)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(.glass, value: flights.pills.map { "\($0.id)\($0.phase)" } + asks.map(\.id.uuidString))
        .onChange(of: signature, initial: true) { flights.sync(store: store) }
    }

    /// What the pills follow of their runs: a change of any syncs them.
    private var signature: [String] {
        let dispatcher = store.routerDispatcher
        return dispatcher.flying.map { id in
            let entry = store.router.record(id)
            return [id.uuidString, dispatcher.progress[id] ?? "", dispatcher.held[id] ?? "",
                    dispatcher.askBacks.contains { $0.id == id } ? "ask" : "", entry.map { "\($0.outcome)" } ?? "",
                    "\(entry?.done.count ?? -1)", entry?.decision.targetID ?? "", entry?.reply == nil ? "" : "r"].joined(separator: "|")
        }
    }
}

/// A message on its way: the loader, your words, where it goes. Failed: why, Retry and ×.
private struct FlightPill: View {
    let store: Store
    let flights: RouterFlights
    let pill: RouterFlights.Pill

    var body: some View {
        switch pill.phase {
        case .pending, .leaving:
            let status = flights.status(pill.id, store: store)
            FlightPillFace(text: pill.text, status: status)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pill.text), \(status)")
        case .failed(let why, let retry):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CDS.Text.warning).frame(width: 14, height: 14)
                Text(pill.text).cdsText((13, 18), .regular, CDS.Text.secondary).lineLimit(1).truncationMode(.tail)
                Text(why).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                if retry {
                    ClaudeButton("Retry", variant: .ghost, size: .sm) { flights.retry(pill.id, store: store) }
                    ChipClose(label: "Dismiss") { flights.dismiss(pill.id, store: store) }
                }
            }
            .flightPillShape()
        }
    }
}

/// The pill's face, in the stack and in flight (`shaped`: false, its flight draws the shape at the size it has on the way).
struct FlightPillFace: View {
    let text: String
    let status: String
    var shaped = true

    var body: some View {
        let face = HStack(spacing: 8) {
            FjordLoader(color: CDS.Text.secondary, label: status).frame(width: 14, height: 14)
            Text(text).cdsText((13, 18), .regular, CDS.Text.primary).lineLimit(1).truncationMode(.tail)
            Text(status).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).fixedSize()
                .id(status)
                .transition(.opacity)
        }
        .motion(.fade, value: status)
        if shaped { face.flightPillShape() } else { face.padding(.horizontal, 12) }
    }
}

private extension View {
    func flightPillShape() -> some View {
        padding(.horizontal, 12).frame(height: 34).flightPillGround()
    }

    func flightPillGround() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return background(shape.fill(CDS.Surface.s3))
            .overlay { shape.strokeBorder(CDS.border, lineWidth: 1) }
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

// MARK: - In flight

/// The pills in flight, over the whole page.
struct FlightLayer: View {
    let store: Store
    let flights: RouterFlights

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(flights.flights) { flight in
                FlyingPill(flight: flight, freeze: flights.freezeFlight) { flights.land(flight.id, store: store) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlyingPill: View {
    let flight: RouterFlights.Flight
    let freeze: CGFloat?
    let landed: () -> Void
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        FlightPillFace(text: flight.text, status: flight.status, shaped: false)
            .modifier(FlightPath(progress: freeze ?? progress, from: flight.from, to: flight.to, still: reduce))
            .onAppear {
                guard freeze == nil else { return }
                // Off slowly enough for the eye to catch it, landing soft: no spring's start at full speed.
                withAnimation(reduce ? .easeOut(duration: 0.22) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.45)) { progress = 1 } completion: {
                    landed()
                }
            }
    }
}

/// A pill's way from over the composer to its place: up first, then across into it (a quadratic curve whose control point
/// sits near the start's column, a little under the place's line), taking the place's width and height on the way, and
/// fading as it merges into it.
private struct FlightPath: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGRect
    let to: CGRect
    /// Reduce Motion: it stays where it is and fades.
    let still: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @ViewBuilder func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        if still {
            content.frame(width: from.width, height: from.height, alignment: .leading).flightPillGround()
                .position(x: from.midX, y: from.midY).opacity(1 - p)
        } else {
            moving(content, p)
        }
    }

    private func moving(_ content: Content, _ p: CGFloat) -> some View {
        // The shape follows a little behind the move, so it reads as the pill until it is near.
        let s = smooth((p - 0.3) / 0.7)
        let width = from.width + (to.width - from.width) * s
        let height = from.height + (to.height - from.height) * s
        let a = CGPoint(x: from.midX, y: from.midY), b = CGPoint(x: to.midX, y: to.midY)
        let c = CGPoint(x: a.x + (b.x - a.x) * 0.1, y: b.y + (a.y - b.y) * 0.25)
        let t = p
        let x = (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x
        let y = (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y
        let fade = p < 0.82 ? 1 : max(0, 1 - (p - 0.82) / 0.18)
        return content
            .frame(width: max(width, 40), height: max(height, 20), alignment: .leading)
            .flightPillGround()
            .scaleEffect(1 - 0.03 * sin(.pi * p))
            .position(x: x, y: y)
            .opacity(fade)
    }

    private func smooth(_ x: CGFloat) -> CGFloat {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
