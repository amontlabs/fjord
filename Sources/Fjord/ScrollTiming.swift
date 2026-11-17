import AppKit
import SwiftUI

/// `--scroll-timing`: how long the bar's inbox list takes to follow a scroll to its end, measured offscreen on the demo's long inbox
/// (`Demo.Scenario.inboxLong`), more rows being added as the end nears (as reading on past the caps does). Prints the main thread's
/// time per scroll step (mean, p95, max, in ms) and the whole run's. No window is shown, nothing takes the focus.
@MainActor
enum ScrollTiming {
    static func run() {
        ShotRun.prepare()
        let store = Store()
        Demo.populate(store, .inboxLong)
        let ui = UIState(persists: false, edge: .right)
        let hub = HubState()
        hub.section = .inbox
        hub.tab = store.categories.first { $0.name == "Contributions" }.map { .category($0.id) }
        let size = Shot.standard
        let root = PlaygroundView(store: store, ui: ui, hub: hub, showsExplainer: false, minSize: size, chrome: Chrome(mode: .opaque))
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = size
        let window = ShotWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        ShotRun.show(window)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard let scroll = largestScrollView(in: hosting), let clip = Optional(scroll.contentView), let document = scroll.documentView else {
                print("no scroll view"); exit(1)
            }
            let phase = ContinuousClock()
            var phases = [0.0, 0.0, 0.0]
            func lap(_ i: Int, _ t: ContinuousClock.Instant) {
                let d = phase.now - t
                phases[i] = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            func spin() {
                var t = phase.now
                hosting.layoutSubtreeIfNeeded(); lap(0, t); t = phase.now
                hosting.displayIfNeeded(); lap(1, t); t = phase.now
                RunLoop.main.run(until: Date().addingTimeInterval(0.002)); lap(2, t)
            }
            let items = hub.tab.map { store.entries(in: $0).count } ?? 0
            print("rows: \(items), document \(Int(document.frame.height)) pt, viewport \(Int(clip.bounds.height)) pt")
            let c0 = ContinuousClock().now
            for _ in 0..<50 { spin() }
            let floor = ContinuousClock().now - c0
            print("floor per spin ms: \(Double(floor.components.attoseconds) / 1e15 / 50)")
            var steps: [Double] = []
            var added = 0
            let clock = ContinuousClock()
            let started = clock.now
            var offset: CGFloat = 0
            while offset < 60_000 {
                let t0 = clock.now
                offset += 24
                clip.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(clip)
                // Near the end of what is listed, more arrives.
                if added < 3, offset + clip.bounds.height > document.frame.height - 400 {
                    added += 1
                    func since(_ t: ContinuousClock.Instant) -> String {
                        let d = clock.now - t
                        return String(format: "%.1f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                    }
                    let c0 = clock.now
                    Demo.addLongInbox(store, Date(), count: 40, from: 1000 + added * 100)
                    let setMs = since(c0)
                    // What the store alone costs (its lists made again), apart from the views.
                    let c1 = clock.now
                    _ = hub.tab.map { store.entries(in: $0).count }
                    print("append \(added): things set \(setMs) ms, lists made \(since(c1)) ms")
                }
                spin()
                if added > 0, steps.count % 1 == 0, phases[0] > 8 { print("  slow append step, phases layout/display/runloop \(phases.map { String(format: "%.1f", $0) })") }
                let d = clock.now - t0
                steps.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                if offset > document.frame.height - clip.bounds.height, added >= 3 { break }
            }
            let total = clock.now - started
            let sorted = steps.sorted()
            func ms(_ x: Double) -> String { String(format: "%.1f", x) }
            print("steps \(steps.count), end at \(Int(offset)), rows \(hub.tab.map { store.entries(in: $0).count } ?? 0)")
            let slow = steps.enumerated().filter { $0.element > 16 }.map { "\($0.offset)@\(ms($0.element))" }
            print("slow steps (>16 ms): \(slow.count) \(slow.prefix(12).joined(separator: " "))")
            print("per step ms: mean \(ms(steps.reduce(0, +) / Double(steps.count))), p50 \(ms(sorted[sorted.count / 2])), p95 \(ms(sorted[sorted.count * 95 / 100])), max \(ms(sorted.last ?? 0)); total \(total)")
            exit(0)
        }
    }

    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.frame.height > (best?.frame.height ?? 0), s.documentView != nil { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }
}
