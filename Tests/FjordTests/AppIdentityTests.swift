import Foundation
import Testing
@testable import Fjord

@Suite struct AppIdentityTests {
    @Test func developmentRunsGetTheirOwnSupportFolder() {
        #expect(AppIdentity.supportFolderName(environment: [:], arguments: [], development: false) == "Fjord")
        #expect(AppIdentity.supportFolderName(environment: [:], arguments: [], development: true) == "Fjord Dev")
        #expect(AppIdentity.supportFolderName(environment: ["FJORD_SUPPORT_FOLDER": "Fjord Probe"], arguments: [], development: false) == "Fjord Probe")
        #expect(AppIdentity.supportFolderName(environment: ["FJORD_SUPPORT_FOLDER": "../Fjord"], arguments: [], development: false) == "Fjord")
    }

    @Test func thisBuildNeverUsesTheInstalledAppsFolder() {
        // Tests are debug builds: they must not point at `Fjord`.
        #expect(AppIdentity.supportFolderName != "Fjord")
        #expect(RouterPaths.unguarded.support.lastPathComponent == AppIdentity.supportFolderName)
    }

    @Test func aTestEnvironmentMarksAReleaseBuildAsDevelopment() {
        #if !DEBUG
        #expect(AppIdentity.isDevelopment(environment: ["FJORD_E2E": "1"], arguments: []))
        #expect(AppIdentity.isDevelopment(environment: [:], arguments: ["--e2e"]))
        #expect(!AppIdentity.isDevelopment(environment: [:], arguments: []))
        #endif
    }
}
