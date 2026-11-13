import AppKit
import SwiftUI

// The layers' stills (docs/design/router-v2/DESIGN.md R10; `--window-shots <dir> v2-layer`): Done, Working and an item,
// each as its line, its hover and its card, light and dark (`-dark`). The cards show the thread's history: under the
// source for Done and for the item (Needs you), as the source for Working; an item's card in a block has none.

@MainActor
enum RouterLayerShots {
    private typealias ID = RouterDemo.ID

    private struct State {
        let name: String
        let id: String
        var item: String?
        var layer: Layer
        enum Layer { case line, hover, card }
    }

    private static let states: [State] = [
        State(name: "v2-layer-done-line", id: ID.guide, layer: .line),
        State(name: "v2-layer-done-hover", id: ID.guide, layer: .hover),
        State(name: "v2-layer-done-card", id: ID.guide, layer: .card),
        State(name: "v2-layer-working-line", id: ID.tab, layer: .line),
        State(name: "v2-layer-working-hover", id: ID.tab, layer: .hover),
        State(name: "v2-layer-working-card", id: ID.tab, layer: .card),
        State(name: "v2-layer-item-line", id: ID.valCenis, layer: .line),
        State(name: "v2-layer-item-hover", id: ID.valCenis, layer: .hover),
        State(name: "v2-layer-item-card", id: ID.valCenis, layer: .card),
        // An item's card in a block: under its row's words, no history (the header's card has it).
        State(name: "v2-layer-item-block-card", id: ID.checkpoint, item: RouterDemo.Item.keep, layer: .card),
    ]

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { [shot($0, .aqua, ""), shot($0, .darkAqua, "-dark")] }
    }

    private static func shot(_ state: State, _ look: NSAppearance.Name, _ suffix: String) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router }, size: CGSize(width: 1280, height: 960),
                            appearance: look,
                            v2: {
                                let model = RouterDemo.records(still: true)
                                if state.item != nil { RouterDemo.items(model) }
                                RouterDemo.layers(model)
                                if state.layer == .card {
                                    model.select(.line(state.id))
                                    if let item = state.item { model.focusItem(item) }
                                } else {
                                    model.select(nil)
                                }
                                return model
                            },
                            v2Pointer: state.layer == .hover ? { model in
                                model.hoverRow = state.id
                                model.hoverName = state.id
                            } : nil)
    }
}
