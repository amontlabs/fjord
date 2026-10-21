import AppKit
import SwiftUI

// What the Router shows of a Claude session: its icon (or letters) and status dot, its project, what it left running, and
// the menu on its rows.

extension ClaudeDot.Kind {
    /// A session's dot, as Claude's list draws it: needs you, done and unread, working (or left something running), else
    /// the quiet hollow ring.
    init(_ row: AgentRow) {
        switch row.group {
        case .needsYou: self = .needsYou
        case .done: self = .done
        case .working: self = .working
        case .idle: self = .quiet
        }
    }
}

/// Claude's session status dot (§1.7), 6pt in a 14pt box: awaiting #fab219 (a question or a plan), ready #2a78d6 (a
/// finished turn), running #898781 blinking (a working session), idle a 1pt hollow ring at 50% (addressed). Claude has
/// no "stuck" state; Fjord's stuck card keeps a red 6pt dot (`CDS.Text.danger`).
struct ClaudeDot: View {
    enum Kind {
        case needsYou, done, stuck, working, waiting, quiet

        init(_ card: RouterCard) {
            guard card.isOpen else { self = .quiet; return }
            switch card.kind {
            case .question, .plan, .asks, .approval, .permission, .finish: self = .needsYou
            case .stuck: self = .stuck
            case .done: self = .done
            case .waiting: self = .waiting
            }
        }
    }

    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .needsYou: Circle().fill(CDS.Fill.warning).frame(width: 6, height: 6)
            case .done: Circle().fill(CDS.Fill.accent).frame(width: 6, height: 6)
            case .stuck: Circle().fill(CDS.Text.danger).frame(width: 6, height: 6)
            case .waiting: Circle().fill(RouterTriage.waitingTint).frame(width: 6, height: 6)
            case .quiet: Circle().strokeBorder(CDS.Text.muted, lineWidth: 1).frame(width: 6, height: 6).opacity(0.5)
            case .working: BlinkingDot()
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// `dframe-dot-blink`: 1.2s ease-in-out, opacity .3 → 1 → .3, forever; lit and still with Reduce Motion. Core Animation
/// blinks it, so SwiftUI draws nothing while it runs (see `SheenNSView`).
private struct BlinkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BlinkingDotRepresentable(color: NSColor(CDS.Text.muted), still: reduceMotion).frame(width: 6, height: 6)
    }
}

private struct BlinkingDotRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool

    func makeNSView(context: Context) -> BlinkingDotView { BlinkingDotView() }
    func updateNSView(_ view: BlinkingDotView, context: Context) {
        view.color = color
        view.still = still
    }
}

/// The working dot: a circle filling the view, its opacity going .3 → 1 → .3 every 1.2 s on the wall clock's phase, so
/// every dot on screen blinks together. It stops when out of a window or hidden; still (lit) is opacity 1.
final class BlinkingDotView: NSView {
    /// Half of the blink: .3 up to 1 (ease-in-out), then back the same way.
    static let half: CFTimeInterval = 0.6
    static let dim: Float = 0.3

    var color: NSColor = .secondaryLabelColor { didSet { if color != oldValue { paint() } } }
    var still = false { didSet { if still != oldValue { animate() } } }
    private let dot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(),
                       "backgroundColor": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(dot)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // (The dot's actions are off: it moves and resizes with no implicit animation.)
        let side = min(bounds.width, bounds.height)
        dot.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        dot.cornerRadius = side / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    override func viewDidHide() { super.viewDidHide(); animate() }
    override func viewDidUnhide() { super.viewDidUnhide(); animate() }

    /// The colour as it reads in this view's look (a dynamic colour resolved again when the look changes).
    private func paint() {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        dot.backgroundColor = cg
    }

    /// The blink, on the wall clock's phase; none when it can't be seen, and lit when still.
    private func animate() {
        dot.removeAllAnimations()
        dot.opacity = 1
        guard !still, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = Self.dim
        blink.toValue = Float(1)
        // SwiftUI's `easeInOut` is this same curve (0.42, 0, 0.58, 1).
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blink.duration = Self.half
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2 * Self.half)
        blink.isRemovedOnCompletion = false
        dot.add(blink, forKey: "blink")
    }
}

/// A session's face in the Router's lists: the icon Jev picked (else its letters, or an emoji) on a neutral square, in the
/// project's colour, with Claude's status dot on its corner when `dot` is on. Without a session behind it, nothing.
struct SessionGlyph: View {
    let row: AgentRow
    var size: CGFloat = 18
    var dot = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Tile.radius * size / CDS.Tile.size + 1, style: .continuous)
        let kind = ClaudeDot.Kind(row)
        let emoji = row.label.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0xFF } ?? false
        Group {
            if let icon = row.icon {
                Image(systemName: icon).font(.system(size: size * 0.6, weight: .medium)).symbolRenderingMode(.monochrome)
            } else {
                Text(row.label)
                    .font(emoji ? .system(size: size * 0.55) : CDS.sans(size * 0.45, .medium))
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
        }
        .foregroundStyle(row.color ?? CDS.Text.secondary)
        .frame(width: size, height: size)
        .background(shape.fill(CDS.Tile.fill))
        .overlay(alignment: .topTrailing) {
            if dot, kind != .quiet {
                ClaudeDot(kind: kind)
                    .scaleEffect(0.8)
                    .background(Circle().fill(Theme.bg).frame(width: 9, height: 9))
                    .offset(x: 5, y: -5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A project's colour dot and name.
struct ProjectLabel: View {
    let name: String
    let color: Color?
    /// The widest it draws; a longer label is cut in its middle.
    var maxWidth: CGFloat = .infinity

    var body: some View {
        HStack(spacing: 4) {
            if let color {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                Image(systemName: "text.bubble").font(.system(size: 9, weight: .medium))
            }
            // A long label (a guest project's "name · SSH host · silo", a path) gives way in its middle. Callers must not
            // `fixedSize` it: that gives it its full ideal width and it overflows the card.
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// A session's context menu in the Router: open it, fork it, pick it another icon, give its project a colour, mute the project.
struct SessionMenu: View {
    let row: AgentRow
    let store: Store

    var body: some View {
        Button("Open in Claude") { store.openAgent(row.id) }
        // A new session that continues from this one's conversation (files aren't forked).
        if store.routerOn, row.session.cliID != nil {
            Button("Fork") { store.forkSession(row.id) }
            Button("Fork from before your last message") { store.forkSession(row.id, point: .beforeLast) }
        }
        if store.canPickIcons && row.entry.label == nil {
            Button(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") { store.repickIcon(row.id) }
        }
        if !row.session.folderKey.isEmpty {
            Menu("Colour for \(row.projectName)") {
                ForEach(Theme.projectColorNames.indices, id: \.self) { i in
                    Button(Theme.projectColorNames[i]) { store.setProjectColor(row.session.folderKey, i) }
                }
            }
        }
        // A session found through search can be of a project muted already: muting it again would do nothing.
        let project = store.routerProjectGroupKey(sessionID: row.session.id, folder: row.session.folderKey)
        if store.isFolderMuted(project) {
            Button("Unmute \(row.projectName)") { store.act(.mute(project: project, name: row.projectName, muted: false)) }
        } else {
            Button("Mute \(row.projectName)") { store.act(.mute(project: project, name: row.projectName, muted: true)) }
        }
    }
}

extension Store {
    /// The row of a session, listed or not (a card's, say). Each session's row is kept in a box of its own, made again
    /// only when what it shows changed (`refreshSessionRows`): a view that draws one session's glyph redraws for that
    /// session alone, not for every change to every session's activity.
    func sessionRow(_ id: String) -> AgentRow? {
        if let box = sessionRowBoxes[id] {
            // Changed in a read still being taken in: made now, for whoever asks meanwhile.
            if sessionRowsPending?.remove(id) != nil, case let row = makeSessionRow(id), row != box.row { box.row = row }
            return box.row
        }
        let box = SessionRowBox(makeSessionRow(id))
        sessionRowBoxes[id] = box
        return box.row
    }
}

/// The Claude link's state as a dot and a line ("Synced with Claude", "Claude's sessions not found"…).
struct ClaudeLinkStatus: View {
    let store: Store

    var body: some View {
        let (color, text, detail): (Color, String, String) = switch store.claudeLink {
        case .ok where Claude.isRunning: (Theme.green, "Synced with Claude", "Updates as the Claude app writes its session files")
        case .ok, .off: (Theme.tertiary, "Claude isn't running", "Sessions update again when the app is open")
        case .missing: (Theme.red, "Claude's sessions not found", "Open the Claude desktop app once")
        case .unreadable: (Theme.red, "Can't read Claude's sessions", "The app's session format changed")
        }
        Circle().fill(color).frame(width: 6, height: 6)
        Text(text).tip(text, detail)
    }
}

/// "N API calls left this hour", only when the shared GitHub rate limit is running low.
struct RateLimitWarning: View {
    let store: Store

    var body: some View {
        if let rate = store.rateRemaining, rate < 500 {
            Label("\(rate.formatted()) API calls left this hour", systemImage: "exclamationmark.triangle.fill")
                .monospacedDigit()
                .foregroundStyle(Theme.amber)
                .tip("GitHub rate limit low",
                     "Shared with gh and other tools. Syncing pauses at 0.")
        }
    }
}

extension EnvironmentValues {
    /// Playground only: force a tooltip to show.
    @Entry var previewTip: String? = nil
}

extension View {
    /// What a session left running, by name, in a tooltip (nothing when it left nothing).
    @ViewBuilder func runningTip(_ tasks: [ClaudeTask]) -> some View {
        if tasks.isEmpty { self } else { tip("Running", tasks.map(\.title).joined(separator: "\n")) }
    }
}

/// One session's row, observed on its own (`Store.sessionRow`).
@Observable @MainActor
final class SessionRowBox {
    var row: AgentRow?
    init(_ row: AgentRow?) { self.row = row }
}
