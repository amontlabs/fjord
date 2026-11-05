import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Fjord

/// The Router's UI: the window's keys and model, the banners and the shortcut.
@MainActor
@Suite struct RouterUITests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func demo(_ scenario: Demo.Scenario = .router) -> Store {
        let store = Store()
        Demo.populate(store, scenario)
        store.interceptOpen = { _ in }
        return store
    }

    private func key(_ code: Int, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    /// The composer's text view holding `text`, the caret at `caret` (the end by default), as the keys see it.
    private func editor(_ model: RouterModel, _ text: String, caret: Int? = nil) -> NSTextView {
        model.draft = text
        let view = NSTextView()
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        model.followCaret(view)
        return view
    }

    // MARK: Window keys



    @Test func returnInTheComposerSendsAndShiftReturnDoesNot() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let editor = NSTextView()
        model.composerFocused = true
        model.draft = "tell lookout to run the tests"
        let before = store.router.decisions.count
        #expect(keys.key(key(kVK_Return, "\r", .shift), responder: editor))
        #expect(store.router.decisions.count == before && !model.draft.isEmpty)
        #expect(keys.key(key(kVK_Return, "\r"), responder: editor))
        #expect(model.draft.isEmpty)
        #expect(store.router.decisions.dropFirst(before).first?.triggerText == "tell lookout to run the tests")
        // Typing in the composer is its own.
        #expect(!keys.key(key(kVK_ANSI_A, "a"), responder: editor))
    }

    @Test func typingWithNothingFocusedGoesToTheComposer() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let request = model.focusRequest
        #expect(keys.key(key(kVK_ANSI_H, "h"), responder: nil))
        #expect(model.focusRequest != request && model.pendingKeys.count == 1)
    }

    // MARK: Sending

    @Test func theComposerIsShutWhileTheRouterOrTheSessionsAreOff() {
        let store = demo()
        let model = RouterModel()
        let before = store.router.decisions.count
        #expect(model.canSend(store))
        store.router.enabled = false
        #expect(!model.canSend(store))
        store.router.enabled = true
        store.agents.enabled = false
        #expect(!model.canSend(store))
        model.draft = "hello"
        model.send(store: store)
        #expect(model.draft == "hello" && store.router.decisions.count == before)
        // Typing with nothing focused doesn't go to a composer that can't send.
        let keys = RouterKeys(store: store, model: model)
        #expect(!keys.key(key(kVK_ANSI_H, "h"), responder: nil))
    }

    @Test func claudeCodeMissingIsSaidOnceLookedForAndSendWaits() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A store of a real Router (not a demo's), the app's folder of Claude Code in `dir`.
        let store = writing(nil)
        store.routerStatus.codeRoot = dir
        defer { store.persists = false; try? FileManager.default.removeItem(at: dir) }
        let model = RouterModel()
        #expect(model.claudeCodeMissing == nil && model.canSend(store))
        await model.checkClaudeCode(store)
        #expect(model.claudeCodeMissing == true && !model.canSend(store))
        model.draft = "hello"
        model.send(store: store)
        #expect(model.draft == "hello")
        // The app's copy appears: looking again finds it.
        let bin = dir.appendingPathComponent("2.1.293/abc/claude.app/Contents/MacOS")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        await model.checkClaudeCode(store)
        #expect(model.claudeCodeMissing == false && model.canSend(store))
        // The app's copy taken away: the window showing again sees it is gone.
        #expect(store.routerStatus.claudeCode != nil, "the Router's runs take the path found")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("2.1.293"))
        await model.checkClaudeCode(store)
        #expect(model.claudeCodeMissing == true && !model.canSend(store))
        #expect(store.routerStatus.claudeCode == nil, "no run is given the path gone")
    }

    // MARK: Reply and @

    @Test func escClearsTheSuggestionsThenTheReplyThenCloses() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        model.composerFocused = true
        store.routerBriefs.focus(store.routerBriefs.page().entries[0].target)
        let editor = editor(model, "tell @mi")
        #expect(!model.suggestions(store).isEmpty)
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(model.suggestions(store).isEmpty && store.routerBriefs.focused != nil)
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(store.routerBriefs.focused == nil)
        // Nothing left to step out of: the field keeps it, and the window stays.
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(store.routerBriefs.focused == nil && model.suggestions(store).isEmpty)
    }

    @Test func atSuggestsProjectsAndReturnOrTabPicksOne() throws {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        model.composerFocused = true
        _ = editor(model, "check @")
        let all = model.suggestions(store).map(\.name)
        #expect(all.count >= 3)
        var view = editor(model, "check @lc")
        #expect(model.suggestions(store).first?.name == "lcu")
        #expect(keys.key(key(kVK_DownArrow), responder: view))
        let second = try #require(model.suggestions(store)[1].folder)
        #expect(keys.key(key(kVK_Tab, "\t"), responder: view))
        #expect(model.projects == [second] && model.pointers == [.project(second)])
        #expect(model.draft == "check \(MentionText.markString) " && model.caretRequest == 8)
        // Picked projects aren't suggested again; Return picks too.
        view = editor(model, "check \(MentionText.markString) and @")
        #expect(!model.suggestions(store).map(\.folder).contains(second))
        #expect(keys.key(key(kVK_Return, "\r"), responder: view))
        #expect(model.projects.count == 2 && model.pointers[0] == .project(second) && model.draft.filter { $0 == MentionText.mark }.count == 2)
        // An @ inside a word (an email) is not a tag.
        #expect(RouterModel.mentionQuery(in: "me@lookout") == nil)
        #expect(RouterModel.mentionQuery(in: "@look  out") == nil)
        #expect(RouterModel.mentionQuery(in: "hey @look") == "look")
    }

    @Test func theSuggestionsFollowTheCaretNotTheEndOfTheText() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        model.composerFocused = true
        // Mid-message: the @ word the caret is in is the one suggested, and picking it keeps the rest of the text.
        let view = editor(model, "ask @lc about the tests", caret: 7)
        #expect(model.suggestions(store).first?.name == "lcu")
        #expect(keys.key(key(kVK_Return, "\r"), responder: view))
        #expect(model.draft == "ask \(MentionText.markString) about the tests" && model.caretRequest == 6)
        #expect(model.projects.count == 1)
        // The caret moved off a trailing @ word: no suggestions, and ↑↓ and Return are the composer's again.
        let away = editor(model, "tell @mi", caret: 2)
        #expect(model.suggestions(store).isEmpty)
        #expect(!keys.key(key(kVK_DownArrow), responder: away))
        let before = store.router.decisions.count
        #expect(keys.key(key(kVK_Return, "\r"), responder: away))
        #expect(store.router.decisions.count > before)
    }

    /// The composer in a window: typing through its own text view, then moving the caret, drives the suggestions.
    @Test(.hostsWindows) func aMountedComposerFollowsTheCaret() async throws {
        let store = demo()
        let model = RouterModel()
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 720))
        let window = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: .titled, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // Other tests' windows may hold the keyboard: the composer's own text view is given it here, once it is drawn.
        func fields(_ view: NSView) -> [MentionTextView] { (view as? MentionTextView).map { [$0] } ?? [] + view.subviews.flatMap(fields) }
        await waitUntil { !fields(hosting).isEmpty }
        // The composer asks for the keyboard as it appears, two main-queue hops later: that is done with before the test
        // types and moves the caret, so it can't land in the middle.
        for _ in 0..<3 {
            await drainMainQueue()
            hosting.layoutSubtreeIfNeeded()
        }
        let composer = fields(hosting).first
        await waitUntil {
            if window.firstResponder !== composer, let composer { window.makeFirstResponder(composer) }
            return window.firstResponder === composer
        }
        let field = try #require(window.firstResponder as? NSTextView)
        /// What the view does happens on its next update, which other tests' work on the main actor can hold back.
        func settle(_ done: () -> Bool) async throws {
            await waitUntil(done)
        }
        field.insertText("ask @mi about it", replacementRange: NSRange(location: 0, length: 0))
        try await settle { model.draft == "ask @mi about it" }
        #expect(model.draft == "ask @mi about it" && model.suggestions(store).isEmpty)
        field.setSelectedRange(NSRange(location: 7, length: 0))
        try await settle { !model.suggestions(store).isEmpty }
        #expect(model.suggestions(store).first?.name == "microsandbox")
        // The composer losing the keyboard (here, as SwiftUI may take it from a field in a window that isn't key) ends its
        // editing, which moves the editor's selection: that is not the composer's caret moving.
        window.makeFirstResponder(nil)
        await drainMainQueue()
        await waitUntilSteady(turns: 10) { model.caret }
        #expect(model.caret == 7 && model.suggestions(store).first?.name == "microsandbox")
        // Other text views moving their caret (another window's, one elsewhere in this window, even holding the same text)
        // leave the composer's alone.
        let other = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered,
                               defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let elsewhere = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        other.contentView = elsewhere
        let beside = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        hosting.addSubview(beside)
        defer { beside.removeFromSuperview() }
        for view in [elsewhere, beside] {
            view.string = "ask @mi about it"
            view.setSelectedRange(NSRange(location: 1, length: 0))
        }
        // Whatever the view does with those notifications it does on its next updates: once the caret has read the same over
        // several turns of the main actor, it has had them.
        await drainMainQueue()
        await waitUntilSteady(turns: 10) { model.caret }
        #expect(model.caret == 7 && model.suggestions(store).first?.name == "microsandbox")
        // The composer's own caret moving away still counts (given the keyboard again if the others took it).
        await waitUntil {
            if window.firstResponder !== field, let composer { window.makeFirstResponder(composer) }
            return window.firstResponder === field
        }
        let own = try #require(window.firstResponder as? NSTextView)
        own.setSelectedRange(NSRange(location: 1, length: 0))
        try await settle { model.suggestions(store).isEmpty }
        #expect(model.suggestions(store).isEmpty)
    }

    /// A notification's "Open in Router" made while the Router's page isn't there: the window goes to the Router, and the
    /// composer, made as the page appears, holds the thing's pill and the keyboard, its caret after the pill.
    @Test(.hostsWindows) func openInRouterBeforeThePageShowsLandsInTheComposer() async throws {
        let store = demo()
        let entry = try #require(store.entries.first { !$0.isDone })
        let model = RouterModel()
        let navigator = AppNavigator(start: .settings, defaults: nil)
        model.open(thing: entry.id, in: navigator)
        #expect(navigator.selection == .router && model.pointers == [.notification(entry.id)])
        #expect(model.draft == MentionText.markString + " " && model.caretRequest == 2 && model.focusRequest == 1)
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 720))
        let window = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: .titled, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func fields(_ view: NSView) -> [MentionTextView] { (view as? MentionTextView).map { [$0] } ?? [] + view.subviews.flatMap(fields) }
        await waitUntil { !fields(hosting).isEmpty }
        let composer = try #require(fields(hosting).first)
        // The composer asks for the keyboard as it appears (given it here if other tests' windows took it): the caret goes
        // after the pill as it takes it.
        await waitUntil {
            if window.firstResponder !== composer { window.makeFirstResponder(composer) }
            return window.firstResponder === composer && model.caretRequest == nil
        }
        #expect(composer.string == MentionText.markString + " " && composer.selectedRange() == NSRange(location: 2, length: 0))
        #expect(MentionText.serialize(composer.attributedString()).pointers == [.notification(entry.id)])
    }

    @Test(.hostsWindows) func aLongDraftScrolledInTheComposerIsStillTheComposers() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.orderOut(nil) }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        // The field: 100pt high at the bottom of the window, its text view scrolled down a draft far taller than it.
        let anchor = FieldAnchor()
        let behind = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        content.addSubview(behind)
        anchor.view = behind
        let scroll = NSScrollView(frame: behind.frame)
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        scroll.documentView = editor
        content.addSubview(scroll)
        editor.string = String(repeating: "a long draft\n", count: 300)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        editor.scroll(CGPoint(x: 0, y: 2000))
        #expect(anchor.owns(editor))
        // A text view elsewhere in the window isn't.
        let beside = NSTextView(frame: CGRect(x: 0, y: 200, width: 600, height: 100))
        content.addSubview(beside)
        #expect(!anchor.owns(beside))
    }

    @Test func backspaceAtTheStartTakesTheReplyOff() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let editor = NSTextView()
        model.composerFocused = true
        store.routerBriefs.focus(store.routerBriefs.page().entries[0].target)
        #expect(keys.key(key(kVK_Delete), responder: editor))
        #expect(store.routerBriefs.focused == nil)
        // Nothing left: the key is the field's. Not at the start: the field's.
        #expect(!keys.key(key(kVK_Delete), responder: editor))
        store.routerBriefs.focus(store.routerBriefs.page().entries[0].target)
        editor.string = "abc"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!keys.key(key(kVK_Delete), responder: editor) && store.routerBriefs.focused != nil)
    }

    @Test func aFailedRemovalStaysInSightWithTheRouterOffAndCanBeTriedAgain() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        s.routerPluginRunner = cli.runner
        s.routerClaudeBinary = { "/fake/claude" }
        s.routerAppVersion = "1.0.0"
        s.agents.enabled = true
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        cli.failing = "plugin uninstall"
        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        let error = try #require(s.routerRemovalError)
        #expect(error.contains("boom"))
        // Settings shows it, and the button that tries again, though the Router's own lines are hidden while it is off.
        let tree = try await AccessibilityTree.render(SettingsView(store: s, hub: HubState()).frame(width: 440, height: 2400),
                                                      size: CGSize(width: 440, height: 2400))
        #expect(tree.all.contains { $0.role == "AXButton" && $0.label == "Try again" })
        cli.failing = nil
        s.retryRouterRemoval()
        await s.routerHookWork?.value
        #expect(s.routerRemovalError == nil && s.routerPluginStatus == .notInstalled && cli.plugins.isEmpty)
    }

    @Test func fuzzyMentionsRankPrefixesFirst() {
        let ranked = RouterMentions.rank([("/a", "microsandbox"), ("/b", "lcu"), ("/c", "lcu-research"), ("/d", "lookout")],
                                         query: "lc", limit: 6).map(\.name)
        #expect(ranked == ["lcu", "lcu-research"])
        #expect(RouterMentions.rank([("/a", "microsandbox")], query: "msb", limit: 6).map(\.name) == ["microsandbox"])
        #expect(RouterMentions.rank([("/a", "microsandbox")], query: "zz", limit: 6).isEmpty)
    }

    // MARK: Forms

    /// A store that writes for real, its forms folder in `dir` (nil: never started, as with the Router off).
    private func writing(_ dir: URL?) -> Store {
        let store = demo()
        store.stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("router-ui-\(UUID().uuidString).json")
        store.persists = true
        if let dir { store.formBridge.start(dir: dir) { _ in } }
        return store
    }

    @Test func anAnswerIsWrittenToTheFormsFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-forms-\(UUID().uuidString)")
        let store = writing(dir)
        defer { store.formBridge.stop(); store.persists = false; try? FileManager.default.removeItem(at: dir) }
        // The brief's local question: option 2 picked, then Return.
        let briefs = store.routerBriefs
        let t = BriefTarget(project: "local:lcu", thread: Demo.briefLocalThread)
        let form = try #require(store.heldForm(t))
        briefs.pick(t, 2, store: store)
        #expect(briefs.confirm(t, store: store))
        await waitUntil { FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: dir).path) }
        // Its line in the drawer once the answer is written.
        await briefs.settled()
        #expect(briefs.trouble[t] == nil && briefs.answers.first?.words == "Ask first")
    }

    @Test func answeringWhileTheRouterIsSwitchedOffWritesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-forms-\(UUID().uuidString)")
        let store = writing(dir)
        defer { store.formBridge.stop(); store.persists = false; try? FileManager.default.removeItem(at: dir) }
        let briefs = store.routerBriefs
        let t = BriefTarget(project: "local:lcu", thread: Demo.briefLocalThread)
        let form = try #require(store.heldForm(t))
        briefs.pick(t, 2, store: store)
        #expect(briefs.confirm(t, store: store))
        // Switched off before the write happens.
        store.router.enabled = false
        await waitUntil { briefs.trouble[t] != nil }
        #expect(briefs.trouble[t] == FormWriter.Cancelled().errorDescription)
        #expect(!FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: dir).path))
    }

    // MARK: Plans

    @Test func anApprovalIsWrittenToTheFormsFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-forms-\(UUID().uuidString)")
        let store = writing(dir)
        defer { store.formBridge.stop(); store.persists = false; try? FileManager.default.removeItem(at: dir) }
        // The Linux sandbox's session, stopped on its plan: Approve carries no note.
        let t = BriefTarget(project: "local:sandbox", thread: "local_demo-linux")
        let form = try #require(store.heldForm(t))
        #expect(form.isPlan)
        if case .failure(let error) = await store.answerPlan(form, .init(approve: true), target: t) { Issue.record("\(error)") }
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: FormBridge.answerURL(form.id, in: dir))) as? NSDictionary
        #expect(written == ["plan": ["approve": true, "feedback": ""]] as NSDictionary)
    }

    // MARK: What works

    @Test func aBrokenReadOfClaudesFilesIsSaidOnTheBar() async throws {
        func says(_ link: ClaudeLink, _ configure: @escaping (HubState) -> Void) async throws -> Bool {
            let tree = try await AccessibilityTree.render(edge: .top, scenario: .router, configure: { store, hub in
                store.claudeLink = link
                configure(hub)
            })
            return tree.all.contains { ($0.label + $0.value).contains("Claude's sessions") }
        }
        let state = { (hub: HubState) in hub.section = .router }
        #expect(try await says(.missing, state))
        #expect(try await !says(.ok, state))
    }

    @Test func theBarNamesTheRouterAtRestAndPeeking() async throws {
        for edge in [DockEdge.right, .top] {
            for peeking in [false, true] {
                let tree = try await AccessibilityTree.render(edge: edge, scenario: .router,
                                                              configure: { _, hub in hub.section = peeking ? .router : nil })
                #expect(tree.all.contains { $0.label == "Router" }, "\(edge) \(peeking)")
            }
        }
    }

    @Test func theWorkingListIsWhatRunsLongestFirstAndOpensIt() {
        let store = demo(.router)
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        let rows = store.routerWorkingRows
        // The turn that works, and the finished one still running its subagents and command (oldest of them first).
        #expect(rows.map(\.id) == ["local_demo-ci", "local_demo-lookout"])
        #expect(!rows[0].session.running)
        #expect(!rows.contains { $0.waitsForYou })
        store.openAgent(rows[1].id)
        #expect(opened.first?.contains("Agent completion notifications") == true)
    }

    // MARK: Banners

    // MARK: Shortcut

    @Test func theRoutersDefaultKeyIsFreeAndEachGlobalKeyHasItsOwnID() {
        let others = ShortcutAction.allCases.filter { $0 != .router }.map(\.defaultShortcut)
        #expect(!others.contains(ShortcutAction.router.defaultShortcut))
        // Each global key is registered under an id of its own.
        let globals = ShortcutAction.allCases.filter(\.isGlobal)
        #expect(Set(globals.map(\.hotKeyID)).count == globals.count)
    }

    // MARK: The page

    @Test func theMentionListStaysInsideTheCard() {
        // Room for it: under the caret.
        #expect(MentionList.place(caretX: 100, available: 800).x == 100)
        #expect(MentionList.place(caretX: 100, available: 800).width == 420)
        // Near the right edge: moved left so it ends at the edge.
        let near = MentionList.place(caretX: 700, available: 800)
        #expect(near.x == 380 && near.x + near.width == 800)
        // A card narrower than the list: the list shrinks to it.
        let narrow = MentionList.place(caretX: 200, available: 300)
        #expect(narrow.x == 0 && narrow.width == 300)
        #expect(MentionList.place(caretX: -5, available: 800).x == 0)
    }

}
