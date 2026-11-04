import AppKit
import SwiftUI

/// What the engine knows of the page, as the setup screen needs it: whether Fjord's tab is linked, and whether claude.ai in it
/// is signed in (nil while unknown, or without a tab).
struct CourierSetupHealth: Equatable {
    var tabConnected = false
    var signedIn: Bool?
}

/// The hooks the setup takes from the engine's host: its health as it changes (the current one first), and the two tabs it can open.
@MainActor protocol RouterCourierSetupHost: AnyObject {
    var healthUpdates: AsyncStream<CourierSetupHealth> { get }
    func openTab()
    func openSignIn()
}

/// What is true of the Mac, apart from the engine: read again when the app is activated or the screen shows.
struct CourierSetupFacts: Equatable, Sendable {
    var chromePath: String?
    var extensionLoaded = false
    var manifestWritten = false
    /// The unpacked extension's folder, when this build can find it.
    var extensionFolder: String?
    /// Only the app bundle may point Chrome at itself.
    var canWriteManifest = true

    /// Reads the Mac as it is now.
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL = AppIdentity.supportDirectory(),
                     bundlePath: String = Bundle.main.bundlePath, executable: String? = Bundle.main.executablePath) -> CourierSetupFacts {
        var facts = CourierSetupFacts()
        facts.chromePath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")?.path
        facts.extensionLoaded = extensionIsLoaded(home: home)
        facts.canWriteManifest = NativeHostManifest.isBundle(bundlePath)
        if let executable {
            let launcher = NativeHostManifest.launcherURL(support: support)
            facts.manifestWritten =
                (try? Data(contentsOf: NativeHostManifest.manifestURL(home: home))) == NativeHostManifest.manifestJSON(launcher: launcher)
                && (try? Data(contentsOf: launcher)) == Data(NativeHostManifest.launcherScript(executable: executable).utf8)
        }
        facts.extensionFolder = extensionFolder(executable: executable)
        return facts
    }

    /// Chrome keeps each profile's extensions in its Preferences: the extension is loaded where one names its id.
    static func extensionIsLoaded(home: URL) -> Bool {
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let id = Data(NativeHost.extensionID.utf8)
        for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
            for name in ["Preferences", "Secure Preferences"] {
                let url = root.appendingPathComponent(profile).appendingPathComponent(name)
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.range(of: id) != nil { return true }
            }
        }
        return false
    }

    /// The bundle's copy, or the repository's (`poc/router/extension`) above a debug binary.
    static func extensionFolder(executable: String?) -> String? {
        let fm = FileManager.default
        if let copy = Bundle.main.resourceURL?.appendingPathComponent("extension"), fm.fileExists(atPath: copy.appendingPathComponent("manifest.json").path) {
            return copy.path
        }
        var dir = URL(fileURLWithPath: executable ?? fm.currentDirectoryPath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("poc/router/extension")
            if fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) { return candidate.path }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// The one-screen first-run setup for claude.ai delivery: five live checks, each with what is missing and one button.
@Observable @MainActor final class RouterCourierSetup {
    enum Status: Equatable { case done, missing, waiting }

    struct Check: Identifiable, Equatable {
        enum ID: String, CaseIterable { case chrome, extensionLoaded, host, tab, signedIn }
        var id: ID
        var title: String
        var status: Status
        var detail: String
        var button: String?
        var enabled = true
    }

    private(set) var facts: CourierSetupFacts
    private(set) var health = CourierSetupHealth()

    @ObservationIgnored private weak var host: (any RouterCourierSetupHost)?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private let read: @Sendable () -> CourierSetupFacts
    @ObservationIgnored var openOutside: (URL) -> Void = RouterCourierSetup.openInChrome
    @ObservationIgnored var reveal: (String) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
    @ObservationIgnored var writeManifest: () -> Void = { NativeHostManifest.install() }

    init(host: (any RouterCourierSetupHost)? = nil, facts: CourierSetupFacts? = nil, health: CourierSetupHealth = .init(),
         read: @escaping @Sendable () -> CourierSetupFacts = { CourierSetupFacts.read() }) {
        self.host = host
        self.read = read
        self.facts = facts ?? read()
        self.health = health
    }

    var isComplete: Bool { checks.allSatisfy { $0.status == .done } }

    var checks: [Check] {
        let chrome = Check(id: .chrome, title: "Chrome is installed", status: facts.chromePath == nil ? .missing : .done,
                           detail: facts.chromePath == nil ? "Google Chrome isn't in Applications" : "Found at \(facts.chromePath ?? "")",
                           button: facts.chromePath == nil ? "Get Chrome" : nil)
        let folder = facts.extensionFolder
        let loaded = Check(id: .extensionLoaded, title: "The Fjord extension is loaded",
                           status: facts.extensionLoaded ? .done : .missing,
                           detail: facts.extensionLoaded ? "Loaded in Chrome"
                               : "In chrome://extensions turn on Developer mode, choose Load unpacked, then pick \(folder ?? "poc/router/extension")",
                           button: facts.extensionLoaded ? nil : "Show folder",
                           enabled: facts.chromePath != nil)
        let hostCheck = Check(id: .host, title: "Chrome can reach Fjord", status: facts.manifestWritten ? .done : .missing,
                              detail: facts.manifestWritten ? "Chrome's native host points at this app"
                                  : facts.canWriteManifest ? "Chrome doesn't know this app yet" : "Only the installed app can register itself with Chrome",
                              button: facts.manifestWritten ? nil : "Register",
                              enabled: facts.canWriteManifest)
        let linked = health.tabConnected
        let tab = Check(id: .tab, title: "Fjord's tab is connected", status: linked ? .done : .missing,
                        detail: linked ? "A claude.ai tab is linked" : "Open claude.ai in Chrome with the extension on",
                        button: linked ? nil : "Open tab", enabled: facts.chromePath != nil)
        let signed: Check
        switch (linked, health.signedIn) {
        case (_, true?) where linked:
            signed = Check(id: .signedIn, title: "Signed in to claude.ai", status: .done, detail: "Signed in", button: nil)
        case (true, false?):
            signed = Check(id: .signedIn, title: "Signed in to claude.ai", status: .missing, detail: "Sign in in Fjord's tab", button: "Sign in")
        default:
            signed = Check(id: .signedIn, title: "Signed in to claude.ai", status: .waiting,
                           detail: linked ? "Checking the page" : "Needs the tab connected", button: nil)
        }
        return [chrome, loaded, hostCheck, tab, signed]
    }

    /// Reads the Mac again (activation, the screen showing).
    func refresh() {
        let read = read
        Task { [weak self] in
            let next = await Task.detached { read() }.value
            self?.facts = next
        }
    }

    /// Follows the engine's health until the screen goes.
    func follow() async {
        guard let host else { return }
        for await next in host.healthUpdates {
            health = next
        }
    }

    func press(_ id: Check.ID) {
        switch id {
        case .chrome:
            if let url = URL(string: "https://www.google.com/chrome/") { NSWorkspace.shared.open(url) }
        case .extensionLoaded:
            if let folder = facts.extensionFolder { reveal(folder) }
            if let url = URL(string: "chrome://extensions") { openOutside(url) }
        case .host:
            writeManifest()
            refresh()
        case .tab:
            host?.openTab()
        case .signedIn:
            host?.openSignIn()
        }
    }

    /// chrome:// pages only open in Chrome itself.
    static func openInChrome(_ url: URL) {
        guard !UnderTest.refuses("Chrome"), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The setup as a Settings section: a tick or what's missing on each line, one button on it.
struct RouterCourierSetupView: View {
    let setup: RouterCourierSetup
    private let comfy = CDS.Density.comfortable

    var body: some View {
        SettingsSection("Delivery through claude.ai",
                        description: setup.isComplete ? "Ready: Fjord can send to claude.ai." : "Five things have to be true before Fjord can send to claude.ai.") {
            let checks = setup.checks
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { SettingsDivider() }
                row(check)
            }
        }
        .task { await setup.follow() }
        .task { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refresh() }
    }

    private func row(_ check: RouterCourierSetup.Check) -> some View {
        SettingsRow(check.title, description: check.detail, descriptionColor: check.status == .missing ? CDS.Text.warning : CDS.Text.muted,
                    adornment: AnyView(mark(check.status))) {
            if let button = check.button {
                ActionButton(button) { setup.press(check.id) }.disabled(!check.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func mark(_ status: RouterCourierSetup.Status) -> some View {
        let symbol = switch status {
        case .done: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .waiting: "circle.dotted"
        }
        let color = switch status {
        case .done: Theme.green
        case .missing: Theme.amber
        case .waiting: CDS.Text.muted
        }
        return Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color).frame(width: 16, height: 16)
            .accessibilityLabel(status == .done ? "Done" : status == .missing ? "Missing" : "Waiting")
    }
}
