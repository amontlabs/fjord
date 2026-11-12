import AppKit
import SwiftUI

// Router v2: what a new thread starts with (docs/design/router-v2/DESIGN.md 1.9.1). When the draft goes to a new thread,
// the destination row previews its settings as chips: the model, the reasoning effort, the access (T3's runtime mode)
// and the mode (build or plan). They start at T3's defaults. Three ways to change them, all live: Tab into the row and
// the arrows (which open the chip's menu and move through it), a click for the same menu, or an @ in the composer, whose
// list also offers the settings: picking one puts a pill in the draft and sets the chip. The pill is not sent; taking
// it out puts the setting back. Free text never sets anything: "use opus for subagents" is for the agent. T3's
// `orchestration.launchThread` takes them as `modelSelection`, `runtimeMode` and `interactionMode`.

// MARK: - The settings

/// A setting of a thread that isn't started yet, in the row's order.
enum RouterV2LaunchField: Int, CaseIterable, Hashable {
    case model, effort, access, mode

    var title: String {
        switch self {
        case .model: "Model"
        case .effort: "Reasoning effort"
        case .access: "Access"
        case .mode: "Mode"
        }
    }
}

/// One of T3's models, as its picker names it (`server.getConfig`), with what it can be started with.
struct RouterV2LaunchModel: Equatable, Identifiable {
    /// T3's slug.
    let id: String
    var name: String
    var provider: String
    /// T3's provider instance it runs on (`modelSelection.instanceId`).
    var instance: String
    /// The reasoning efforts it takes, in T3's order (empty: none).
    var efforts: [RouterV2Launch.Effort]
    var defaultEffort: RouterV2Launch.Effort?
    /// The runtime modes its provider supports, from the most supervised to the least.
    var access: [RouterV2Launch.Access]
    /// T3's other names for it ("opus"): what the @ list finds it by.
    var aliases: [String] = []
}

/// What a new thread starts with.
struct RouterV2Launch: Equatable {
    /// A reasoning effort, as T3 names it: T3's lists are the lists, the names below only the ones known by sight.
    struct Effort: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        static let low = Effort(rawValue: "low"), medium = Effort(rawValue: "medium"), high = Effort(rawValue: "high")
        static let xhigh = Effort(rawValue: "xhigh"), max = Effort(rawValue: "max")
        /// Claude's, in order: the demo's lists.
        static let claude: [Effort] = [.low, .medium, .high, .xhigh, .max]

        var label: String {
            switch rawValue {
            case "low": "Low"
            case "medium": "Medium"
            case "high": "High"
            case "xhigh": "Extra high"
            case "max": "Max"
            default: RouterV2Launch.label(rawValue)
            }
        }
    }

    /// A runtime mode, as T3 names it, under the name T3's composer gives it.
    struct Access: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        static let supervised = Access(rawValue: "approval-required"), autoEdits = Access(rawValue: "auto-accept-edits")
        static let auto = Access(rawValue: "auto"), full = Access(rawValue: "full-access")
        /// From the most supervised to the least: the demo's list.
        static let all: [Access] = [.supervised, .autoEdits, .auto, .full]

        var label: String {
            switch rawValue {
            case "approval-required": "Supervised"
            case "auto-accept-edits": "Auto-accept edits"
            case "auto": "Auto"
            case "full-access": "Full access"
            default: RouterV2Launch.label(rawValue)
            }
        }
    }

    /// A name T3 gave that has no label here: its words, the first one capitalised ("on-request" → "On request").
    static func label(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var model: String
    var effort: Effort
    var access: Access
    /// T3's interaction mode: plan (it writes a plan and waits for your go) or build.
    var plan = false

    /// T3's defaults as this install's `server.getConfig` gives them (FEASIBILITY.md): Opus 5.5, its default effort,
    /// runtime `auto`, interaction mode `default`. What the demo starts from; the real page reads them from T3.
    static let t3Default = RouterV2Launch(model: "claude-opus-5-5", effort: .high, access: .auto)

    /// The demo's models: this install's.
    static let demoModels: [RouterV2LaunchModel] = [
        ("claude-fable-5-2", "Fable 5.2"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
    ].map {
        RouterV2LaunchModel(id: $0.0, name: $0.1, provider: "Claude", instance: "claudeAgent", efforts: Effort.claude,
                            defaultEffort: .high, access: Access.all)
    }
}

/// The settings someone named, and only those: the draft's words as the Router's model read them, or what you set by
/// hand in the row.
struct RouterV2LaunchAsk: Equatable {
    var model: String?
    var effort: RouterV2Launch.Effort?
    var access: RouterV2Launch.Access?
    var plan: Bool?

    func names(_ field: RouterV2LaunchField) -> Bool {
        switch field {
        case .model: model != nil
        case .effort: effort != nil
        case .access: access != nil
        case .mode: plan != nil
        }
    }

    mutating func clear(_ field: RouterV2LaunchField) {
        switch field {
        case .model: model = nil
        case .effort: effort = nil
        case .access: access = nil
        case .mode: plan = nil
        }
    }
}

/// A setting's last change, for its chip: the value it had, which way the new one comes in, and a count that moves with
/// each change (the roll runs from one count to the next).
struct RouterV2Roll: Equatable {
    var from: String
    var down: Bool
    var tick: Int
}

/// A value a setting can take, as a chip and a menu row show it.
struct RouterV2LaunchChoice: Equatable {
    var label: String
    /// After the label in the menu: a model's provider.
    var detail = ""
}

// MARK: - The model's side

extension RouterV2Model {
    /// What the draft's settings pills name: only the models T3 has count.
    private var said: RouterV2LaunchAsk {
        var ask = launchPills
        if let slug = ask.model, !launchModels.contains(where: { $0.id == slug }) { ask.model = nil }
        return ask
    }

    /// What the new thread would start with: what you set by hand, else what the draft says, else T3's default (for
    /// another model than the default one, that model's default effort). An effort or an access the model doesn't
    /// take falls back to its default.
    var launch: RouterV2Launch {
        let said = said
        let model = launchMine.model ?? said.model ?? launchDefault.model
        let info = launchModel(model)
        let fallback = model == launchDefault.model ? launchDefault.effort : info?.defaultEffort ?? launchDefault.effort
        var effort = launchMine.effort ?? said.effort ?? fallback
        if let info, !info.efforts.isEmpty, !info.efforts.contains(effort) {
            effort = info.efforts.contains(fallback) ? fallback : info.defaultEffort ?? info.efforts[0]
        }
        var access = launchMine.access ?? said.access ?? launchDefault.access
        if let info, !info.access.isEmpty, !info.access.contains(access) {
            access = info.access.contains(launchDefault.access) ? launchDefault.access : info.access[0]
        }
        return RouterV2Launch(model: model, effort: effort, access: access, plan: launchMine.plan ?? said.plan ?? launchDefault.plan)
    }

    func launchModel(_ slug: String) -> RouterV2LaunchModel? { launchModels.first { $0.id == slug } }

    /// The efforts and the access the row's model offers (T3's lists for it).
    private var launchEfforts: [RouterV2Launch.Effort] { launchModel(launch.model)?.efforts ?? [] }
    private var launchAccess: [RouterV2Launch.Access] { launchModel(launch.model)?.access ?? [] }

    /// The row shows a new thread: its settings are there to see and to change.
    var launchShown: Bool {
        switch destination {
        case .place(.newThread, _): return true
        case .unsure(let places, let lit, let mine, _):
            if mine, case .newThread = places[lit] { return true }
            return false
        default: return false
        }
    }

    /// The chips: all four, always, so the row keeps its width as the keyboard comes and goes.
    var launchFields: [RouterV2LaunchField] { RouterV2LaunchField.allCases }

    /// Changes that may move a setting: each one that did is told which value it had and which way the new one rolls
    /// in, in the same mutation as the value, so its chip rolls once and from the right face.
    func rolling(_ body: () -> Void) {
        let fields = RouterV2LaunchField.allCases
        let before = fields.map { (index: launchIndex($0), label: launchLabel($0)) }
        body()
        for (i, field) in fields.enumerated() {
            let now = launchIndex(field)
            guard now != before[i].index else { continue }
            launchRolls[field] = RouterV2Roll(from: before[i].label, down: now > before[i].index,
                                              tick: (launchRolls[field]?.tick ?? 0) + 1)
        }
    }

    func launchChoices(_ field: RouterV2LaunchField) -> [RouterV2LaunchChoice] {
        switch field {
        case .model: launchModels.map { RouterV2LaunchChoice(label: $0.name, detail: $0.provider) }
        case .effort: launchEfforts.map { RouterV2LaunchChoice(label: $0.label) }
        case .access: launchAccess.map { RouterV2LaunchChoice(label: $0.label) }
        case .mode: [RouterV2LaunchChoice(label: "Build"), RouterV2LaunchChoice(label: "Plan")]
        }
    }

    private func index(_ field: RouterV2LaunchField, of launch: RouterV2Launch) -> Int {
        switch field {
        case .model: launchModels.firstIndex { $0.id == launch.model } ?? 0
        case .effort: launchEfforts.firstIndex(of: launch.effort) ?? 0
        case .access: launchAccess.firstIndex(of: launch.access) ?? 0
        case .mode: launch.plan ? 1 : 0
        }
    }

    /// The setting's value, as its place among its choices.
    func launchIndex(_ field: RouterV2LaunchField) -> Int { index(field, of: launch) }

    func launchLabel(_ field: RouterV2LaunchField) -> String {
        let choices = launchChoices(field)
        return choices.isEmpty ? "" : choices[min(launchIndex(field), choices.count - 1)].label
    }

    /// It isn't T3's default: its chip is lit.
    func launchChanged(_ field: RouterV2LaunchField) -> Bool { launchIndex(field) != index(field, of: launchDefault) }

    /// A pill in the draft set it (and you haven't set it by hand since): its chip glows as it changes.
    func launchSaid(_ field: RouterV2LaunchField) -> Bool { said.names(field) && !launchMine.names(field) }

    /// Sets a setting by hand: yours until the draft's words name it again.
    func setLaunch(_ field: RouterV2LaunchField, _ index: Int) {
        let choices = launchChoices(field)
        guard !choices.isEmpty else { return }
        let index = min(choices.count - 1, max(0, index))
        guard index != launchIndex(field) else { return }
        if scripted { RouterV2Frames.note("setting \(field)") }
        animate(.spatial) {
            rolling {
                switch field {
                case .model: launchMine.model = launchModels[index].id
                case .effort: launchMine.effort = launchEfforts[index]
                case .access: launchMine.access = launchAccess[index]
                case .mode: launchMine.plan = index == 1
                }
            }
        }
    }

    /// Tab / ⇧Tab: into the row, on to the next chip, and after the last one back to the words. ← →: across the chips.
    func moveLaunchFocus(forward: Bool, leaves: Bool) {
        guard launchShown else { return }
        let fields = RouterV2LaunchField.allCases
        if scripted { RouterV2Frames.note("ring") }
        animate(.fade) {
            launchMenu = nil
            placesMenu = false
            guard let focus = launchFocus, let i = fields.firstIndex(of: focus) else {
                launchFocus = forward ? fields.first : fields.last
                return
            }
            let next = i + (forward ? 1 : -1)
            if fields.indices.contains(next) { launchFocus = fields[next] } else if leaves { launchFocus = nil }
        }
    }

    /// ↑ ↓ on the ringed chip: its menu opens (the one a click opens) and the value moves to the choice before or
    /// after, applying as it moves, so the choices are seen and nothing waits to be confirmed.
    func stepLaunch(down: Bool) {
        guard let field = launchFocus else { return }
        setLaunch(field, launchIndex(field) + (down ? 1 : -1))
        if launchMenu != field { animate(.fade) { launchMenu = field; placesMenu = false } }
    }

    func leaveLaunch() {
        guard launchFocus != nil || launchMenu != nil else { return }
        animate(.fade) {
            launchFocus = nil
            launchMenu = nil
        }
    }

    /// A click on a chip: its menu. The pointer has the row, so the keyboard's ring goes.
    func toggleLaunchMenu(_ field: RouterV2LaunchField) {
        animate(.fade) {
            launchMenu = launchMenu == field ? nil : field
            launchFocus = nil
            placesMenu = false
        }
    }

    /// A click on a menu's row.
    func chooseLaunch(_ field: RouterV2LaunchField, _ index: Int) {
        setLaunch(field, index)
        animate(.fade) { launchMenu = nil }
    }

    /// The row no longer shows a new thread: nothing of its settings is open.
    func settleLaunch() {
        if !launchShown {
            launchFocus = nil
            launchMenu = nil
        }
    }

    /// The model and the effort (and the access or plan mode when they aren't T3's default): after a new thread's words
    /// on its Sent line.
    func brief(_ launch: RouterV2Launch) -> String {
        let name = launchModels.first { $0.id == launch.model }?.name ?? launch.model
        return [name, launch.effort.label, launch.access != launchDefault.access ? launch.access.label : nil,
                launch.plan ? "Plan" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The settings in a few words: the row's accessibility label, a sent thread's card.
    func words(_ launch: RouterV2Launch) -> String {
        let name = launchModels.first { $0.id == launch.model }?.name ?? launch.model
        return [name, launch.effort.label, launch.access.label, launch.plan ? "Plan" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Chips

/// A new thread's settings in the destination row, and after them the key that takes the keyboard there.
struct RouterV2LaunchChips: View {
    let model: RouterV2Model
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: RouterV2.Launch.gap) {
            ForEach(model.launchFields, id: \.self) { field in
                RouterV2LaunchChip(model: model, field: field, ring: ring)
            }
            // Every act on the page shows its key: Tab moves into the row. Hidden while the keyboard is there.
            RouterV2KeyHint(keys: ["tab"]).opacity(model.launchFocus == nil ? 1 : 0)
                .padding(.leading, 3)
                .accessibilityHidden(true)
        }
        // The chips' widths follow their values on the roll's curve; the ring slides from chip to chip.
        .motion(RouterV2.roll, value: model.launchRolls)
        .motion(.glass, value: model.launchFocus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Starts with")
    }
}

/// One setting: its value on a quiet ground (no outline), rolling as it changes. Chosen (a step more ground, the
/// primary ink) when it isn't T3's default; ringed when the keyboard is on it; its ground glows in the accent as the
/// draft's words change it, and its value sheens while the draft is read again. A click opens its menu.
struct RouterV2LaunchChip: View {
    let model: RouterV2Model
    let field: RouterV2LaunchField
    let ring: Namespace.ID
    @State private var glow: Double

    private typealias M = RouterV2.Launch

    init(model: RouterV2Model, field: RouterV2LaunchField, ring: Namespace.ID) {
        self.model = model
        self.field = field
        self.ring = ring
        // A still shows a setting the words set as it looks just after they did.
        _glow = State(initialValue: model.still && model.launchSaid(field) ? 0.7 : 0)
    }

    var body: some View {
        let index = model.launchIndex(field)
        let label = model.launchLabel(field)
        let ringed = model.launchFocus == field
        let open = model.launchMenu == field
        let lit = model.launchChanged(field)
        let said = model.launchSaid(field)
        let roll = model.launchRolls[field]
        let shape = RoundedRectangle(cornerRadius: M.radius, style: .continuous)
        RouterV2Button(model: model, hit: .launch(field), action: { model.toggleLaunchMenu(field) }) { hot, pressed in
            let ink = hot || ringed || open || lit ? CDS.Text.primary : CDS.Text.secondary
            HStack(spacing: 4) {
                if field == .mode, index == 1 {
                    Image(systemName: "list.bullet.clipboard").font(.system(size: 9, weight: .medium)).foregroundStyle(ink)
                        .transition(.opacity)
                }
                RouterV2RollText(text: label, roll: roll, tint: ink,
                                 // What the pills set roll one chip after the other.
                                 delay: said ? Double(field.rawValue) * RouterV2.rollStagger : 0)
                                }
            .padding(.horizontal, M.padX)
            .frame(height: M.chip)
            // Your words set it: the accent's tint over its ground, then gone. A colour, no edge.
            .background { shape.fill(CDS.Text.accent.opacity(M.glowFill * glow)) }
            .background {
                let s = RouterV2.Surface.self
                shape.fill(pressed || open ? s.pressed : lit ? (hot ? s.chosenHover : s.chosen) : hot ? s.chosen : s.quiet)
                    .hoverMotion(hot)
            }
            // A leaving value never runs over the next chip: it is gone before the chip has narrowed much.
            .clipShape(shape)
            .overlay { if ringed { RouterV2Ring(radius: M.radius).matchedGeometryEffect(id: "ring", in: ring) } }
        }
        .onChange(of: roll?.tick) {
            // A pill set it: the chip glows, then settles.
            guard said, !model.still else { return }
            glow = 1
            // A colour fading, no movement: the same under Reduce Motion.
            let hold = RouterV2.glowHold + Double(field.rawValue) * RouterV2.rollStagger
            let settle = Animation.easeOut(duration: RouterV2.glowFade).delay(hold).resolved(reduce: false)
            DispatchQueue.main.async { withAnimation(settle) { glow = 0 } }
        }
        .help("\(field.title): click for the choices, or Tab into the row and use the arrows")
        .accessibilityLabel("\(field.title): \(label)")
        .accessibilityHint("Click for the choices. Tab moves into the row; the arrows change it.")
    }
}

/// A value that rolls as it changes: the new one comes in from below when it is further down its list and from above
/// when it is further up, the old one leaves the other way, both faces drawn once and moved by one progress. The roll is
/// keyed on the change's count, which the model moves in the same mutation as the value: nothing is set a frame late.
/// A cross-fade under Reduce Motion; no movement in a still.
struct RouterV2RollText: View {
    let text: String
    let roll: RouterV2Roll?
    var tint: Color = CDS.Text.secondary
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let tick = roll?.tick ?? 0
        Self.face(text, tint: tint)
            .modifier(Rolling(phase: Double(tick), tick: tick, from: roll?.from, tint: tint,
                              travel: reduce ? 0 : RouterV2.Launch.travel * (roll?.down == false ? -1 : 1)))
            .animation(reduce ? Motion.fade.resolved(reduce: true) : RouterV2.roll.delay(delay).resolved(reduce: false), value: tick)
    }

    static func face(_ text: String, tint: Color) -> some View {
        Text(text).font(CDS.sans(RouterV2.Launch.font)).foregroundStyle(tint).lineLimit(1).fixedSize()
    }

    /// `phase` runs from the last count to this one: the part past the last count is how far the new face has come.
    private struct Rolling: ViewModifier, Animatable {
        var phase: Double
        let tick: Int
        let from: String?
        let tint: Color
        let travel: CGFloat

        var animatableData: Double {
            get { phase }
            set { phase = newValue }
        }

        func body(content: Content) -> some View {
            // 0 as the change lands, 1 once the new face is in place (a little past it while the spring settles).
            let p = CGFloat(max(0, phase - Double(tick - 1)))
            let shown = min(1, p)
            content
                .opacity(Double(shown))
                .offset(y: (1 - p) * travel)
                .background(alignment: .leading) {
                    // The old face is gone by the roll's middle, before its chip has changed width much.
                    if let from, shown < 0.5 {
                        RouterV2RollText.face(from, tint: tint)
                            .opacity(Double(1 - 2 * shown))
                            .offset(y: -p * travel)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: RouterV2.Launch.chip)
                // The faces fade out at the chip's top and bottom edges; nothing is cut hard.
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.17),
                                           .init(color: .black, location: 0.83), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.horizontal, -60)
                }
        }
    }
}

// MARK: - Menu

/// A chip's menu: its setting's choices, the current one checked. A click on a chip opens it, and so do ↑ ↓ on the
/// ringed chip: the value then moves through the list as the keys do, its row lit.
struct RouterV2LaunchMenu: View {
    let model: RouterV2Model
    let field: RouterV2LaunchField

    var body: some View {
        let m = CDS.Menu.self
        let sections: [RouterV2LaunchField] = [field]
        // Opened from the keyboard: the current choice is the one the arrows are on.
        let keyed = model.launchFocus == field
        // Read here, in the body: a value read only inside the rows' closure doesn't redraw the menu when it moves.
        let currents = sections.map { model.launchIndex($0) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.self) { section in
                if section != sections.first {
                    Rectangle().fill(CDS.border).frame(height: 1).padding(.horizontal, m.separatorInset).padding(.vertical, 4)
                }
                Text(section.title).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.muted)
                    .padding(.horizontal, m.itemPadX).frame(height: m.labelHeight)
                let current = currents[sections.firstIndex(of: section) ?? 0]
                ForEach(Array(model.launchChoices(section).enumerated()), id: \.offset) { n, choice in
                    RouterV2Button(model: model, hit: .launchChoice(section, n), action: { model.chooseLaunch(section, n) }) { hot, pressed in
                        HStack(spacing: m.itemGap) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.primary)
                                .opacity(n == current ? 1 : 0)
                                .frame(width: 12)
                            Text(choice.label).font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                            Spacer(minLength: m.hintGap)
                            if !choice.detail.isEmpty {
                                Text(choice.detail).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, m.itemPadX)
                        .frame(height: m.item + 2)
                        .background(RoundedRectangle(cornerRadius: m.itemRadius, style: .continuous)
                            .fill(pressed ? RouterV2.Surface.pressed : hot || (keyed && n == current) ? RouterV2.Surface.hover : .clear))
                    }
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(n == current ? .isSelected : [])
                }
            }
        }
        .padding(m.pad)
        .frame(width: RouterV2.Launch.menuWidth)
        .routerV2Floating()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.title)
    }
}
