import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fjord

@MainActor
@Suite struct PalettePlacesSourceTests {
    /// A context over a demo store (Triage on; the Router off until a test turns it on), recording where `go` was asked to go.
    @MainActor private final class Rig {
        let store = Store()
        let navigator = AppNavigator(start: .router, defaults: nil)
        let routerModel = RouterModel()
        let hub = HubState()
        var went: [AppDestination] = []

        init(router: Bool = false, triage: Bool = true) {
            Demo.populate(store, .router)
            store.settings.triage = triage
            // The demo has the Router on: each test says whether it wants it.
            store.router.enabled = router
            store.agents.enabled = router
        }

        var context: PaletteContext {
            PaletteContext(store: store, navigator: navigator, routerModel: routerModel, hub: hub, go: { [self] in went.append($0) })
        }

        var items: [PaletteItem] { PalettePlacesSource.make(context).items }

        func item(_ id: String) -> PaletteItem? { items.first { $0.id == id } }
    }

    @Test func pagesFollowTheToolsThatAreOn() {
        let all = Rig(router: true)
        let ids = Set(all.items.filter { $0.kind == .page }.map(\.id))
        #expect(ids == ["page:done", "page:router", "page:snippets", "page:settings", "page:categories"])

        let none = Rig(router: false, triage: false)
        #expect(Set(none.items.filter { $0.kind == .page }.map(\.id)) == ["page:settings"])

        let triage = Rig()
        let pages = Set(triage.items.filter { $0.kind == .page }.map(\.id))
        #expect(pages == ["page:done", "page:snippets", "page:settings", "page:categories"])
    }

    @Test func pagesAreNamedAsTheWindowNamesThemAndGoThere() throws {
        let rig = Rig(router: true)
        let router = try #require(rig.item("page:router"))
        #expect(router.title == "Router" && router.weight == 1)
        #expect(try #require(rig.item("page:done")).title == "Archive")
        #expect(try #require(rig.item("page:categories")).title == "Inbox categories")
        // The same names as the Go menu.
        let window = AppDestination.all(shown: rig.store.shownCategories.map(\.id), tools: rig.store.tools)
        #expect(window.count > 6)
        router.actions[0].run()
        #expect(rig.went == [.router])
        // ⌘1…: the categories come first in the sidebar, so the Router's number counts them.
        let position = try #require(window.firstIndex(of: .router))
        #expect(router.actions[0].caps == ["⌘", String(position + 1)])
        // A category is the Triage source's.
        #expect(!rig.items.contains { $0.id.hasPrefix("page:category") })
    }

    @Test func settingsRowsFollowTheConditionsOfTheirSection() {
        let off = Rig()
        let offIDs = Set(off.items.filter { $0.kind == .setting }.map(\.id))
        #expect(offIDs.contains("setting:github.token"))
        #expect(offIDs.contains("setting:general.interval"))
        #expect(!offIDs.contains { $0.hasPrefix("setting:claude.") })

        let on = Rig(router: true)
        let onIDs = Set(on.items.filter { $0.kind == .setting }.map(\.id))
        #expect(onIDs.contains("setting:claude.key") && onIDs.contains("setting:claude.comments"))
        // Shortcuts follow the tools too.
        #expect(onIDs.contains("setting:shortcuts.router"))
        #expect(!offIDs.contains("setting:shortcuts.router"))

        let routerOnly = Rig(router: true, triage: false)
        let routerIDs = Set(routerOnly.items.filter { $0.kind == .setting }.map(\.id))
        #expect(!routerIDs.contains("setting:github.token") && !routerIDs.contains("setting:claude.comments"))
        #expect(!routerIDs.contains("setting:general.interval"))
        #expect(routerIDs.contains("setting:code-folders.clones"))

        let neither = Rig(triage: false)
        #expect(!Set(neither.items.map(\.id)).contains("setting:code-folders.clones"))
    }

    @Test func aSettingsRowScrollsToItsSectionAndGoesToSettings() throws {
        let rig = Rig(router: true)
        let token = try #require(rig.item("setting:github.token"))
        #expect(token.title == "Personal access token" && token.subtitle == "Settings · GitHub" && token.weight == 0.8)
        #expect(token.keywords.contains("PAT") && token.keywords.contains("GitHub"))
        token.actions[0].run()
        #expect(rig.hub.settingsScroll?.id == SettingsView.githubID)
        #expect(rig.went == [.settings])
        // Another request is a new one, also for the same section.
        let first = rig.hub.settingsScroll?.seq ?? 0
        token.actions[0].run()
        #expect((rig.hub.settingsScroll?.seq ?? 0) > first)
        // The Router's row in Tools has an anchor of its own.
        try #require(rig.item("setting:tools.router")).actions[0].run()
        #expect(rig.hub.settingsScroll?.id == SettingsView.routerID)
        try #require(rig.item("setting:tools.triage")).actions[0].run()
        #expect(rig.hub.settingsScroll?.id == SettingsView.toolsID)
    }

    @Test func everySettingsRowHasAnAnchorInSettings() {
        let rig = Rig(router: true)
        var sections = Set<String>()
        for item in rig.items where item.kind == .setting {
            item.actions[0].run()
            let anchor = rig.hub.settingsScroll?.id ?? ""
            #expect(SettingsView.anchors.contains(anchor) || anchor == SettingsView.routerID, "\(item.id) -> \(anchor)")
            sections.insert(anchor)
        }
        #expect(sections.isSuperset(of: Set(SettingsView.anchors)))
        #expect(Set(SettingsView.anchors).count == SettingsView.anchors.count)
    }

    @Test func idsAreUniqueAndStable() {
        let rig = Rig(router: true)
        let first = rig.items.map(\.id)
        #expect(Set(first).count == first.count)
        #expect(rig.items.map(\.id) == first)
        for item in rig.items {
            #expect(item.id.hasPrefix(item.kind.rawValue + ":") || item.kind == .project && item.id.hasPrefix("project:"), "\(item.id)")
            #expect(!item.actions.isEmpty)
        }
    }

    @Test func theKeywordsLeadTheSynonyms() throws {
        let rig = Rig(router: true)
        #expect(try #require(rig.item("page:done")).keywords.contains("done"))
        #expect(try #require(rig.item("page:snippets")).keywords.contains("prompts"))
        #expect(try #require(rig.item("setting:general.login")).keywords.contains("startup"))
        #expect(try #require(rig.item("setting:claude.key")).keywords.contains("Jev") || rig.item("setting:claude.key")?.keywords.contains("jev") == true)
        #expect(try #require(rig.item("setting:notifications.desktop")).keywords.contains("banner"))
        #expect(try #require(rig.item("setting:shortcuts.refresh")).keywords.contains("keyboard"))
    }

    @Test func aSnippetsFirstActionFillsTheRouterWhileItIsOn() throws {
        let rig = Rig(router: true)
        let snippet = try #require(rig.store.snippets.first)
        let item = try #require(rig.item("snippet:" + snippet.id.uuidString))
        #expect(item.title == snippet.title && item.subtitle == snippet.preview)
        #expect(item.actions.map(\.title) == ["Use in the Router", "Show snippets", "Copy text"])
        item.actions[0].run()
        #expect(rig.routerModel.draft.contains(snippet.text.split(separator: "\n").first.map(String.init) ?? ""))
        #expect(rig.went == [.router])
        item.actions[1].run()
        #expect(rig.went == [.router, .snippets])

        let off = Rig()
        let plain = try #require(off.item("snippet:" + snippet.id.uuidString))
        #expect(plain.actions.map(\.title) == ["Show snippets", "Copy text"])
    }


    @Test func projectsAskTheRouterWhileItIsOn() throws {
        let rig = Rig(router: true)
        let folder = try #require(rig.store.projectFolders.first)
        let item = try #require(rig.item("project:" + folder))
        #expect(item.title == rig.store.folderName(folder))
        #expect(item.subtitle == (folder as NSString).abbreviatingWithTildeInPath)
        #expect(folder.split(separator: "/").allSatisfy { item.keywords.contains(String($0)) })
        #expect(item.actions.map(\.title) == ["Ask the Router about it", "Reveal in Finder"])
        item.actions[0].run()
        #expect(rig.routerModel.pointers == [.project(folder)])
        #expect(rig.went == [.router])
        let off = Rig()
        #expect(off.item("project:" + folder)?.actions.map(\.title) == ["Reveal in Finder"])
    }

    @Test func commandsAreThereOnlyUnderTheirConditions() throws {
        let triage = Rig()
        let ids = Set(triage.items.filter { $0.kind == .command }.map(\.id))
        #expect(ids.isSuperset(of: ["command:new-category", "command:add-code-folder", "command:refresh", "command:tools"]))
        // A build from source never updates itself.
        #expect(ids.contains("command:check-updates") == triage.store.updater.isRelease)
        #expect((triage.item("setting:updates.automatic") != nil) == triage.store.updater.isRelease)

        let none = Rig(triage: false)
        #expect(Set(none.items.filter { $0.kind == .command }.map(\.id)) == ["command:tools"])

        let routerOnly = Rig(router: true, triage: false)
        #expect(Set(routerOnly.items.filter { $0.kind == .command }.map(\.id)) == ["command:add-code-folder", "command:rewrite-briefs", "command:tools"])

        let refresh = try #require(triage.item("command:refresh"))
        #expect(refresh.actions[0].caps == triage.store.shortcut(.refresh).caps)
        triage.item("command:add-code-folder")?.actions[0].run()
        #expect(triage.hub.settingsScroll?.id == SettingsView.codeFoldersID && triage.went == [.settings])
        triage.item("command:tools")?.actions[0].run()
        #expect(triage.hub.settingsScroll?.id == SettingsView.toolsID)
    }

    @Test func newCategoryAsksForTheEditorOnTheCategoriesPage() throws {
        let rig = Rig()
        try #require(rig.item("command:new-category")).actions[0].run()
        #expect(rig.store.newCategoryRequest)
        #expect(rig.went == [.categories])
    }

    @Test func repeatingNewCategoryKeepsADraftThatIsOpen() {
        #expect(CategoriesView.startsDraft(whileEditing: nil))
        #expect(CategoriesView.startsDraft(whileEditing: .existing(UUID())))
        #expect(!CategoriesView.startsDraft(whileEditing: .new))
    }

    @Test func theTypeSafeKeyIsOfferedOnlyWhereSettingsShowsItsField() {
        let rig = Rig(router: true)
        rig.store.agents.iconsEnabled = false
        #expect(rig.item("setting:claude.key") == nil && rig.item("setting:claude.icons") != nil)
        rig.store.agents.iconsEnabled = true
        #expect(rig.item("setting:claude.key") != nil)
    }


    /// How far Settings scrolls when asked for a section, in a window too short to show the page.
    private func scrollOffset(toward anchor: String) async -> CGFloat {
        let rig = Rig(router: true)
        rig.hub.settingsScroll = ScrollRequest(id: anchor, seq: 1)
        let size = CGSize(width: 520, height: 400)
        let hosting = NSHostingView(rootView: SettingsView(store: rig.store, hub: rig.hub).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
            return nil
        }
        // The page takes the request once it has appeared; it is then cleared.
        for _ in 0..<100 where rig.hub.settingsScroll != nil {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        return scrollView(in: hosting)?.contentView.bounds.origin.y ?? -1
    }

    @Test func settingsScrollsToEverySectionAnchor() async {
        var offsets: [String: CGFloat] = [:]
        for anchor in SettingsView.anchors { offsets[anchor] = await scrollOffset(toward: anchor) }
        // The first section is at the top already; every other one is somewhere below it.
        for anchor in SettingsView.anchors where anchor != SettingsView.toolsID {
            #expect((offsets[anchor] ?? -1) > 0, "\(anchor) did not scroll: \(offsets)")
        }
        // Each to its own place: a section further down the page is further down.
        let down = SettingsView.anchors.dropFirst().compactMap { offsets[$0] }
        #expect(down.first == down.min() && Set(down).count > 3, "\(offsets)")
        // An anchor that isn't there goes nowhere.
        #expect(await scrollOffset(toward: "no-such-section") == 0)
    }

    @Test func buildingItIsCheap() {
        let rig = Rig(router: true)
        _ = rig.items
        let clock = ContinuousClock()
        let took = clock.measure { _ = rig.items }
        #expect(took < .milliseconds(50), "took \(took)")
    }
}
