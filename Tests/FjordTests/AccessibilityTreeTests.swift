import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// One element of the accessibility tree VoiceOver would read, as SwiftUI builds it for a hosted view.
struct AXNode: Equatable {
    let role: String
    let label: String
    let children: [AXNode]
    /// What a static text says (its value, not its label).
    var value = ""
    /// What the app identifies it by, for tests to find it (`accessibilityIdentifier`); empty for most.
    var identifier = ""

    /// This element and everything under it.
    var all: [AXNode] { [self] + children.flatMap(\.all) }

    /// The controls: what a screen reader user presses, ticks or types in, so each must say what it is.
    static let controls: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
                                        "AXTextArea", "AXSlider", "AXLink", "AXComboBox"]
}

/// The bar (or the app window) in a window of its own, offscreen, and its accessibility tree.
@MainActor
enum AccessibilityTree {
    /// SwiftUI builds the tree only when it believes an assistive technology is attached.
    private static let enabled: Void = {
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("setAccessibilityEnhancedUserInterface:"), with: true as NSNumber)
    }()

    /// The tree of the bar on `edge`, in the state `configure` asks for once it is on screen.
    static func render(edge: DockEdge = .right, scenario: Demo.Scenario = .agents, size: CGSize = CGSize(width: 1000, height: 800),
                       ready: (AXNode) -> Bool = hasControls,
                       configure: (Store, HubState) -> Void = { _, _ in }) async throws -> AXNode {
        _ = enabled
        let store = Store()
        Demo.populate(store, scenario)
        let hub = HubState()
        let view = FjordHub(store: store, ui: UIState(persists: false, edge: edge), hub: hub)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        configure(store, hub)
        return await settled(hosting, ready: ready)
    }

    /// The tree of any view, in a window of its own (the app window, say).
    static func render<V: View>(_ view: V, size: CGSize = CGSize(width: 920, height: 640),
                                ready: (AXNode) -> Bool = hasControls) async throws -> AXNode {
        _ = enabled
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        return await settled(hosting, ready: ready)
    }

    /// What a tree must have before it is read at all: some controls (an empty tree, before SwiftUI has built it, has no
    /// unnamed control either).
    nonisolated static func hasControls(_ tree: AXNode) -> Bool {
        tree.all.contains { AXNode.controls.contains($0.role) }
    }

    /// The tree once it is `ready` and the same over several turns of the main actor in a row (SwiftUI has drawn what it had
    /// pending), however slow the machine; the shared watchdog, past which the test fails.
    private static func settled(_ hosting: NSView, ready: (AXNode) -> Bool) async -> AXNode {
        var watchdog = Watchdog(), last: AXNode?, same = 0
        while !watchdog.expired() {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            let tree = node(hosting)
            same = ready(tree) && tree == last ? same + 1 : 0
            last = tree
            if same >= 5 { return tree }
        }
        // Never ready, or never still: the tree read now would prove nothing (an empty one has no unnamed control).
        hosting.layoutSubtreeIfNeeded()
        let tree = node(hosting)
        Issue.record("""
            The accessibility tree wasn't ready and steady within \(Int(watchdog.elapsed)) s (\(ready(tree) ? "still changing" : "no controls")): \
            \(tree.children.count) children at the top, \(hosting.subviews.count) subviews, in a window \
            \(hosting.window.map { "\($0.frame), visible \($0.isVisible), occlusion \($0.occlusionState.rawValue)" } ?? "none"); \
            \(waitContext())
            """)
        return tree
    }

    private static func node(_ element: Any) -> AXNode {
        guard let object = element as? NSObject else { return AXNode(role: "?", label: "", children: []) }
        func value() -> String { (object.value(forKey: "accessibilityValue") as? String) ?? "" }
        func string(_ key: String) -> String { (object.value(forKey: key) as? String) ?? "" }
        let role = string("accessibilityRole")
        // A scroll bar's parts are the system's own.
        let children = role == "AXScrollBar" ? [] : ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).map(node)
        return AXNode(role: role, label: string("accessibilityLabel"), children: children,
                      value: role == "AXStaticText" ? value() : "", identifier: string("accessibilityIdentifier"))
    }
}

@MainActor
@Suite(.hostsWindows) struct AccessibilityTreeTests {
    /// What the hub in `state` has for a control without a name, wherever it is.
    private func unnamed(_ state: String, edge: DockEdge = .right, scenario: Demo.Scenario = .agents,
                         configure: @escaping (Store, HubState) -> Void) async throws -> [String] {
        let tree = try await AccessibilityTree.render(edge: edge, scenario: scenario, configure: configure)
        return tree.all.filter { AXNode.controls.contains($0.role) && $0.label.isEmpty }.map { "\(state) (\(edge)): \($0.role) has no label" }
    }

    @Test func theTreeHasTheControlsItIsMeasuredOn() async throws {
        // A render that came out empty would pass the test below for nothing.
        let tree = try await AccessibilityTree.render(configure: { _, hub in hub.section = .inbox })
        let buttons = tree.all.filter { $0.role == "AXButton" }
        #expect(buttons.count > 5, "\(buttons.count) buttons in \(tree.all.map(\.role))")
        #expect(buttons.contains { !$0.label.isEmpty })
    }

    @Test func noControlIsLeftWithoutAName() async throws {
        var missing: [String] = []
        for edge in [DockEdge.right, .top] {
            missing += try await unnamed("at rest", edge: edge) { _, _ in }
            for section in [HubSection.inbox, .router, .controls] {
                missing += try await unnamed("peek \(section)", edge: edge) { _, hub in hub.section = section }
            }
        }
        missing += try await unnamed("Archive tab") { _, hub in hub.section = .inbox; hub.tab = .done }
        missing += try await unnamed("CI tab") { store, hub in
            hub.section = .inbox
            hub.tab = store.categories.first { $0.isCI }.map { .category($0.id) }
        }
        missing += try await unnamed("signed out", scenario: .signedOut) { _, hub in hub.section = .inbox }
        missing += try await unnamed("update ready", scenario: .updateReady) { _, hub in hub.section = .controls }
        missing += try await unnamed("peek router", scenario: .router) { _, hub in hub.section = .router }
        #expect(missing.isEmpty, "\(missing)")
    }

    /// The Router place has a question entry focused, so its options' controls are counted too.
    @Test func everyPlaceOfTheAppWindowNamesItsControls() async throws {
        var missing: [String] = []
        let places: [(String, (Store) -> AppDestination)] = [
            ("category", { $0.shownCategories[0].id.asDestination }), ("Archive", { _ in .done }), ("Router", { _ in .router }),
            ("Settings", { _ in .settings }), ("Inbox categories", { _ in .categories }), ("Snippets", { _ in .snippets }),
        ]
        for (name, destination) in places {
            let store = Store()
            Demo.populate(store, .router)
            // The categories ask GitHub for suggestions: a GitHub of its own, with nothing to suggest.
            store.gh.session = StubbedGitHub.session { _ in .init(200, "[]") }
            let model = RouterModel()
            // The brief with its question entry focused, its options' controls counted too.
            if name == "Router" { store.routerBriefs.focus(store.routerBriefs.page().entries.first { $0.kind == .question }?.target) }
            let root = AppRootView(store: store, navigator: AppNavigator(start: destination(store), defaults: nil),
                                   routerModel: model, hub: HubState(), checksClaudeCode: false)
            let tree = try await AccessibilityTree.render(root, size: CGSize(width: 1200, height: 800))
            missing += tree.all.filter { AXNode.controls.contains($0.role) && $0.label.isEmpty }
                .map { "\(name): \($0.role) has no label" }
            if name == "Router" {
                #expect(store.routerBriefs.focused != nil)
                #expect(tree.all.contains { $0.label == "Message the Router" }, "\(tree.all.map(\.label))")
            }
        }
        #expect(missing.isEmpty, "\(missing)")
    }
}

private extension UUID {
    var asDestination: AppDestination { .category(self) }
}
