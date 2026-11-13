import Foundation
import Testing
@testable import Fjord

/// The wide layouts to choose from (WIDE-OPTIONS.md): where each puts its columns, and when the page stays its own.
@MainActor
@Suite struct RouterLabTests {
    @Test func noOptionWithoutTheSwitch() {
        // Tests run without `FJORD_WIDE`: a page's model starts with none, so the page is its own.
        #expect(RouterLab.pinned == nil)
        #expect(RouterDemo.records(still: true).lab == nil)
    }

    @Test func noOptionStretchesTheReadingColumn() {
        for option in RouterLab.Option.allCases {
            for page in stride(from: CGFloat(600), through: 3000, by: 37) {
                guard let frame = RouterLab.frame(option, page: page) else { continue }
                #expect(frame.column <= Router.column, "\(option) at \(page)")
                // Everything it draws is inside the page, a gutter from its sides.
                let left = frame.start - (frame.margin > 0 ? Router.Margin.lead + frame.margin + frame.rail : 0)
                #expect(left >= Router.gutter - 0.5, "\(option) at \(page)")
                #expect(frame.end <= page - Router.gutter + 0.5, "\(option) at \(page)")
            }
        }
    }

    @Test func aPageWithoutTheRoomStaysItsOwn() {
        // The window of the page's own shots (1040 wide, its sidebar aside) is too narrow for any of them.
        for option in RouterLab.Option.allCases { #expect(RouterLab.frame(option, page: 790) == nil) }
        // The margin notes hold in the default 1280 window, the column pushed right of its margin; the pane doesn't.
        let a = RouterLab.frame(.a, page: 1032)
        #expect(a?.column == Router.column)
        #expect(a.map { $0.start > (1032 - Router.column) / 2 } == true)
        #expect(RouterLab.frame(.b, page: 1032) == nil)
    }

    @Test func aWidePageCentresTheMarginNotesColumn() {
        let frame = RouterLab.frame(.a, page: 1352)
        #expect(frame?.start == (1352 - Router.column) / 2)
        #expect(frame?.margin == RouterLab.margin.upperBound)
    }
}
