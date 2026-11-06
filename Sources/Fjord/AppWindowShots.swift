import AppKit
import SwiftUI

// Dev entries for the app window: `--window` opens it alone on the demo data; `--window-shots <dir> [substring...]` renders
// its destinations as PNGs, offscreen, the title bar included.

@MainActor
enum AppWindowDev {
    /// `--window`: the window on the demo data (the Router's brief included), the app ending with it.
    static func open(_ store: Store) -> AppWindowController {
        Demo.populate(store, .router)
        let controller = AppWindowController(store: store, remembers: false)
        controller.onClose = { NSApp.terminate(nil) }
        controller.show()
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
        /// A tooltip shown at once: the one whose title starts with this.
        var tip: String?
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
        // The brief (RouterBriefView.swift): every section, an entry focused with option 2 picked (a question, a plan and a
        // local form), a stale project, all quiet, and the history open.
        briefShot("brief-home", .aqua), briefShot("brief-home-dark", .darkAqua),
        briefShot("brief-needs-you", .aqua, height: 1500, focus: true), briefShot("brief-needs-you-dark", .darkAqua, height: 1500, focus: true),
        briefShot("brief-stale", .aqua, variant: .stale), briefShot("brief-stale-dark", .darkAqua, variant: .stale),
        briefShot("brief-quiet", .aqua, height: 800, variant: .quiet), briefShot("brief-quiet-dark", .darkAqua, height: 800, variant: .quiet),
        // The history at the right on a wide window, across the bottom on a narrow one.
        briefShot("brief-drawer", .aqua, drawer: true), briefShot("brief-drawer-dark", .darkAqua, drawer: true),
        briefShot("brief-drawer-narrow", .aqua, width: 900, drawer: true), briefShot("brief-drawer-narrow-dark", .darkAqua, width: 900, drawer: true),
        // A highlight hovered (its peek), and opened: a plan's popover, a question's with an option picked, a form of two
        // questions, a finished thread's (a line to message it).
        briefShot("brief-hover", .aqua, hover: "lead-you#chan_demo_fjord/th_settings"),
        briefShot("brief-open-plan", .darkAqua, open: "chan_demo_fjord#chan_demo_fjord/th_migrate"),
        briefShot("brief-open-question", .aqua, focus: true, open: "chan_demo_fjord#chan_demo_fjord/th_settings"),
        briefShot("brief-open-form", .aqua, open: "local:lcu#local:lcu/\(Demo.briefLocalThread)", twoQuestions: true),
        briefShot("brief-open-finished", .darkAqua, open: "chan_demo_docs#chan_demo_docs/th_guide"),
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
        Shot(name: "router-composing", destination: { _ in .router }, compose: { model, store in
            let folder = store.knownFolders.first { !$0.isEmpty } ?? "/Users/me/code/lookout"
            model.pointers = [.project(folder)]
            model.draft = "check the failing tests in \(MentionText.markString) and tell me what you find"
        }),
        // The claude.ai delivery setup: nothing done, partway (Chrome and the host, no tab yet), and everything done.
        setupShot("courier-setup-missing", .aqua, facts: .init(extensionFolder: "/Applications/Fjord.app/Contents/Resources/extension"), health: .init()),
        setupShot("courier-setup-missing-dark", .darkAqua, facts: .init(extensionFolder: "/Applications/Fjord.app/Contents/Resources/extension"), health: .init()),
        setupShot("courier-setup-partway", .aqua, facts: .init(chromePath: "/Applications/Google Chrome.app", extensionLoaded: true, manifestWritten: true),
                  health: .init(tabConnected: true, signedIn: false)),
        setupShot("courier-setup-partway-dark", .darkAqua, facts: .init(chromePath: "/Applications/Google Chrome.app", extensionLoaded: true, manifestWritten: true),
                  health: .init(tabConnected: true, signedIn: false)),
        setupShot("courier-setup-done", .aqua, facts: .init(chromePath: "/Applications/Google Chrome.app", extensionLoaded: true, manifestWritten: true),
                  health: .init(tabConnected: true, signedIn: true)),
        setupShot("courier-setup-done-dark", .darkAqua, facts: .init(chromePath: "/Applications/Google Chrome.app", extensionLoaded: true, manifestWritten: true),
                  health: .init(tabConnected: true, signedIn: true)),
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
    ] + courierShots + proposalShots

    // MARK: The engine's pills

    private typealias CourierStep = (work: RouterCourierPills.Item.Work, updates: [(CourierState, String?, JSON?)])

    /// A pause as the engine reports it: its code, and its cause in the engine's words.
    private static func paused(_ pause: CourierPause) -> (CourierState, String?, JSON?) { (.paused, CourierDo.sentence(pause), .string(pause.rawValue)) }

    /// The engine's pills over the composer, one shot per state, light and dark (`router-courier-<state>[-dark]`).
    private static var courierShots: [Shot] {
        let send = { (words: String, thread: String?) in RouterCourierPills.Item.Work.send(words: words, project: "lookout", thread: thread) }
        let goal: RouterCourierPills.Item.Work = .tool(.setGoal, args: ["project": "lookout", "text": "Ship the Swift engine by Friday"])
        let scenes: [(String, [CourierStep])] = [
            ("sending", [(send("run the release checklist again", nil), [(.taken, nil, nil)])]),
            ("sending-thread", [(send("yes, merge it once CI is green", "Fix the login redirect"), [(.sending, nil, nil)])]),
            ("delivered", [(send("run the release checklist again", nil), [(.taken, nil, nil), (.delivered, nil, nil)])]),
            ("answered", [(.answer(option: "A sidebar with sections", project: "fjord", thread: "Redesign the Settings window"),
                           [(.taken, nil, nil), (.delivered, nil, nil)])]),
            ("failed", [(send("run the release checklist again", nil), [(.taken, nil, nil), (.failed, CourierCore.went, nil)])]),
            ("late", [(send("run the release checklist again", nil), [(.failed, CourierCore.went, nil), (.deliveredLate, "confirmed late by a later row", nil)])]),
            ("paused-signedout", [(send("run the release checklist again", nil), [paused(.signedOut)])]),
            ("paused-chrome", [(send("run the release checklist again", nil), [paused(.chromeClosed)])]),
            ("paused-tab", [(send("run the release checklist again", nil), [paused(.away)])]),
            ("paused-app", [(send("yes, merge it once CI is green", "Fix the login redirect"), [paused(.appClosed)])]),
            ("awaiting", [(.tool(.preapproveFolder, args: ["project": "lookout", "path": "~/code/projects/lookout"]), [(.awaiting, nil, nil)])]),
            ("tool-revert", [(goal, [(.taken, nil, nil), (.toolDone, nil, .string("Port the board and the store"))])]),
            ("tool-already", [(goal, [(.toolDone, "it was already so, as far as Fjord's tab knows", nil)])]),
            ("refused", [(.tool(.addRepo, args: ["project": "lookout", "repo": "amontlabs/x"]), [(.refused, "no repo option amontlabs/x", nil)])]),
            ("unconfirmed", [(.tool(.createProject, args: ["name": "fjord-site"]),
                              [(.toolUnconfirmed, "the projects page didn't list it after the create; a later read may still show it", nil)])]),
            // Several at once: a delivery settling, one waiting for the tab, a refusal, a grant to allow.
            ("stack", [(send("run the release checklist again", nil), [(.delivered, nil, nil)]),
                       (.tool(.createProject, args: ["name": "lookout"]), [(.refused, "a project named lookout already exists", nil)]),
                       (send("yes, merge it once CI is green", "Fix the login redirect"), [paused(.signedOut)]),
                       (.tool(.preapproveFolder, args: ["project": "lookout", "path": "~/code/x"]), [(.awaiting, nil, nil)])]),
        ]
        return scenes.flatMap { name, steps in
            [(name, NSAppearance.Name.aqua), (name + "-dark", .darkAqua)].map { shot, look in
                Shot(name: "router-courier-\(shot)", destination: { _ in .router }, compose: { model, store in
                    courier(model, store, steps)
                }, appearance: look)
            }
        }
    }

    /// The engine's intents as `steps` left them: each tracked, then each update applied, nothing settling away.
    private static func courier(_ model: RouterModel, _ store: Store, _ steps: [CourierStep]) {
        let pills = store.routerCourier
        pills.settleAfter = nil
        for (i, step) in steps.enumerated() {
            pills.track(i + 1, step.work)
            for (state, cause, before) in step.updates {
                // A pause carries its code where a setting carries what it was (`paused`).
                let pause = state == .paused ? before?.asString.flatMap(CourierPause.init(rawValue:)) : nil
                pills.apply(CourierUpdate(intentID: i + 1, state: state, cause: cause, before: pause == nil ? before : nil, at: Date(), pause: pause))
            }
        }
    }

    // MARK: The proposal to start a project

    /// The pill proposing a project for a message that fit none, one shot per state, light and dark
    /// (`router-proposal-<state>[-dark]`).
    private static var proposalShots: [Shot] {
        let message = "set up a Swift package for the iOS companion app, with a CI workflow that builds on every push"
        let first = RouterProjectFields(name: "fjord-ios-companion", folder: NSHomeDirectory() + "/code/projects/fjord-ios-companion",
                                        repo: "amontlabs/fjord-ios-companion",
                                        instructions: "A Swift package for Fjord's iOS companion app; keep CI green on every push.")
        let revised = RouterProjectFields(name: "fjord-ios", folder: first.folder, repo: nil, instructions: first.instructions)
        let scenes: [(String, RouterProjectFields, RouterProjectProposal.Phase, [String], String?)] = [
            ("proposed", first, .proposed, [], nil),
            ("revising", first, .revising, [], nil),
            ("revised", revised, .proposed, ["name", "repo"], nil),
            ("revise-failed", first, .proposed, [], "Couldn't revise that: the model didn't answer. The proposal stays as it was."),
            ("creating", revised, .creating("Adding the repo"), [], nil),
            ("waiting", revised, .waiting("Chrome isn't connected: Fjord goes on once it is"), [], nil),
            ("created", revised, .created, [], nil),
            ("failed", revised, .failed("The project wasn't created: a project named fjord-ios already exists"), [], nil),
            ("none", RouterProjectFields(name: "scratch-notes"), .proposed, [], nil),
        ]
        return scenes.flatMap { name, fields, phase, changed, note in
            [(name, NSAppearance.Name.aqua), (name + "-dark", .darkAqua)].map { shot, look in
                Shot(name: "router-proposal-\(shot)", destination: { _ in .router }, compose: { _, store in
                    let proposal = store.proposeProject(for: message, first: first, reviser: RouterProjectFakeReviser(),
                                                        engine: RouterProjectFakeEngine())
                    proposal.settleAfter = nil
                    proposal.show(fields, phase: phase, changed: changed, note: note)
                }, appearance: look)
            }
        }
    }

    private static func setupShot(_ name: String, _ look: NSAppearance.Name, facts: CourierSetupFacts, health: CourierSetupHealth) -> Shot {
        Shot(name: name, destination: { _ in .router }, size: CGSize(width: 680, height: 460), appearance: look, standalone: { _, _ in
            AnyView(RouterCourierSetupView(setup: RouterCourierSetup(facts: facts, health: health, read: { facts }))
                .padding(24)
                .frame(width: 680, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(CDS.Surface.s1))
        })
    }

    private static func briefShot(_ name: String, _ look: NSAppearance.Name, width: CGFloat = 1280, height: CGFloat = 1100, variant: Demo.BriefVariant = .home,
                                  focus: Bool = false, drawer: Bool = false, hover: String? = nil, open: String? = nil,
                                  twoQuestions: Bool = false) -> Shot {
        Shot(name: name, destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: width, height: height),
             compose: { _, store in
                 let briefs = store.routerBriefs
                 if focus {
                     let t = BriefTarget(project: "chan_demo_fjord", thread: "th_settings")
                     briefs.focus(t)
                     briefs.pick(t, 2, store: store)
                 }
                 briefs.hovered = hover
                 if let open {
                     BriefSpan.popoverInline = true
                     briefs.opened = open
                 }
                 if twoQuestions, var form = store.pendingForms["cli-demo-lcu"] {
                     form.questions.append(PendingForm.Question(question: "Which channel should it follow?", header: "Channel", multiSelect: false,
                                                                options: [PendingForm.Option(label: "Stable", description: ""),
                                                                          PendingForm.Option(label: "Beta", description: "")]))
                     store.pendingForms["cli-demo-lcu"] = form
                 }
                 if drawer {
                     briefs.drawerOpen = true
                     store.briefAct(.read, on: BriefTarget(project: "chan_demo_docs", thread: "th_guide"), mark: "chan_demo_docs/th_guide/0",
                                    title: briefs.title(BriefTarget(project: "chan_demo_docs", thread: "th_guide")))
                     briefs.record(BriefTarget(project: "chan_demo_fjord", thread: "th_bar"), "Count only what's unread")
                 }
             },
             prepare: { store in if variant != .home { Demo.briefs(store, now: Date(), variant) } },
             appearance: look)
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
            let controller = NSHostingController(rootView: standalone(store, routerModel).environment(\.cdsColumnWidth, shot.size.width))
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
        let controller = NSHostingController(rootView: root.environment(\.previewTip, shot.tip))
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
    /// when asked for on its own), so the Router's brief was missing. Each scroll view's visible content is drawn on its
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
