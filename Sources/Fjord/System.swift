import AppKit
import Carbon
import ServiceManagement
import UserNotifications

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click: the notification's id (`inbox:<thing id>` for a thing) and the page it is about (for when the thing is gone).
    var onOpen: ((_ id: String, _ url: String?) -> Void)?
    /// Tests: every post and withdrawal, whether or not the system would show it.
    var onPost: ((UNNotificationRequest) -> Void)?
    var onRemove: (([String]) -> Void)?
    /// Bulk summaries ("7 new in your inbox") belong to no one thing: identified by this and a unique suffix.
    nonisolated static let summaryPrefix = "summary#"
    /// Banners need an app bundle; a test run, hosted in one or not, never has the system's.
    private var available: Bool { Self.canReachSystem }
    private nonisolated static var canReachSystem: Bool { Bundle.main.bundleIdentifier != nil && !UnderTest.isRunning }

    /// The notification center's delegate: set as launch finishes, so the click on a banner that launched the app is
    /// heard.
    func attach() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for banners (the system prompts once); can wait until the app has shown its bar.
    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Whether macOS refuses this app's banners: said no at the first prompt, or turned off since in System Settings.
    static func isBlocked() async -> Bool {
        guard canReachSystem else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func post(id: String, title: String, subtitle: String, body: String, quiet: Bool, url: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.userInfo = ["id": id, "url": url?.absoluteString ?? ""]
        content.threadIdentifier = quiet ? "bots" : "main"
        if quiet {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        onPost?(req)
        guard available else { return }
        UNUserNotificationCenter.current().add(req)
    }

    /// Withdraws banners.
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        onRemove?(ids)
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String ?? ""
        let url = info["url"] as? String
        DispatchQueue.main.async { self.onOpen?(id, url) }
        completionHandler()
    }
}

// MARK: - Global hotkeys

/// What registers a key combination with the system: Carbon, or a stand-in under test.
protocol HotKeyBackend {
    /// What holds the registration, or nil when another app holds the combination.
    func register(_ shortcut: Shortcut, id: UInt32) -> AnyObject?
    func unregister(_ registration: AnyObject)
}

/// Carbon hot keys, which the system delivers to the app wherever the keys are pressed.
final class CarbonHotKeys: HotKeyBackend {
    private final class Registration {
        let ref: EventHotKeyRef
        init(_ ref: EventHotKeyRef) { self.ref = ref }
    }

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeys.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ shortcut: Shortcut, id: UInt32) -> AnyObject? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: OSType(0x4C4B4F54), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { return Registration(ref) }
        NSLog("Fjord: global shortcut \(shortcut.display) unavailable (\(status))")
        return nil
    }

    func unregister(_ registration: AnyObject) {
        if let registration = registration as? Registration { UnregisterEventHotKey(registration.ref) }
    }
}

/// System-wide shortcuts, one registration per id. Matched by key position, so any keyboard layout works.
/// Key combinations go through Carbon hot keys; lone modifier taps (e.g. right ⌘) through event monitors,
/// which need Accessibility access to see the keys typed in other apps.
final class HotKeys {
    static let debug = ProcessInfo.processInfo.environment["FJORD_DEBUG"] != nil
    fileprivate static var handlers: [UInt32: () -> Void] = [:]
    /// Where the key combinations are registered with the system.
    private let backend: HotKeyBackend
    private var refs: [UInt32: AnyObject] = [:]
    /// The key combinations asked for, kept while suspended so they come back as they were.
    private var combos: [UInt32: (shortcut: Shortcut, handler: () -> Void)] = [:]
    /// While true, the key combinations are released so the keys reach the app (e.g. a shortcut being recorded).
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            for id in combos.keys { register(id) }
            // Told only: a tap that couldn't be made (no Accessibility access) is not tried, and access not asked for,
            // again at each start and end of a shortcut's recording.
            tellButtonTap()
        }
    }
    var registeredIDs: Set<UInt32> { Set(refs.keys) }
    private var taps: [UInt32: (key: UInt16, handler: () -> Void)] = [:]
    /// Mouse button shortcuts, caught (and kept from the app under the pointer) by an event tap.
    private var buttons: [UInt32: (button: Int, flags: NSEvent.ModifierFlags, handler: () -> Void)] = [:]
    private var buttonTap: ButtonTap?
    private var tap = ModifierTap()
    private var monitors: [Any] = []
    /// Waits for Fjord to come back to the front while taps or mouse buttons are set and Accessibility is not
    /// granted.
    private var activation: NSObjectProtocol?
    /// When the held modifier went down (event timestamps, i.e. system uptime), to ask whether anything else happened since.
    private var heldSince: TimeInterval?
    /// Taps are ignored while this is true (e.g. while a shortcut is being recorded).
    var paused: () -> Bool = { false }
    /// Whether Accessibility access was granted when last asked: see `isTrusted`.
    private let trust = TrustCache()

    init(backend: HotKeyBackend = CarbonHotKeys()) {
        self.backend = backend
    }

    /// The mouse-button tap's thread holds the tap until it is stopped: it goes with this.
    deinit { buttonTap?.stop() }

    /// `nil` unregisters. A system-wide key that another app holds is refused (`false`), and what the action had stays
    /// registered until a replacement is.
    @discardableResult
    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void = {}) -> Bool {
        defer { updateMonitors(); updateButtonTap(); updateActivation() }
        if let shortcut, shortcut.mouseButton == nil, !shortcut.isModifierTap {
            if combos[id]?.shortcut == shortcut, refs[id] != nil || isSuspended {
                combos[id] = (shortcut, handler)
                if refs[id] != nil { HotKeys.handlers[id] = handler }
                return true
            }
            // The replacement first: Carbon refuses a key another app holds, and the old one should keep working then.
            guard let ref = claim(shortcut, id) else { return false }
            release(id)
            combos[id] = (shortcut, handler)
            if isSuspended {
                backend.unregister(ref)
            } else {
                refs[id] = ref
                HotKeys.handlers[id] = handler
            }
            return true
        }
        release(id)
        guard let shortcut else { return true }
        if let button = shortcut.mouseButton { buttons[id] = (button, shortcut.flags, handler) } else { taps[id] = (shortcut.keyCode, handler) }
        return true
    }

    /// Lets go of whatever `id` holds, of every kind.
    private func release(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { backend.unregister(ref) }
        combos[id] = nil
        HotKeys.handlers[id] = nil
        taps[id] = nil
        buttons[id] = nil
    }

    /// Asks the system for a key combination, which it refuses when another app holds it.
    private func claim(_ shortcut: Shortcut, _ id: UInt32) -> AnyObject? {
        backend.register(shortcut, id: id)
    }

    /// (Re)registers one combination with the system, or only releases it while suspended or removed.
    private func register(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { backend.unregister(ref) }
        HotKeys.handlers[id] = nil
        guard !isSuspended, let (shortcut, handler) = combos[id], let ref = claim(shortcut, id) else { return }
        refs[id] = ref
        HotKeys.handlers[id] = handler
    }

    /// Access is granted in System Settings, with Fjord behind it, and the tap that failed before it, or the
    /// monitors that heard nothing, are not tried again by themselves: coming back to the front is when to look.
    /// Nothing listens otherwise.
    private func updateActivation() {
        let waiting = (!taps.isEmpty || !buttons.isEmpty) && !AXIsProcessTrusted()
        if waiting, activation == nil {
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.accessMayBeGranted() }
        } else if !waiting, let observer = activation {
            NotificationCenter.default.removeObserver(observer)
            activation = nil
        }
    }

    private func accessMayBeGranted() {
        trust.forget()
        guard AXIsProcessTrusted() else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        updateMonitors()
        updateButtonTap()
        updateActivation()
    }

    private func updateMonitors() {
        if taps.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            heldSince = nil
            return
        }
        guard monitors.isEmpty else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Only modifier changes are watched; whether anything else happened during a tap is asked on release.
        let events: NSEvent.EventTypeMask = [.flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    /// Whether a key, click or scroll happened since the modifier went down: the window server remembers, so
    /// nothing has to watch those events (and wake the app) while typing or scrolling.
    private func interrupted(since start: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < elapsed }
    }

    /// A session event tap for the mouse buttons in use: it sees them in every app and can keep a shortcut's click
    /// from also going back in a browser. It needs Accessibility access, like modifier taps. It runs on a thread of its
    /// own (`ButtonTap`) and is told the buttons and whether shortcuts are suspended (a shortcut being recorded).
    private func updateButtonTap() {
        if buttons.isEmpty {
            buttonTap?.stop()
            buttonTap = nil
            return
        }
        if buttonTap == nil {
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            let tap = ButtonTap { [weak self] id in self?.buttonPressed(id) }
            guard tap.start() else {
                NSLog("Fjord: can't watch mouse buttons (Accessibility access?)")
                return
            }
            buttonTap = tap
        }
        tellButtonTap()
    }

    /// The running tap told the buttons and whether shortcuts are suspended.
    private func tellButtonTap() {
        buttonTap?.update(buttons: buttons.map { ButtonTap.Button(id: $0.key, button: $0.value.button, flags: $0.value.flags) },
                          paused: isSuspended)
    }

    /// A shortcut's mouse button was pressed (the tap kept the click from the app under the pointer).
    private func buttonPressed(_ id: UInt32) {
        guard !paused() else { return }
        buttons[id]?.handler()
    }

    /// Whether Accessibility access is granted, for a modifier tap that just completed: what the system said when last
    /// asked (only the very first time, or after `accessMayBeGranted`, is it asked here and then), asked again off the
    /// main thread as a modifier goes down once that answer is two seconds old, so a tap never waits on another process.
    private func isTrusted() -> Bool { trust.value() }

    private func handle(_ event: NSEvent) {
        if Self.debug {
            NSLog("Fjord keys: flagsChanged %d flags %lx trusted %d", event.keyCode, event.modifierFlags.rawValue, AXIsProcessTrusted() ? 1 : 0)
        }
        let held = UInt(event.modifierFlags.rawValue) & Shortcut.sideBits != 0
        let since = heldSince
        if held {
            if heldSince == nil {
                heldSince = event.timestamp
                trust.refresh()
            }
        } else {
            heldSince = nil
        }
        // Without Accessibility the keys typed elsewhere are invisible, so right ⌘ + C would look like a tap.
        guard let key = tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue),
              !paused(), isTrusted() else { return }
        if let since, interrupted(since: since) { return }
        for entry in taps.values where entry.key == key { entry.handler() }
    }
}

/// Whether Accessibility access is granted (`AXIsProcessTrusted`, a call to another process), as last asked: asked at the
/// first read, then again off the main thread when `refresh`ed once two seconds old.
final class TrustCache: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = false
    private var at: TimeInterval?
    private var refreshing = false
    /// Bumped by `forget` and by a read that asks itself: an answer asked for before it is dropped, so a background refresh
    /// that heard "no" before access was granted can't land over a fresher "yes".
    private var generation = 0
    /// The system's answer, and where a refresh asks for it: replaceable, so a test can step them.
    private let ask: @Sendable () -> Bool
    private let inBackground: (@escaping @Sendable () -> Void) -> Void

    init(ask: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
         inBackground: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }) {
        self.ask = ask
        self.inBackground = inBackground
    }

    func value() -> Bool {
        let mine: Int? = lock.withLock {
            guard at == nil else { return nil }
            generation += 1
            return generation
        }
        guard let mine else { return lock.withLock { trusted } }
        let now = ask()
        lock.withLock {
            guard generation == mine else { return }
            trusted = now
            at = ProcessInfo.processInfo.systemUptime
            refreshing = false
        }
        return now
    }

    func refresh() {
        let mine: Int? = lock.withLock {
            guard let at, !refreshing, ProcessInfo.processInfo.systemUptime - at >= 2 else { return nil }
            refreshing = true
            return generation
        }
        guard let mine else { return }
        inBackground { [self] in
            let now = ask()
            lock.withLock {
                guard generation == mine else { return }
                trusted = now
                at = ProcessInfo.processInfo.systemUptime
                refreshing = false
            }
        }
    }

    /// Asked again at the next read; an answer still on its way is dropped.
    func forget() {
        lock.withLock {
            generation += 1
            at = nil
            refreshing = false
        }
    }

    /// Tests: as if the answer were `seconds` old.
    func age(by seconds: TimeInterval) { lock.withLock { at = at.map { $0 - seconds } } }
}

/// The mouse-button shortcuts' event tap, on a thread and run loop of its own: the window server holds every side and
/// middle click, in every app, until a tap has answered, so the answer must not wait on Fjord's main thread (and
/// a long wait there would get the tap disabled). It decides from what it was last told (the buttons, whether shortcuts
/// are suspended) and goes to the main queue only to run a shortcut's action.
private final class ButtonTap: @unchecked Sendable {
    struct Button {
        let id: UInt32
        let button: Int
        let flags: NSEvent.ModifierFlags
    }

    private let lock = NSLock()
    private var buttons: [Button] = []
    private var paused = false
    /// Buttons whose press was a shortcut: their release is kept from the app under the pointer too.
    private var swallowedUps: Set<Int> = []
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopped = false
    /// On the main queue: the shortcut whose button was pressed.
    private let pressed: (UInt32) -> Void

    init(pressed: @escaping (UInt32) -> Void) { self.pressed = pressed }

    /// The tap made and running on its thread; false when the system refuses it (no Accessibility access).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ButtonTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            lock.withLock { self.loop = loop }
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Fjord mouse buttons"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func update(buttons: [Button], paused: Bool) {
        lock.withLock {
            self.buttons = buttons
            self.paused = paused
        }
    }

    /// The tap off for good and its thread ended (which lets go of it): once, by its owner, `HotKeys`, as the buttons go
    /// or as it goes itself. Until then the thread holds it, so a tap nobody stops would go on keeping clicks.
    func stop() {
        guard let port else { return }
        let loop: CFRunLoop? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return self.loop
        }
        guard let loop else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopStop(loop)
    }

    /// On the tap's thread. Returns nil to keep the click from the app under the pointer.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port, !lock.withLock({ stopped }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(Shortcut.relevant)
        let match: UInt32? = lock.withLock {
            if type == .otherMouseUp { return swallowedUps.remove(number) == nil ? nil : 0 }
            guard !paused, let button = buttons.first(where: { $0.button == number && $0.flags == flags }) else { return nil }
            swallowedUps.insert(number)
            return button.id
        }
        guard let match else { return Unmanaged.passUnretained(event) }
        // A release kept from the app: nothing to run.
        guard type == .otherMouseDown else { return nil }
        let pressed = pressed
        DispatchQueue.main.async { pressed(match) }
        return nil
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        guard !UnderTest.refuses("the login item (Launch at login)") else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var hub: HubController?
    private lazy var hotKeys = HotKeys()
    private var globalShortcuts: GlobalShortcuts?
    private var playground: Playground?
    private var appWindow: AppWindowController?
    private var sigtermSource: DispatchSourceSignal?
    private var motion: MotionScriptPlayer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        handleSigterm()
        store = Store()
        if let i = CommandLine.arguments.firstIndex(of: "--playground-shots"), i + 1 < CommandLine.arguments.count {
            PlaygroundShots.run(to: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--window-shots"), i + 1 < CommandLine.arguments.count {
            AppWindowShots.run(to: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--window") {
            appWindow = AppWindowDev.open(store)
            return
        }
        if CommandLine.arguments.contains("--playground") {
            playground = Playground()
            playground?.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--update"), i + 1 < CommandLine.arguments.count {
            UpdateCheck.run(as: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--t3") {
            T3Check.run()
            return
        }
        if CommandLine.arguments.contains("--check-inbox") {
            InboxCheck.run(store: store)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--check"), i + 1 < CommandLine.arguments.count {
            Check.run(store: store, repo: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo") {
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            Demo.populate(store, Demo.Scenario(rawValue: name) ?? .busy)
        } else {
            // The state now, and the banners' delegate and routing (before the Router's chains onto it, below); what runs on
            // the state (updates, polling, Claude's sessions, the Router, the code folders) once the bar has been drawn: see
            // the end of this function.
            store.load()
            store.wireNotifications()
        }
        let demo = CommandLine.arguments.contains("--demo")
        let window = AppWindowController(store: store)
        appWindow = window
        let hub = HubController(store: store, demo: demo)
        self.hub = hub
        // The window is the bar's other mode: while it is in front the bar is away, and closing it (or leaving it behind) puts the bar back.
        window.onClose = { [weak hub] in hub?.setWindowOpen(false) }
        window.barScreen = { [weak hub] in hub?.dockedScreen }
        window.bar = { [weak hub] in hub?.morph }
        // As the close's motion starts: the bar fades back in, then the keyboard goes back to the app that had it (the Dock
        // icon goes once the motion is over).
        window.onClosing = { [weak hub] in
            hub?.setWindowOpen(false)
            AppPolicy.yieldFocus()
        }
        // Made active by the user (⌘-Tab, the Dock) while the window closes: it opens again.
        AppPolicy.reopen = { [weak self] in self?.showWindow(nil) }
        // The bar is back on its edge while the window is out of sight (another app in front, minimized), away when it returns.
        window.onFront = { [weak hub] front in hub?.setWindowFront(front) }
        hub.openApp = { [weak self] in self?.showWindow($0) }
        hub.reopenApp = { [weak self] in self?.showWindow(nil) }
        hub.openUpdates = { [weak self] in
            self?.appWindow?.showUpdates()
            self?.hub?.setWindowOpen(true)
        }
        hub.pickBriefEntry = { [weak window] t in window?.pick(entry: t) }
        hub.pickRouterMessage = { [weak window] id in window?.pick(message: id) }
        hub.prefillRouter = { [weak window] thing in window?.prefillRouter(thing: thing) }
        hub.windowPlace = { [weak window] in window?.navigator.selection }
        // Demo: the window's key on right ⌘ (not saved), to try tap and double-tap.
        if demo {
            store.settings.shortcuts = [ShortcutAction.togglePanel.rawValue: Shortcut(keyCode: 54)]
        }
        hotKeys.paused = { [weak self] in self?.store.isRecordingShortcut ?? false }
        store.onRecordingShortcutChange = { [weak self] on in self?.globalShortcuts?.suspend(on) }
        // A banner's click: the window on the thing's category with it picked (on the archive if it was archived since), or, for a
        // summary, on the first category with something unread.
        store.onOpenInbox = { [weak self] category, thing in
            guard let self else { return }
            if let thing, let entry = self.store.entries.first(where: { $0.id == thing }) {
                self.appWindow?.show(entry: entry)
                self.hub?.setWindowOpen(true)
            } else {
                self.showWindow(category.map { .category($0) } ?? AppDestination(self.store.tabNeedingYou))
            }
        }
        // A brief entry's banner: the Router, on that entry.
        store.onOpenBrief = { [weak self] t in self?.showWindow(.router, entry: t) }
        // Default ⌃⌥L: ⌃⌥Space is macOS's "next input source".
        let globals = GlobalShortcuts(store: store, hotKeys: hotKeys) { [weak self] action in
            switch action {
            case .togglePanel: self?.toggleWindow()
            case .router: if self?.store.routerOn == true { self?.showWindow(.router) }
            default: break
            }
        }
        globals.start()
        globalShortcuts = globals
        // The first launch opens on the onboarding, where the tools are picked.
        if CommandLine.arguments.contains("--open") || store.settings.toolsPicked != true { toggleWindow() }
        playMotionScript(demo: demo)
        // The bar on screen first (its first frame shown, or a tenth of a second at most), the store's services after it,
        // and after the window's morph when the launch opens the window (the onboarding, `--open`).
        if !demo {
            AppTransition.nextFrame(hub.dockedScreen) {
                MotionGate.whenStill { [weak self] in self?.store.startServices() }
            }
        }
        if CommandLine.arguments.contains(Lifecycle.flag) {
            Lifecycle.start(store)
        } else {
            // What the first open needs, made out of sight once launch is past, so the open only brings it in: the
            // morph's overlay and glass pieces (and the Router's icons) first, the window's content next, each in its own
            // slice at a moment the main run loop has nothing else to do and nobody is using the mouse, the modifiers or
            // the bar. Not under `--lifecycle`, whose idle measurement wants nothing done after launch.
            let blocked = { [weak hub] in
                Self.preparationIsBlocked(mouseButtons: NSEvent.pressedMouseButtons, modifiers: NSEvent.modifierFlags,
                                          barInteracting: hub?.isInteracting == true)
            }
            // Short of memory: none of it (the overlay, once made, is kept for good).
            let steps: [@MainActor () -> Void] = [
                { [weak window, weak hub, weak self] in
                    guard let window, let hub, !window.memoryShort else { return }
                    AppTransition.prepareOverlay(on: hub.dockedScreen)
                    if self?.store.router.enabled == true { SessionIcons.warm() }
                },
                { [weak window] in window?.prepare() },
            ]
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.prepareDelay, qos: .utility) {
                MainActor.assumeIsolated { Self.prepare(steps, interacting: blocked) }
            }
        }
    }

    /// How long after launch the first open's preparing starts (`prepare(_:interacting:)`): past the launch's own turns,
    /// the store's load and the bar's first draw; each step then waits for the main run loop to be idle as well.
    static let prepareDelay: TimeInterval = 0.5

    /// `steps` one at a time, each once the main run loop is idle and nobody is interacting (see `prepareWhenIdle`).
    static func prepare(_ steps: [@MainActor () -> Void], interacting: @escaping () -> Bool) {
        guard let step = steps.first else { return }
        atIdle {
            prepareWhenIdle(interacting: interacting, prepare: {
                step()
                prepare(Array(steps.dropFirst()), interacting: interacting)
            })
        }
    }

    /// Runs `block` once the main run loop has nothing left to do (`NotificationQueue`'s idle posting): after whatever a
    /// launch, a sync's results or the user had asked of it.
    static func atIdle(_ block: @escaping @MainActor () -> Void) {
        final class Token: @unchecked Sendable { var observer: NSObjectProtocol? }
        let name = Notification.Name("Fjord.idle." + UUID().uuidString)
        let token = Token()
        token.observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            if let observer = token.observer { NotificationCenter.default.removeObserver(observer) }
            token.observer = nil
            MainActor.assumeIsolated { block() }
        }
        NotificationQueue.default.enqueue(Notification(name: name), postingStyle: .whenIdle, coalesceMask: [], forModes: nil)
    }

    static func preparationIsBlocked(mouseButtons: Int, modifiers: NSEvent.ModifierFlags, barInteracting: Bool) -> Bool {
        mouseButtons != 0 || !modifiers.intersection(Shortcut.relevant).isEmpty || barInteracting
    }

    /// A busy user gets another chance in 250 ms, once the main run loop is idle again (`atIdle`); the scheduler is
    /// replaceable so tests can step retries.
    static func prepareWhenIdle(interacting: @escaping () -> Bool, prepare: @escaping () -> Void,
                                schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, qos: .utility) { MainActor.assumeIsolated { atIdle(block) } }
    }) {
        if interacting() {
            schedule(0.25) { prepareWhenIdle(interacting: interacting, prepare: prepare, schedule: schedule) }
        } else {
            prepare()
        }
    }

    /// Opens the app window on `destination` (the bar leaves the edge), or on a brief entry.
    private func showWindow(_ destination: AppDestination?, entry: BriefTarget? = nil) {
        appWindow?.show(destination, entry: entry)
        hub?.setWindowOpen(true)
    }

    /// The window shortcut: closes the window you are looking at (the bar comes back), else brings it in front where it
    /// was left, whether it was closed, minimized or behind another app.
    private func toggleWindow() {
        if appWindow?.shortcutCloses == true { appWindow?.close() } else { showWindow(nil) }
    }

    /// `--motion-script` (`MotionScript`), with `--demo` only: the motions played on a timer for `scripts/motion-trace.sh`.
    /// A script that doesn't parse ends the app, so a recording never runs on nothing.
    private func playMotionScript(demo: Bool) {
        let script: MotionScript?
        do {
            script = try MotionScript.parse(arguments: CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("motion: not a script (steps among open, close, fold, peek, drag, then xN)\n".utf8))
            exit(2)
        }
        guard let script else { return }
        guard demo else {
            FileHandle.standardError.write(Data("motion: \(MotionScript.flag) plays only with --demo\n".utf8))
            return
        }
        let player = MotionScriptPlayer()
        player.open = { [weak self] in if self?.appWindow?.shortcutCloses == false { self?.toggleWindow() } }
        player.close = { [weak self] in if self?.appWindow?.shortcutCloses == true { self?.toggleWindow() } }
        player.fold = { SidebarState.shared.toggle() }
        player.peek = { [weak self] in
            guard let hub = self?.hub, !hub.barAway else { return nil }
            // The pointer's own check first: off the bar, it lifts the quiet a window's close leaves.
            hub.mouseMoved()
            guard !hub.hub.quiet else { return nil }
            hub.hub.enter(.inbox)
            return {
                hub.hub.cancelDwell()
                hub.hub.section = nil
            }
        }
        player.drag = { [weak self] in self?.hub?.dragToOppositeEdge() ?? false }
        player.play(script, quitAfter: CommandLine.arguments.contains(MotionScript.quitFlag))
        motion = player
    }

    /// The Dock icon (there while the window is open): the window in front, whatever was in front of it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return false
    }

    @objc private func openSettings() { showWindow(.settings) }
    @objc private func rewriteBriefs() { store?.routerBriefs.rewriteAll() }

    /// SIGTERM would skip `applicationWillTerminate` and lose a pending save.
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The Router's runs go with the app, the actions' too (a send's `claude` process is ended, not left behind).
        store?.routerDispatcher.stopAll(actions: true)
        // What was typed into a category's fields and still waits for its pause goes into the store before its last save.
        PendingEdits.flushAll()
        store?.flushSave()
    }

    /// The main menu: shown while the app window is open; an accessory app has none, but key equivalents (⌘C/⌘V/⌘A) still route
    /// through it.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fjord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        appMenu.insertItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",", at: 0)
        appMenu.items[0].target = self
        appMenu.insertItem(.separator(), at: 1)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        main.addItem(GoMenu.shared.makeItem())
        let routerItem = NSMenuItem()
        let routerMenu = NSMenu(title: "Router")
        let rewrite = NSMenuItem(title: "Rewrite Briefs", action: #selector(rewriteBriefs), keyEquivalent: "")
        rewrite.target = self
        routerMenu.addItem(rewrite)
        routerItem.submenu = routerMenu
        main.addItem(routerItem)
        main.addItem(SidebarMenu.shared.makeItem())
        // ⌘W closes the window, which puts the bar back; ⌘Q quits.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
