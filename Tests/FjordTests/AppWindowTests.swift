import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fjord

extension WindowSeams {
    /// The app window as the bar's other mode: it opens on a place, and closing it tells the bar to come back.
    @MainActor
    @Suite(.hostsWindows) struct AppWindowTests {
        private func controller() -> (AppWindowController, Store) {
            _ = NSApplication.shared
            let store = Store()
            store.persists = false
            Demo.populate(store, .router)
            return (AppWindowController(store: store, remembers: false, checksClaudeCode: false), store)
        }

        /// The window off every screen, and closed again when the test is done.
        private func away(_ controller: AppWindowController) {
            controller.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        }

        @Test func showingOpensTheWindowOnThePlaceAndClosingTellsTheBar() async {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            #expect(!window.isOpen)
            window.show(.settings)
            away(window)
            #expect(window.isOpen && window.navigator.selection == .settings)
            // A regular app while the window is open: a Dock icon and ⌘-Tab.
            // (Wanted only: a test run never applies it, or its helper would land in the Dock.)
            #expect(AppPolicy.current == .regular)
            #expect(NSApp.activationPolicy() != .regular)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            #expect(!window.isOpen && closed == 1)
            // The bar only again: no Dock icon.
            #expect(AppPolicy.current == .accessory)
        }

        @Test func showingWithoutAPlaceOpensWhereItWasLeft() async {
            let (window, _) = controller()
            window.show(.done)
            away(window)
            window.close()
            await waitUntil { !window.isOpen }
            window.show()
            away(window)
            #expect(window.navigator.selection == .done)
            window.close()
            await waitUntil { !window.isOpen }
        }

        /// Opened again after a close, the window has its size back (its content leaves it on close, and coming back must not
        /// size it to the content's minimum: a window too small to see).
        @Test func openingAgainKeepsTheWindowsSize() async {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.settings)
            window.window?.setContentSize(NSSize(width: 1100, height: 700))
            let size = window.window?.frame.size
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            window.show(.settings)
            #expect(window.window?.frame.size == size)
            away(window)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// The window made smaller while closed (opening on a smaller screen fits it to that one) keeps that size when its kept
        /// content, still at the old size, goes back in.
        @Test func keptContentTakesTheSizeTheWindowHasNow() async {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.settings)
            window.window?.setContentSize(NSSize(width: 1300, height: 800))
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            let smaller = NSRect(x: -5000, y: -5000, width: 1050, height: 650)
            window.window?.setFrame(smaller, display: false)
            window.show(.settings)
            #expect(window.window?.frame.size == smaller.size)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// Closed, the window lets go of its content, which stands still out of it, and keeps it for the next open: the same
        /// content comes back, as it was left, without being made again.
        @Test func closingKeepsTheContentOutOfTheWindowForTheNextOpen() async throws {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.router)
            away(window)
            let content = try #require(window.window?.contentViewController)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            #expect(window.window?.contentViewController == nil && content.view.window == nil)
            window.show(.router)
            away(window)
            #expect(window.window?.contentViewController === content)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// Without a morph, the bar returns a turn before the content leaves the window and the app gives up its Dock icon.
        @Test func closingRestoresTheBarBeforeDeferredContentCleanup() throws {
            #expect(!AppTransition.enabled)
            let (window, _) = controller()
            let nextTurn = AppTransition.nextTurn, policy = AppPolicy.current
            var turns: [@MainActor () -> Void] = []
            AppTransition.nextTurn = { turns.append($0) }
            defer {
                window.onClose = nil
                window.close()
                AppTransition.nextTurn = nextTurn
                AppPolicy.update(windowOpen: policy == .regular)
            }
            window.show(.settings)
            let content = try #require(window.window?.contentViewController)
            var closed = 0
            window.onClose = {
                closed += 1
                #expect(window.window?.contentViewController === content && AppPolicy.current == .regular)
            }
            window.close()
            #expect(!window.isOpen && closed == 0 && turns.count == 1)
            let restore = try #require(turns.first)
            turns.removeFirst()
            restore()
            #expect(closed == 1 && window.window?.contentViewController === content && AppPolicy.current == .regular)
            let cleanup = try #require(turns.first)
            turns.removeFirst()
            cleanup()
            #expect(window.window?.contentViewController == nil && content.view.window == nil && AppPolicy.current == .accessory)
            #expect(turns.isEmpty)
        }

        /// Opening from the bar's return callback or before the following cleanup keeps the content attached and the app regular.
        @Test(arguments: [true, false]) func openingAgainAfterTheBarReturnsCancelsContentCleanup(duringCallback: Bool) throws {
            #expect(!AppTransition.enabled)
            let (window, _) = controller()
            let nextTurn = AppTransition.nextTurn, policy = AppPolicy.current
            var turns: [@MainActor () -> Void] = []
            AppTransition.nextTurn = { turns.append($0) }
            defer {
                window.onClose = nil
                window.close()
                AppTransition.nextTurn = nextTurn
                AppPolicy.update(windowOpen: policy == .regular)
            }
            window.show(.settings)
            let content = try #require(window.window?.contentViewController)
            var closed = 0
            window.onClose = {
                closed += 1
                if duringCallback { window.show(.settings) }
            }
            window.close()
            let restore = try #require(turns.first)
            turns.removeFirst()
            restore()
            if !duringCallback {
                #expect(turns.count == 1)
                window.show(.settings)
                let cleanup = try #require(turns.first)
                turns.removeFirst()
                cleanup()
            }
            #expect(closed == 1 && turns.isEmpty && window.isOpen && window.window?.contentViewController === content)
            #expect(AppPolicy.current == .regular)
            // Close for real, with both turns stepped so no cleanup remains when another test begins.
            window.onClose = nil
            window.close()
            let finalRestore = try #require(turns.first)
            turns.removeFirst()
            finalRestore()
            let finalCleanup = try #require(turns.first)
            turns.removeFirst()
            finalCleanup()
            #expect(turns.isEmpty && window.window?.contentViewController == nil && AppPolicy.current == .accessory)
        }

        /// The categories page kept from a close has an undo history of what was done before it: a change the Router made while
        /// the window was closed is newer, so ⌘Z after opening again must not take the page back to before it.
        @Test func aRouterChangeWhileClosedIsNotUndoneByTheKeptCategoriesPage() async throws {
            let (window, store) = controller()
            // The page asks GitHub for repos to suggest when it has none.
            store.suggestions = ["octo/repo"]
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.categories)
            away(window)
            await waitUntil { store.categoryHistory != nil }
            // A step of the page's own, so it has something to undo.
            var renamed = try #require(store.categories.first)
            renamed.name += " (edited)"
            store.categories[0] = renamed
            await waitUntil { store.categoryHistory?.canUndo == true }
            #expect(store.categoryHistory?.canUndo == true)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            #expect(store.categoryHistory == nil)
            var made = CategoriesView.newDraft(after: store.categories)
            made.name = "From the Router"
            store.categories.append(made)
            store.categoriesChangedByRouter()
            window.show(.categories)
            away(window)
            await waitUntil { store.categoryHistory != nil }
            await waitUntilSteady { store.categoryHistory?.canUndo }
            store.categoryHistory?.undo(store)
            #expect(store.categories.contains { $0.id == made.id })
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// The composer kept from a close, given the keyboard again when the window opens, says so: Return sends again rather
        /// than starting a new line.
        @Test func theKeptComposerSaysItHasTheKeyboardAgainAfterReopening() async throws {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            func fields(_ view: NSView) -> [MentionTextView] { (view as? MentionTextView).map { [$0] } ?? [] + view.subviews.flatMap(fields) }
            func focus() async throws {
                let host = try #require(window.window?.contentView)
                await waitUntil { !fields(host).isEmpty }
                await drainMainQueue()
                let field = fields(host).first
                await waitUntil {
                    if window.window?.firstResponder !== field, let field { window.window?.makeFirstResponder(field) }
                    return window.window?.firstResponder === field
                }
            }
            window.show(.router)
            away(window)
            try await focus()
            await waitUntil { window.routerModel.composerFocused }
            #expect(window.routerModel.composerFocused)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            #expect(!window.routerModel.composerFocused)
            window.show(.router)
            away(window)
            try await focus()
            await waitUntil { window.routerModel.composerFocused }
            #expect(window.routerModel.composerFocused)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// Short of memory, a closed window lets go of the content it kept, and the next open makes it again; an open one keeps it.
        @Test func memoryPressureReleasesTheContentKeptWhileClosed() async throws {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.settings)
            away(window)
            let content = try #require(window.content)
            window.releaseKept()
            #expect(window.content === content && window.window?.contentViewController === content)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            window.releaseKept()
            #expect(window.content == nil)
            window.show(.settings)
            away(window)
            #expect(window.window?.contentViewController != nil && window.window?.contentViewController !== content)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
        }

        /// Short of memory before the launch's preparing comes, the window prepares nothing: the content it would build is
        /// what the pressure asked to let go of. Once memory is back, it prepares again.
        @Test func memoryPressureBeforeThePreparingSkipsIt() {
            let (window, _) = controller()
            window.memoryPressure(elevated: true)
            window.prepare()
            #expect(window.content == nil)
            window.memoryPressure(elevated: false)
            window.prepare()
            #expect(window.content != nil)
        }

        /// Short of memory while the window is open (its content in it, so nothing is let go then), closing it afterwards keeps
        /// neither its content nor a picture for the next open, until memory is back.
        @Test func memoryPressureWhileOpenLetsGoOfTheContentOnClose() async throws {
            let (window, _) = controller()
            var closed = 0
            window.onClose = { closed += 1 }
            window.show(.settings)
            away(window)
            let content = try #require(window.content)
            window.memoryPressure(elevated: true)
            #expect(window.content === content)
            window.close()
            // The bar is told first; the content leaves the window, and goes, a turn later.
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            #expect(window.content == nil && window.window?.contentViewController == nil && !window.keepsPicture)
            window.memoryPressure(elevated: false)
            window.show(.settings)
            away(window)
            window.close()
            await waitUntil { closed == 2 && window.window?.contentViewController == nil }
            #expect(window.content != nil)
        }

        /// Prepared at idle after launch, the window and its content are made out of sight: nothing is ordered in, the window is
        /// not open or in front, the app stays an accessory; the first open then brings in that content rather than making it.
        @Test func aPreparedContentIsMadeOutOfSightAndTheFirstOpenUsesIt() async throws {
            let (window, _) = controller()
            var fronts = 0, closed = 0
            window.onFront = { _ in fronts += 1 }
            window.onClose = { closed += 1 }
            let policy = AppPolicy.current
            window.prepare()
            let content = try #require(window.content)
            #expect(window.window?.isVisible == false && !window.isOpen && !window.isFront && fronts == 0)
            #expect(window.window?.contentViewController == nil && content.view.window == nil)
            #expect(AppPolicy.current == policy)
            #expect(!NSApp.windows.contains { $0.isVisible && $0 === window.window })
            // Twice is once.
            window.prepare()
            #expect(window.content === content)
            // Nothing a close leaves for later comes of it: the bar is not told the window closed.
            await drainMainQueue()
            #expect(closed == 0)
            window.show(.router)
            away(window)
            #expect(window.isOpen && window.window?.contentViewController === content)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
        }

        /// Prepared on the Router out of sight, a notice it would show (the form hook couldn't be installed) is not said to
        /// VoiceOver; it is once the window opens on it.
        @Test func aPreparedRouterSaysItsNoticeOnlyOnceShown() async {
            await Announced.exclusively {
                var said: [String] = []
                Announce.sink = { said.append($0) }
                let (window, store) = controller()
                store.routerHookError = "denied"
                var closed = 0
                window.onClose = { closed += 1 }
                window.navigator.go(.router)
                window.prepare()
                try? await Task.sleep(for: .milliseconds(600))
                await drainMainQueue()
                #expect(!said.contains { $0.contains("denied") })
                window.show(.router)
                away(window)
                await waitUntil { said.contains { $0.contains("denied") } }
                #expect(said.contains { $0.contains("denied") })
                window.close()
                await waitUntil { closed == 1 && window.window?.contentViewController == nil }
            }
        }

        /// Prepared on the categories page, the page out of sight leaves no undo history to take ⌘Z, and opening on it has a
        /// fresh one.
        @Test func aPreparedCategoriesPageRegistersItsHistoryOnlyOnceOpen() async throws {
            let (window, store) = controller()
            store.suggestions = ["octo/repo"]
            var closed = 0
            window.onClose = { closed += 1 }
            window.navigator.go(.categories)
            window.prepare()
            await drainMainQueue()
            #expect(store.categoryHistory == nil)
            window.show(.categories)
            away(window)
            await waitUntil { store.categoryHistory != nil }
            #expect(store.categoryHistory?.canUndo == false)
            window.close()
            await waitUntil { closed == 1 && window.window?.contentViewController == nil }
        }

        /// Why `prepare` builds the content in the window and takes it out again: once it has been in a window, a hosting
        /// controller out of one stands still (no body runs as the store behind it changes).
        @Test func contentTakenOutOfTheWindowStandsStill() async {
            let model = ProbeModel(), count = ProbeCount()
            let window = AwayWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: ProbeView(model: model, count: count))
            content.sizingOptions = []
            content.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            window.contentViewController = content
            content.view.layoutSubtreeIfNeeded()
            window.contentViewController = nil
            #expect(count.bodies >= 1 && !window.isVisible)
            let built = count.bodies
            for _ in 0..<10 {
                model.n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            #expect(count.bodies == built)
            withExtendedLifetime((content, window)) {}
        }

        @Test func aPlaceThatIsGoneOpensOnTheFirstCategory() async {
            let (window, store) = controller()
            window.show(.category(UUID()))
            away(window)
            #expect(window.navigator.selection == .category(store.shownCategories[0].id))
            window.close()
            await waitUntil { !window.isOpen }
        }

        @Test func anEntryOpensOnTheRouterFocused() async throws {
            let (window, store) = controller()
            window.show(.settings)
            away(window)
            let entry = try #require(store.routerBriefs.page().entries.first)
            window.show(entry: entry.target)
            #expect(window.navigator.selection == .router && store.routerBriefs.focused == entry.target)
            window.close()
            await waitUntil { !window.isOpen }
        }

        @Test func anEntryOpensOnItsCategoryPickedAndAskedFor() async throws {
            let (window, store) = controller()
            let entry = try #require(store.entries.first { !$0.isDone })
            window.show(entry: entry)
            away(window)
            #expect(window.navigator.selection == .category(entry.categoryID))
            #expect(window.hub.selection == "i:" + entry.id && window.hub.keyboardSelection?.id == "i:" + entry.id)
            window.close()
            await waitUntil { !window.isOpen }
        }

        /// Check for Updates (the bar's menu) asks the window's own Settings for Updates, which takes the request: from another
        /// place, and again while Settings is open already.
        @Test func checkForUpdatesScrollsTheWindowsSettingsToUpdates() async {
            let (window, _) = controller()
            window.show(.done)
            away(window)
            window.showUpdates()
            #expect(window.isOpen && window.navigator.selection == .settings)
            #expect(window.hub.settingsScroll?.id == SettingsView.updatesID)
            await waitUntil { window.hub.settingsScroll == nil }
            #expect(window.hub.settingsScroll == nil)
            window.showUpdates()
            #expect(window.hub.settingsScroll?.id == SettingsView.updatesID)
            await waitUntil { window.hub.settingsScroll == nil }
            #expect(window.hub.settingsScroll == nil)
            // Closed on Settings and opened again by the menu: the page kept from the close takes it as it comes back.
            var closed = false
            window.onClose = { closed = true }
            window.close()
            await waitUntil { closed && window.window?.contentViewController == nil }
            window.showUpdates()
            away(window)
            #expect(window.hub.settingsScroll?.id == SettingsView.updatesID)
            await waitUntil { window.hub.settingsScroll == nil }
            #expect(window.hub.settingsScroll == nil)
            window.close()
            await waitUntil { !window.isOpen }
        }
    }
}

@MainActor
@Suite struct BarState {
    /// The window shortcut closes only a window you are looking at (or one on its way in); one behind another app or
    /// minimized comes in front instead, and one on its way out comes back.
    @Test func theShortcutClosesOnlyAWindowInFront() {
        #expect(AppWindowController.shortcutCloses(phase: .idle, front: true))
        #expect(!AppWindowController.shortcutCloses(phase: .idle, front: false))
        #expect(AppWindowController.shortcutCloses(phase: .opening, front: false))
        #expect(!AppWindowController.shortcutCloses(phase: .closing, front: true))
    }

    /// The rows' avatars are warmed at the URL a row asks for: the latest actor's, at a row's size; and the account's at
    /// Settings' size.
    @Test func theAvatarsWarmedAreTheOnesTheRowsShow() {
        let store = Store()
        store.persists = false
        Demo.populate(store, .router)
        let warmed = store.avatarsToWarm()
        let shown = Set(store.shownCategories.flatMap { store.entries(in: .category($0.id)) }
            .filter { $0.thing.kind != .workflow }
            .compactMap { Avatar.sizedURL($0.thing.latestActor?.avatar, size: EntryRow.avatar) })
        let account = Avatar.sizedURL(store.me?.avatarUrl, size: SettingsView.accountAvatar)
        #expect(!warmed.isEmpty && warmed.count <= 61 && Set(warmed).count == warmed.count)
        #expect(warmed.contains { shown.contains($0) })
        #expect(warmed.allSatisfy { shown.contains($0) || $0 == account })
        // The tab the inbox opens on comes first.
        let first = store.entries(in: store.tabNeedingYou).filter { $0.thing.kind != .workflow }
            .compactMap { Avatar.sizedURL($0.thing.latestActor?.avatar, size: EntryRow.avatar) }
        if let lead = first.first { #expect(warmed.first == lead) }
        #expect(store.avatarsToWarm(limit: 1).filter { $0 != account }.count <= 1)
    }

    /// The page actually opened is warmed first: a category other than the one needing you, or Done (whose actors are
    /// warmed only then).
    @Test func theAvatarsOfThePageOpenedComeFirst() throws {
        let store = Store()
        store.persists = false
        Demo.populate(store, .router)
        func faces(_ tab: InboxTab) -> [URL] {
            store.entries(in: tab).filter { $0.thing.kind != .workflow }
                .compactMap { Avatar.sizedURL($0.thing.latestActor?.avatar, size: EntryRow.avatar) }
        }
        let done = faces(.done)
        try #require(!done.isEmpty)
        let doneOnly = done.filter { !store.avatarsToWarm().contains($0) }
        let warmed = store.avatarsToWarm(first: .done)
        #expect(warmed.first == done.first && doneOnly.allSatisfy(warmed.contains))
        if let other = store.shownCategories.map({ InboxTab.category($0.id) }).last(where: { !faces($0).isEmpty }) {
            #expect(store.avatarsToWarm(first: other).first == faces(other).first)
        }
        #expect(Set(warmed).count == warmed.count)
    }

    /// Warming keeps the order it is given (the page opened first), each picture once.
    @Test func warmingKeepsItsOrder() throws {
        let urls = try ["a", "b", "a", "c", "b"].map { try #require(URL(string: "https://x.test/" + $0)) }
        #expect(ImageCache.unique(urls).map(\.lastPathComponent) == ["a", "b", "c"])
    }

    @Test func aPeekWaitsForThePointerToSettleThenSwitchesAtOnce() async {
        let hub = HubState()
        hub.enter(.inbox)
        #expect(hub.section == nil)
        await waitUntil { hub.section == .inbox }
        #expect(hub.section == .inbox)
        hub.enter(.router)
        #expect(hub.section == .router)
        hub.cancelDwell()
    }

    @Test func aPeekIsNotShownWhileTheBarIsQuiet() {
        let hub = HubState()
        hub.section = .inbox
        // A panel's view in a window never shown.
        let window = NSWindow(contentRect: NSRect(origin: UnderTest.away, size: NSSize(width: 100, height: 100)), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let piece = HubPieceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        piece.section = .inbox
        window.contentView = piece
        hub.pieces.add(piece)
        #expect(hub.panelsOnScreen.count == 1)
        hub.quiet = true
        #expect(hub.panelsOnScreen.isEmpty)
    }

    @Test func changingThePeekedTabDropsTheRowPickedInTheOther() {
        let hub = HubState()
        hub.selection = "i:a"
        hub.tab = .done
        #expect(hub.selection == nil)
    }
}

extension WindowSeams {
    /// The bar and the window: the bar is away only while the window is open and in front, and the morph is a no-op under test.
    @MainActor
    @Suite(.hostsWindows) struct BarComesBack {
        @Test func theBarIsAwayOnlyWhileTheOpenWindowIsInFront() {
            var presence = BarPresence()
            #expect(!presence.barAway)
            presence.opened(true)
            #expect(presence.barAway)
            // Another app in front: the bar is back, the window stays open behind.
            presence.front(false)
            #expect(!presence.barAway && presence.windowOpen)
            // The window returns (a click on the bar's item, the Dock icon).
            presence.front(true)
            #expect(presence.barAway)
            presence.opened(false)
            #expect(!presence.barAway)
            // A window that is not open is never in front.
            presence.front(true)
            #expect(!presence.barAway)
        }

        @Test func resigningActiveReportsOutOfSightAndBecomingActiveReportsFront() async {
            _ = NSApplication.shared
            let store = Store()
            store.persists = false
            Demo.populate(store, .router)
            let controller = AppWindowController(store: store, remembers: false, checksClaudeCode: false)
            var reports: [Bool] = []
            controller.onFront = { reports.append($0) }
            controller.show(.settings)
            controller.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            // The window is on screen; whether the app counts as active depends on the runner, so say it.
            controller.reportFront(active: true)
            #expect(reports.last == true || controller.window?.occlusionState.contains(.visible) == false)
            let seen = reports.count
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            await waitUntil { reports.count > seen || reports.last == false }
            #expect(reports.last == false)
            controller.close()
            await waitUntil { !controller.isOpen }
            #expect(!controller.isOpen)
        }

        @Test func theMorphIsSkippedUnderTestSoTheWindowOpensAndClosesAtOnce() async {
            #expect(!AppTransition.enabled)
            _ = NSApplication.shared
            let store = Store()
            store.persists = false
            Demo.populate(store, .router)
            let controller = AppWindowController(store: store, remembers: false, checksClaudeCode: false)
            var asked = 0
            controller.bar = { asked += 1; return BarMorph(frame: NSRect(x: 0, y: 0, width: 50, height: 200)) }
            var closing = 0
            var closed = 0
            controller.onClosing = { closing += 1 }
            controller.onClose = { closed += 1 }
            controller.show(.settings)
            controller.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            #expect(controller.window?.alphaValue == 1 && controller.isOpen)
            controller.close()
            await waitUntil { closed == 1 && controller.window?.contentViewController == nil }
            #expect(closed == 1 && closing == 0 && asked == 0 && !controller.isOpen)
        }

        /// A wait for several refreshes runs once, after them (or after its fallback, a display giving none).
        /// A stalled link is given up on about as long as its refreshes take: a 120 Hz screen's at 60 Hz, a 24 Hz one's at
        /// 24, with half a refresh more so a late tick still wins.
        @Test func aWaitGivesUpAfterTheScreensOwnRefreshes() {
            #expect(abs(FrameTick.fallback(2, on: nil) - 2.5 / 60) < 1e-9)
            // At the screen's slowest refresh (an adaptive display runs below its maximum rate), at least a 60 Hz one.
            for screen in NSScreen.screens {
                let slowest = max(1.0 / 60, screen.maximumRefreshInterval)
                #expect(abs(FrameTick.fallback(1, on: screen) - 1.5 * slowest) < 1e-9)
            }
            #expect(abs(FrameTick.fallback(3, frame: 1.0 / 24) - 3.5 / 24) < 1e-9)
        }

        @Test func aWaitForSeveralRefreshesRunsOnce() async {
            var runs = 0
            FrameTick.wait(2, on: NSScreen.main) { runs += 1 }
            await waitUntil { runs > 0 }
            try? await Task.sleep(for: .milliseconds(300))
            #expect(runs == 1)
            var asleep = 0
            FrameTick.wait(2, on: nil) { asleep += 1 }
            await waitUntil { asleep > 0 }
            #expect(asleep == 1)
        }

        private final class Ticks {
            var blocks: [@MainActor () -> Void] = []
            var turns: [@MainActor () -> Void] = []

            /// Every turn queued, and those they queue in turn: a close tells the bar a turn before it tidies.
            @MainActor func runTurns() {
                while !turns.isEmpty { turns.removeFirst()() }
            }
        }

        /// A morph with the frame ticks in the test's hands. Synchronous: nothing else sees the morph switched on. A window under
        /// test never has the keyboard (the test runner is not the active app): `AppTransition.isKey` may say otherwise.
        private func morphing(_ body: (AppWindowController, Ticks) throws -> Void) rethrows {
            let (window, ticks, restore) = beginMorphing()
            defer { restore() }
            try body(window, ticks)
        }

        /// The same stepped morph kept alive while an asynchronous test waits for the overlay's real fade to finish.
        private func beginMorphing() -> (AppWindowController, Ticks, @MainActor () -> Void) {
            let saved = (AppTransition.enabled, AppTransition.nextFrames, AppTransition.nextTurn, AppTransition.isKey,
                         AppTransition.isMiniaturized, AppTransition.flushInitial)
            // The app's policy as found: the morph's close never gets to its tidying turn here, which would put it back, and a
            // test awaiting its own close meanwhile reads it.
            let policy = AppPolicy.current
            let ticks = Ticks()
            AppTransition.enabled = true
            // One block per refresh: a wait for several queues the next as each comes.
            AppTransition.nextFrames = { _, count, block in
                func wait(_ left: Int) { ticks.blocks.append { left > 1 ? wait(left - 1) : block() } }
                wait(count)
            }
            AppTransition.nextTurn = { block in ticks.turns.append(block) }
            let keeper = (AppTransition.inputIdle, AppTransition.isFront, AppTransition.costs, AppTransition.lastCapture)
            _ = NSApplication.shared
            let store = Store()
            store.persists = false
            Demo.populate(store, .router)
            let window = AppWindowController(store: store, remembers: false, checksClaudeCode: false)
            window.bar = { BarMorph(frame: NSRect(x: 1400, y: 300, width: 46, height: 300)) }
            // Every seam put back, and the window closed while its turns are still the test's (none of them run), even
            // when the test stops early.
            let restore: @MainActor () -> Void = {
                window.run?.end()
                window.close()
                AppTransition.enabled = saved.0
                AppTransition.nextFrames = saved.1
                AppTransition.nextTurn = saved.2
                AppTransition.isKey = saved.3
                AppTransition.isMiniaturized = saved.4
                AppTransition.flushInitial = saved.5
                (AppTransition.inputIdle, AppTransition.isFront, AppTransition.costs, AppTransition.lastCapture) = keeper
                AppPolicy.update(windowOpen: policy == .regular)
                // A morph the test left under way holds no other test's waiting work.
                MotionGate.ended()
            }
            return (window, ticks, restore)
        }

        @Test func theRealWindowIsShownBeforeTheOverlayGoes() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let run = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                // Waiting at its frame, invisible and taking no clicks, while the overlay grows out of the bar.
                #expect(controller.phase == .opening && window.alphaValue == 0 && run.overlay.isVisible)
                ticks.runTurns()
                #expect(window.ignoresMouseEvents && window.alphaValue == 0)
                run.complete()
                // At the end: the real window is in under the overlay at once, taking clicks, and the overlay stays until two
                // refreshes later.
                #expect(window.alphaValue == 1 && !window.ignoresMouseEvents && run.overlay.isVisible && !run.ended)
                #expect(ticks.blocks.count == 1)
                ticks.blocks.removeFirst()()
                #expect(window.alphaValue == 1 && run.overlay.isVisible && ticks.blocks.count == 1)
                ticks.blocks.removeFirst()()
                #expect(window.alphaValue == 1 && !run.ended)
            }
        }

        /// An opening's motion is handed to the render server before anything heavy: its first frame is flushed with nothing
        /// captured and no content in the window, and the window is brought in only on the turn after, on the spring as on
        /// Reduce Motion's fade (no bar to grow out of takes that path too).
        @Test(arguments: [false, true]) func theMotionIsFlushedBeforeTheWindowIsBroughtIn(reduced: Bool) {
            morphing { controller, ticks in
                if reduced { controller.bar = { nil } }
                var flushes: [(captures: Int, content: Bool, turns: Int)] = []
                let before = AppTransition.captures
                AppTransition.flushInitial = {
                    flushes.append((AppTransition.captures - before, controller.window?.contentViewController != nil,
                                    ticks.turns.count))
                }
                controller.show(.settings)
                #expect(flushes.count == 1)
                #expect(flushes.first?.captures == 0 && flushes.first?.content == false && flushes.first?.turns == 0)
                #expect(controller.window?.contentViewController == nil && ticks.turns.count == 1)
                ticks.turns.removeFirst()()
                #expect(controller.window?.contentViewController != nil && flushes.count == 1)
            }
        }

        @Test(arguments: [false, true]) func closingBeforeBringInReversesWithoutWarmingContent(prepared: Bool) throws {
            try morphing { controller, ticks in
                if prepared { controller.prepare() }
                let content = controller.content
                controller.show(.settings)
                let run = try #require(controller.run)
                let window = try #require(controller.window)
                let glances = AppTransition.glances, captures = AppTransition.captures
                #expect(!window.isVisible && window.contentViewController == nil)
                controller.close()
                #expect(controller.phase == .closing && controller.run === run && run.overlay.isVisible)
                #expect(!window.isVisible && window.contentViewController == nil && controller.content === content)
                ticks.runTurns() // The cancelled bring-in must stay cancelled.
                #expect(!window.isVisible && window.contentViewController == nil && controller.content === content)
                #expect(AppTransition.glances == glances && AppTransition.captures == captures)
                controller.show(.settings)
                #expect(controller.run === run && controller.phase == .opening)
                ticks.runTurns()
                #expect(window.contentViewController != nil && window.isVisible)
            }
        }

        @Test func theMorphMovesBeforeTheWindowIsBuilt() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let run = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                // The overlay is on screen at once, on the window's bare surface; the window and its content come a turn later,
                // and it counts as open meanwhile (a toggle closes it).
                #expect(run.overlay.isVisible && run.image == nil && controller.isOpen)
                #expect(!window.isVisible && window.contentViewController == nil)
                #expect(ticks.turns.count == 1)
                ticks.turns.removeFirst()()
                #expect(window.isVisible && window.alphaValue == 0 && window.contentViewController != nil)
                // No picture is taken as the real window takes over (it would hold the handoff up): the window never had the
                // keyboard here, so none was, and the overlay fades into the real window rather than cutting to it.
                let taken = AppTransition.captures
                run.complete()
                #expect(AppTransition.captures == taken && run.image == nil && run.fadesOut)
                #expect(window.alphaValue == 1 && run.overlay.isVisible)
            }
        }

        /// What a close leaves for the next turn (the content out of the window, the bar told) is called off when the window is
        /// opened again first: the bar must not be told the window closed while it is on its way in.
        @Test func openingAgainBeforeTheCloseIsTidiedKeepsTheWindowOpen() {
            morphing { controller, ticks in
                var closed = 0
                controller.onClose = { closed += 1 }
                controller.show(.settings)
                controller.close()
                controller.run?.complete()
                #expect(controller.phase == .idle && controller.window?.isVisible == false)
                controller.show(.settings)
                #expect(controller.phase == .opening && controller.isOpen)
                // Every turn queued but the new opening's own bringing in: the close's tidying among them.
                let turns = ticks.turns
                ticks.turns = []
                turns.dropLast().forEach { $0() }
                #expect(closed == 0 && controller.isOpen && AppPolicy.current == .regular)
                #expect(controller.window?.contentViewController == nil)
                turns.last?()
                #expect(controller.window?.contentViewController != nil)
                #expect(closed == 0 && controller.window?.isVisible == true)
            }
        }

        /// Once the overlay has let go of its picture, a close is a close of the window as it is: on the kept picture when
        /// it is still the window, else, with nothing captured, the live window fading out in place above the overlay
        /// already shrinking beneath it.
        @Test func aCloseWithNoPictureOfTheWindowFadesTheLiveWindowAndCapturesNothing() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let opened = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                ticks.turns.removeFirst()()
                opened.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                #expect(opened.handedOver && controller.phase == .opening && window.isVisible)
                // Its overlay gone already.
                opened.end()
                let taken = AppTransition.captures
                let level = window.level
                controller.close()
                guard let closing = controller.run else { return #expect(Bool(false), "no close morph") }
                #expect(controller.phase == .closing && AppTransition.captures == taken && closing.image == nil)
                // The motion starts at once, the window above the overlay until its fade is over.
                #expect(closing.overlay.isVisible && ticks.blocks.isEmpty && closing.startPose?.container == 1)
                #expect(window.isVisible && window.level.rawValue > closing.overlay.level.rawValue)
                closing.complete()
                #expect(window.level == level)
            }
        }

        @Test(arguments: [false, true], [false, true])
        func reopeningDuringTheLiveCloseFadeKeepsTheWindowVisible(reduced: Bool, glass: Bool) async throws {
            let (controller, ticks, restore) = beginMorphing()
            defer { restore() }
            let glassMorph = AppTransition.glassMorph
            AppTransition.glassMorph = glass
            defer { AppTransition.glassMorph = glassMorph }
            controller.show(.done)
            ticks.runTurns()
            controller.run?.complete()
            ticks.blocks.removeFirst()()
            ticks.blocks.removeFirst()()
            controller.run?.end()
            let window = try #require(controller.window)
            if reduced { controller.bar = { nil } }
            let level = window.level, fadeWindow = AppTransition.fadeWindow
            var fades: [(from: CGFloat, to: CGFloat, done: @MainActor () -> Void)] = []
            AppTransition.fadeWindow = { window, alpha, done in fades.append((window.alphaValue, alpha, done)) }
            defer { AppTransition.fadeWindow = fadeWindow }
            controller.close()
            let run = try #require(controller.run)
            #expect(run.isGlass == (glass && GlassCapture.chromeIsGlass))
            #expect(fades.count == 1 && fades[0].to == 0 && run.image == nil)
            window.alphaValue = 0.4 // Step the live fade to its presentation halfway through the close.
            let lifted = window.level
            controller.show(.done)
            #expect(controller.phase == .opening && controller.run === run)
            #expect(window.alphaValue == 0.4 && window.level == lifted && lifted.rawValue > run.overlay.level.rawValue)
            #expect(fades.count == 2 && fades[1].from == 0.4 && fades[1].to == 1)
            fades[0].done() // The superseded close cannot hide or lower the reopened window.
            ticks.runTurns()
            #expect(window.isVisible && window.alphaValue == 0.4 && window.level == lifted)
            run.complete()
            #expect(window.alphaValue == 1 && window.level == lifted && !window.ignoresMouseEvents)
            #expect(run.overlay.isVisible && !run.handedOver)
            ticks.blocks.removeFirst()()
            #expect(window.level == lifted && run.overlay.isVisible && !run.handedOver)
            ticks.blocks.removeFirst()()
            #expect(window.level == lifted && run.overlay.isVisible && run.handedOver)
            await waitUntil { controller.phase == .idle }
            #expect(run.ended && !run.overlay.isVisible && window.level == level && window.isVisible)
        }

        /// A close while the opening's picture is still fading into the real window goes on from that blend: the same
        /// overlay, not shown whole again, the live window fading out under it, nothing captured.
        @Test func aCloseDuringTheHandoffsFadeGoesOnFromTheBlend() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let opened = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                ticks.turns.removeFirst()()
                opened.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                #expect(opened.fadingContent)
                let taken = AppTransition.captures
                let level = window.level
                controller.close()
                #expect(controller.run === opened && controller.phase == .closing && !opened.handedOver)
                #expect(AppTransition.captures == taken && window.isVisible && window.level == level)
                // From where the fade had got to, not the picture whole.
                #expect((opened.startPose?.container ?? 1) <= 1)
            }
        }

        /// The overlay still fading out is taken over only when it stands where the close would put one: the window resized
        /// meanwhile, the close starts an overlay of its own.
        @Test func aCloseTakesOverTheFadingOverlayOnlyWhereItStands() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let opened = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                ticks.turns.removeFirst()()
                opened.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                window.setFrame(window.frame.insetBy(dx: 20, dy: 20), display: false)
                controller.close()
                #expect(controller.phase == .closing && controller.run !== opened && opened.ended)
            }
        }

        /// With the window's picture kept, the close starts on it: the overlay shows it and the real window goes in the same
        /// turn, nothing captured.
        @Test func aCloseStartsOnTheKeptPictureAtOnce() {
            morphing { controller, ticks in
                AppTransition.isKey = { _ in true }
                controller.show(.done)
                ticks.runTurns()
                guard let opened = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                opened.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                opened.end()
                controller.keepPictureNow()
                let taken = AppTransition.captures
                controller.close()
                guard let closing = controller.run else { return #expect(Bool(false), "no close morph") }
                #expect(AppTransition.captures == taken && closing.image != nil && ticks.blocks.isEmpty)
                #expect(!window.isVisible && closing.startPose?.container == 1 && closing.startPose?.window == 1)
            }
        }

        /// The close is committed before restoring the bar; if that callback opens the window again, its opening takes over.
        @Test func restoringTheBarCanReverseTheCloseAlreadyUnderWay() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let opened = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                ticks.turns.removeFirst()()
                opened.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                opened.end()
                AppTransition.isKey = { _ in true }
                controller.keepPictureNow()
                var restored = false
                controller.onClosing = {
                    restored = true
                    #expect(controller.run?.startPose != nil && !window.isVisible)
                    controller.show(.settings)
                }
                defer { controller.onClosing = nil }
                controller.close()
                guard let closing = controller.run else { return #expect(Bool(false), "no close morph") }
                #expect(restored && controller.phase == .opening && controller.run === closing)
                // The callback's opening is the animation completed now, so the real window takes over.
                closing.complete()
                #expect(window.isVisible && window.alphaValue == 1 && controller.isOpen)
            }
        }

        /// Opened, then closed with the keyboard (the picture it closes on is kept), and its close under way.
        private func openAndStartClosing(_ controller: AppWindowController, _ ticks: Ticks, on place: AppDestination) {
            AppTransition.isKey = { _ in true }
            controller.show(place)
            ticks.runTurns()
            ticks.turns = []
            controller.run?.complete()
            ticks.blocks.removeFirst()()
            ticks.blocks.removeFirst()()
            // A while later: the opening's overlay gone, the picture kept as the idle keeper would.
            controller.run?.end()
            controller.keepPictureNow()
            controller.close()
        }

        /// Short of memory as a morphing close is under way, its picture is not kept for the next open, and the content the
        /// close's tidying takes out of the window goes with it (it was still in the window as the pressure came).
        @Test func memoryPressureJustBeforeTheCloseIsTidiedLetsGoOfTheContent() {
            morphing { controller, ticks in
                openAndStartClosing(controller, ticks, on: .settings)
                controller.run?.complete()
                #expect(controller.keepsPicture && controller.window?.contentViewController != nil)
                controller.memoryPressure(elevated: true)
                #expect(!controller.keepsPicture && controller.content != nil)
                ticks.runTurns()
                #expect(controller.window?.contentViewController == nil && controller.content == nil)
            }
        }

        /// Work that can wait holds from the morph's start (the opening's, then the close's that takes over) until it is over.
        @Test func theMotionGateHoldsWhileTheWindowMorphs() {
            morphing { controller, ticks in
                controller.show(.settings)
                #expect(MotionGate.moving)
                ticks.runTurns()
                ticks.turns = []
                controller.close()
                #expect(controller.phase == .closing && MotionGate.moving)
                controller.run?.complete()
                #expect(controller.phase == .idle && !MotionGate.moving)
            }
        }

        /// The window open with no morph, in front and with the keyboard, the user idle, no picture taken lately.
        private func openForTheKeeper(_ controller: AppWindowController) -> NSWindow? {
            AppTransition.enabled = false
            controller.show(.done)
            AppTransition.enabled = true
            AppTransition.isKey = { _ in true }
            AppTransition.isFront = { _ in true }
            AppTransition.inputIdle = { _ in true }
            AppTransition.lastCapture = -.infinity
            // A flat page isolates the keeper's decisions from SwiftUI's drawing cost and appearing callbacks.
            if let window = controller.window {
                let page = NSViewController()
                page.view = NSView(frame: window.contentView?.bounds ?? .zero)
                page.view.wantsLayer = true
                page.view.layer?.backgroundColor = NSColor.white.cgColor
                window.contentViewController = page
            }
            // Pictures of this page known to be cheap (a debug build's own would not be).
            AppTransition.costs = AppTransition.CaptureCosts()
            if let window = controller.window {
                for scale in [window.backingScaleFactor, AppTransition.reducedScale(of: window)] {
                    let cost = scale == window.backingScaleFactor ? 0.01 : 0.0025
                    AppTransition.costs.record(cost, size: AppTransition.drawnSize(window), pixelScale: scale,
                                               page: AppTransition.page(.done))
                }
            }
            return controller.window
        }

        @Test(arguments: ["none", "size", "place", "key"])
        func aCloseWithoutAnEligiblePictureDrawsNoGlance(reason: String) throws {
            try morphing { controller, ticks in
                AppTransition.isKey = { _ in true }
                controller.show(.done)
                ticks.runTurns()
                controller.run?.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                controller.run?.end()
                let window = try #require(controller.window)
                if reason != "none" {
                    controller.keepPictureNow()
                    #expect(controller.keepsPicture)
                }
                switch reason {
                case "size":
                    let size = try #require(window.contentView).bounds.size
                    window.setContentSize(NSSize(width: size.width + 80, height: size.height + 40))
                case "place": controller.navigator.go(.settings)
                case "key": AppTransition.isKey = { _ in false }
                default: break
                }
                let glances = AppTransition.glances, captures = AppTransition.captures
                controller.close()
                #expect(controller.phase == .closing && controller.run?.image == nil)
                #expect(AppTransition.glances == glances && AppTransition.captures == captures)
            }
        }

        /// The idle keeper keeps off the user's input, waiting three times what its picture would cost, and keeps a soft
        /// picture when a sharp one would cost over its budget, so no look holds a key typed meanwhile for long.
        @Test func theIdleKeeperBoundsWhatItCosts() throws {
            try morphing { controller, _ in
                let window = try #require(openForTheKeeper(controller))
                AppTransition.inputIdle = { _ in false }
                controller.keepPicture()
                #expect(!controller.keepsPicture)
                var asked: TimeInterval = 0
                AppTransition.inputIdle = { asked = $0; return true }
                let size = AppTransition.drawnSize(window), page = AppTransition.page(.done)
                // Sharp costs over the budget on this page: soft, and the wait is three times its cost (half a second).
                AppTransition.costs.record(0.5, size: size, pixelScale: window.backingScaleFactor, page: page)
                let soft = AppTransition.reducedScale(of: window)
                // Two looks: a picture only of a window at rest.
                controller.keepPicture()
                controller.keepPicture()
                #expect(controller.keepsPicture && controller.keptPictureIsSoft && asked == 0.5)
                // Soft over it too: no picture at all (a close fades the live window instead).
                let taken = AppTransition.captures
                AppTransition.costs.record(0.2, size: size, pixelScale: soft, page: page)
                controller.pick(message: UUID())
                controller.keepPicture()
                controller.keepPicture()
                #expect(AppTransition.captures == taken)
            }
        }

        @Test func theIdleKeeperBacksOffWhenNeitherCaptureScaleFitsItsBudget() throws {
            try morphing { controller, _ in
                let window = try #require(openForTheKeeper(controller))
                let size = AppTransition.drawnSize(window), page = AppTransition.page(.done)
                for scale in [window.backingScaleFactor, AppTransition.reducedScale(of: window)] {
                    AppTransition.costs.record(0.2, size: size, pixelScale: scale, page: page)
                }
                let captures = AppTransition.captures
                controller.keepPicture()
                #expect(controller.keeperPace == 0.5)
                controller.keepPicture()
                controller.keepPicture()
                controller.keepPicture()
                #expect(controller.keeperPace == AppWindowController.keeperPaces.longest)
                #expect(AppTransition.captures == captures && !controller.keepsPicture)
            }
        }

        /// The idle keeper settles: a picture only once two looks agree, then no glance at all while nothing is typed, clicked,
        /// asked or synced (what ticks on its own is noise a close forgives), its looks further and further apart; something
        /// asked of the window has it look again, and a window drawn alike keeps its picture.
        @Test func theIdleKeeperSettles() throws {
            try morphing { controller, _ in
                _ = try #require(openForTheKeeper(controller))
                let taken = AppTransition.captures
                controller.keepPicture()
                #expect(!controller.keepsPicture && controller.keeperPace == 0.5)
                controller.keepPicture()
                #expect(controller.keepsPicture && AppTransition.captures == taken + 1 && controller.keeperPace == 1)
                let glances = AppTransition.glances
                controller.keepPicture()
                controller.keepPicture()
                #expect(AppTransition.glances == glances && AppTransition.captures == taken + 1)
                #expect(controller.keeperPace == 4)
                controller.pick(message: UUID())
                controller.keepPicture()
                #expect(AppTransition.glances == glances + 1 && AppTransition.captures == taken + 1)
                // At the slowest pace a glance checks the window moved no further than noise, unmarked.
                controller.keepPicture()
                #expect(AppTransition.glances == glances + 2 && AppTransition.captures == taken + 1)
                #expect(controller.keepsPicture)
            }
        }

        /// What the window shows of Claude besides the inbox and the Router (sessions, their activity, forms pending) marks
        /// it too; and a picture an opening's handoff faded from is forgiven nothing.
        @Test func claudesSessionsMarkTheWindowAndAFadedHandoffsPictureIsForgivenNothing() {
            morphing { controller, ticks in
                let before = controller.marks
                controller.store.pendingForms = [:]
                #expect(controller.marks != before)
                let marked = controller.marks
                controller.store.threadWork = [:]
                #expect(controller.marks != marked)
                closeWithKeptPicture(controller, ticks, on: .done)
                controller.show(.done)
                guard let picture = controller.run?.picture else { return #expect(Bool(false), "no kept picture") }
                #expect(picture.marks != nil && picture.handedOver(fading: false).marks != nil)
                #expect(picture.handedOver(fading: true).marks == nil)
            }
        }

        @Test func aChangedTaskTitleIsNotForgivenAsPictureNoise() throws {
            try morphing { controller, _ in
                controller.store.backgroundWork = ["session": [BackgroundWork(id: "task", kind: .agent, title: "Read logs", since: .now)]]
                let bitmap = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                let pixels = [UInt8](repeating: 100, count: 20 * 20 * 4)
                let before = AppTransition.Glance(width: 20, height: 20, pixels: pixels)
                var changed = pixels
                changed[0] = 200 // One pixel changed: within the close's noise tolerance.
                let now = AppTransition.Glance(width: 20, height: 20, pixels: changed)
                let picture = AppTransition.Picture(image: try #require(bitmap.makeImage()), frame: .zero, scale: 1,
                                                    destination: .router, glance: before, marks: controller.marks)
                @MainActor func freshness() -> AppTransition.Freshness {
                    AppTransition.freshness(of: picture, glance: now, marks: controller.marks, destination: .router,
                                            tolerance: AppTransition.Glance.closeTolerance)
                }
                #expect(freshness() == .cosmetic)
                controller.store.backgroundWork["session"]?[0].title = "Fix the failure"
                #expect(freshness() == .stale)
            }
        }

        /// The keeper runs only for a window shown, with the keyboard and in front, and stops as it resigns the keyboard,
        /// whatever the morph's phase.
        @Test func theKeeperRunsOnlyForAWindowInFrontWithTheKeyboard() throws {
            try morphing { controller, _ in
                _ = try #require(openForTheKeeper(controller))
                AppTransition.isFront = { _ in false }
                controller.keepPictureFresh()
                #expect(controller.keeperTimer == nil)
                AppTransition.isFront = { _ in true }
                controller.keepPictureFresh()
                #expect(controller.keeperTimer != nil)
                controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
                #expect(controller.keeperTimer == nil)
            }
        }

        /// The idle keeper's timer goes with its controller: it does not wake every second for nothing once the window is gone.
        @Test func theKeeperStopsWithItsController() {
            morphing { _, _ in
                var other: AppWindowController? = AppWindowController(store: Store(), remembers: false, checksClaudeCode: false)
                AppTransition.enabled = false
                other?.show(.done)
                AppTransition.enabled = true
                AppTransition.isKey = { _ in true }
                AppTransition.isFront = { _ in true }
                other?.keepPictureFresh()
                let window = other?.window
                defer { window?.close() }
                guard let timer = other?.keeperTimer else { return #expect(Bool(false), "no keeper") }
                #expect(timer.isValid)
                other = nil
                timer.fire()
                #expect(!timer.isValid)
            }
        }

        /// Every close lets go of the kept picture in a while, a morph's or not (closed out of sight, it does not morph), and
        /// an opening calls that off.
        @Test func everyCloseLetsGoOfThePictureInAWhile() {
            morphing { controller, ticks in
                openAndStartClosing(controller, ticks, on: .done)
                controller.run?.complete()
                #expect(controller.keepsPicture && controller.keptPictureExpires)
                controller.show(.done)
                #expect(!controller.keptPictureExpires)
                controller.close()
                controller.run?.complete()
                #expect(controller.phase == .idle && controller.keptPictureExpires)
                // Opened and closed with no morph: the close still lets go of it in a while.
                AppTransition.enabled = false
                controller.show(.done)
                #expect(controller.window?.isVisible == true && !controller.keptPictureExpires)
                controller.close()
                #expect(controller.window?.isVisible != true && controller.keptPictureExpires)
            }
        }

        /// A close starts on the kept picture when nothing happened to the window since; something asked of it (a card, a
        /// message) marks it, so a small difference is no longer forgiven (`aPicturesFreshness…`).
        @Test func aCloseTakesAPictureAgainOnlyWhenSomethingHappened() {
            morphing { controller, ticks in
                openAndStartClosing(controller, ticks, on: .done)
                // Turned round, and handed over: the close's picture is kept.
                controller.show(.done)
                ticks.runTurns()
                controller.run?.complete()
                ticks.blocks.forEach { $0() }
                ticks.blocks = []
                #expect(controller.keepsPicture)
                let taken = AppTransition.captures
                controller.close()
                #expect(controller.phase == .closing && AppTransition.captures == taken)
                controller.show(.done)
                ticks.runTurns()
                controller.run?.complete()
                ticks.blocks.forEach { $0() }
                ticks.blocks = []
                // Something asked of it marks the window: no small difference is forgiven any more.
                let before = controller.marks
                controller.pick(message: UUID())
                #expect(controller.marks != before)
                controller.close()
                #expect(controller.phase == .closing)
            }
        }

        /// Short of memory while open, a morphing close keeps no picture for the next open.
        @Test func memoryPressureWhileOpenKeepsNoPictureOnAMorphingClose() {
            morphing { controller, ticks in
                controller.memoryPressure(elevated: true)
                openAndStartClosing(controller, ticks, on: .settings)
                #expect(controller.phase == .closing && !controller.keepsPicture)
                controller.memoryPressure(elevated: false)
            }
        }

        /// Opened, its picture kept, closed and the close over: the window closed with a sharp picture kept, as after a while
        /// open and still.
        private func closeWithKeptPicture(_ controller: AppWindowController, _ ticks: Ticks, on place: AppDestination) {
            openAndStartClosing(controller, ticks, on: place)
            controller.run?.complete()
            ticks.runTurns()
        }

        /// A close turned round by a banner's click on another card of the same place captures nothing: the overlay, whose
        /// picture shows the card it closed on, fades into the real window at the handoff.
        @Test func aCloseTurnedRoundOnAnotherEntryFadesIntoIt() throws {
            try morphing { controller, ticks in
                let entries = controller.store.routerBriefs.page().entries
                try #require(entries.count >= 2)
                controller.store.routerBriefs.focus(entries[0].target)
                openAndStartClosing(controller, ticks, on: .router)
                guard let run = controller.run, let shown = run.image else { return #expect(Bool(false), "no close morph") }
                let taken = AppTransition.captures
                controller.show(entry: entries[1].target)
                #expect(controller.phase == .opening && controller.run === run && controller.navigator.selection == .router)
                ticks.runTurns()
                run.complete()
                #expect(run.image === shown && run.fadesOut && AppTransition.captures == taken)
            }
        }

        /// Closed before its handoff, an opening to another place keeps the picture it started on as that of the place it
        /// shows: turned round, the overlay fades into the real window rather than handing over on the other place's picture.
        @Test func aCloseCutShortOnAnotherPlaceFadesWhenTurnedRound() {
            morphing { controller, ticks in
                closeWithKeptPicture(controller, ticks, on: .router)
                ticks.turns = []
                #expect(controller.phase == .idle && controller.window?.isVisible == false)
                // Settings starts on the Router's picture; the window does not get the keyboard before the toggle.
                AppTransition.isKey = { _ in false }
                controller.show(.settings)
                guard let run = controller.run, let started = run.image else { return #expect(Bool(false), "no kept picture") }
                controller.close()
                #expect(controller.phase == .closing && controller.run === run)
                controller.show(.settings)
                #expect(controller.phase == .opening && controller.run === run && run.image === started)
                run.complete()
                #expect(run.image === started && run.fadesOut)
            }
        }

        /// Nothing is captured on the way in, whatever is asked meanwhile (another place by the Go menu, a card, a message):
        /// the overlay keeps what it started on and fades into the real window at the handoff.
        @Test func anOpeningNeverCaptures() throws {
            try morphing { controller, ticks in
                closeWithKeptPicture(controller, ticks, on: .router)
                let taken = AppTransition.captures
                controller.show(.router)
                ticks.runTurns()
                guard let run = controller.run, let shown = run.image else { return #expect(Bool(false), "no kept picture") }
                if let e = controller.store.routerBriefs.page().entries.last { controller.pick(entry: e.target) }
                controller.pick(message: UUID())
                controller.navigator.go(.done)
                ticks.runTurns()
                run.complete()
                #expect(AppTransition.captures == taken && run.image === shown && run.fadesOut)
                // A first opening, on the bare surface, likewise.
                let other = AppWindowController(store: controller.store, remembers: false, checksClaudeCode: false)
                other.bar = controller.bar
                other.show(.settings)
                ticks.runTurns()
                other.run?.complete()
                #expect(AppTransition.captures == taken && other.run?.image == nil && other.run?.fadesOut == true)
                other.run?.end()
                other.close()
            }
        }

        /// Once the overlay has let go of its picture (the real window's live pixels show), a change of place or a card asked
        /// for takes no picture any more: nothing would show it.
        @Test func nothingIsPicturedOnceTheOverlayHasLetGo() throws {
            try morphing { controller, ticks in
                AppTransition.isKey = { _ in true }
                controller.show(.settings)
                ticks.runTurns()
                ticks.turns = []
                guard let run = controller.run else { return #expect(Bool(false), "no morph") }
                run.complete()
                ticks.blocks.removeFirst()()
                ticks.blocks.removeFirst()()
                try #require(run.handedOver && controller.phase == .opening)
                let taken = AppTransition.captures
                controller.navigator.go(.done)
                controller.showUpdates()
                if let e = controller.store.routerBriefs.page().entries.first { controller.pick(entry: e.target) }
                ticks.runTurns()
                #expect(AppTransition.captures == taken)
            }
        }

        /// Opened again with nothing changed since its close, the window takes no picture: the one kept is still the window
        /// as drawn, and the overlay hands over on it.
        @Test func reopeningUnchangedTakesNoPicture() {
            morphing { controller, ticks in
                // The archive: no field takes the keyboard (and draws its focus ring) as the window comes back.
                closeWithKeptPicture(controller, ticks, on: .done)
                #expect(controller.phase == .idle && controller.keepsPicture)
                let taken = AppTransition.captures
                controller.show(.done)
                ticks.runTurns()
                ticks.turns = []
                guard let run = controller.run, let shown = run.image else { return #expect(Bool(false), "no kept picture") }
                run.complete()
                #expect(AppTransition.captures == taken && run.image === shown && run.picture?.exact == true)
            }
        }

        /// Something asked of the window between the handoff's check and the overlay letting go (two refreshes) has the
        /// overlay fade into the real window rather than cut away from a picture that no longer stands for it.
        @Test func somethingAskedAsTheOverlayLetsGoHasItFade() throws {
            try morphing { controller, ticks in
                AppTransition.enabled = false
                controller.show(.done)
                AppTransition.enabled = true
                let window = try #require(controller.window)
                for asked in [false, true] {
                    let run = try #require(AppTransition.makeRun(for: window, picture: nil, bar: controller.bar()))
                    defer { run.end() }
                    run.open(reduced: false) {
                        run.handoff(fading: false, stillExact: { !asked }, reveal: {}, finished: {})
                    }
                    run.complete()
                    ticks.blocks.removeFirst()()
                    ticks.blocks.removeFirst()()
                    #expect(run.handedOver && run.fadesOut == asked)
                }
            }
        }

        /// A close turned round takes no picture either: it hands over on the one it shows, or fades from it.
        @Test func aCloseTurnedRoundTakesNoPicture() {
            morphing { controller, ticks in
                openAndStartClosing(controller, ticks, on: .done)
                guard let run = controller.run, let shown = run.image else { return #expect(Bool(false), "no close morph") }
                let taken = AppTransition.captures
                controller.show(.done)
                #expect(controller.phase == .opening && controller.run === run)
                ticks.runTurns()
                run.complete()
                #expect(run.image === shown && AppTransition.captures == taken)
            }
        }

        /// The handoff looks at the window again before it cuts: a change since the picture (its appearing's, a turn on) has
        /// it fade into the real window rather than cut to it.
        @Test func theHandoffLooksAgainBeforeItCuts() {
            morphing { controller, ticks in
                closeWithKeptPicture(controller, ticks, on: .done)
                controller.show(.done)
                ticks.runTurns()
                guard let run = controller.run, let view = controller.window?.contentView else {
                    return #expect(Bool(false), "no morph")
                }
                #expect(run.picture?.exact == true)
                view.layer?.backgroundColor = NSColor.systemRed.cgColor
                view.layer?.opacity = 0.5
                run.complete()
                #expect(run.fadesOut)
            }
        }

        /// Minimized on its way in, then closed by a toggle, the window turned round by another toggle opens again: the close's
        /// end does not close it after all.
        @Test func aCloseOfAWindowMinimizedOnItsWayInTurnsRound() {
            morphing { controller, ticks in
                controller.show(.settings)
                ticks.runTurns()
                ticks.turns = []
                guard let window = controller.window else { return #expect(Bool(false), "no window") }
                // ⌘M: a window under test does not minimize at once.
                AppTransition.isMiniaturized = { $0 === window }
                controller.close()
                guard let closing = controller.run else { return #expect(Bool(false), "no close morph") }
                #expect(controller.phase == .closing)
                controller.show(.settings)
                #expect(controller.phase == .opening && controller.isOpen)
                closing.complete()
                ticks.runTurns()
                #expect(controller.phase != .closing && controller.isOpen)
            }
        }

        /// A morph turned round mid-fade starts its shadow where it is drawn: the pose read back holds the shadow apart from the
        /// container's opacity, which the new animation multiplies it by (once), so the shadow does not jump darker or lighter.
        @Test func aPoseReadMidFadeHoldsTheShadowApartFromTheContainer() {
            let drawn: Float = 0.5 * 0.4
            let shadow = AppTransition.Pose.shadow(drawn: drawn, container: 0.4)
            #expect(abs(shadow * 0.4 - drawn) < 0.0001)
            #expect(AppTransition.Pose.shadow(drawn: 0, container: 0) == 0)
            #expect(AppTransition.Pose.shadow(drawn: 1, container: 1) == 1)
        }

        @Test func closingWhileOpeningPicksUpFromWhereTheOverlayIs() {
            morphing { controller, ticks in
                controller.show(.settings)
                guard let run = controller.run, let window = controller.window else { return #expect(Bool(false), "no morph") }
                let before = run.pose
                let overlayFrame = run.overlay.frame
                let geometry = run.geometry.frame
                controller.close()
                // On its way out it counts as closed: a toggle opens it again.
                #expect(controller.phase == .closing && controller.run === run && !controller.isOpen)
                #expect(run.startPose?.rect == before.rect && run.startPose?.radius == before.radius)
                // The real window is out of the way and the overlay carries the close.
                #expect(!window.isVisible && run.overlay.isVisible)
                // Opening again turns it round from there.
                let now = run.pose
                controller.show(.settings)
                #expect(controller.phase == .opening && run.startPose?.rect == now.rect && controller.isOpen)
                #expect(ticks.blocks.isEmpty)
                #expect(controller.run === run && run.overlay.frame == overlayFrame && run.geometry.frame == geometry)
                #expect(run.overlay.frame.origin == UnderTest.away)
            }
        }
    }
}

/// A view that counts its body runs, over a store it reads.
@Observable @MainActor private final class ProbeModel { var n = 0 }
@MainActor private final class ProbeCount { var bodies = 0 }

private struct ProbeView: View {
    let model: ProbeModel
    let count: ProbeCount
    var body: some View {
        count.bodies += 1
        return Text("\(model.n)").frame(width: 200, height: 100)
    }
}
