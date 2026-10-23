import AppKit
import SwiftUI

// Dev entries for the app window: `--window` opens it alone on the demo data; `--window-shots <dir> [substring...]` renders
// its destinations as PNGs, offscreen, the title bar included.

@MainActor
enum AppWindowDev {
    /// `--window`: the window on the demo data (the Router's cards included), the app ending with it.
    static func open(_ store: Store) -> AppWindowController {
        Demo.populate(store, .router)
        let controller = AppWindowController(store: store, remembers: false)
        controller.onClose = { NSApp.terminate(nil) }
        if CommandLine.arguments.contains(RouterFlightDemo.flag) {
            RouterFlightDemo.install(store)
            controller.show(.router)
            RouterFlightDemo.play(store: store, model: controller.routerModel)
        } else {
            controller.show()
        }
        return controller
    }
}

/// The window of a shot: it may sit anywhere, so it can be off every screen, and it never becomes key or main, so no field
/// in it takes keyboard focus or the keystrokes typed in other apps while a shot runs.
final class ShotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Writes a shot's window content to a PNG.
///
/// `cacheDisplay` walks the views' `draw(_:)`, which skips what SwiftUI keeps in layers of its own: the content of every
/// `ScrollView` (the Router's list and history, the Brief) came out empty. The window server composites those layers,
/// and may be asked for a window of this process without any screen-recording permission, even when the window sits
/// off every screen, so the shot is the window's own picture, cropped to its content view (a full-size-content window's
/// traffic lights and rounded corners are in it).
@MainActor
enum ShotCapture {
    static func write(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let png = windowPicture(of: view) ?? cachedDisplay(of: view)
        try? png?.write(to: URL(fileURLWithPath: path))
    }

    /// Writes the window server's picture of the view; false when there is none (nothing is written).
    static func writeWindowPicture(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let png = windowPicture(of: view) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func windowPicture(of view: NSView) -> Data? {
        guard let window = view.window, window.windowNumber > 0 else { return nil }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming]), image.width > 0 else { return nil }
        let scale = CGFloat(image.width) / window.frame.width
        let rect = view.convert(view.bounds, to: nil)
        let crop = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        guard let content = image.cropping(to: crop) else { return nil }
        return NSBitmapImageRep(cgImage: content).representation(using: .png, properties: [:])
    }

    private static func cachedDisplay(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// The shot runs (`--window-shots`, `--playground-shots`) never activate the app.
@MainActor
enum ShotRun {
    /// Before any shot window is made: an accessory app (no Dock icon, no menu bar) that nothing activates.
    static func prepare() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Shows a shot's window offscreen: ordered front without activating the app or making the window key.
    static func show(_ window: NSWindow) {
        // The shot loop closes the window while ARC owns it, and its close animation over-released it (a crash that
        // cut a run with several shots after the first).
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
    }
}

@MainActor
enum AppWindowShots {
    struct Shot {
        let name: String
        /// Resolved against the demo data when the shot is made.
        let destination: (Store) -> AppDestination
        var sidebarHidden = false
        var size = CGSize(width: 1280, height: 800)
        /// Sets the Router's composer up (a draft with a pill in it).
        var compose: ((RouterModel, Store) -> Void)?
        /// Prepares a tool page or stateful overlay for this shot.
        var prepare: ((Store) -> Void)? = nil
        /// The window's look; nil follows the Mac.
        var appearance: NSAppearance.Name?
        /// Opens the ⌘K palette over the window.
        var palette: PaletteShot?
        /// A view drawn on its own in the window instead of the app (for what the app's pages don't show by themselves).
        var standalone: ((Store, RouterModel) -> AnyView)?
    }

    /// How a shot opens the palette: with a query typed, on the first row's actions page, on fixture items rather than the
    /// demo data's.
    struct PaletteShot {
        var query = ""
        var actions = false
        var fixture = false
    }

    static let catalog: [Shot] = [
        Shot(name: "category") { $0.shownCategories[0].id.asCategory },
        Shot(name: "reviews") { store in store.shownCategories.first { $0.name.contains("Review") }?.id.asCategory ?? .done },
        Shot(name: "ci") { store in store.shownCategories.first(where: \.isCI)?.id.asCategory ?? .done },
        Shot(name: "done") { _ in .done },
        Shot(name: "computers", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
        }),
        Shot(name: "computers-keychain", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            (store.engineClient as? MockEngineClient)?.denyCredentials()
            Task { await store.computers.refreshKeychainStatus() }
        }),
        Shot(name: "computer-secure-token-note", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .overview
            (store.engineClient as? MockEngineClient)?.setComputerNote(
                "This imported computer has no SecureToken. It works normally, but it cannot turn on FileVault or change its password the SecureToken way.",
                for: MockEngineClient.devID)
        }),
        Shot(name: "computers-remote", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            (store.engineClient as? MockEngineClient)?.connectDemoRemoteDevice()
        }),
        Shot(name: "computer-detail-remote", destination: { _ in
            .computerDetail(GuestReference(deviceId: MockEngineClient.remoteDeviceID, computerId: MockEngineClient.devID))
        }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .overview
            (store.engineClient as? MockEngineClient)?.connectDemoRemoteDevice()
        }),
        Shot(name: "computer-files-remote", destination: { _ in
            .computerDetail(GuestReference(deviceId: MockEngineClient.remoteDeviceID, computerId: MockEngineClient.linuxID))
        }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .files
            (store.engineClient as? MockEngineClient)?.connectDemoRemoteDevice()
        }),
        Shot(name: "computer-queue", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            let entry = OperationQueueEntry(id: 42, jobId: "job:queued-macos", label: "Create macOS computer",
                                            kind: "computerConfiguration", computerId: MockEngineClient.devID,
                                            computerName: "dev", sinceMs: 1, cancellable: true, blockedByHidden: false)
            (store.engineClient as? MockEngineClient)?.operationQueue = OperationsList(running: [], waiting: [entry],
                                                                                       unacknowledgedJobIds: [])
        }),
        Shot(name: "computer-detail", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
        }),
        Shot(name: "computer-overview", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .overview
        }),
        Shot(name: "computer-agent-tools", destination: { _ in .computerDetail(.thisMac(MockEngineClient.linuxID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .overview
            (store.engineClient as? MockEngineClient)?.mockAgentTools[MockEngineClient.linuxID] = MockEngineClient.agentTools(.outdated)
        }),
        Shot(name: "computer-files", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .files
        }),
        Shot(name: "computer-network", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .network
        }),
        Shot(name: "computer-access", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .access
        }),
        Shot(name: "computer-activity", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .activity
        }),
        Shot(name: "computer-storage", destination: { _ in .computerDetail(.thisMac(MockEngineClient.devID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.selectedDetailSection = .storage
            let destination = "/Users/fjord/Exports"
            let archive = SiloWireArchive(archivePath: destination + "/dev.silo-backup",
                completedLabel: "Exported dev", computers: ["dev"], destination: destination,
                name: "dev.silo-backup", size: "1.2 GB")
            let operation = SiloWireOperationClass(archive: archive, kind: .result, operation: .backup,
                runningNames: ["dev"], detail: "The archive is ready.", message: "The archive is ready.",
                outcome: .success, title: "Export complete")
            let exports = SiloWireBackupState(archives: [archive], availability: .available,
                destination: destination, operation: operation, operationId: "export-shot",
                resultUnseen: true, snapshotId: "export-shot")
            (store.engineClient as? MockEngineClient)?.mockExportState = exports
            store.computers.exportState = exports
        }),
        Shot(name: "computer-viewer", destination: { _ in .computerDetail(.thisMac(MockEngineClient.linuxID)) }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.pendingViewer = SiloWireViewerOpenResult(connectionId: "viewer-shot",
                cookie: SiloWireViewerCookie(domain: "127.0.0.1", httpOnly: true, name: "silo-viewer", path: "/", value: "demo"),
                initScript: "", name: "linux-1", url: "http://127.0.0.1:5099/")
        }),
        Shot(name: "computer-create-linux", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.createSheetKind = .linux
            store.computers.isCreatePresented = true
        }),
        Shot(name: "computer-create-macos", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            store.computers.createSheetKind = .macos
            store.computers.isCreatePresented = true
        }),
        Shot(name: "settings-computers", destination: { _ in .settings }, size: CGSize(width: 1280, height: 1600), prepare: { store in
            store.setTool(.computers, on: true)
            let settings = SiloWireSettingsSnapshot(onboardingDraft: .null, revision: 1,
                settings: SiloWireSettingsValues(automaticCheckpointRetentionCount: 3,
                    startComputersAtLaunch: true, startupComputerIds: [MockEngineClient.devID]), writeProtected: false)
            (store.engineClient as? MockEngineClient)?.settingsSnapshot = settings
            store.computers.engineSettings = settings
            let device = SiloWireDevice(address: "dev@studio.local", id: "device-shot", name: "Studio Mac")
            (store.engineClient as? MockEngineClient)?.connectedDevices = [device]
            store.computers.connectionsStatus = SiloWireConnectionsStatus(address: "dev@studio.local", addresses: [],
                deviceId: "local-shot", enabled: true, name: "Fjord Mac")
            store.computers.connectionDevices = [device]
            store.computers.connectionHealth = [device.id: SiloWireDeviceHealth(busy: false, connected: true,
                deviceId: device.id, lastSeen: "Just now")]
        }),
        Shot(name: "computers-quit-dialog", destination: { _ in .computers }, prepare: { store in
            store.setTool(.computers, on: true)
            if let prompt = ComputerQuitPrompt.make(inventory: MockEngineClient.demoInventory) {
                store.computers.presentQuitPrompt(prompt)
            }
        }),
        Shot(name: "router") { _ in .router },
        Shot(name: "palette", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot()),
        Shot(name: "palette-search", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot(query: "fix")),
        Shot(name: "palette-actions", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", actions: true)),
        Shot(name: "palette-router", destination: { _ in .router }, palette: PaletteShot()),
        Shot(name: "palette-fixture", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot(fixture: true)),
        Shot(name: "palette-fixture-search", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", fixture: true)),
        Shot(name: "palette-fixture-many", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "e", fixture: true)),
        Shot(name: "palette-fixture-actions", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", actions: true, fixture: true)),
        Shot(name: "router-placement-popover", destination: { _ in .router }, compose: { model, store in
            model.draft = "@lookout"
            model.caret = nil
        }, prepare: { store in
            store.routerPlacementShot = true
            guard let engine = store.engineClient as? MockEngineClient else { return }
            let ownerID = "shot-owner"
            engine.connectedDevices = [SiloWireDevice(address: "dev@example.test", id: ownerID, name: "Dev box")]
            let inventory = engine.inventory
            engine.ownerInventories[ownerID] = inventory
        }),
        Shot(name: "router-composing", destination: { _ in .router }, compose: { model, store in
            let folder = store.knownFolders.first { !$0.isEmpty } ?? "/Users/me/code/lookout"
            model.pointers = [.project(folder)]
            model.draft = "check the failing tests in \(MentionText.markString) and tell me what you find"
        }),
        // Typing paused: Jev's pick of where the draft goes is a ghost chip over the composer, its card marked on the page.
        Shot(name: "router-predicting", destination: { _ in .router }, compose: { model, store in
            guard let card = store.openRouterCards.first(where: { $0.kind == .question }) ?? store.openRouterCards.first else { return }
            model.draft = "use sqlite for now, and add an index on the user id"
            let target = "answer:\(card.id)"
            model.live.preview(.init(target: target, title: card.title, detail: store.routerDispatcher.describe(target, store: store),
                                     text: model.draft, mark: card.id))
            model.highlighted = card.id
        }),
        Shot(name: "router-history", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            store.router.cards = store.router.cards.map { var c = $0; if c.isOpen { c.addressedAt = Date(); c.addressedBy = .you }; return c }
            if let d = store.router.decisions.first(where: { !$0.links.changes.isEmpty }) { model.expanded.insert(d.id.uuidString) }
        }),
        // The Router page's card actions (archive, reopen, mute), done at once with Revert on their history cards.
        Shot(name: "router-actions", destination: { _ in .router }, size: CGSize(width: 820, height: 560), compose: { model, store in
            routerActions(store, model: model)
        }, appearance: .aqua, standalone: actionCards),
        Shot(name: "router-actions-dark", destination: { _ in .router }, size: CGSize(width: 820, height: 560), compose: { model, store in
            routerActions(store, model: model)
        }, appearance: .darkAqua, standalone: actionCards),
        Shot(name: "router-summary-history", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            store.router.cards = store.router.cards.map { var c = $0; if c.isOpen { c.addressedAt = Date(); c.addressedBy = .you }; return c }
            if let summary = store.router.summaries.last { model.expanded.insert(RouterPage.Entry.summary(summary).id) }
        }),
        // Four sessions working, each but the last with its summary under it, the last being summarized.
        Shot(name: "router-working-summaries", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            for id in ["local_demo-transfer", "local_demo-linux"] { store.claudeSessions[id]?.running = true }
            let rows = store.routerWorkingRows
            for row in rows.dropLast() where store.router.summaries.allSatisfy({ $0.sessionID != row.id }) {
                store.addSummary(RouterSummary(at: Date().addingTimeInterval(-60), text: RouterSummarizer.canned(store.summarySubject(row)),
                                               sessionID: row.id, title: row.session.title))
            }
            model.summarizer.runner = { _ in try await Task.sleep(for: .seconds(3600)); return "" }
            if let last = rows.last { model.summarizer.request(last.id, store: store) }
        }),
        // Every session with its two lines (RouterLife.swift): what it is about overall, and what its latest turn did.
        Shot(name: "router-session-lines", destination: { _ in .router }, size: CGSize(width: 1500, height: 1400), compose: { model, store in
            Demo.routerTriage(store)
            routerLines(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        Shot(name: "router-session-lines-narrow", destination: { _ in .router }, size: CGSize(width: 900, height: 1400), compose: { model, store in
            Demo.routerTriage(store)
            routerLines(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        Shot(name: "router-replying-history", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            store.router.cards = store.router.cards.map { var c = $0; if c.isOpen { c.addressedAt = Date(); c.addressedBy = .you }; return c }
            if let card = store.routerPage.history.last(where: { if case .card = $0 { true } else { false } }) {
                model.tap(card.id, store: store)
            }
        }),
        // A long Needs you: every open card six times over, so the zones would take the page.
        Shot(name: "router-many-needs", destination: { _ in .router }, compose: { _, store in manyNeeds(store) }),
        // A narrow window: Now and History one at a time, the switch and the sections' chips over them; then History.
        Shot(name: "router-narrow-now", destination: { _ in .router }, size: CGSize(width: 900, height: 1000), compose: { _, store in
            manyNeeds(store)
        }),
        Shot(name: "router-narrow-history", destination: { _ in .router }, size: CGSize(width: 900, height: 1000), compose: { model, store in
            manyNeeds(store)
            model.pane = .history
        }),
        // A card whose project label is far too long (a guest project's "name · SSH host · silo"): it truncates inside the card.
        Shot(name: "router-long-project", destination: { _ in .router }, size: CGSize(width: 1000, height: 420),
             compose: { _, store in longProjects(store) }),
        Shot(name: "router-long-project-narrow", destination: { _ in .router }, size: CGSize(width: 520, height: 420),
             compose: { _, store in longProjects(store) }),
        // Every section folded to its line, what it holds said on it.
        Shot(name: "router-folded", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            Demo.routerTriage(store)
            for zone in RouterZone.allCases { model.setFolded(zone, true) }
        }),
        // Every section open, Waiting and Working with them.
        Shot(name: "router-all-open", destination: { _ in .router }, size: CGSize(width: 1500, height: 1000), compose: { model, store in
            manyNeeds(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        // Jev's triage: an OK asked, a turn asking two questions, chips on the finished ones; and the sessions waiting.
        Shot(name: "router-triage-needs", destination: { _ in .router }, size: CGSize(width: 1280, height: 1400), compose: { model, store in
            Demo.routerTriage(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
            model.expandedNeed = store.router.cards.first { $0.kind == .asks }?.id
        }),
        Shot(name: "router-filter-solo", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            Demo.routerTriage(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
            model.filter.solo = [.needs, .working]
        }),
        Shot(name: "router-filter-mute", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            Demo.routerTriage(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
            model.filter.mute = [.working, .waiting]
        }),
        Shot(name: "router-triage-waiting", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            Demo.routerTriage(store)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        // A session going in circles in Needs you, one that builds on another's work ready to continue; then what came while
        // you were away at the top of Needs you.
        Shot(name: "router-jev-circles", destination: { _ in .router }, size: CGSize(width: 1280, height: 1400), compose: { model, store in
            Demo.routerJevAttention(store, away: false)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        Shot(name: "router-jev-away", destination: { _ in .router }, size: CGSize(width: 1280, height: 1400), compose: { model, store in
            Demo.routerJevAttention(store, away: true)
            for zone in RouterZone.allCases { model.setFolded(zone, false) }
        }),
        // Now as a canvas: each project a frame, its sessions grouped and joined to their groups by lines.
        // The Brief: the day written as prose, at rest, a highlight hovered, one opened, dark, narrow.
        Shot(name: "router-brief", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1420),
             compose: { model, store in Demo.routerDigest(store); model.pickBrief() }, appearance: .aqua),
        Shot(name: "router-brief-dark", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1420),
             compose: { model, store in Demo.routerDigest(store); model.pickBrief() }, appearance: .darkAqua),
        Shot(name: "router-brief-hover", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1420),
             compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.hovered = "/Users/me/code/silo#local_demo-silo-guest"
             }, appearance: .aqua),
        Shot(name: "router-brief-open", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1800),
             compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.open = "/Users/me/code/microsandbox#local_demo-api"
                 if let card = store.router.cards.first(where: { $0.sessionID == "local_demo-api" && $0.isOpen }) {
                     model.select(card.id, store: store, reveal: false)
                 }
             }, appearance: .aqua),
        Shot(name: "router-brief-narrow", destination: { _ in .router }, size: CGSize(width: 1000, height: 1640),
             compose: { model, store in Demo.routerDigest(store); model.pickBrief() }, appearance: .aqua),
        // The Brief's history beside it: the latest rewrite and your answer opened to their diffs.
        Shot(name: "router-brief-history", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.historyOpen = true
                 if let history = store.routerDigest?.history {
                     model.digest.expanded = [history[0].id, history[3].id]
                 }
             }, appearance: .aqua),
        Shot(name: "router-brief-history-dark", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.historyOpen = true
                 if let history = store.routerDigest?.history { model.digest.expanded = [history[1].id] }
             }, appearance: .darkAqua),
        // A message sent to a session, delivered, in the Brief's history among the rewrites, opened (the shape of a real send).
        Shot(name: "router-brief-history-sent", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.historyOpen = true
                 var sent = RouterDecision(at: Date().addingTimeInterval(-30),
                                           trigger: .you("@superradcompany/microsandbox#1739 apparently there are some conflicts in this PR, fix them"),
                                           decision: .init(target: "session “fix the merge conflicts in there” in modify-mounts", intent: "message", label: "reply"),
                                           outcome: .done)
                 sent.add(.sent(to: "fix the merge conflicts in there", text: "fix them", original: nil), session: "local_demo-transfer")
                 store.router.decisions.append(sent)
                 model.digest.expanded = [sent.id.uuidString]
             }, appearance: .aqua),
        // The history dragged wider, nothing opened in it.
        Shot(name: "router-brief-history-wide", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.digest.historyOpen = true
                 model.digest.historyWidth = 560
             }, appearance: .aqua),
        // Handled since the text was written: the release approved and the docs marked seen, checks before the rewrite.
        Shot(name: "router-brief-handled", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 for session in ["local_demo-release", "local_demo-transfer"] {
                     if let card = store.router.cards.last(where: { $0.sessionID == session && $0.isOpen }) {
                         store.setCardAddressed(card.id, true)
                     }
                 }
             }, appearance: .aqua),
        // Your latest messages under the sessions they went to: sending, delivered, working, and one that didn't go. A session
        // that replied has none (the theme fix), nor does one with only older words.
        Shot(name: "router-brief-sent", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief(); briefSent(store)
             }, appearance: .aqua),
        Shot(name: "router-brief-sent-dark", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1420), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief(); briefSent(store)
             }, appearance: .darkAqua),
        // A message that went to a session the Brief has no row for: its pill says where, then leaves.
        Shot(name: "router-brief-pill-sent", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1000), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief(); briefPillSent(store)
             }, appearance: .aqua),
        Shot(name: "router-brief-pill-sent-dark", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1600, height: 1000), compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief(); briefPillSent(store)
             }, appearance: .darkAqua),
        // No brief yet, the Router on: it is about to be written.
        Shot(name: "router-brief-empty", destination: { _ in .router }, sidebarHidden: true,
             size: CGSize(width: 1400, height: 800), compose: { model, store in
                 Demo.routerBusyDay(store); model.pickBrief()
             }, appearance: .aqua),
        Shot(name: "router-canvas-busy", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1000), compose: { model, store in
            Demo.routerBusyDay(store)
            model.pickCanvas()
        }, appearance: .aqua),
        Shot(name: "router-canvas", destination: { _ in .router }, size: canvasSize, compose: { model, _ in model.pickCanvas() },
             appearance: .aqua),
        Shot(name: "router-canvas-dark", destination: { _ in .router }, size: canvasSize, compose: { model, _ in model.pickCanvas() },
             appearance: .darkAqua),
        // Jev's triage on the canvas: an OK asked, a turn asking two questions (one answered), sessions waiting and one ready.
        Shot(name: "router-canvas-triage", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
        }, appearance: .aqua),
        // A card at the canvas's 420: its kind, Jev's chips, the approval's tint and how many questions are left.
        Shot(name: "router-canvas-card420", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            if let i = store.router.cards.firstIndex(where: { $0.sessionID == "local_demo-api" && $0.isOpen }),
               let asks = store.router.cards[i].asks {
                store.router.cards[i].left = Array(asks.dropFirst().map(\.question))
                store.router.cards[i].total = asks.count
            }
            model.pickCanvas()
            // microsandbox's frame at full size.
            look(model, at: "microsandbox")
        }, appearance: .darkAqua),
        Shot(name: "router-canvas-narrow", destination: { _ in .router }, size: CGSize(width: 1000, height: 760), compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
        }, appearance: .aqua),
        // A card opened in place on the canvas: the question's form, the plan, a working session's summaries and tasks, a
        // finished turn worth a look, a finished one's details; the canvas gone to it.
        Shot(name: "router-canvas-open-needs", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            model.pickCanvas()
            if let card = store.router.cards.first(where: { $0.kind == .question && $0.isOpen }) {
                model.select(card.id, store: store)
            }
        }, appearance: .aqua),
        Shot(name: "router-canvas-open-plan", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            model.pickCanvas()
            if let card = store.router.cards.first(where: { $0.kind == .plan && $0.isOpen }) { model.select(card.id, store: store) }
        }, appearance: .darkAqua),
        Shot(name: "router-canvas-open-working", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            model.pickCanvas()
            model.canvas.openRow = RouterModel.workingID("local_demo-ci")
        }, appearance: .aqua),
        Shot(name: "router-canvas-open-notes", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            if let card = model.zones(store).notes.first { model.select(card.id, store: store) }
        }, appearance: .aqua),
        Shot(name: "router-canvas-open-waiting", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            if let card = model.zones(store).ready.first { model.select(card.id, store: store) }
        }, appearance: .darkAqua),
        // The chips: only Needs you and Working shown, the other groups gone from their frames in place.
        Shot(name: "router-canvas-filter", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            model.filter.solo = [.needs, .working]
        }, appearance: .aqua),
        Shot(name: "router-canvas-filter-solo", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            model.filter.solo = [.working]
            model.filter.mute = [.needs]
        }, appearance: .darkAqua),
        Shot(name: "router-canvas-filter-mute", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            model.filter.mute = [.working, .waiting]
        }, appearance: .aqua),
        // The frames of finished sessions only, opened from their fold.
        Shot(name: "router-canvas-done-open", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            model.pickCanvas()
            for folder in model.canvasFolders(store, page: model.zones(store)) where folder.doneOnly {
                model.canvas.folderFolds[folder.key] = false
            }
        }, appearance: .darkAqua),
        // The canvas at full size on one frame, the rest of the ground round it.
        Shot(name: "router-canvas-zoom", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            look(model, at: "lcu")
        }, appearance: .aqua),
        Shot(name: "router-canvas-zoom-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            Demo.routerTriage(store)
            model.pickCanvas()
            look(model, at: "lcu")
        }, appearance: .darkAqua),
        // The history's panel open over the canvas's right side.
        Shot(name: "router-canvas-history", destination: { _ in .router }, size: canvasSize, compose: { model, _ in
            model.pickCanvas()
            model.show(.history)
        }, appearance: .aqua),
        Shot(name: "router-canvas-history-dark", destination: { _ in .router }, size: canvasSize, compose: { model, _ in
            model.pickCanvas()
            model.show(.history)
        }, appearance: .darkAqua),
        // The frames moved by hand: in a row, staggered, Reset layout among the buttons.
        Shot(name: "router-canvas-arranged", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            arranged(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-arranged-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            arranged(model, store)
        }, appearance: .darkAqua),
        // A frame's Done group of mixed lines (one unread, short and long words): their caret, age and Open in Claude in the
        // same columns.
        Shot(name: "router-canvas-done-lines", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            let closed = store.router.cards.filter { !$0.isOpen }
            let folder = store.router.cards.first { $0.isOpen && $0.folder != nil }?.folder
            store.router.cards += (closed + closed).enumerated().map { i, card in
                var card = card
                card.id += "#line\(i)"
                card.sessionID += "#line\(i)"
                card.folder = folder
                if i == 0 { card.unread = true }
                return card
            }
            model.pickCanvas()
            // Opened past its first few: "Show less" under them.
            if let folder { model.canvas.expandedMore.insert("\(folder)#done") }
        }, appearance: .aqua),
        // Frames sized by hand: one made shorter than what it holds (its body scrolled, faded where it is cut), one at the
        // narrowest (its cards' chips and kinds' names gone, the groups named by their glyphs).
        Shot(name: "router-canvas-sizes", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            sized(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-sizes-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            sized(model, store)
        }, appearance: .darkAqua),
        // A message to a card off the view: flown to the edge, its marker there pointing the way.
        Shot(name: "router-canvas-edge", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            edge(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-edge-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            edge(model, store)
        }, appearance: .darkAqua),
        // A search on the canvas: only the frames with a match.
        Shot(name: "router-canvas-search", destination: { _ in .router }, size: canvasSize, compose: { model, _ in
            model.pickCanvas()
            model.search.query = "lcu"
        }, appearance: .aqua),
        // Your messages over the composer: one being sent, with what the Router is doing, and one it asks you about.
        Shot(name: "router-canvas-pending", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            pending(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-pending-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            pending(model, store)
        }, appearance: .darkAqua),
        // The same ask when the checks are in doubt: its buttons are verbs on their targets (stop and send, archive, send to…).
        Shot(name: "router-canvas-ask-typed", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            typedAsk(store)
            pending(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-ask-typed-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            typedAsk(store)
            pending(model, store)
        }, appearance: .darkAqua),
        Shot(name: "router-canvas-pending-pill", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            pending(model, store, asks: false)
        }, appearance: .aqua),
        Shot(name: "router-canvas-pending-pill-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            pending(model, store, asks: false)
        }, appearance: .darkAqua),
        Shot(name: "router-canvas-pending-pill-narrow", destination: { _ in .router }, size: CGSize(width: 1000, height: 760), compose: { model, store in
            pending(model, store, asks: false)
        }, appearance: .aqua),
        Shot(name: "router-list-pending-pill", destination: { _ in .router }, compose: { model, store in
            pending(model, store, asks: false)
            model.layout = .list
        }, appearance: .aqua),
        Shot(name: "router-canvas-failed-pill", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            pending(model, store, asks: false)
            guard let id = store.routerDispatcher.flying.first,
                  let i = store.router.decisions.firstIndex(where: { $0.id == id }) else { return }
            store.router.decisions[i].add(.failed("the session's inbox is closed"))
            store.router.decisions[i].outcome = .done
            store.routerDispatcher.preview(flying: [id])
        }, appearance: .aqua),
        // The message being sent goes to its session once the canvas is up, held mid-arc; an earlier one landed on a card.
        Shot(name: "router-canvas-flight", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            flight(model, store)
        }, appearance: .aqua),
        Shot(name: "router-canvas-flight-dark", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            flight(model, store)
        }, appearance: .darkAqua),
        // One message that went to several places, its history entry open with a line for each part: sent (with its Cancel),
        // answered, started, held (Send now, Don't send), failed and cancelled.
        Shot(name: "router-split-history", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            splitHistory(model, store)
        }, appearance: .aqua),
        Shot(name: "router-split-history-dark", destination: { _ in .router }, size: CGSize(width: 1280, height: 1000), compose: { model, store in
            splitHistory(model, store)
        }, appearance: .darkAqua),
        // A message that divided into three, a pill for each part over the composer.
        Shot(name: "router-list-split-pills", destination: { _ in .router }, compose: { model, store in
            splitPills(store)
            model.layout = .list
        }, appearance: .aqua),
        // The same, two parts held halfway to the two cards they go to.
        Shot(name: "router-canvas-split-flight", destination: { _ in .router }, size: canvasSize, compose: { model, store in
            splitFlight(model, store)
        }, appearance: .aqua),
        // Typing paused with Jev's read for several places: the divider's parts under the composer, each place with its words,
        // the last one held for another place's answer.
        Shot(name: "router-split-live", destination: { _ in .router }, compose: { model, store in
            splitLive(model, store)
        }, appearance: .aqua),
        Shot(name: "router-split-live-dark", destination: { _ in .router }, compose: { model, store in
            splitLive(model, store)
        }, appearance: .darkAqua),
        // The same, while the divider is still being asked.
        Shot(name: "router-split-dividing", destination: { _ in .router }, compose: { model, store in
            model.draft = "rerun the build, add the page, and mute notifications for an hour"
            model.live.previewDividing()
        }, appearance: .aqua),
        // Two sessions ⌘-clicked on the Brief: marked in the text, a chip each over the composer, the message going to both whole.
        Shot(name: "router-brief-recipients", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 1600, height: 1420),
             compose: { model, store in
                 Demo.routerDigest(store); model.pickBrief()
                 model.live.recipients = ["session:local_demo-silo-guest", "session:local_demo-api"]
                 model.draft = "pull main before you go on"
             }, appearance: .aqua),
        Shot(name: "settings") { _ in .settings },
        Shot(name: "categories") { _ in .categories },
        Shot(name: "snippets") { _ in .snippets },
        // Two sections, one folded: its row with the counts added up and its caret turned, its categories gone from the sidebar.
        Shot(name: "categories-sections", destination: { _ in .categories }, compose: { _, store in
            let builds = store.createSection(name: "Builds")
            for c in store.categories where c.isCI { store.moveCategory(c.id, toSection: builds.id) }
            store.toggleCollapsed(builds.id)
        }),
        Shot(name: "category-collapsed", destination: { $0.shownCategories[0].id.asCategory }),
        Shot(name: "router-collapsed", destination: { _ in .router }),
        Shot(name: "router-760", destination: { _ in .router }, size: CGSize(width: 760, height: 1000)),
        Shot(name: "router-collapsed-760", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 760, height: 1000)),
        Shot(name: "category-narrow", destination: { $0.shownCategories[0].id.asCategory }, size: CGSize(width: 1000, height: 640)),
    ]

    private static let canvasSize = CGSize(width: 1440, height: 900)

    /// The canvas at full size on the frame of the project named `name`, once the frames are drawn.
    private static func look(_ model: RouterModel, at name: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let key = model.canvas.frameRects.keys.first(where: { URL(fileURLWithPath: $0).lastPathComponent == name }) else { return }
            model.canvas.look(at: key)
        }
    }

    /// Frames moved and resized by hand, as drags would leave them: one widened, one narrowed, one dropped over another
    /// (the last moved on top), one far off on its own; Done's lines opened.
    private static func arranged(_ model: RouterModel, _ store: Store) {
        Demo.routerTriage(store)
        model.pickCanvas()
        let folders = model.canvasFolders(store, page: model.zones(store))
        for folder in folders where folder.doneOnly { model.canvas.folderFolds[folder.key] = false }
        let spots: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 900, y: 40), CGPoint(x: 300, y: 330),
                                CGPoint(x: 1500, y: 900), CGPoint(x: -200, y: 700)]
        var positions: [String: CGPoint] = [:]
        for (i, folder) in folders.enumerated() { positions[folder.key] = spots[i % spots.count] }
        model.canvas.positions = positions
        if folders.count > 1 {
            model.canvas.sizes[folders[0].key] = CGSize(width: 820, height: 0)
            model.canvas.sizes[folders[1].key] = CGSize(width: CanvasMetrics.minFrameWidth, height: 0)
        }
        if folders.count > 2 { model.canvas.stack = [folders[2].key] }
    }

    /// Frames sized by hand: the busiest made short and scrolled a little, the next at the narrowest, the rest packed.
    private static func sized(_ model: RouterModel, _ store: Store) {
        Demo.routerTriage(store)
        model.pickCanvas()
        let folders = model.canvasFolders(store, page: model.zones(store))
        guard folders.count > 2 else { return }
        model.canvas.positions = [folders[0].key: .zero, folders[1].key: CGPoint(x: 620, y: 0),
                                  folders[2].key: CGPoint(x: 1000, y: 0)]
        model.canvas.sizes = [folders[0].key: CGSize(width: 560, height: 260),
                              folders[1].key: CGSize(width: CanvasMetrics.minFrameWidth, height: 0)]
        model.canvas.scroll(folders[0].key).offset = 70
    }

    /// The demo's ask with typed options (`RouterActionChecks`): the checks name a stop, an archive and a send.
    private static func typedAsk(_ store: Store) {
        guard let ask = store.routerDispatcher.askBacks.first else { return }
        var acts: [RouterAct] = [.interrupt(session: "local_demo-ci"), .stop(session: "local_demo-ci")]
        if let card = store.routerShownOpenCards.first(where: { $0.kind == .done }) { acts.append(.archive(card: card.id)) }
        acts += [.say(session: "local_demo-ci"), .say(session: "local_demo-transfer")]
        var typed = ask
        typed.message = "stop the CI run and use the staging config"
        typed.options = acts.compactMap { store.routerDispatcher.option($0.target, store: store, verb: true) }.prefix(4).map { $0 }
        typed.suggestion = typed.options.first?.target
        if let i = store.router.decisions.firstIndex(where: { $0.id == ask.id }) {
            store.router.decisions[i].trigger = .you(typed.message)
        }
        store.routerDispatcher.preview(ask: typed, progress: store.routerDispatcher.progress)
    }

    /// Messages you sent, each in the state of one line under its session in the Brief.
    private static func briefSent(_ store: Store) {
        let now = Date()
        func send(_ session: String, _ words: String, _ state: DeliveryOperation.State, running: Bool? = nil, replied: Bool = false,
                  reason: String? = nil, ago: TimeInterval = 40) {
            let at = now.addingTimeInterval(-ago)
            var entry = RouterDecision(at: at, trigger: .you(words), decision: .init(target: session, intent: "message", label: "reply"),
                                       outcome: .done)
            entry.add(.sent(to: session, text: words, original: nil), session: session)
            store.router.decisions.append(entry)
            store.noteOperation(DeliveryOperation(nonce: UUID().uuidString, target: session, kind: .message, bodyHash: "", state: state,
                                                  decisionID: entry.id, session: session, to: session, createdAt: at, updatedAt: at))
            guard var live = store.claudeSessions[session] else { return }
            if let running { live.running = running }
            if replied { live.lastActivity = now }
            store.claudeSessions[session] = live
        }
        send("local_demo-lookout", "run the whole suite once more before you tag it", .sent, running: true)
        send("local_demo-api", "per API key, and 100 a minute is fine", .waiting, ago: 2)
        send("local_demo-bump", "ping me when CI is green", .sent, running: false)
        send("local_demo-zig", "put it in a new file, fs/walk_test.zig", .unsure, ago: 300)
        send("local_demo-theme", "merge it", .sent, running: false, replied: true, ago: 120)
    }

    /// The demo's message being sent, then sent to its session a moment later.
    private static func briefPillSent(_ store: Store) {
        let runs = store.routerDispatcher.progress
        store.routerDispatcher.preview(ask: nil, progress: runs, flying: Array(runs.keys))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard let i = store.router.decisions.lastIndex(where: { store.routerDispatcher.flying.contains($0.id) && $0.outcome == .pending }) else { return }
            var decisions = store.router.decisions
            decisions[i].add(.sent(to: "Repository ownership transfer setup", text: decisions[i].triggerText, original: nil),
                             session: "local_demo-transfer")
            decisions[i].outcome = .done
            decisions[i].decision.targetID = "session:local_demo-transfer"
            store.router.decisions = decisions
        }
    }

    private static func pending(_ model: RouterModel, _ store: Store, asks: Bool = true) {
        model.pickCanvas()
        let ask = asks ? store.routerDispatcher.askBacks.first : nil
        let runs = store.routerDispatcher.progress
        store.routerDispatcher.preview(ask: ask, progress: runs, flying: Array(runs.keys) + (ask.map { [$0.id] } ?? []))
    }

    /// The demo's message going to a card off the view: it flies to the viewport's edge, towards it, where its marker is.
    private static func edge(_ model: RouterModel, _ store: Store) {
        flight(model, store)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            // The camera far right of the frames, so every card is off the view, to the left.
            let bounds = model.canvas.contentBounds
            model.canvas.camera.moved = true
            model.canvas.camera.transform = CanvasTransform(origin: CGPoint(x: -bounds.maxX - 200, y: 120), scale: 1)
            try? await Task.sleep(for: .milliseconds(500))
            if let flight = model.flights.flights.first {
                // Complete the shared flight: its own destination supplies the matching marker and landed message.
                model.flights.land(flight.id, store: store)
            }
        }
    }

    /// The demo's message under way sent to its session a moment after the canvas is drawn, its flight held halfway; and
    /// "You: …" on the plan card, as an earlier message left it.
    private static func flight(_ model: RouterModel, _ store: Store) {
        pending(model, store)
        model.canvas.freezeFlight = 0.5
        model.flights.freezeFlight = 0.5
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if let card = store.router.cards.first(where: { $0.kind == .plan && $0.isOpen }) {
                model.canvas.land("run it on the lab box first", on: card.id)
            }
            guard let i = store.router.decisions.lastIndex(where: { store.routerDispatcher.flying.contains($0.id) && $0.outcome == .pending
                                                                    && !store.routerDispatcher.askBacks.map(\.id).contains($0.id) }) else { return }
            var decisions = store.router.decisions
            let text = decisions[i].triggerText
            decisions[i].add(.sent(to: "Repository ownership transfer setup", text: text, original: nil), session: "local_demo-transfer")
            decisions[i].outcome = .done
            decisions[i].decision.targetID = "session:local_demo-transfer"
            store.router.decisions = decisions
        }
    }

    /// Logs a message that divided into `parts` (its words, the place each went to as `session:<id>`, `answer:<card>` or
    /// `new:<folder>`) and returns the parts' ids.
    @discardableResult
    private static func divided(_ store: Store, _ message: String, at: Date, _ parts: [(text: String, place: String, waitsFor: String?)])
        -> (entry: UUID, parts: [UUID]) {
        var entry = RouterDecision(at: at, trigger: .you(message))
        let ids = entry.divide(into: parts.map {
            RouterDecision.Part(text: $0.text, place: $0.place, waitsFor: $0.waitsFor, decision: .init(intent: "message"))
        })
        store.router.decisions.append(entry)
        return (entry.id, ids)
    }

    /// One message to six places, each part at a different point: the history entry open, and the first part open with its Cancel.
    private static func splitHistory(_ model: RouterModel, _ store: Store) {
        let now = Date()
        let card = store.router.cards.first { $0.sessionID == "local_demo-linux" }?.id ?? ""
        let (entry, ids) = divided(store, "rerun the build, approve the Linux plan, add a plugin page in lcu, tell the transfer to use the version CI "
            + "picked, rebase the games, and drop the calculator run", at: now.addingTimeInterval(-90), [
                (text: "rerun the build", place: "session:local_demo-ci", waitsFor: nil),
                (text: "approve the plan", place: "answer:\(card)", waitsFor: nil),
                (text: "add a plugin page", place: "new:/Users/demo/lcu", waitsFor: nil),
                (text: "use the version CI picked", place: "session:local_demo-transfer", waitsFor: "session:local_demo-ci"),
                (text: "rebase the games", place: "session:local_demo-games", waitsFor: nil),
                (text: "drop the calculator run", place: "session:local_demo-calc", waitsFor: nil),
            ])
        func title(_ session: String) -> String { store.claudeSessions[session]?.title ?? session }
        func delivered(_ session: String, _ cancelled: RouterDecision.Cancelled? = nil) -> RouterDecision.Delivered {
            RouterDecision.Delivered(session: session, cli: "cli-" + session, nonce: UUID().uuidString, at: now.addingTimeInterval(-80),
                                     turns: store.claudeSessions[session]?.completedTurns ?? 0, busy: false, abortable: true,
                                     cancelled: cancelled)
        }
        func sent(_ n: Int, _ session: String, cancelled: RouterDecision.Cancelled? = nil) {
            store.updateDecision(ids[n]) { part in
                part.decision.targetID = "session:" + session
                part.add(.sent(to: title(session), text: part.triggerText, original: nil), session: session)
                if let cancelled { part.add(.cancelled(cancelled)) }
                part.delivered = delivered(session, cancelled)
                part.outcome = .done
            }
        }
        sent(0, "local_demo-ci")
        store.updateDecision(ids[1]) { part in
            part.decision.targetID = "answer:" + card
            part.add(.answered(card: card), card: card)
            part.outcome = .done
        }
        store.updateDecision(ids[2]) { part in
            part.decision.targetID = "new:/Users/demo/lcu"
            part.add(.started(session: nil, project: "lcu", model: nil, effort: nil))
            part.outcome = .done
        }
        store.updateDecision(ids[3]) { $0.decision.targetID = "session:local_demo-transfer" }
        store.routerDispatcher.held[ids[3]] = "waits for session “\(title("local_demo-ci"))” in microsandbox; it isn't sent unless you "
            + "send it, and is dropped after 30 minutes"
        store.updateDecision(ids[4]) { part in
            part.decision.targetID = "session:local_demo-games"
            part.add(.failed("not delivered (the session isn't open in Claude)"))
            part.outcome = .done
        }
        sent(5, "local_demo-calc", cancelled: .aborted)
        model.pane = .history
        model.expanded.insert(entry.uuidString)
        model.expanded.insert(ids[0].uuidString)
    }

    /// A draft for three places, the divider's parts shown under the composer, one of them waiting for another's answer.
    private static func splitLive(_ model: RouterModel, _ store: Store) {
        let text = "rerun the build, tell the transfer to use the version CI picked, and mute notifications for an hour"
        model.draft = text
        model.live.preview(division: RouterDivision(text: text, parts: [
            RouterDivider.Part(target: "session:local_demo-ci", text: "rerun the build", waitsFor: nil),
            RouterDivider.Part(target: "session:local_demo-transfer", text: "use the version CI picked", waitsFor: "session:local_demo-ci"),
            RouterDivider.Part(target: "change_fjord", text: "mute notifications for an hour", waitsFor: nil),
        ]), store: store)
    }

    /// A message divided into three, its parts being sent: a pill each over the composer, two placed and one still looking.
    private static func splitPills(_ store: Store) {
        let (_, ids) = divided(store, "rerun the build, add the page, and mute notifications for an hour", at: Date(), [
            (text: "rerun the build", place: "session:local_demo-ci", waitsFor: nil),
            (text: "add the page", place: "session:local_demo-transfer", waitsFor: nil),
            (text: "mute notifications for an hour", place: "change_fjord", waitsFor: nil),
        ])
        store.updateDecision(ids[0]) { $0.decision.targetID = "session:local_demo-ci" }
        store.updateDecision(ids[1]) { $0.decision.targetID = "session:local_demo-transfer" }
        store.routerDispatcher.preview(progress: Dictionary(uniqueKeysWithValues: ids.map { ($0, "sending") }), flying: ids)
    }

    /// Two parts of a message flying to the cards they went to, held halfway.
    private static func splitFlight(_ model: RouterModel, _ store: Store) {
        let (_, ids) = divided(store, "tell the transfer to remove the old remote, and CI to rerun", at: Date(), [
            (text: "remove the old remote", place: "session:local_demo-transfer", waitsFor: nil),
            (text: "rerun", place: "session:local_demo-ci", waitsFor: nil),
        ])
        model.pickCanvas()
        model.canvas.freezeFlight = 0.5
        model.flights.freezeFlight = 0.5
        store.routerDispatcher.preview(progress: Dictionary(uniqueKeysWithValues: ids.map { ($0, "sending") }), flying: ids)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            for (id, session) in zip(ids, ["local_demo-transfer", "local_demo-ci"]) {
                store.updateDecision(id) { part in
                    part.decision.targetID = "session:" + session
                    part.add(.sent(to: store.claudeSessions[session]?.title ?? session, text: part.triggerText, original: nil), session: session)
                    part.outcome = .done
                }
            }
        }
    }

    /// Every open card six times over, so the zones would take the page.
    private static func longProjects(_ store: Store) {
        store.router.cards = store.router.cards.map {
            var c = $0
            if c.isOpen { c.folder = "/Users/demo/e2e-proj-with-a-very-long-guest-project-name · SSH e2e-relay-with-a-long-host-name · silo" }
            return c
        }
    }

    /// The card-action changes as the history's run details draw them (`ChangeCard`, one under the other).
    private static func actionCards(_ store: Store, _ model: RouterModel) -> AnyView {
        let changes = store.router.changes.filter { if case .cardAction = $0.patch { true } else { false } }
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            ForEach(changes) { ChangeCard(change: $0, store: store) }
        }
        .environment(\.cdsColumnWidth, 780)
        .padding(20)
        .frame(width: 820, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CDS.Surface.s1))
    }

    /// An archive, a reopen and a mute as the page's buttons do them: applied, in the history with Revert.
    /// The demo's sessions with demo lines: a whole-life line each, and a latest-turn line for most.
    private static func routerLines(_ store: Store) {
        for id in ["local_demo-transfer", "local_demo-linux"] { store.claudeSessions[id]?.running = true }
        let whole = [
            "local_demo-lookout": "Adding completion notifications to Fjord: banners when a session finishes, then tuning when they stay quiet.",
            "local_demo-ci": "Finding why the sandbox tests fail only in CI, and getting the pipeline green again.",
            "local_demo-transfer": "Moving the repository to a new owner: remotes, branch protections and the old fork's clean-up.",
            "local_demo-linux": "Running LCU's JavaScript sandbox on Linux guests, starting from the storage layout.",
            "local_demo-silo-guest": "Rebasing the guest agent branch onto main before the v0.9 release.",
            "local_demo-silo-rel": "Cutting Silo v0.9: changelog, signing, and waiting on the release workflow.",
            "local_demo-site-copy": "Writing the landing page copy: headline options, then the sections under it.",
            "local_demo-zig": "Making std.fs walk symlinks, with tests for the edge cases.",
            "local_demo-release": "Shipping Fjord 2.4: the build, the release notes and the App Store submission.",
            "local_demo-api": "Adding a rate limiter to the public API, per key, with a test for the burst case.",
            "local_demo-calc": "Reading the calculator's display reliably in LCU, so its tests can assert on it.",
            "local_demo-theme": "Fixing the Router's theme so dark and Claude themes stay legible.",
            "local_demo-login": "Fixing the login redirect that drops the return URL, then waiting on CI.",
            "local_demo-docs": "Redesigning the docs site: navigation, search and the getting-started page.",
            "local_demo-schema": "Migrating the schema in steps without downtime.",
            "local_demo-bump": "Bumping the SDK across the packages, waiting on CI for the result.",
        ]
        let latest = [
            "local_demo-lookout": "Wired the badge to the unread count and started the test suite.",
            "local_demo-ci": "Fixed the flaky sandbox test; CI is green again.",
            "local_demo-transfer": "Added the new remote and asked who should own the old fork.",
            "local_demo-silo-guest": "Rebased cleanly, but needs your OK to force-push.",
            "local_demo-silo-rel": "Pushed the tag; the release workflow is running.",
            "local_demo-site-copy": "Wrote three headline options for the landing page.",
            "local_demo-zig": "Added the symlink walk and one test; asks where the second belongs.",
            "local_demo-release": "Built 2.4 and wrote the notes; needs your OK to publish.",
            "local_demo-api": "Wrote the limiter and asks whether the limit is per key or per IP.",
            "local_demo-calc": "Couldn't read the display after three tries.",
            "local_demo-theme": "Fixed the contrast and opened a PR.",
            "local_demo-login": "Fixed the redirect and pushed; CI is running.",
            "local_demo-docs": "Rebuilt the navigation; says it works but didn't run the site.",
        ]
        var state = store.router
        for (id, text) in whole {
            var life = SessionLife(first: 3)
            life.open(text, at: Date().addingTimeInterval(-7200))
            if let line = latest[id] { life.add(RouterLeaf(turn: 4, at: Date().addingTimeInterval(-300), text: line)) }
            state.lives[id] = life
        }
        store.router = state
    }

    private static func routerActions(_ store: Store, model: RouterModel) {
        Demo.routerBusyDay(store)
        store.router.enabled = true
        // A card archived a few minutes ago, to reopen.
        let archived = "local_demo-silo-rel#t\(store.claudeSessions["local_demo-silo-rel"]?.completedTurns ?? 0)"
        if let i = store.router.cards.firstIndex(where: { $0.id == archived }) {
            store.router.cards[i].addressedAt = Date().addingTimeInterval(-300)
            store.router.cards[i].addressedBy = .you
        }
        if let card = store.shownRouterCards.first(where: { $0.title.contains("std.fs") }) {
            store.act(.archive(card: card.id, title: card.title, project: store.routerProject(card).name))
        }
        if let card = store.router.cards.first(where: { $0.id == archived }) {
            store.act(.reopen(card: card.id, title: card.title, project: store.routerProject(card).name))
        }
        if let project = store.routerProjects().first(where: { $0.name == "dotfiles" }) {
            store.act(.mute(project: project.key, name: project.name, muted: true))
        }
        if let run = store.router.decisions.last(where: { !$0.links.changes.isEmpty }) { model.expanded.insert(run.id.uuidString) }
        // The list layout draws no page body in shots; the canvas layout's history panel shows the same history.
        model.layout = .canvas
        model.pane = .history
    }

    private static func manyNeeds(_ store: Store) {
        let open = store.router.cards.filter(\.isOpen)
        store.router.cards += (1...5).flatMap { n in open.map { var c = $0; c.id += "#copy\(n)"; return c } }
    }

    /// `--window-shots <dir> [substring...]`.
    static func run(to dir: String) {
        let arguments = CommandLine.arguments
        let start = (arguments.firstIndex(of: "--window-shots") ?? 0) + 2
        let filters = Array(arguments.dropFirst(start).filter { !$0.hasPrefix("--") }).map { $0.lowercased() }
        let shots = catalog.filter { shot in filters.isEmpty || filters.contains { shot.name.contains($0) } }
        guard !shots.isEmpty else {
            print("No shot matches \(filters.joined(separator: ", ")). \(catalog.count) shots, e.g. \(catalog[0].name)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ShotRun.prepare()
        Task {
            for shot in shots {
                let window = open(shot)
                try? await Task.sleep(for: .seconds(2))
                capture(window, to: "\(dir)/window-\(shot.name).png")
                window.close()
            }
            print("\(shots.count) shots in \(dir)")
            exit(0)
        }
    }

    private static func open(_ shot: Shot) -> NSWindow {
        let store = Store()
        Demo.populate(store, .router)
        shot.prepare?(store)
        let navigator = AppNavigator(start: shot.destination(store), defaults: nil)
        let routerModel = RouterModel()
        // The list unless the shot picks the Brief or the canvas (most shots are of the list's cards).
        routerModel.layout = .list
        shot.compose?(routerModel, store)
        let hub = HubState()
        let palette = PaletteModel(store: store, navigator: navigator, routerModel: routerModel, hub: hub,
                                   sources: shot.palette?.fixture == true ? PaletteFixture.sources(store) : nil)
        if let open = shot.palette {
            palette.open()
            if !open.query.isEmpty { palette.setQuery(open.query) }
            if open.actions { palette.showActions() }
        }
        if let standalone = shot.standalone {
            let controller = NSHostingController(rootView: standalone(store, routerModel).column(shot.size.width))
            controller.sizingOptions = []
            let window = ShotWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.titled], backing: .buffered, defer: false)
            if let look = shot.appearance { window.appearance = NSAppearance(named: look) }
            window.contentViewController = controller
            window.setContentSize(shot.size)
            ShotRun.show(window)
            return window
        }
        let root = AppRootView(store: store, navigator: navigator, routerModel: routerModel, hub: hub, palette: palette,
                               checksClaudeCode: false,
                               sidebar: SidebarState(defaults: nil, collapsed: shot.sidebarHidden),
                               // Glass can't be captured: shots draw the opaque chrome, whatever the Mac's settings.
                               chrome: Chrome(mode: .opaque))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = ShotWindow(contentRect: NSRect(origin: .zero, size: shot.size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        AppWindowController.style(window)
        if let look = shot.appearance { window.appearance = NSAppearance(named: look) }
        window.contentViewController = controller
        window.setContentSize(shot.size)
        ShotRun.show(window)
        return window
    }

    /// The content as drawn (the title bar and its toolbar belong to the window server, which a CLI can't ask for the
    /// window without screen-recording permission).
    ///
    /// `cacheDisplay` of the whole window skips the content of every SwiftUI `ScrollView` (its document view is only drawn
    /// when asked for on its own), so the Router's cards were missing. Each scroll view's visible content is drawn on its
    /// own and composited over the window, then the views stacked above that scroll view (the bar, the chips, the composer)
    /// again over it.
    private static func capture(_ window: NSWindow, to path: String) {
        let captureWindow = window.attachedSheet ?? window
        guard let view = captureWindow.contentView else { return }
        // The window server's picture first (it has every scroll view's content as shown); without one, the window drawn
        // here.
        if ShotCapture.writeWindowPicture(view, to: path) { return }
        view.layoutSubtreeIfNeeded()
        guard let base = snapshot(view, view.bounds) else { return }
        // Composited in a bitmap context of our own, top to bottom: the window pass, then each scroll view's content, then
        // the views stacked above it.
        let scale = captureWindow.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func draw(_ rep: NSBitmapImageRep, at rect: NSRect) {
            guard let image = rep.cgImage else { return }
            // `rect` is in the root's coordinates (flipped or not); the context's origin is the bottom left.
            let y = view.isFlipped ? view.bounds.height - rect.maxY : rect.minY
            ctx.draw(image, in: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale))
        }
        // Opaque from the start: what no pass draws is the window's ground, not a hole.
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(base, at: view.bounds)
        var above = false
        for child in view.subviews {
            let documents = scrollViews(in: child).compactMap(\.documentView)
            if !documents.isEmpty {
                for document in documents {
                    let visible = document.visibleRect
                    if let shot = snapshot(document, visible) { draw(shot, at: document.convert(visible, to: view)) }
                }
                above = true
            } else if above, let shot = snapshot(child, child.bounds) {
                draw(shot, at: child.convert(child.bounds, to: view))
            }
        }
        guard let cg = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func snapshot(_ view: NSView, _ rect: NSRect) -> NSBitmapImageRep? {
        // With an alpha channel (the cache `bitmapImageRepForCachingDisplay` makes has none, so a transparent view came out
        // black and shadows piled up), and transparent to begin with.
        let scale = view.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        if let data = rep.bitmapData { memset(data, 0, rep.bytesPerRow * rep.pixelsHigh) }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// The SwiftUI scroll views with a document (the sidebar's included) under a view, in drawing order.
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        // SwiftUI's only: an AppKit text field's own scroll view draws fine in the window pass.
        if let scroll = view as? NSScrollView, scroll.documentView != nil, String(describing: type(of: scroll)).contains("Hosting") { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}

private extension UUID {
    var asCategory: AppDestination { .category(self) }
}
