import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite("Router courier setup")
struct RouterCourierSetupTests {
    private func done(_ id: RouterCourierSetup.Check.ID, _ setup: RouterCourierSetup) -> RouterCourierSetup.Status {
        setup.checks.first { $0.id == id }!.status
    }

    @Test func allMissingOffersOneButtonEach() {
        let setup = RouterCourierSetup(facts: .init(), health: .init(), read: { .init() })
        #expect(setup.checks.map(\.status) == [.missing, .missing, .missing, .missing, .waiting])
        #expect(setup.checks.compactMap(\.button) == ["Get Chrome", "Show folder", "Register", "Open tab"])
        #expect(!setup.isComplete)
    }

    @Test func healthDrivesTheTabAndSignIn() {
        let facts = CourierSetupFacts(chromePath: "/Applications/Google Chrome.app", extensionLoaded: true, manifestWritten: true)
        let setup = RouterCourierSetup(facts: facts, health: .init(tabConnected: true, signedIn: false), read: { facts })
        #expect(done(.tab, setup) == .done)
        #expect(done(.signedIn, setup) == .missing)
        #expect(setup.checks.last?.button == "Sign in")
        let ready = RouterCourierSetup(facts: facts, health: .init(tabConnected: true, signedIn: true), read: { facts })
        #expect(ready.isComplete)
        #expect(ready.checks.allSatisfy { $0.button == nil })
    }

    @Test func signedInWaitsWithoutATab() {
        let setup = RouterCourierSetup(facts: .init(), health: .init(tabConnected: false, signedIn: true), read: { .init() })
        #expect(done(.signedIn, setup) == .waiting)
    }

    @Test func manifestCheckFollowsTheFilesAndNeedsABundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home"), support = dir.appendingPathComponent("support")
        let bundle = "/Applications/Fjord.app", exe = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        func read() -> CourierSetupFacts { .read(home: home, support: support, bundlePath: bundle, executable: exe) }
        #expect(!read().manifestWritten)
        NativeHostManifest.install(bundlePath: bundle, executable: exe, home: home, support: support)
        #expect(read().manifestWritten)
        #expect(!CourierSetupFacts.read(home: home, support: support, bundlePath: "/x/debug", executable: exe).canWriteManifest)
        // Pointing at another build is not "reaches this app".
        #expect(!CourierSetupFacts.read(home: home, support: support, bundlePath: bundle, executable: "/Other.app/Contents/MacOS/Fjord").manifestWritten)
    }

    @Test func extensionIsLoadedWhereAProfileNamesItsID() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Profile 2")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        #expect(!CourierSetupFacts.extensionIsLoaded(home: home))
        try Data("{\"extensions\":{\"settings\":{\"\(NativeHost.extensionID)\":{}}}}".utf8).write(to: profile.appendingPathComponent("Secure Preferences"))
        #expect(CourierSetupFacts.extensionIsLoaded(home: home))
    }

    @Test func buttonsDoTheirOneThing() {
        var revealed: [String] = [], opened: [URL] = [], wrote = 0
        let facts = CourierSetupFacts(chromePath: "/Applications/Google Chrome.app", extensionFolder: "/f/extension")
        let setup = RouterCourierSetup(facts: facts, read: { facts })
        setup.reveal = { revealed.append($0) }
        setup.openOutside = { opened.append($0) }
        setup.writeManifest = { wrote += 1 }
        setup.press(.extensionLoaded)
        setup.press(.host)
        #expect(revealed == ["/f/extension"])
        #expect(opened.map(\.absoluteString) == ["chrome://extensions"])
        #expect(wrote == 1)
    }

    @Test func followsTheHostsHealth() async {
        @MainActor final class Host: RouterCourierSetupHost {
            let stream: AsyncStream<CourierSetupHealth>
            let sink: AsyncStream<CourierSetupHealth>.Continuation
            init() { (stream, sink) = AsyncStream.makeStream() }
            var healthUpdates: AsyncStream<CourierSetupHealth> { stream }
            func openTab() {}
            func openSignIn() {}
        }
        let host = Host()
        let setup = RouterCourierSetup(host: host, facts: .init(), read: { .init() })
        host.sink.yield(.init(tabConnected: true, signedIn: false))
        host.sink.finish()
        await setup.follow()
        #expect(setup.health == .init(tabConnected: true, signedIn: false))
    }
}
