import AppKit


// The saved state is read and decoded in the background meanwhile: `Store.load` takes it.
if !Store.isDemo { Store.readSavedStateEarly() }
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
