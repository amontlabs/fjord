import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md; `--window-shots <dir> v2-split`), light and dark
// (`-dark`): two threads with their words tinted, answer pills with free text, one part unsure, and the read under way.
// Look only: the demo's reads carry the sends.

@MainActor
enum RouterSplitShots {
    private typealias ID = RouterDemo.ID

    private static let states: [(name: String, make: (RouterModel) -> Void)] = [
        ("v2-split-two", { model in
            draft(model, "bar count: push it and open the PR. for the updater, install silently on the stable channel",
                  sends: [RouterSend(places: [.thread(ID.bar)], parts: ["bar count: push it and open the PR"]),
                          RouterSend(places: [.thread(ID.updater)],
                                     parts: ["for the updater, install silently on the stable channel"])])
        }),
        ("v2-split-pills", { model in
            draft(model, pills + "keep the sidebar icons in the page headers, and tab handover: skip the fade for now",
                  answers: answers,
                  sends: [RouterSend(places: [.thread(ID.settings)], parts: ["keep the sidebar icons in the page headers"],
                                     answers: [0]),
                          RouterSend(places: [.thread(ID.valCenis)], answers: [1]),
                          RouterSend(places: [.thread(ID.tab)], parts: ["tab handover: skip the fade for now"])])
        }),
        ("v2-split-unsure", { model in
            draft(model, "bar count: push it and open the PR, and the spacing is off again",
                  sends: [RouterSend(places: [.thread(ID.bar)], parts: ["bar count: push it and open the PR"]),
                          RouterSend(places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")], sure: false,
                                     parts: ["the spacing is off again"])])
        }),
        // The pills are placed by code at once; the free text waits for the read, Fjord's mark in its row.
        ("v2-split-reading", { model in
            draft(model, pills + "keep the sidebar icons in the page headers, and tab handover: skip the fade for now",
                  answers: answers,
                  sends: [RouterSend(places: [.thread(ID.settings)], answers: [0]),
                          RouterSend(places: [.thread(ID.valCenis)], answers: [1])])
            model.reading = true
        }),
    ]

    /// Two answer pills at the start of the draft: Settings layout's and Val Cenis booking's picked options.
    private static let pills = MentionText.markString + " " + MentionText.markString + " "
    private static let answers = ["One scrolling page", "Reserve for five (+€62)"]

    /// A draft with nothing selected, and the read that split it.
    private static func draft(_ model: RouterModel, _ text: String, answers: [String] = [], sends: [RouterSend]) {
        model.select(nil)
        if answers.isEmpty {
            model.setDraft(text)
        } else {
            var names = answers.makeIterator()
            let pointers = answers.indices.map { RouterPointer.notification("answer:\($0)") }
            model.edit(text, marks: RouterMentions.marks(text, pointers: pointers, name: { _ in names.next() ?? "" }))
        }
        model.apply(.read(RouterRead(draft: model.plainDraft, places: sends.first.map { [$0.place] } ?? [], sure: false,
                                     sends: sends)))
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
