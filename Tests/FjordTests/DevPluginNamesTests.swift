import Foundation
import Testing
@testable import Fjord

/// Debug and E2E builds have plugin and marketplace names of their own, so they never re-point
/// what the installed app registered in Claude Code.
@Suite struct DevPluginNamesTests {
    @Test func installedAndDevelopmentNamesNeverCollide() {
        #expect(ClaudePlugin.pluginName(development: false) == "fjord")
        #expect(ClaudePlugin.pluginName(development: true) == "fjord-dev")
    }

    @Test func marketplacesCarryTheirBuildsNames() {
        #expect(ClaudePlugin.marketplaceJSON(development: false) == ClaudePlugin.marketplaceTemplate)
        let dev = ClaudePlugin.marketplaceJSON(development: true)
        #expect(dev.contains("\"name\": \"fjord-dev\"") && !dev.contains("\"name\": \"fjord\""))
    }

    @Test func thisTestBuildIsDevelopment() {
        #expect(AppIdentity.isDevelopment())
        #expect(ClaudePlugin.id == "fjord-dev@fjord-dev")
    }
}
