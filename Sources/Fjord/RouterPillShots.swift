import AppKit
import SwiftUI

// The composer's item and answer pills (`RouterAnswerPills`; `--window-shots <dir> v2-pill`), light and dark (`-dark`):
// the @ list on an item with its row lit on the page, an item pill after ⌘-click, an answer pill with its card, Other
// typed and live in the pill, and two answers from two threads with free words.

@MainActor
enum RouterPillShots {
    private typealias ID = RouterDemo.ID
    private typealias Pill = RouterDemo.Pill

    private struct State {
        let name: String
        let make: (RouterModel) -> Void
    }

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { [shot($0, .aqua, ""), shot($0, .darkAqua, "-dark")] }
    }

    private static func shot(_ state: State, _ look: NSAppearance.Name, _ suffix: String) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router }, size: CGSize(width: 1280, height: 960),
                            appearance: look,
                            v2: {
                                let model = RouterDemo.records(still: true)
                                RouterDemo.pills(model)
                                state.make(model)
                                return model
                            })
    }

    /// The trial build's card open, in Snapshot API's block.
    private static func trialCard(_ model: RouterModel) {
        model.select(.line(ID.snapshot))
        model.focusItem(Pill.trial)
    }

    private static let states: [State] = [
        // "@launchd": the list finds the Do by a word of its sentence, under Snapshot API; its row on the page is lit.
        State(name: "v2-pill-at-items") { model in
            model.select(nil)
            model.setDraft("check @launchd")
            model.lightAt(.item(RouterModel.itemKey(ID.snapshot, Pill.launchd)))
        },
        // ⌘-click on the launchd row: the item as a pill after the words, the composer's.
        State(name: "v2-pill-item") { model in
            model.select(nil)
            model.setDraft("can you look at ")
            model.pillItem(Pill.launchd, of: ID.snapshot)
            model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.snapshot)], sure: true)))
        },
        // The first option picked on the trial build's card: one pill, `? trial build → Owed live tests`.
        State(name: "v2-pill-answer") { model in
            trialCard(model)
            model.pick(1)
        },
        // Words typed in the card's Other: the answer, live in the pill.
        State(name: "v2-pill-other") { model in
            trialCard(model)
            model.typeOther(RouterModel.itemKey(ID.snapshot, Pill.trial), question: 0, Pill.other)
        },
        // Two answers from two threads (Bar count's and the trial build's), then free words.
        State(name: "v2-pill-several") { model in
            model.select(.line(ID.bar))
            model.focusItem(RouterDemo.Item.push)
            model.pick(1)
            trialCard(model)
            model.pick(1)
            model.edit(model.draft + Pill.words, marks: model.mentions)
            model.select(nil)
        },
    ]
}
