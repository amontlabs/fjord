import Foundation
import Testing
@testable import Fjord

/// The page in a wide window (WIDE-OPTIONS.md): which layout each width gets, and where it puts its columns.
@MainActor
@Suite struct RouterWideTests {
    @Test func aPageWithoutTheRoomStaysItsOwn() {
        #expect(RouterWide.frame(page: 790) == nil)
        #expect(RouterWide.frame(page: RouterWide.ledgerFrom - 1) == nil)
    }

    @Test func theLedgerThenThePane() {
        #expect(RouterWide.frame(page: RouterWide.ledgerFrom)?.layout == .ledger)
        #expect(RouterWide.frame(page: RouterWide.paneFrom - 1)?.layout == .ledger)
        #expect(RouterWide.frame(page: RouterWide.paneFrom)?.layout == .pane)
        #expect(RouterWide.ledgerFrom < RouterWide.paneFrom)
    }

    @Test func noLayoutStretchesTheReadingColumnOrLeavesThePage() {
        for page in stride(from: CGFloat(700), through: 3000, by: 10) {
            guard let (layout, frame) = RouterWide.frame(page: page) else { continue }
            #expect(frame.column <= Router.column)
            #expect(frame.start - Router.Margin.lead - frame.margin - frame.rail >= Router.gutter - 0.5)
            #expect(frame.end <= page - Router.gutter + 0.5)
            if layout == .pane { #expect(RouterWide.pane.contains(frame.side)) }
        }
    }

    @Test func aVeryWidePageCentresThePane() {
        let page: CGFloat = 2400
        guard let (layout, frame) = RouterWide.frame(page: page) else { Issue.record("no layout"); return }
        #expect(layout == .pane)
        #expect(frame.side == RouterWide.pane.upperBound)
        let left = frame.start - Router.Margin.lead - frame.margin - frame.rail
        #expect(abs(left - (page - frame.end)) < 1)
    }
}
