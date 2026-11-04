import AppKit

// Claude Code runs this binary as its form hook (see `FormHook`): no app, nothing on stdout but the hook's decision.
if CommandLine.arguments.dropFirst().first == "--form-hook" { FormHook.main() }
// Chrome runs it as the Router extension's native messaging host (see `NativeHost`): the same, nothing else started.
if CommandLine.arguments.dropFirst().contains("--native-host") { NativeHost.main() }

// The saved state is read and decoded in the background meanwhile: `Store.load` takes it.
if !Store.isDemo { Store.readSavedStateEarly() }
ClaudeFonts.load()
Brand.loadFonts()
// Text drawn as Claude's web view draws it (`-webkit-font-smoothing: antialiased`): no stem thickening. For this process
// only, as if launched with `-AppleFontSmoothing 0`.
UserDefaults.standard.setVolatileDomain(["AppleFontSmoothing": 0], forName: UserDefaults.argumentDomain)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
