import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md; `--window-shots <dir> v2-split`), light and dark
// (`-dark`): three targets on the page (a thread, an item it answers, a new thread's ghost line), the Router reading
// again, a part it isn't sure of, one target, and six (four rows over the composer and "+2 more"). The composer is
// plain; each target shows what it will receive, and one row a destination over the composer says the same.
// Look only: the demo's reads carry the sends.

@MainActor
enum RouterSplitShots {
    private typealias ID = RouterDemo.ID

    /// The owner's words, and what the Router wrote for each place from them: trimmed, never rephrased.
    private static let three = "keep the sidebar icons in the page headers. val cenis: yes, reserve for five. "
        + "new thread: trim the onboarding copy to two screens"
    private static var threeSends: [RouterSend] {
        [RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons in the page headers"),
         RouterSend(places: [.thread(ID.valCenis)], words: "yes, reserve for five", item: "i1"),
         RouterSend(places: [.newThread(project: "fjord")], words: "trim the onboarding copy to two screens")]
    }

    private static let states: [(name: String, make: (RouterModel) -> Void)] = [
        ("v2-split-page", { model in draft(model, three, sends: threeSends) }),
        // More typed after the last read: its targets stay as they were while the Router reads again.
        ("v2-split-reading", { model in
            draft(model, three, sends: threeSends)
            model.setDraft(three + ", and")
            model.reading = true
        }),
        ("v2-split-unsure", { model in
            draft(model, "keep the sidebar icons in the page headers, and the spacing is off again",
                  sends: [RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons in the page headers"),
                          RouterSend(places: [.thread(ID.tab), .thread(ID.snapshot), .newThread(project: "fjord")], sure: false,
                                     words: "the spacing is off again", part: "“the spacing”")])
        }),
        ("v2-split-many", { model in
            draft(model, three + ". briefs: copy the old rows first. updater: ship it. tab handover: the spacing is off",
                  sends: threeSends + [
                      RouterSend(places: [.thread(ID.briefs)], words: "copy the old rows first"),
                      RouterSend(places: [.thread(ID.updater)], words: "ship it"),
                      RouterSend(places: [.thread(ID.tab)], words: "the spacing is off"),
                  ])
        }),
        ("v2-split-one", { model in
            draft(model, "settings: keep the sidebar icons in the page headers",
                  sends: [RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons in the page headers")])
        }),
    ]

    /// A draft with nothing selected, and the read that split it.
    private static func draft(_ model: RouterModel, _ text: String, sends: [RouterSend]) {
        model.select(nil)
        model.setDraft(text)
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [sends[0].place], sure: sends[0].sure, sends: sends)))
        model.finishTurn()
    }

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { state in
            [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")].map { look, suffix in
                AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router }, size: CGSize(width: 1280, height: 960),
                                    appearance: look,
                                    v2: {
                                        let model = RouterDemo.records(still: true)
                                        state.make(model)
                                        return model
                                    })
            }
        }
    }
}
