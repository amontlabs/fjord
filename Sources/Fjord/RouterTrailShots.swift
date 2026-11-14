import AppKit
import SwiftUI

// What sits at a row's trailing end (docs/design/router-v2/DESIGN.md R11, 2026-11-14; `--window-shots <dir> v2-trail`):
// an item row under the pointer with its quiet Done at the row's end and its age still after the words; a working
// line's activity glyphs at the row's end; the pointer on them showing their peek (each subagent, background command
// and wait), on a summed-up working line too, whose own hover gives way to it. Narrow and wide, light and dark (`-dark`).

@MainActor
enum RouterTrailShots {
    private typealias ID = RouterDemo.ID

    private struct State {
        let name: String
        var width: CGFloat = 1280
        let make: (RouterModel) -> Void
        var pointer: ((RouterModel) -> Void)?
    }

    private static let wide: CGFloat = 1450

    private static let states: [State] = [
        State(name: "v2-trail-item-done", make: items, pointer: itemDone),
        State(name: "v2-trail-wide-item-done", width: wide, make: items, pointer: itemDone),
        State(name: "v2-trail-wide-item-hover", width: wide, make: items, pointer: { model in
            model.hoverRow = RouterModel.itemKey(ID.checkpoint, RouterDemo.Item.smaller)
        }),
        State(name: "v2-trail-narrow-item-done", width: 900, make: items, pointer: itemDone),
        State(name: "v2-trail-narrow-activity-peek", width: 900, make: items, pointer: glyphs),
        State(name: "v2-trail-activity", make: items),
        State(name: "v2-trail-wide-activity", width: wide, make: items),
        State(name: "v2-trail-activity-peek", make: items, pointer: glyphs),
        State(name: "v2-trail-wide-activity-peek", width: wide, make: items, pointer: glyphs),
    ]

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { [shot($0, .aqua, ""), shot($0, .darkAqua, "-dark")] }
    }

    private static func shot(_ state: State, _ look: NSAppearance.Name, _ suffix: String) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router },
                            size: CGSize(width: state.width, height: 1000), appearance: look,
                            v2: {
                                let model = RouterDemo.records(still: true)
                                state.make(model)
                                return model
                            },
                            v2Pointer: state.pointer)
    }

    /// The items' page with the demo's subagents, commands and waits, and the working lines summed up (so a working
    /// line has its own hover, which the glyphs' peek must win over).
    private static func items(_ model: RouterModel) {
        RouterDemo.itemsLook(model)
        RouterDemo.workingSummaries(model)
        for (id, a) in RouterDemo.activity(at: model.now) { model.activity(id, a) }
        model.select(nil)
    }

    private static func itemDone(_ model: RouterModel) {
        let key = RouterModel.itemKey(ID.checkpoint, RouterDemo.Item.smaller)
        model.hoverRow = key
        model.hoverControl = .itemDone(key)
    }

    private static func glyphs(_ model: RouterModel) {
        model.hoverRow = ID.tab
        model.hoverControl = .activity(ID.tab)
    }
}
