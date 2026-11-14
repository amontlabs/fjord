import AppKit
import SwiftUI

// The quote mark's stills (docs/design/router-v2/DESIGN.md R10, 2026-11-14; `--window-shots <dir> v2-quote v2-item-card-no`):
// the pointer on the lastdrop item's mark, its long quote cut at 14 lines; an item with a quote and no detail (the mark
// after the item's sentence); an item with a detail and no quote (the mark points at the thread's last message). Light
// and dark (`-dark`).

@MainActor
enum RouterQuoteShots {
    private typealias ID = RouterDemo.ID

    private struct State {
        let name: String
        var change: (inout RouterItem) -> Void
        var pointer = false
        var hot = false
        var scrolled: CGFloat = 0
    }

    private static let states: [State] = [
        State(name: "v2-quote-hover", change: { $0.quote = longQuote }, pointer: true),
        State(name: "v2-quote-hover-scrolled", change: { $0.quote = longQuote }, pointer: true, scrolled: 90),
        State(name: "v2-quote-mark-hot", change: { $0.quote = longQuote }, hot: true),
        State(name: "v2-item-card-no-detail", change: { $0.detail = nil }),
        State(name: "v2-item-card-no-quote", change: { $0.quote = nil }),
    ]

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { [shot($0, .aqua, ""), shot($0, .darkAqua, "-dark")] }
    }

    private static func shot(_ state: State, _ look: NSAppearance.Name, _ suffix: String) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: state.name + suffix, destination: { _ in .router }, size: CGSize(width: 1280, height: 960),
                            appearance: look,
                            v2: {
                                let model = RouterDemo.records(still: true)
                                RouterDemo.itemsLook(model)
                                model.update(ID.transcriptGap) { t in
                                    if let i = t.ledger.items.firstIndex(where: { $0.id == RouterDemo.Item.update }) {
                                        state.change(&t.ledger.items[i])
                                    }
                                }
                                model.select(.line(ID.transcriptGap))
                                model.focusItem(RouterDemo.Item.update)
                                return model
                            },
                            v2Pointer: state.pointer || state.hot ? { model in
                                RouterQuotePeek.shotStart = state.scrolled
                                RouterQuotePeek.shotNoPeek = state.hot
                                // Hot with no hover: the mark's ground alone (the hover reads this hit).
                                model.hoverControl = RouterQuoteMark.hit(ID.transcriptGap, RouterDemo.Item.update)
                            } : nil)
    }

    /// The lastdrop release's whole message: longer than the mark's hover shows, so its cut and fade show.
    static let longQuote = """
        The fix is committed, pushed to `main` (d24947a), and released as lastdrop 0.8.13: https://github.com/amontlabs/lastdrop/releases/tag/v0.8.13

        - Cause: a subagent's transcript was read from its first turn's file only, so a second subagent's turns landed in a gap between the two.
        - Fix: each subagent's turns are read from its own file, in order, and joined when both are done.
        - Build: the release is the signed universal app (Apple silicon and Intel), notarized and stapled.
        - Check: a run with two subagents now keeps both transcripts whole, with no gap between their turns. I ran it three times on the release build.
        - Install: the app's update panel offers 0.8.13; accept it there. The installed app is still 0.8.12, so the fix isn't live until you do.

        Nothing else changed in this release. The next one picks up the settings page rework once its review is in.
        """
}
