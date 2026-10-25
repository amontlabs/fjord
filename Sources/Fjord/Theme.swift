import AppKit
import SwiftUI

enum Theme {
    // Claude's own palette (CDS, dark mode), read from the Claude app: Fjord is part of it.
    /// The bar and its panels: black.
    static let bg = Brand.map(Color.black)
    static let raised = CDS.alpha(0.05)
    static let hover = CDS.alpha(0.075)
    static let stroke = CDS.alpha(0.10)
    /// CDS gray-50.
    static let text = Brand.map(Color(red: 0xF0 / 255, green: 0xEF / 255, blue: 0xEC / 255))
    /// CDS gray-200.
    static let secondary = Brand.map(Color(red: 0xC3 / 255, green: 0xC2 / 255, blue: 0xB7 / 255))
    /// CDS gray-400.
    static let tertiary = Brand.map(Color(red: 0x89 / 255, green: 0x87 / 255, blue: 0x81 / 255))
    /// Claude's sidebar dot for done and unread (blue-400).
    static let accent = Brand.map(Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255))
    /// Needs you: Claude's warning (yellow-200).
    static let amber = Brand.map(Color(red: 0xFA / 255, green: 0xB2 / 255, blue: 0x19 / 255))
    static let green = Brand.map(Color(red: 0x55 / 255, green: 0xBF / 255, blue: 0x50 / 255))
    static let red = Brand.map(Color(red: 0xEC / 255, green: 0x7E / 255, blue: 0x7E / 255))
    static let purple = Brand.map(Color(red: 0xA0 / 255, green: 0x96 / 255, blue: 0xEB / 255))
    /// Claude's clay, for anything about Claude sessions.
    static let claude = Brand.map(Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
    /// Project colours for Claude sessions: as far apart as possible, and nowhere near the status colours (amber
    /// needs you, blue unread, clay working) or CI's red. In assignment order, so the first projects differ most.
    static let projectColors: [Color] = [
        Color(red: 0.30, green: 0.82, blue: 0.47),  // green
        Color(red: 0.67, green: 0.52, blue: 1.00),  // violet
        Color(red: 0.96, green: 0.42, blue: 0.75),  // pink
        Color(red: 0.24, green: 0.82, blue: 0.93),  // cyan
        Color(red: 0.78, green: 0.90, blue: 0.24),  // lime
        Color(red: 0.86, green: 0.86, blue: 0.90),  // silver
    ]
    static let projectColorNames = ["Green", "Violet", "Pink", "Cyan", "Lime", "Silver"]
}

func shortAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    if s < 7 * 86400 { return "\(s / 86400)d" }
    return TimeTexts.cached(date, .day) { $0.formatted(.dateTime.month(.abbreviated).day()) }
}

/// The time an age stands for, shown on hovering it: the clock time today, with the date before.
func exactTime(_ date: Date) -> String {
    TimeTexts.cached(date, .exact) {
        $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened)
    }
}

/// The dates the lists write out (a line's time on hover and in what VoiceOver says, an old age's day), each formatted once:
/// a history line asks for its time twice each time it is drawn, and every line is drawn again on the minute. Kept until the
/// day ends (what "today" leaves out changes then), or the time zone, the locale, the clock, the day or the 12/24-hour
/// preference changes; at most a few thousand; the main thread's alone (elsewhere, formatted).
enum TimeTexts {
    enum Kind { case exact, day }
    nonisolated(unsafe) private static var exact: [Date: String] = [:]
    nonisolated(unsafe) private static var days: [Date: String] = [:]
    nonisolated(unsafe) private static var until = Date.distantPast
    nonisolated(unsafe) private static var watching = false

    static func cached(_ date: Date, _ kind: Kind, _ make: (Date) -> String) -> String {
        guard Thread.isMainThread else { return make(date) }
        if !watching { watch() }
        let now = Date()
        if now >= until {
            exact = [:]
            days = [:]
            until = dayEnd(after: now, calendar: .current)
        }
        if let hit = kind == .exact ? exact[date] : days[date] { return hit }
        let text = make(date)
        switch kind {
        case .exact:
            if exact.count > 4000 { exact = [:] }
            exact[date] = text
        case .day:
            if days.count > 4000 { days = [:] }
            days[date] = text
        }
        return text
    }

    /// The next midnight after `now` in `calendar`: a day isn't always 24 hours (daylight saving time).
    static func dayEnd(after now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    }

    /// Everything formatted is formatted again on its next ask.
    static func invalidate() {
        guard Thread.isMainThread else { return DispatchQueue.main.async { invalidate() } }
        until = .distantPast
    }

    private static func watch() {
        watching = true
        let center = NotificationCenter.default
        for name: Notification.Name in [.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification,
                                        .NSSystemClockDidChange, .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in invalidate() }
        }
        // The 12/24-hour and date formats chosen in System Settings.
        for name in ["AppleTimePreferencesChangedNotification", "AppleDatePreferencesChangedNotification"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                invalidate()
            }
        }
    }
}

/// `shortAgo` for a sentence: "just now", "3m ago", "on Sep 28" (never "now ago" or "Sep 28 ago").
func agoPhrase(_ date: Date, now: Date = Date()) -> String {
    let short = shortAgo(date, now: now)
    if short == "now" { return "just now" }
    return now.timeIntervalSince(date) < 7 * 86400 ? "\(short) ago" : "on \(short)"
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    /// What VoiceOver says; defaults to `help`. Give one when `help` is empty: icon-only buttons need a label.
    var label: String? = nil
    var detail: String? = nil
    var size: CGFloat = 26
    var tint: Color = Theme.secondary
    var active = false
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let button = Button(action: action) { IconButtonLabel(symbol: symbol, size: size, tint: tint, active: active) }
            // Claude's ghost icon button: a square at the control's size, radius 6, white 7.5% on hover, 15% when on.
            .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.GhostIcon.radius(size), style: .continuous),
                                              hover: Theme.Fill.hover, isActive: active))
            .focused($focused)
            .accessibilityLabel(label ?? help)
            .accessibilityHint(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "")

        // The pill's window is too small to host our tooltip bubble: `.tip` falls back to the system one there.
        if help.isEmpty {
            button
        } else {
            button.tip(help, detail, focused: focused)
        }
    }
}

private struct IconButtonLabel: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let active: Bool
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        // Claude's 16pt glyph (wght 533) as an SF Symbol; secondary ink, white on hover (`.df-chrome-btn`). The GitHub mark
        // isn't one: drawn from its path, a point over, optically the weight of the symbols beside it.
        let ink = active || hover ? (tint == Theme.secondary ? Brand.ink : tint) : tint
        Group {
            if symbol == CategorySection.githubMark {
                GitHubMark().fill(ink).frame(width: CDS.GhostIcon.glyph(size) + 1, height: CDS.GhostIcon.glyph(size) + 1)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: CDS.GhostIcon.glyph(size), weight: .medium))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: size, height: size)
    }
}

extension IconButton {
    /// The button sizes: one per kind of place, so the same action looks the same everywhere.
    enum Size {
        /// A section header's actions (mark all read): CDS compact control, 24.
        static let header: CGFloat = 24
        /// A row's hover actions: Claude's row controls, 24 (sidebar §2.7).
        static let row: CGFloat = 24
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 26
    /// Shown as initials until (or unless) the picture is there.
    var name: String?

    @State private var loaded: (url: URL, image: NSImage)?
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let sized = Self.sizedURL(url, size: size)
        // A cached image is there on the first frame; otherwise a placeholder, then a quick fade-in.
        let image = loaded.flatMap { $0.url == sized ? $0.image : nil } ?? ImageCache.shared.cached(sized)
        // Claude's Avatar: a circle, no ring; white 10% (`fill-control`) under initials or the picture.
        ZStack {
            Circle().fill(Theme.Fill.tile)
            if image == nil { placeholder }
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: sized) {
            guard let sized, ImageCache.shared.cached(sized) == nil else { loaded = nil; return }
            loaded = nil
            let img = await ImageCache.shared.load(sized)
            guard !Task.isCancelled, let img else { return }
            withAnimation(Motion.fade.resolved(reduce: reduce)) { loaded = (sized, img) }
        }
    }

    /// Initials of the name (one at xs, two above, as Claude's), at 460 in primary; a person glyph without a name.
    @ViewBuilder private var placeholder: some View {
        let initials = name.map { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(CDS.Avatar.initialsCount(size)).compactMap(\.first).map(String.init).joined().uppercased() } ?? ""
        if initials.isEmpty {
            Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(Theme.tertiary)
        } else {
            Text(initials).font(CDS.sans(CDS.Avatar.initialsSize(size), .medium)).foregroundStyle(CDS.Text.primary)
        }
    }

    private static let sizedURLs = RenderCache<URL?>(countLimit: 1000)

    /// The avatar URL asking GitHub for twice the point size, in pixels; made once per URL and size (rows ask on every redraw).
    static func sizedURL(_ url: URL?, size: CGFloat) -> URL? {
        guard let url else { return nil }
        return sizedURLs.value("\(Int(size * 2)) \(url.absoluteString)") { resized(url, pixels: Int(size * 2)) }
    }

    private static func resized(_ url: URL, pixels: Int) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(pixels)")]
        return comps.url
    }
}

/// A tab, as Claude's Tabs draw one (search-tabs-avatars.md §2, compact base): 24 tall, 8 padding, 13pt at 460; muted,
/// secondary on hover, primary when picked; hovered or picked, a white 7.5% pill (radius 6, inset 1 at each side). A count
/// follows as a Badge, 6 after the label: neutral, or `countTint`'s variant (amber: warning).
struct Chip: View {
    let label: String
    var count: Int? = nil
    var selected = false
    var countTint: Color? = nil
    let action: () -> Void

    init(label: String, count: Int? = nil, selected: Bool = false, countTint: Color? = nil, action: @escaping () -> Void) {
        self.label = label
        self.count = count
        self.selected = selected
        self.countTint = countTint
        self.action = action
    }

    var body: some View {
        Button(action: action) { ChipLabel(label: label, count: count, selected: selected, countTint: countTint) }
            .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Tabs.radius, style: .continuous),
                                              hover: CDS.Fill.ghostHover, active: CDS.Fill.ghostHover,
                                              pressed: CDS.Fill.ghostHover, isActive: selected))
            .padding(.horizontal, CDS.Tabs.pillInset)
    }
}

private struct ChipLabel: View {
    let label: String
    let count: Int?
    let selected: Bool
    let countTint: Color?
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        HStack(spacing: CDS.Tabs.badgeGap) {
            Text(label)
            if let count, count > 0 { CountBadge(count, tint: countTint) }
        }
        .font(CDS.sans(13, .medium))
        .foregroundStyle(selected ? CDS.Text.primary : hover ? CDS.Text.secondary : CDS.Text.muted)
        .padding(.horizontal, CDS.Tabs.pad - CDS.Tabs.pillInset)
        .frame(height: CDS.Tabs.height)
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(CDS.sans(13))
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.field)
            // Claude's field: white 5%, a 1pt white-10% inset ring.
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(CDS.Fill.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(CDS.border))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }

    func card() -> some View {
        self
            .padding(12)
            // `rounded-card` (10) with Claude's card ring: white 5% under a 1pt white-10% line.
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = measure(subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    /// An item's size, never wider than the row: one that can give (a line limit, a truncating text) does, instead of
    /// running past the edge.
    private func measure(_ sub: LayoutSubview, within width: CGFloat) -> CGSize {
        var size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
        size.width = min(size.width, width)
        return size
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = measure(sub, within: width)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let prev = rows[rows.count - 1]
                rows.append(Row(y: prev.y + prev.height + spacing))
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Tooltip

/// A quick, styled tooltip (the system one waits ~1s and looks out of place on the dark panel).
/// Badges only *request* a tooltip; the nearest `.tipSpace()` draws it in one top layer, so nothing
/// (headers, neighbouring rows, scroll views) can cover or clip it.
@Observable
final class TipCenter {
    struct Request: Equatable {
        let id: UUID
        let title: String
        let detail: String?
        var anchor: CGRect
    }

    private(set) var current: Request?

    /// The centre showing a tooltip right now, so the hub's Esc handling can dismiss it before anything else.
    private(set) static weak var visible: TipCenter?

    /// Key monitors that exist only while a tooltip is up: nothing listens (or wakes the app) otherwise.
    @ObservationIgnored private var monitors: [Any] = []

    func show(_ request: Request) {
        current = request
        Self.visible = self
        watchEscape()
    }

    func move(_ id: UUID, to anchor: CGRect) {
        if current?.id == id { current?.anchor = anchor }
    }

    func dismiss() {
        current = nil
        if Self.visible === self { Self.visible = nil }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func dismiss(ifShowing id: UUID) {
        if current?.id == id { dismiss() }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    /// Esc dismisses the tooltip and is consumed only then, ahead of the hub's own Esc (back, close).
    @discardableResult static func dismissVisible(for event: NSEvent) -> Bool {
        guard let center = visible, isEscape(event) else { return false }
        center.dismiss()
        return true
    }

    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    private func watchEscape() {
        guard monitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            Self.dismissVisible(for: event) ? nil : event
        }) { monitors.append(local) }
        // While another app has the keys: it still gets the Esc (a global monitor can't take it), and only
        // delivers with Accessibility access, which is checked without asking.
        guard AXIsProcessTrusted() else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if Self.isEscape(event) { self?.dismiss() }
        }) { monitors.append(global) }
    }
}

private struct Tip: ViewModifier {
    let title: String
    let detail: String?
    /// The control's own keyboard focus: its tip shows after a second, and goes when the focus does.
    let focused: Bool
    @State private var id = UUID()
    /// Where the control is, as last laid out: written on every layout and scroll frame, read only when the tip shows, so
    /// kept out of view state (writing it redraws nothing).
    @State private var anchor = Anchor()
    @State private var pending: Task<Void, Never>?

    private final class Anchor { var frame = CGRect.zero }
    /// Measured only while the pointer is on it, it has the keyboard, or it is the tip asked for: not on every layout and
    /// scroll frame of every control carrying a tip.
    @State private var measuring = false
    @State private var hovering = false
    @Environment(\.tipCenter) private var center
    @Environment(\.previewTip) private var previewTip
    @Environment(\.systemHelp) private var systemHelp
    @Environment(\.tipFocusDelay) private var focusDelay

    @ViewBuilder func body(content: Content) -> some View {
        // No tooltip layer above (or one too small to host the bubble): the system tooltip says the same.
        if center == nil || systemHelp {
            content.help(detail.map { $0.isEmpty ? title : "\(title)\n\($0)" } ?? title)
        } else {
            styled(content)
        }
    }

    private func styled(_ content: Content) -> some View {
        content
            .background {
                if measuring {
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TipSpace.name)) } action: { frame in
                        anchor.frame = frame
                        center?.move(id, to: frame)
                    }
                }
            }
            .onAppear {
                if let previewTip, title.hasPrefix(previewTip) {
                    measuring = true
                    DispatchQueue.main.async { show() }
                }
            }
            .onHover { inside in
                hovering = inside
                let measure = inside || focused
                if measuring != measure { measuring = measure }
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        show()
                    }
                } else {
                    center?.dismiss(ifShowing: id)
                }
            }
            .onChange(of: focused) { _, focused in
                let measure = hovering || focused
                if measuring != measure { measuring = measure }
                pending?.cancel()
                if focused {
                    let delay = focusDelay
                    pending = Task {
                        await delay()
                        guard !Task.isCancelled else { return }
                        show()
                    }
                } else {
                    center?.dismiss(ifShowing: id)
                }
            }
            .onDisappear { center?.dismiss(ifShowing: id) }
    }

    private func show() {
        center?.show(TipCenter.Request(id: id, title: title, detail: detail, anchor: anchor.frame))
    }
}

/// Claude's Tooltip (composer-overlays.md §9): surface-3, radius 6, 13/18 primary at 360, 8 × 3 padding (8 × 6 with a
/// detail, its lines muted, 2 under the title), at least 24 tall, at most 240 wide; 4 above its control (below without room).
private struct TipBubble: View {
    let request: TipCenter.Request
    let bounds: CGSize
    @State private var size = CGSize.zero

    var body: some View {
        let detail = request.detail.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 2) {
            Text(request.title)
                .font(CDS.sans(CDS.Tooltip.text.0))
                .foregroundStyle(CDS.Text.primary)
                .frame(width: Self.width(of: request.title), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(CDS.sans(CDS.Tooltip.text.0))
                    .foregroundStyle(CDS.Text.muted)
                    .frame(width: Self.width(of: detail), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lineSpacing(Self.spacing)
        .padding(.horizontal, CDS.Tooltip.padX)
        .padding(.vertical, detail == nil ? CDS.Tooltip.padY : CDS.Tooltip.padYMulti)
        .frame(minHeight: CDS.Tooltip.minHeight)
        .background(Theme.Radius.shape(CDS.Tooltip.radius).fill(CDS.Surface.s3))
        .overlay(Theme.Radius.shape(CDS.Tooltip.radius).strokeBorder(CDS.Tooltip.ring, lineWidth: 1))
        .shadow(color: CDS.Tooltip.shadowNear, radius: 1, y: 1)
        .shadow(color: CDS.Tooltip.shadowFar, radius: 4, y: 2)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .offset(placement)
        .opacity(size == .zero ? 0 : 1)
        .allowsHitTesting(false)
    }

    /// 13/18: the line height less the font's own.
    private static let spacing: CGFloat = {
        let font = CDS.nsSans(CDS.Tooltip.text.0)
        return max(0, CDS.Tooltip.text.1 - (font.ascender - font.descender + font.leading))
    }()

    /// The widest a line may be inside the 240 box.
    private static let inner = CDS.Tooltip.maxWidth - 2 * CDS.Tooltip.padX

    /// Centered over the anchor, clamped inside the panel; flips below when there's no room above.
    private var placement: CGSize {
        let a = request.anchor
        let margin: CGFloat = 8
        let gap = CDS.Tooltip.offset
        let x = min(max(a.midX - size.width / 2, margin), max(margin, bounds.width - margin - size.width))
        let y = a.minY - size.height - gap >= margin ? a.minY - size.height - gap : a.maxY + gap
        return CGSize(width: x, height: y)
    }

    /// Natural width of the widest line, capped so long details wrap instead of stretching the bubble past 240.
    private static func width(of text: String) -> CGFloat {
        let font = CDS.nsSans(CDS.Tooltip.text.0)
        let widest = text.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 2, inner)
    }
}

enum TipSpace {
    static let name = "tips"
}

extension EnvironmentValues {
    @Entry var systemHelp = false
    /// How long a control has to keep the keyboard focus before its tip shows (a second); a test holds it open instead.
    @Entry var tipFocusDelay: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    @Entry var tipCenter: TipCenter? = nil
}

private struct TipSpaceModifier: ViewModifier {
    @State private var center = TipCenter()
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TipSpace.name))
            .environment(\.tipCenter, center)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Its key monitors go with it.
            .onDisappear { center.dismiss() }
            .overlay(alignment: .topLeading) {
                if let request = center.current {
                    TipBubble(request: request, bounds: size)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
    }
}

extension View {
    /// Hosts tooltips for everything inside (use once, at the root of the panel).
    func tipSpace() -> some View { modifier(TipSpaceModifier()) }
    /// A tip space only where `on`: inside a view that has one already, that one draws the tips.
    @ViewBuilder func tipSpace(_ on: Bool) -> some View {
        if on { tipSpace() } else { self }
    }

    /// A tooltip for a control: on hover, and after a second on keyboard focus when it hands over its own `focused`.
    func tip(_ title: String, _ detail: String? = nil, focused: Bool = false) -> some View {
        modifier(Tip(title: title, detail: detail, focused: focused))
    }
}
