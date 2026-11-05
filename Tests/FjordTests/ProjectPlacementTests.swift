import Foundation
import Testing
@testable import Fjord

struct ProjectPlacementTests {
    @Test func routerStatePersistsProjectIdentityAndPlacement() throws {
        let id = UUID()
        var state = RouterSaved()
        state.runsOnProjects = [RunsOnProject(
            id: id,
            name: "fjord",
            sourceFolder: "/Users/test/code/fjord",
            placement: .computer(deviceId: "owner-a", computerId: "computer-a", guestPath: "/workspace/fjord")
        )]

        let decoded = try JSONDecoder().decode(RouterSaved.self, from: JSONEncoder().encode(state))

        #expect(decoded.runsOnProjects == state.runsOnProjects)
        #expect(decoded.runsOnProjects.first?.id == id)
    }

    @Test func guestPathIsAbsoluteAndNeverHostNormalized() throws {
        #expect(try GuestFolderPath.validate(" /workspace/../repo ") == "/workspace/../repo")
        #expect(throws: GuestFolderPath.Failure.absolutePathRequired) { try GuestFolderPath.validate("workspace/repo") }
    }

    @Test func sameGuestPathOnDifferentComputersHasDifferentExecutionIdentity() {
        let first = ProjectPlacement.computer(deviceId: "owner-a", computerId: "computer-a", guestPath: "/workspace/repo")
        let second = ProjectPlacement.computer(deviceId: "owner-a", computerId: "computer-b", guestPath: "/workspace/repo")

        #expect(first != second)
        #expect(first.location != second.location)
    }

    @Test func changingPlacementDoesNotChangeAnExistingSessionLocation() {
        let existingLocation = SessionLocation.computer(deviceId: "owner-a", computerId: "computer-a")
        let futurePlacement = ProjectPlacement.thisMac(path: "/Users/test/code/repo")

        #expect(futurePlacement.location == .thisMac)
        #expect(existingLocation == .computer(deviceId: "owner-a", computerId: "computer-a"))
    }
}
