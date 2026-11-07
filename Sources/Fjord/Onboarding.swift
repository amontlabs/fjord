import SwiftUI

/// The first launch, in the window in place of its sidebar and pages: one screen to pick the tools. Each switch is the tool's
/// own (what is switched on starts at once), and what the tool needs unfolds under it: GitHub's sign-in under Triage, the
/// TypeSafe key under the Router. Get started hands the window over; Settings changes the tools after.
struct OnboardingView: View {
    let store: Store
    /// The tools are picked: the window shows them.
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    static let width: CGFloat = 460
    private let comfy = CDS.Density.comfortable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FjordLogo().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("Fjord").cdsText(comfy.title, .medium).padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                Text("The power without the storm. Pick your tools; Settings can change them later.")
                    .cdsText(comfy.body, .regular, CDS.Text.secondary).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) {
                    ForEach(Tool.allCases) { tool($0) }
                }
                .padding(.top, 32)
                HStack {
                    Spacer()
                    Button("Get started", action: done).buttonStyle(PrimaryButtonStyle())
                        .disabled(store.tools.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 24)
            }
            .frame(width: Self.width)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 72)
        }
        .scrollIndicators(.never)
    }

    /// A tool: its switch, and once it is on, what it needs, folding away when it is switched off.
    private func tool(_ tool: Tool) -> some View {
        let on = store.isOn(tool)
        // The Router works through T3 Code: without it the Router can't be switched on (as in Settings).
        let needsClaude = tool == .router && !on && !store.t3.installed
        return SettingsNest {
            SettingsRow(tool.name, description: needsClaude ? "Needs T3 Code" : tool.summary,
                        adornment: SettingsView.toolMark(tool)) {
                SettingsSwitch(tool.name, isOn: Binding(get: { on }, set: { store.setTool(tool, on: $0) }))
                    .disabled(needsClaude)
            }
            if on {
                needs(tool).padding(.bottom, 4).transition(.opacity)
            }
        }
        .animation(Motion.spatial.resolved(reduce: reduce), value: on)
    }

    @ViewBuilder private func needs(_ tool: Tool) -> some View {
        switch tool {
        case .triage:
            GitHubSignIn(store: store)
        case .router:
            VStack(alignment: .leading, spacing: 8) {
                TypeSafeKeyField(store: store)
                SettingsNote("Optional. With a key, Jev (TypeSafe's classifier) routes what you send and reads how each turn ended. Keys come from console.typesafe.ai.")
            }
        case .computers:
            EmptyView()
        }
    }
}

/// The mark in its colours, as the logo: the sun in the text's ink, the two bands in fonte.
struct FjordLogo: View {
    static let fonte = Color(red: 0x0F / 255, green: 0x9A / 255, blue: 0xC3 / 255)

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { part in
                FjordMarkPart(part: part).fill(part == 0 ? CDS.Text.primary : Self.fonte)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// One of the mark's parts (0 the sun, then the bands), in the circle that fits its frame.
struct FjordMarkPart: Shape {
    let part: Int

    func path(in rect: CGRect) -> Path { Path(FjordMark.parts(in: rect, yDown: true)[part]) }
}
