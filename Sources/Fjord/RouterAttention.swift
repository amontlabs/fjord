import AppKit
import CoreGraphics
import SwiftUI

// The one place that decides whether something interrupts you. A banner comes at once for what stops a session (a question,
// a plan, an OK asked, a stuck turn) and for a turn asking you something Jev rates soon or more urgent; the rest waits quietly
// in Needs you. Away (no input for a few minutes, the screen locked, the Mac asleep) only what can't wait comes; when you're
// back, one banner says what came meanwhile ("While you were away: 2 need you, 3 finished, 1 ready to continue") and the
// Router shows it at the top of Needs you, Jev's most urgent first, until you dismiss it. Focus modes are macOS's own.

/// What came while you were away.
struct AwayStrip: Equatable {
    var since: Date
    /// The cards that came, by id, in the order they came.
    var cards: [String]
    /// Inbox banners held.
    var inbox = 0

    /// Its cards still open, by what they are: those that need you (Needs you's order), those ready to continue, those that
    /// finished (a trivial turn left out), each part most urgent first.
    func items(_ all: [RouterCard]) -> (needs: [RouterCard], ready: [RouterCard], finished: [RouterCard]) {
        let ids = Set(cards)
        let open = all.filter { $0.isOpen && ids.contains($0.id) }
        return (open.filter(\.kind.needsYou).sorted(by: RouterPage.ranked),
                open.filter { $0.kind == .waiting && $0.triage?.ready != nil }.sorted(by: RouterPage.ranked),
                open.filter { $0.kind == .done && $0.triage?.trivial != true }.sorted(by: RouterPage.ranked))
    }

    func listed(_ all: [RouterCard]) -> [RouterCard] {
        let i = items(all)
        return i.needs + i.ready + i.finished
    }

    /// "2 need you, 3 finished, 1 ready to continue, 4 in your inbox"; nil when nothing is left of it.
    func line(_ all: [RouterCard]) -> String? {
        let i = items(all)
        var parts: [String] = []
        if !i.needs.isEmpty { parts.append(i.needs.count == 1 ? "1 needs you" : "\(i.needs.count) need you") }
        if !i.finished.isEmpty { parts.append("\(i.finished.count) finished") }
        if !i.ready.isEmpty { parts.append("\(i.ready.count) ready to continue") }
        if inbox > 0 { parts.append("\(inbox) in your inbox") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

@MainActor @Observable final class RouterAttention {
    /// No input for this long is being away.
    static let awayAfter: TimeInterval = 300
    /// Jev's "soon" (3 of 0…4), his probability-weighted score rounded.
    static let soon = 2.5

    /// Seconds since your last input; none until `start` (tests and the demo are never away unless they say so).
    @ObservationIgnored var idleSeconds: () -> TimeInterval = { 0 }
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// The screen is locked, the Mac or its displays asleep.
    @ObservationIgnored var locked = false
    @ObservationIgnored var asleep = false
    /// Since when you've been away; nil while you're here.
    @ObservationIgnored private(set) var awaySince: Date?
    @ObservationIgnored private(set) var heldCards: [String] = []
    @ObservationIgnored private(set) var heldInbox = 0
    /// The cards a banner was shown for: never a second one.
    @ObservationIgnored private(set) var delivered: Set<String> = []
    /// What the summary when you came back told of each card it said (`reported`): no banner of their own after it for that,
    /// until you're away again. One it told of as finished that needs you now (Jev's triage came after), or that is ready to
    /// continue now, is news and still comes.
    @ObservationIgnored private(set) var summarized: [String: Told] = [:]

    /// What a card was told as in the summary.
    /// A ready card is told as the readiness it had (what came of the wait, and when): a renewed one is news.
    enum Told: Equatable { case needs, ready(RouterTriage.Ready?), finished }
    /// What came while you were last away, on the Router until dismissed.
    var strip: AwayStrip?
    /// You're back and something came meanwhile (the summary banner).
    @ObservationIgnored var onBack: ((AwayStrip) -> Void)?
    /// The Router's cards, as they are now.
    @ObservationIgnored var cards: () -> [RouterCard] = { [] }
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?

    // MARK: The rule

    /// Whether a card is worth a banner now: only what needs you, and away only what can't wait.
    static func bannerNow(_ card: RouterCard, away: Bool) -> Bool {
        guard card.kind.needsYou else { return false }
        if away { return RouterPage.urgency(card) >= soon }
        switch card.kind {
        case .question, .plan, .permission, .approval, .stuck: return true
        case .asks, .finish: return (card.triage?.urgency ?? 4) >= soon
        case .done, .waiting: return false
        }
    }

    /// Of the new cards, those to banner now. While you're away every one is kept for the summary when you're back. A card
    /// may come again (Jev's triage made it more urgent, or answered for one held until he did): it is weighed again, and
    /// bannered once at most.
    func admit(_ new: [RouterCard]) -> [RouterCard] {
        let away = refresh()
        if away { for card in new where card.kind.isTurn || card.kind.needsYou { hold(card.id) } }
        return new.filter { !delivered.contains($0.id) && summarized[$0.id] != .needs && Self.bannerNow($0, away: away) }
    }

    /// A card's banner was shown.
    func posted(_ id: String) { delivered.insert(id) }

    /// A waiting session ready to continue: a banner now, or, away, in the summary (also when it became ready as you came
    /// back, and the summary that coming back makes says so already).
    func admitReady(_ card: RouterCard) -> Bool {
        guard refresh() else { return summarized[card.id] != .ready(card.triage?.ready) }
        hold(card.id)
        return false
    }

    /// An inbox banner: away, only what Jev rates high or urgent comes now; the others are counted for the summary.
    func admitInbox(_ importance: Importance?) -> Bool {
        guard refresh() else { return true }
        if let importance, importance >= .high { return true }
        heldInbox += 1
        return false
    }

    /// Asked in every triage call: is the turn too slight to tell you about when you're back? Sure of it (p ≥ 0.8), its
    /// card isn't in the summary nor the strip (it stays in Needs you's Done as ever).
    static let trivialExtra = TriageExtra(
        questions: ["trivial": .noul(instructions: "Is this turn trivial: a short reply, an acknowledgment or a small step, with nothing in it the user would want to look at?")],
        apply: { answers, triage in triage.trivial = (answers["trivial"]?.yes ?? 0) >= 0.8 })

    private func hold(_ id: String) {
        if !heldCards.contains(id) { heldCards.append(id) }
    }

    // MARK: Away and back

    /// Whether you're away now; coming back makes the summary.
    @discardableResult func refresh() -> Bool {
        let idle = idleSeconds()
        let away = locked || asleep || idle >= Self.awayAfter
        if away {
            if awaySince == nil {
                awaySince = clock().addingTimeInterval(locked || asleep ? 0 : -idle)
                summarized = [:]
            }
        } else if let since = awaySince {
            back(since: since)
        }
        return away
    }

    private func back(since: Date) {
        awaySince = nil
        let came = AwayStrip(since: since, cards: heldCards, inbox: heldInbox)
        heldCards = []
        heldInbox = 0
        guard came.line(cards()) != nil else { return }
        strip = came
        onBack?(came)
    }

    func dismissStrip() { strip = nil }

    /// The summary said these cards, each as what it is now (those it left out, as the Router's while it is off, are not).
    func reported(_ cards: [RouterCard]) {
        for card in cards {
            summarized[card.id] = card.kind.needsYou ? .needs : card.kind == .waiting ? .ready(card.triage?.ready) : .finished
        }
    }

    /// Watches your input, the screen lock and sleep (the app, not tests).
    func start(cards: @escaping () -> [RouterCard]) {
        guard timer == nil else { return }
        self.cards = cards
        idleSeconds = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (RouterAttention) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                    self.refresh()
                }
            }))
        }
        on(distributed, .init("com.apple.screenIsLocked")) { $0.locked = true }
        on(distributed, .init("com.apple.screenIsUnlocked")) { $0.locked = false }
        on(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        on(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { _ = self?.refresh() } }
        // A few seconds either way changes nothing it decides; the system can fold the wake into others.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - The strip

/// At the top of Needs you after you were away: what came meanwhile, most urgent first; a click goes to its card.
struct AwayStripView: View {
    let store: Store
    let model: RouterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let shown = 5

    var body: some View {
        let attention = store.routerAttention
        if let strip = attention.strip, let line = strip.line(store.routerShownCards) {
            let listed = strip.listed(store.routerShownCards)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.muted)
                    Text("While you were away").cdsText((12, 16), .semibold, CDS.Text.secondary)
                    Text(line).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(Motion.fade.resolved(reduce: reduceMotion)) { attention.dismissStrip() }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss what came while you were away")
                }
                ForEach(listed.prefix(Self.shown)) { card in
                    AwayStripRow(card: card) { model.select(card.id, store: store) }
                }
                if listed.count > Self.shown {
                    Text("+\(listed.count - Self.shown) more").cdsText((11, 14), .regular, CDS.Text.muted).padding(.leading, 20)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CDS.Text.muted.opacity(0.07)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("While you were away: \(line)")
        }
    }
}

private struct AwayStripRow: View {
    let card: RouterCard
    let action: () -> Void
    @State private var hovered = false

    private var what: String {
        if card.kind == .waiting { return "ready to continue" }
        if card.triage?.circles == true { return "going in circles" }
        return card.kind.label.lowercased()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: card.kind == .waiting ? "checkmark.circle.fill" : card.kind.symbol)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(card.kind.color).frame(width: 14)
                Text(card.title).cdsText((12, 16), .medium, hovered ? CDS.Text.primary : CDS.Text.secondary).lineLimit(1)
                Text(what).cdsText((11, 14), .regular, CDS.Text.muted).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Go to its card")
    }
}
