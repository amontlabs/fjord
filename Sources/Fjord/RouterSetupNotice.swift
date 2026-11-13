import AppKit
import SwiftUI

/// What stands in the way of using the Router, in one line, and the fix. Nothing when all is well.
struct RouterSetupNotice: View {
    let store: Store
    let model: RouterComposerModel
    /// The view the notice is in, to know whether its window is on screen.
    @State private var place = ShownProbe.Place()

    var body: some View {
        Group {
            if !store.agents.enabled || !store.router.enabled {
                line("The Router is off.", color: Theme.amber, action: "Turn on") { store.switchRouter(true) }
            } else if model.claudeCodeMissing == true && store.routerStatus.claudeCode == nil {
                line("Claude Code wasn't found. Install or open the Claude desktop app.", color: Theme.amber,
                     action: "Look again") { Task { await model.checkClaudeCode(store) } }
            }
        }
    }

    private func line(_ text: String, color: Color, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action { ActionButton(action, action: perform) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .background(ShownProbe(place: place))
        // Said once its window is on screen, a moment after: not while the window's content is prepared out of sight, nor
        // once it has left the window again (the task is cancelled then).
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, place.isShown else { return }
            Announce.say(text, after: .zero)
        }
    }
}

/// Finds the window a SwiftUI view is in: whether it is on screen.
struct ShownProbe: NSViewRepresentable {
    @MainActor final class Place {
        weak var view: NSView?
        var isShown: Bool { view?.window?.isVisible == true }
    }

    let place: Place

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        place.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { place.view = view }
}
