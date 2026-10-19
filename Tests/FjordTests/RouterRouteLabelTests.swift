import Testing
@testable import Fjord

@Suite("Route labels")
struct RouterRouteLabelTests {
    @Test("the labels are the intent criteria's names but unclear")
    func labelsAreTheCriteriaNames() {
        let names = RouterTools.intentCriteria.map(\.name).filter { $0 != "unclear" }
        #expect(RouteLabel.allCases.map(\.rawValue) == names)
    }

    @Test("a target is Fjord's own only by its label")
    func isFjord() {
        for label in RouteLabel.allCases { #expect(RouteLabel.isFjord(label.rawValue)) }
        #expect(!RouteLabel.isFjord("unclear"))
        #expect(!RouteLabel.isFjord("new:/tmp/x"))
        #expect(!RouteLabel.isFjord("session:abc"))
    }
}
