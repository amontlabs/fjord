import AppKit
import SwiftUI

// The state filter's stills (docs/design/router-v2/DESIGN.md 1.2, 4; `--window-shots <dir> v2-filter-state`): the page
// under each state token, on the demo's Checkpoint boot (a Stuck, a Decide and a Know), and the history row's hover
// (`v2-history-hover`: a long message of yours cut on its line, shown whole). Light and dark (`-dark`).

@MainActor
enum RouterFilterShots {
    private typealias ID = RouterDemo.ID

    private static let states: [(name: String, section: RouterSection)] = [
        ("v2-filter-state-needs", .needsYou), ("v2-filter-state-done", .done), ("v2-filter-state-working", .working),
    ]

    static let longMessage = "rewrite the install guide around the Chrome extension, drop the CLI path entirely because nobody installs it that way now, and keep the screenshots of the old flow in an appendix for the people still on 0.7"

    static var catalog: [AppWindowShots.Shot] {
        let looks: [(NSAppearance.Name, String)] = [(.aqua, ""), (.darkAqua, "-dark")]
        return looks.flatMap { look, suffix in
            states.map { state in
                AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router }, size: CGSize(width: 1280, height: 960),
                                    appearance: look,
                                    v2: {
                                        let model = RouterDemo.records(still: true)
                                        RouterDemo.items(model)
                                        model.select(nil)
                                        model.section = state.section
                                        return model
                                    })
            } + [AppWindowShots.Shot(name: "v2-history-hover" + suffix, destination: { _ in .router },
                                     size: CGSize(width: 1280, height: 960), appearance: look,
                                     v2: {
                                         let model = RouterDemo.records(still: true)
                                         RouterDemo.layers(model)
                                         model.update(ID.guide) { t in
                                             if let i = t.history.firstIndex(where: { if case .started(.asked) = $0.kind { true } else { false } }) {
                                                 t.history[i].kind = .started(.asked(longMessage))
                                             }
                                         }
                                         model.select(.line(ID.guide))
                                         return model
                                     },
                                     v2Pointer: { model in
                                         guard let event = model.thread(ID.guide)?.history.first(where: {
                                             if case .started(.asked) = $0.kind { true } else { false }
                                         }) else { return }
                                         model.hoverControl = RouterHistoryPeek.hit(ID.guide, event.id)
                                     })]
        }
    }
}
