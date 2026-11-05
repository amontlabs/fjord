import Foundation
import Observation
import Testing
@testable import Fjord

@MainActor
struct SelectionMarksTests {
    @Test func aRowObservesOnlyItsOwnMark() {
        let hub = HubState()
        var aChanged = false
        withObservationTracking { _ = hub.isSelected("i:a") } onChange: { aChanged = true }
        hub.selection = "i:b"
        #expect(!aChanged, "another row picked: a isn't redrawn")
        hub.selection = "i:a"
        #expect(aChanged && hub.isSelected("i:a") && !hub.isSelected("i:b"))
    }

    @Test func marksOfRowsGoneAreLetGoAndARowStillDrawnIsToldToReadAgain() {
        let hub = HubState()
        var told = false
        withObservationTracking { _ = hub.isSelected("i:kept") } onChange: { told = true }
        for i in 0...HubState.Mark.kept { _ = hub.isSelected("i:\(i)") }
        hub.selection = "i:0"
        #expect(told, "the marks were let go: a row still drawn reads its own again")
        #expect(hub.isSelected("i:0") && !hub.isSelected("i:kept"))
        hub.selection = "i:kept"
        #expect(hub.isSelected("i:kept") && !hub.isSelected("i:0"))
    }

}
