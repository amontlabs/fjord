import SwiftUI

// What the Router changed in Fjord, as a card in its transcript: the icon and one line, a compact read-only preview of
// what it touched (a category's rules as the editor's own chips, a setting's before → after…), and Open and Revert. A
// card taken back says so.

/// The column's content width, for the previews' measure.
private struct ColumnWidthKey: EnvironmentKey { static let defaultValue = CDS.Transcript.measure }

extension EnvironmentValues {
    /// The column's content width: what a change card measures its previews by.
    var cdsColumnWidth: CGFloat {
        get { self[ColumnWidthKey.self] }
        set { self[ColumnWidthKey.self] = newValue }
    }

    /// Shows a change's place in the app window (the window's own; a shot or a hub shows nothing).
    @Entry var openChange: (FjordChange) -> Void = { _ in }
}

struct ChangeCard: View {
    let change: FjordChange
    let store: Store
    @Environment(\.openChange) private var openChange
    @Environment(\.cdsColumnWidth) private var width

    private var reverted: Bool { change.isReverted }
    /// The whole before and after of a change waiting for Apply, shown.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            waiting
            Rectangle().fill(CDS.border).frame(height: 1).padding(.horizontal, -(CDS.Transcript.cardPadX - 1))
            preview
                .padding(.horizontal, CDS.Density.compact.pad.xs)
                .padding(.top, CDS.Density.compact.pad.md).padding(.bottom, CDS.Density.compact.pad.sm)
                .opacity(reverted ? 0.5 : 1)
        }
        .padding(.horizontal, CDS.Transcript.cardPadX)
        .padding(.vertical, CDS.Transcript.cardPadY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: CDS.Transcript.cardRadius, style: .continuous).strokeBorder(CDS.border, lineWidth: 1)
        }
        .padding(.trailing, CDS.Transcript.textStop(width))
        .onChange(of: change.failureNote) { _, note in
            if let note { AccessibilityNotification.Announcement("\(change.title). \(note)").post() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reverted ? "\(change.title). \(change.revertNote ?? "Reverted")"
                            : (change.pending.map { "\(change.title). \(notApplied($0))" } ?? change.title)
                + (change.failureNote.map { ". \($0)" } ?? ""))
    }

    /// The note under a waiting change.
    private func notApplied(_ why: String) -> String { "Not applied yet: \(why)." }

    // MARK: Header

    private var header: some View {
        HStack(spacing: CDS.Density.compact.gap.sm) {
            icon
            Text(change.title)
                .cdsText(CDS.Transcript.text, .medium, reverted ? CDS.Text.muted : CDS.Text.primary)
                .strikethrough(reverted, color: CDS.Text.muted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: CDS.Density.compact.gap.sm)
            if reverted {
                Text(change.revertNote ?? "Reverted").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                    .lineLimit(2).multilineTextAlignment(.trailing)
            } else if change.touchesTriage, !store.triageOn {
                // Triage is off: what was changed in it is only told, nothing of it is opened or changed back.
                EmptyView()
            } else if change.isPending {
                failure
                ClaudeButton("Discard", variant: .ghost, size: .sm) { store.discardFjordChange(change.id) }
                ClaudeButton("Apply", variant: .primary, size: .sm) { store.applyFjordChange(change.id) }
            } else {
                failure
                ClaudeButton("Open", variant: .ghost, size: .sm) { openChange(change) }
                ClaudeButton("Revert", variant: .secondary, size: .sm) { store.revertFjordChange(change.id) }
            }
        }
        .padding(.horizontal, CDS.Density.compact.pad.xs)
        .frame(minHeight: 36)
    }

    /// Why the last Apply or Revert failed, in the line's own note place; the buttons stay for another try.
    @ViewBuilder private var failure: some View {
        if let note = change.failureNote {
            Text(note).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.danger)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .help(note)
        }
    }

    /// Why a change waits for you, under its line: nothing of it is applied until Apply. Everything Apply allows (every
    /// prompt, comment, trigger, setting and rule, before and after) opens under it, whole.
    @ViewBuilder private var waiting: some View {
        if let why = change.pending, change.isPending {
            VStack(alignment: .leading, spacing: CDS.Density.compact.gap.sm) {
                HStack(alignment: .firstTextBaseline, spacing: CDS.Density.compact.gap.sm) {
                    Text(notApplied(why))
                        .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary)
                    Spacer(minLength: 0)
                    ClaudeButton(expanded ? "Hide details" : "Details", variant: .ghost, size: .sm) { expanded.toggle() }
                        .help("Everything Apply allows: the whole before and after of this change")
                }
                if expanded { PayloadView(payload: change.payload(store: store)) }
            }
            .padding(.horizontal, CDS.Density.compact.pad.xs).padding(.bottom, CDS.Density.compact.pad.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var icon: some View {
        if case .category(_, let before, let after) = change.patch, let c = after ?? before {
            CategoryTile(symbol: c.symbol, color: c.color, size: 24)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CDS.Fill.secondary).frame(width: 24, height: 24)
                .overlay(Image(systemName: change.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(CDS.Text.secondary))
                .accessibilityHidden(true)
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        switch change.patch {
        case .category(_, let before, let after):
            CategoryPreview(before: before, after: after, store: store)
        case .group(_, let before, let after):
            GroupPreview(group: after ?? before, deleted: after == nil)
        case .order(_, let after):
            OrderPreview(names: after.compactMap { id in store.categories.first { $0.id == id }?.title })
        case .setting(let key, let before, let after):
            if let setting = FjordSetting.named(key) {
                HStack(spacing: 6) {
                    Text(setting.display(before)).cdsText(CDS.Transcript.text, .regular, CDS.Text.muted)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                    Text(setting.display(after)).cdsText(CDS.Transcript.text)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(setting.display(before)) to \(setting.display(after))")
            }
        case .marks(_, let changes):
            MarksPreview(changes: changes, store: store)
        case .briefAction(_, _, let act, _):
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs you").cdsText(CDS.Transcript.text, .regular, CDS.Text.muted)
                Text(act.label).cdsText(CDS.Transcript.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Pieces

/// A change's whole before and after, line by line, nothing cut.
private struct PayloadView: View {
    let payload: ChangePayload

    var body: some View {
        VStack(alignment: .leading, spacing: CDS.Density.compact.gap.sm) {
            side("Before", payload.before)
            side("After", payload.after)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func side(_ name: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).cdsText(CDS.Density.compact.footnote, .medium, CDS.Text.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rule's lines as read-only chips, in the editor's own look.
struct RuleChips: View {
    let lines: [[RulePiece]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, pieces in
                SentenceLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        switch piece.style {
                        case .word: Word(piece.text)
                        case .chip: Text(piece.text).modifier(ChipLook())
                        case .danger: Text(piece.text).modifier(ChipLook(tone: .danger))
                        }
                    }
                }
                .padding(.leading, i > 1 ? 10 : 0)
                .overlay(alignment: .leading) { if i > 1 { Rectangle().fill(CDS.Settings.railLine).frame(width: 1) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: ", "))
    }
}

private struct CategoryPreview: View {
    let before: InboxCategory?
    let after: InboxCategory?
    let store: Store

    var body: some View {
        let shown = after ?? before
        let words = RuleWords(store: store)
        VStack(alignment: .leading, spacing: 10) {
            if let before, let after {
                let diff = FjordChange.diff(before, after)
                if !diff.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(diff, id: \.self) { Text($0).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary) }
                    }
                }
            }
            if let shown {
                ForEach(Array(shown.rules.enumerated()), id: \.element.id) { i, rule in
                    if i > 0 { Word("or") }
                    RuleChips(lines: words.lines(rule))
                }
                if shown.rules.isEmpty { Text("No rules").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted) }
                let notes = notes(shown)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notes(_ c: InboxCategory) -> [String] {
        var out: [String] = []
        if !c.notifies { out.append("No notifications") }
        if c.hidden { out.append("Hidden from the bar") }
        if !c.actions.isEmpty { out.append("⚡ " + c.actions.items.map(\.title).joined(separator: ", ")) }
        return out
    }
}

private struct GroupPreview: View {
    let group: InboxGroup?
    let deleted: Bool

    var body: some View {
        if let group {
            VStack(alignment: .leading, spacing: 6) {
                SentenceLayout(spacing: 4, lineSpacing: 4) {
                    Word(group.kind == .people ? "People" : "Repos")
                    // Every member: what a rule by this group takes is all of them.
                    ForEach(group.members, id: \.self) { Text($0).modifier(ChipLook()) }
                    if group.members.isEmpty { Word("no members yet") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OrderPreview: View {
    let names: [String]

    var body: some View {
        SentenceLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted) }
                Text(name).modifier(ChipLook())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.joined(separator: ", then "))
    }
}

private struct MarksPreview: View {
    let changes: [EntryChange]
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(changes.prefix(3), id: \.thing) { item in
                Text(store.things[item.thing].map { "\($0.repo)\($0.number.map { "#\($0)" } ?? "") · \($0.title)" } ?? item.thing)
                    .cdsText(CDS.Transcript.text, .regular, CDS.Text.secondary).lineLimit(1).truncationMode(.tail)
            }
            if changes.count > 3 {
                Text("and \(changes.count - 3) more").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
