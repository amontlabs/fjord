import AppKit
import SwiftUI

// The `v2-mention` still: the Router v2 page with the @ field live (a text view, not the still's drawn words) and the @
// list open over the caret, on the demo's records. A live field needs the store and the composer's text model, which the
// `v2` shots don't have (they draw the dock's words as a still), so the page is drawn on its own with
// `routerV2Composer` set, as the app's window will set it.

@MainActor
enum RouterV2MentionShot {
    static var catalog: [AppWindowShots.Shot] {
        [shot("v2-mention", .aqua), shot("v2-mention-dark", .darkAqua)]
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name) -> AppWindowShots.Shot {
        let size = CGSize(width: 1280, height: 960)
        return AppWindowShots.Shot(name: name, destination: { _ in .router }, size: size, appearance: look,
                                   standalone: { store, text in
            let model = RouterV2Demo.records()
            model.select(nil)
            text.draft = "ask @fj"
            return AnyView(
                RouterV2Screen(model: model)
                    .environment(\.routerV2Composer, (store, text))
                    .background(CDS.Surface.s1))
        })
    }
}
