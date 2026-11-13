import AppKit
import SwiftUI

// The `v2-mention` still: the Router v2 page with the @ field live (a text view, not the still's drawn words) and the @
// list open over the caret, on the demo's records. A live field needs the store and the composer's text model, which the
// `v2` shots don't have (they draw the dock's words as a still), so the page is drawn on its own with
// `routerComposer` set, as the app's window will set it.

@MainActor
enum RouterMentionShot {
    static var catalog: [AppWindowShots.Shot] {
        [shot("v2-mention", .aqua), shot("v2-mention-dark", .darkAqua), waiting("v2-waiting", .aqua), waiting("v2-waiting-dark", .darkAqua)]
            + RouterPillShots.catalog
    }

    /// An unattended action's words waiting for a place, in the dock's status stack.
    private static func waiting(_ name: String, _ look: NSAppearance.Name) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: name, destination: { _ in .router }, size: CGSize(width: 1280, height: 960), appearance: look,
                            standalone: { store, text in
            let model = RouterDemo.records()
            model.select(nil)
            let waiting = RouterWaiting()
            waiting.items = [.init(id: "w1", origin: "Triage's action on octo/app#12", words: "rebase on main and rerun the checks",
                                   places: [.thread(RouterDemo.ID.tab), .newThread(project: "fjord")])]
            return AnyView(
                RouterScreen(model: model)
                    .environment(\.routerComposer, (store, text))
                    .environment(\.routerWaiting, waiting)
                    .background(CDS.Surface.s1))
        })
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name) -> AppWindowShots.Shot {
        let size = CGSize(width: 1280, height: 960)
        return AppWindowShots.Shot(name: name, destination: { _ in .router }, size: size, appearance: look,
                                   standalone: { store, text in
            let model = RouterDemo.records()
            model.select(nil)
            text.draft = "ask @fj"
            return AnyView(
                RouterScreen(model: model)
                    .environment(\.routerComposer, (store, text))
                    .background(CDS.Surface.s1))
        })
    }
}
