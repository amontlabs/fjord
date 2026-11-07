import SwiftUI

/// Under the Router's header: the T3 link needing a look (nothing when it is fine or on its way).
struct T3Notice: View {
    let store: Store

    var body: some View {
        let status = store.t3.status
        if status.isProblem || status == .notLinked {
            Text(status.text)
                .font(Theme.Typography.meta)
                .foregroundStyle(status.isProblem ? Theme.red : Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.xs)
                .accessibilityLabel(status.text)
        }
    }
}

/// The link's rows in Settings: its state and button, then the Anthropic key the decider will use.
struct T3SettingsRows: View {
    let store: Store
    @State private var key = ""
    @State private var hasKey = false

    var body: some View {
        let link = store.t3
        let status = link.status
        SettingsRow("T3 Code", description: description(status),
                    info: ("T3 Code", "Fjord reads your threads from the T3 Code app on this Mac and sends your words to them. Linking asks T3 for a token that can read and act on threads, and keeps it in your Keychain. Unlink forgets it here; T3's own settings can revoke the session.")) {
            if status != .notInstalled {
                if status.isConnected {
                    ActionButton("Unlink") { link.unlink() }
                } else if status == .linking {
                    ProgressView().controlSize(.small)
                } else if status == .notLinked || status == .tokenRejected || status.isMintFailure {
                    ActionButton("Link to T3") { Task { await link.link() } }
                }
            }
        }
        SettingsRail {
            SettingsStatusLine(text: status.text, color: color(status))
        }
        SettingsDivider()
        anthropicKey
    }

    private func description(_ status: T3LinkStatus) -> String? {
        status == .notInstalled ? "Install T3 Code to use the Router" : nil
    }

    private func color(_ status: T3LinkStatus) -> Color {
        if status.isConnected { return Theme.green }
        if status.isProblem { return Theme.red }
        return Theme.tertiary
    }

    private var anthropicKey: some View {
        Group {
            if hasKey {
                SettingsRow("Anthropic API key", info: ("Anthropic API key", "Saved in the Keychain. The Router's decider asks Sonnet through it.")) {
                    ActionButton("Remove") { AnthropicClient.deleteKey(); hasKey = false }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "Paste an Anthropic API key", text: $key, secure: true,
                                          accessibilityLabel: "Anthropic API key", onSubmit: save)
                        ActionButton("Save", height: CDS.Settings.field, action: save).disabled(key.isEmpty)
                    }
                    SettingsNote("For the decider that picks where a message goes.")
                }
            }
        }
        .task { hasKey = await Task.detached { AnthropicClient.readKeychain() != nil }.value }
        .onDisappear { key = "" }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AnthropicClient.saveKey(trimmed) else { return }
        key = ""
        hasKey = true
    }
}

extension T3LinkStatus {
    var isMintFailure: Bool { if case .mintFailed = self { true } else { false } }
}
