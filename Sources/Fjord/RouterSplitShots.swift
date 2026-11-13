import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md; `--window-shots <dir> v2-split`), light and dark
// (`-dark`): three targets on the page (a thread, an item it answers, a new thread's ghost line), the Router reading
// again, a part it isn't sure of, one target, and six (four rows over the composer and "+2 more"). The composer is
// plain; each target shows what it will receive, and one row a destination over the composer says the same.
// Each state is the decider's decision read by `RouterReader.read`, as a live one lands.

@MainActor
enum RouterSplitShots {
    private typealias ID = RouterDemo.ID

    /// The owner's words, and the decider's parts for them (its places and the words it kept for each: trimmed, never
    /// rephrased), read into the page's sends by the reader as a live decision is.
    private typealias Part = RouterProjectDecision.Part
    private static func to(_ id: String, _ words: String) -> Part { Part(places: [.thread(id)], sure: true, words: words, confidence: 0.95) }
    private static func new(_ project: String, _ words: String) -> Part {
        Part(places: [.newThread(project: project)], sure: true, words: words, confidence: 0.9)
    }
    private static let three = "keep the sidebar icons in the page headers. val cenis: yes, reserve for five. "
        + "new thread: trim the onboarding copy to two screens"
    private static let threeParts = [to(ID.settings, "keep the sidebar icons in the page headers"),
                                     to(ID.valCenis, "yes, reserve for five"),
                                     new("fjord", "trim the onboarding copy to two screens")]

    private static let states: [(name: String, make: (RouterModel) -> Void)] = [
        ("v2-split-page", { model in draft(model, three, parts: threeParts) }),
        // More typed after the last read: its targets stay as they were while the Router reads again.
        ("v2-split-reading", { model in
            draft(model, three, parts: threeParts)
            model.setDraft(three + ", and")
            model.reading = true
        }),
        ("v2-split-unsure", { model in
            draft(model, "keep the sidebar icons in the page headers, and the spacing is off again",
                  parts: [to(ID.settings, "keep the sidebar icons in the page headers"),
                          Part(places: [.thread(ID.tab), .thread(ID.snapshot), .newThread(project: "fjord")], sure: false,
                               words: "the spacing is off again", confidence: 0.5)])
        }),
        ("v2-split-many", { model in
            draft(model, three + ". briefs: copy the old rows first. updater: ship it. tab handover: the spacing is off",
                  parts: threeParts + [to(ID.briefs, "copy the old rows first"), to(ID.updater, "ship it"),
                                       to(ID.tab, "the spacing is off")])
        }),
        // One place: the decider writes no parts, and the usual destination row shows.
        ("v2-split-one", { model in
            draft(model, "settings: keep the sidebar icons in the page headers", parts: [], one: .thread(ID.settings))
        }),
    ]

    /// A draft with nothing selected, and the decider's decision on it, read as the reader reads a live one.
    private static func draft(_ model: RouterModel, _ text: String, parts: [Part], one: RouterProjectDecision.Kind? = nil) {
        model.select(nil)
        model.setDraft(text)
        var decision = RouterProjectDecision(kind: one ?? parts[0].places[0], confidence: 0.95, decider: .sonnet)
        decision.sends = parts
        let read = RouterReader.read(model.plainDraft, decision: decision, selected: nil, eligible: { _ in true })
        model.apply(.read(read))
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
