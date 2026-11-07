import AppKit
import SwiftUI

private let body13: (CGFloat, CGFloat) = (13, 19)
private let foot12: (CGFloat, CGFloat) = (12, 16)

/// A category's "Then": what it does by itself when a thing comes in. Each action is edited in place; "Try on latest match"
/// shows what it would do to the latest thing the rules match, and does nothing.
struct ActionsEditor: View {
    @Binding var actions: ActionList
    let store: Store
    let rules: [Rule]
    let categoryName: String

    private var kinds: Set<ThingKind> { Set(rules.flatMap(\.scope.kinds)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Then").cdsText(CDS.Density.comfortable.heading, .semibold)
                .accessibilityAddTraits(.isHeader)
                .tip("Then", "Runs once for each thing that comes in, never for what is already here when you add it")
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 6) {
                // One that sends to the Router shows only while Triage and the Router are both on (it is kept meanwhile).
                ForEach(actions.items) { action in
                    if store.toolsLinked || !action.kind.sendsToRouter {
                        ActionRow(action: binding(action), store: store, rules: rules, categoryName: categoryName, kinds: kinds) {
                            actions.items.removeAll { $0.id == action.id }
                        }
                    }
                }
                addMenu.padding(.top, actions.isEmpty ? 0 : 6)
            }
        }
    }

    /// An action's binding by its id, not its place in the list: a write that comes after it was removed (its prompt's
    /// typing written as the field goes) is dropped, rather than landing on the action that took its place, or past the end.
    private func binding(_ action: CategoryAction) -> Binding<CategoryAction> {
        let id = action.id
        return Binding(get: { actions.items.first { $0.id == id } ?? action },
                       set: { new in Self.replace(new, in: &actions.items) })
    }

    /// An action's prompt, read from the action as it is when asked (not as it was when the row was drawn: the field holds
    /// its write for as long as it is on screen, `PendingEdits`, and compares what it holds with this), `fallback` once the
    /// action sends no prompt.
    static func prompt(of action: Binding<CategoryAction>, else fallback: ActionPrompt) -> Binding<ActionPrompt> {
        Binding(get: {
            if case .askRouter(let prompt) = action.wrappedValue.kind { return prompt }
            return fallback
        }, set: { action.wrappedValue.kind = .askRouter(prompt: $0) })
    }

    /// `action` in place of the one with its id; nothing when that one is gone.
    static func replace(_ action: CategoryAction, in items: inout [CategoryAction]) {
        guard let i = items.firstIndex(where: { $0.id == action.id }) else { return }
        items[i] = action
    }

    private var addMenu: some View {
        Menu {
            if store.toolsLinked {
                Button("Send to the Router") { actions.items.append(.make(.askRouter(prompt: ActionPrompt()))) }
            }
            Button("Comment on GitHub") { actions.items.append(.make(.comment(""))) }
            Button("Re-run failed checks") { actions.items.append(.make(.rerun)) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Action")
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChipButtonStyle(tone: .dashed))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add an action")
    }
}

private struct ActionRow: View {
    @Binding var action: CategoryAction
    let store: Store
    let rules: [Rule]
    let categoryName: String
    let kinds: Set<ThingKind>
    let remove: () -> Void
    @State private var preview: [String]?
    @State private var trying = false

    private var applies: Bool { kinds.isEmpty || kinds.contains { action.applies(to: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: action.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(CDS.Text.secondary)
                    .frame(width: 16)
                Text(action.title).cdsText(body13, .medium)
                Spacer(minLength: 8)
                MenuChip(title: action.trigger == .enter ? "when it comes in" : "on each new fact", label: "When it runs") {
                    Toggle("When it comes in", isOn: Binding(get: { action.trigger == .enter }, set: { _ in action.trigger = .enter }))
                    Toggle("On each new fact", isOn: Binding(get: { action.trigger == .eachFact }, set: { _ in action.trigger = .eachFact }))
                }
                IconButton(symbol: "xmark", help: "Remove", label: "Remove \(action.title)", size: 24, tint: CDS.Text.muted, action: remove)
            }
            switch action.kind {
            case .askRouter(let prompt):
                ActionPromptField(prompt: ActionsEditor.prompt(of: $action, else: prompt), store: store)
                    .tip("Prompt", "Sent to the Router as yours, from this category, with the thing tagged: @this notification says where it goes in your words (else it is added at the end). The Router sends it to the claude.ai project or thread it is for; if it isn't sure where, it asks you and waits. Its title, link, why it is here and the last comment go with it in a block marked as written by others, so nothing others wrote reads as your words. @ also inserts a snippet, or tags a claude.ai project or thread, a local project or a category.")
                HStack(spacing: 8) {
                    Text("The thread it starts").cdsText(foot12, .regular, CDS.Text.secondary)
                    MenuChip(title: Self.modeTitle(action.runtimeMode), label: "What the thread may do") {
                        ForEach(Self.modes, id: \.mode) { choice in
                            Toggle(choice.title, isOn: Binding(get: { action.runtimeMode == choice.mode }, set: { _ in action.runtimeMode = choice.mode }))
                        }
                    }
                }
                RouterWarning(strong: InboxActions.rulesMatchOthers(rules))
            case .comment(let text):
                ActionTextBox(text: Binding(get: { text }, set: { action.kind = .comment($0) }),
                              placeholder: "The comment, like “Thanks @{author}, taking a look”", label: "Comment")
                    .tip("Comment", "{title} {url} {number} {repo} {author} are filled in. PRs and issues only.")
            case .rerun:
                EmptyView()
            }
            if !applies {
                Text("None of this category's rules is something this applies to.").cdsText(foot12, .regular, CDS.Text.danger)
            }
            HStack(spacing: 8) {
                Button { Task { await tryIt() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eye").font(.system(size: 11, weight: .medium))
                        Text(trying ? "Looking…" : "Try on latest match")
                    }
                }
                .buttonStyle(SettingsButtonStyle(size: .sm))
                .disabled(trying)
                .tip("Try on latest match", "Shows what it would do. Nothing is done.")
                if preview != nil {
                    Button("Hide") { preview = nil }.buttonStyle(SettingsButtonStyle(variant: .ghost, size: .sm))
                }
            }
            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                        Text(line).cdsText(foot12, .regular, CDS.Text.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CDS.Fill.field))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preview")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CDS.border, lineWidth: 1))
    }

    /// What the thread an action starts may do, unattended (`T3RuntimeMode`); nil is T3's own default.
    private static let modes: [(mode: String?, title: String)] = [
        (nil, "uses T3's default"), ("approval-required", "asks before it acts"),
        ("auto-accept-edits", "edits freely, asks for the rest"), ("full-access", "can do anything"),
    ]

    private static func modeTitle(_ mode: String?) -> String { modes.first { $0.mode == mode }?.title ?? "uses T3's default" }

    private func tryIt() async {
        trying = true
        defer { trying = false }
        guard let match = store.latestMatch(of: rules) else {
            preview = ["Nothing matches yet, so there is nothing to try it on."]
            return
        }
        let performer = store.actionPerformer ?? (store.persists && !Store.isDemo ? StoreActionPerformer(store: store) : nil)
        preview = await InboxActions.preview(action, category: categoryName.isEmpty ? "New category" : categoryName,
                                             thing: match.thing, facts: match.facts, performer: performer, name: store.pointerName)
    }

}

/// Under "Send to the Router": what reaches the session is written by others; stronger when the rules can match their items.
private struct RouterWarning: View {
    let strong: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold))
            Text("GitHub text reaches an agent thread on your Mac").cdsText(foot12, strong ? .medium : .regular, CDS.Text.warning)
        }
        .foregroundStyle(CDS.Text.warning)
        .padding(.horizontal, strong ? 8 : 0).padding(.vertical, strong ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CDS.Text.warning.opacity(strong ? 0.16 : 0)))
        .tip("Prompt injection", "Anyone who can write a title or comment on matching items can try to steer the session it reaches. The thread runs in a worktree of its own, unattended, with the permissions chosen above. The Router never acts on the item itself (it never changes Fjord in response to one), but keep the prompt narrow and the rules tight (by me, Maintainers)."
             + (strong ? " These rules match items others write." : ""))
        .accessibilityElement(children: .combine)
    }
}

/// A few lines of text in the field's look, with a placeholder.
private struct ActionTextBox: View {
    @Binding var text: String
    let placeholder: String
    let label: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(CDS.sans(13))
            .foregroundStyle(CDS.Text.primary)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(minHeight: 72)
            .background(RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous).fill(CDS.Fill.field))
            .overlay(RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous)
                .strokeBorder(focused ? CDS.Fill.accent : CDS.Settings.fieldRing, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
    }
}

/// A "Send to the Router" prompt, written as the Router's composer is (`MentionField`): typing @ suggests "this notification"
/// first (the thing the action runs for), then projects, sessions and categories as pills, and snippets as text; ↑↓ walk
/// them, Return or Tab picks, Esc dismisses.
struct ActionPromptField: View {
    @Binding var prompt: ActionPrompt
    let store: Store
    /// The field's own draft, pills and @ word: the composer's model, never the Router's.
    @State private var model = RouterModel()
    @State private var editor = EditorBox()
    @State private var focused = false
    @State private var focusTick = 0
    @State private var pendingWrite: Task<Void, Never>?
    /// The field's place in `PendingEdits`.
    @State private var field = UUID()

    /// The text view, once it has told where its caret is (a pick puts the caret after it).
    final class EditorBox {
        weak var view: NSTextView?
    }

    var body: some View {
        let rows = Self.suggestions(model, store: store)
        VStack(alignment: .leading, spacing: 6) {
            MentionField(store: store, model: model, maxHeight: 200, editable: true, focusTick: focusTick,
                         onFocus: { focused = $0 }, label: "Prompt",
                         hint: "@ tags this notification, a project, a session or a category, or inserts a snippet",
                         onCommand: command, onSelection: { view in
                             editor.view = view
                             model.followCaret(view)
                         })
                .frame(minHeight: 60, alignment: .topLeading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("What to do, like “Review @\(ActionPrompt.thisItemName) and fix what Greptile flagged”")
                            .font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
                            .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .background(RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous).fill(CDS.Fill.field))
                .overlay(RoundedRectangle(cornerRadius: CDS.Settings.fieldRadius, style: .continuous)
                    .strokeBorder(focused ? CDS.Fill.accent : CDS.Settings.fieldRing, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { focusTick &+= 1 }
            if !rows.isEmpty {
                MentionList(suggestions: rows, index: model.mentionIndex, width: 340, hover: { model.mentionIndex = $0 }) {
                    model.pickMention($0)
                }
                .fixedSize()
            }
        }
        .onAppear {
            Self.load(prompt, into: model)
            // Its write, held for as long as it is here: a quit or an undo writes what it holds now.
            PendingEdits.hold(field) { write() }
        }
        .onChange(of: prompt) { _, now in Self.load(now, into: model) }
        // Typing is written to the category once it pauses (each write is a change of the categories: saved, logged, a step
        // of the page's history, the bar redrawn); a pill picked, the field left or gone, at once.
        .onChange(of: model.draft) { writeSoon() }
        .onChange(of: model.pointers) { write() }
        .onChange(of: focused) { _, now in if !now { write() } }
        .onDisappear {
            write()
            PendingEdits.release(field)
        }
        .onChange(of: model.caretRequest) { _, request in
            guard let request else { return }
            model.caretRequest = nil
            // After the field has the new text.
            DispatchQueue.main.async {
                guard let view = editor.view else { return }
                view.setSelectedRange(NSRange(location: min(request, (view.string as NSString).length), length: 0))
                model.followCaret(view)
            }
        }
    }

    private func write() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let now = Self.prompt(of: model)
        if now != prompt { prompt = now }
    }

    /// `write`, once typing has paused for `pause`.
    private func writeSoon() {
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(for: TypingPause.pause)
            guard !Task.isCancelled else { return }
            write()
        }
    }

    /// The keys while @ suggestions show: ↑↓ walk them, Return or Tab picks, Esc dismisses. Otherwise the text view's own.
    private func command(_ selector: Selector) -> Bool {
        let rows = Self.suggestions(model, store: store)
        guard !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            model.moveMention(down: selector == #selector(NSResponder.moveDown(_:)), count: rows.count)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            model.pickMention(rows[min(model.mentionIndex, rows.count - 1)])
        case #selector(NSResponder.cancelOperation(_:)):
            model.dismissMention()
        default:
            return false
        }
        return true
    }

    /// What the @ word matches: "this notification" first (while the prompt doesn't have it), then what the composer offers
    /// but a notification (the thing it runs for is "this notification").
    static func suggestions(_ model: RouterModel, store: Store) -> [MentionSuggestion] {
        guard let query = model.mention else { return [] }
        let others = model.suggestions(store).filter { $0.section != .notifications }
        guard !model.pointers.contains(.thisItem), RouterMentions.score(ActionPrompt.thisItemName, query: query) != nil else {
            return others
        }
        let this = MentionSuggestion(section: .notifications, pick: .pointer(.thisItem), name: ActionPrompt.thisItemName,
                                     detail: "the thing it runs for", look: store.pointerLook(.thisItem),
                                     keys: [ActionPrompt.thisItemName])
        return [this] + others
    }

    /// The prompt in the field, unless the field has it already (what it writes back, an undo).
    static func load(_ prompt: ActionPrompt, into model: RouterModel) {
        guard prompt != Self.prompt(of: model) else { return }
        model.pointers = prompt.pointers
        model.draft = prompt.text
    }

    /// The prompt the field holds.
    static func prompt(of model: RouterModel) -> ActionPrompt { ActionPrompt(text: model.draft, pointers: model.pointers) }
}
