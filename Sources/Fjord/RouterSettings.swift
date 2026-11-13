import SwiftUI

// A new thread's settings as the @ list offers them (RouterSetting.swift): the rows, what a pill does to the chips, and the
// demo's own typing of an @ word (its composer is drawn, not a text view).

extension RouterModel {
    /// The settings the @ list offers for a typed word: T3's models (by their names, slugs and aliases), the efforts and
    /// the access the model in the row takes, and the mode. The list ranks and cuts them (`RouterMentions.suggest`).
    func settingRows(_ query: String) -> [MentionSuggestion] {
        guard !launchModels.isEmpty else { return [] }
        let now = launch
        var rows: [MentionSuggestion] = []
        func add(_ setting: RouterSetting, detail: String, keys: [String]) {
            rows.append(MentionSuggestion(section: .settings, pick: .pointer(.setting(setting)), name: setting.label, detail: detail,
                                          look: setting.look, keys: [setting.label] + keys))
        }
        for m in launchModels {
            add(RouterSetting(kind: .model, value: m.id, label: m.name), detail: "Model · \(m.provider)", keys: [m.id] + m.aliases)
        }
        let model = launchModel(now.model)
        for e in model?.efforts ?? [] {
            add(RouterSetting(kind: .effort, value: e.rawValue, label: e.label), detail: "Reasoning effort",
                keys: [e.rawValue, e.label.replacingOccurrences(of: " ", with: "")])
        }
        for a in model?.access ?? [] {
            add(RouterSetting(kind: .access, value: a.rawValue, label: a.label), detail: "Access", keys: [a.rawValue])
        }
        add(RouterSetting(kind: .mode, value: "plan", label: "Plan"), detail: "Mode · writes a plan and waits for your go", keys: [])
        add(RouterSetting(kind: .mode, value: "build", label: "Build"), detail: "Mode · builds at once", keys: [])
        // Only what the word starts or holds: a setting is never found by its letters in order.
        guard !query.isEmpty else { return rows }
        return rows.filter { row in row.keys.contains { RouterMentions.score($0, query: query).map { $0 <= 2 } ?? false } }
    }

    /// The settings pills of the draft changed: the chips follow, rolling, and a chip you set by hand before gives way to the
    /// pill that names it. Taking a pill out puts the setting back to your pick, else T3's default.
    func followPills(before: [RouterPointer], now: [RouterPointer]) {
        let was = RouterSetting.ask(before), next = RouterSetting.ask(now)
        guard was != next else { return }
        if scripted { RouterFrames.note("pill") }
        animate(.spatial) {
            rolling {
                if next.model != nil, next.model != was.model { launchMine.clear(.model) }
                if next.effort != nil, next.effort != was.effort { launchMine.clear(.effort) }
                if next.access != nil, next.access != was.access { launchMine.clear(.access) }
                if next.plan != nil, next.plan != was.plan { launchMine.clear(.mode) }
                launchPills = next
            }
        }
    }

    // MARK: The demo's @ word

    /// The @ word the draft ends with, when the demo's composer shows the list: what follows the "@".
    func updateScriptedMention() {
        var query: String?
        if let at = draft.lastIndex(of: "@") {
            let before = draft[..<at].last
            let rest = draft[draft.index(after: at)...]
            if before == nil || MentionText.isBreak(before!), !rest.contains(where: MentionText.isBreak) { query = String(rest) }
        }
        if query != scriptedMention {
            scriptedMention = query
            scriptedMentionIndex = 0
        }
    }

    /// The rows the demo's list shows.
    var scriptedRows: [MentionSuggestion] {
        guard let query = scriptedMention else { return [] }
        let taken = Set(mentions.map(\.pointer))
        let rows = settingRows(query).filter { if case .pointer(let p) = $0.pick { !taken.contains(p) } else { true } }
        return RouterMentions.suggest(rows, query: query)
    }

    /// Return on the demo's list: the lit row becomes a pill in the @ word's place, with a space after it.
    func pickScripted() {
        let rows = scriptedRows
        guard let at = draft.lastIndex(of: "@"), !rows.isEmpty,
              case .pointer(let pointer) = rows[min(scriptedMentionIndex, rows.count - 1)].pick else { return }
        var text = draft
        text.replaceSubrange(at..., with: MentionText.markString + " ")
        // The new pill is the last one: the demo types the @ word at the end.
        let pointers = mentions.map(\.pointer) + [pointer]
        scriptedMention = nil
        edit(text, marks: RouterMentions.marks(text, pointers: pointers, name: { p in
            if case .setting(let s) = p { s.label } else { "" }
        }))
    }
}
