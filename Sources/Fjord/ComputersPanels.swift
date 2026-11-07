import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComputerCreationSheet: View {
    let store: Store
    let kind: ComputerKind
    @Environment(\.dismiss) private var dismiss
    @State private var limits: ComputerResourceLimits?
    @State private var loadError: String?
    @State private var name = ""
    @State private var cpus = 1
    @State private var memoryGiB = 1
    @State private var diskGiB = 64
    private var model: ComputersModel { store.computers }
    /// The device the computer is created on, fixed when the sheet opens.
    @State private var deviceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create \(kind.title) computer").font(CDS.sans(18, .semibold)).foregroundStyle(CDS.Text.primary)
                    Text("Limits come from \(deviceId == nil ? "this Mac" : model.ownerName(deviceId))'s available host capacity.")
                        .font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let loadError {
                ComputerNotice(text: loadError, tone: .warning)
            } else if limits == nil {
                ProgressView("Reading host limits…").font(CDS.sans(11))
            } else if let limits {
                TextField("Computer name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Computer name")
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("CPU  ·  \(cpus) of \(limits.maxCPUs)", value: $cpus, in: limits.minCPUs...limits.maxCPUs)
                    Stepper("Memory  ·  \(memoryGiB) GiB of \(limits.maxMemoryGiB) GiB",
                            value: $memoryGiB, in: limits.minMemoryGiB...limits.maxMemoryGiB)
                    if let minDisk = limits.minDiskGiB, let maxDisk = limits.maxDiskGiB {
                        Stepper("Disk  ·  \(diskGiB) GiB (\(minDisk)–\(maxDisk) GiB)",
                                value: $diskGiB, in: minDisk...maxDisk, step: 16)
                    } else {
                        Text("Workspace and runtime disks use Fjord's fixed Linux sizes.")
                            .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                    }
                }
                .font(CDS.sans(12))
                .foregroundStyle(CDS.Text.secondary)
                HStack {
                    Spacer()
                    ActionButton("Create", height: 34) { create() }
                        .disabled(!ComputerName.isValid(name) || !withinLimits(limits))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(CDS.Surface.s1)
        .preferredColorScheme(.dark)
        .task {
            deviceId = model.createDeviceId
            await loadLimits()
        }
    }

    private func loadLimits() async {
        do {
            let value = try await model.resourceLimits(for: kind, deviceId: model.createDeviceId)
            limits = value
            let base = kind == .linux ? "linux-new" : "macos-new"
            name = ComputerName.unique(base, among: model.inventory(for: model.createDeviceId)?.allComputers.map(\.name) ?? [])
            cpus = value.defaultCPUs
            memoryGiB = value.defaultMemoryGiB
            diskGiB = value.defaultDiskGiB ?? 64
        } catch { loadError = error.localizedDescription }
    }

    private func withinLimits(_ limits: ComputerResourceLimits) -> Bool {
        (limits.minCPUs...limits.maxCPUs).contains(cpus)
            && (limits.minMemoryGiB...limits.maxMemoryGiB).contains(memoryGiB)
            && (limits.minDiskGiB.map { diskGiB >= $0 } ?? true)
            && (limits.maxDiskGiB.map { diskGiB <= $0 } ?? true)
    }

    private func create() {
        guard ComputerName.isValid(name) else { return }
        Task {
            if kind == .linux {
                await model.createLinuxComputer(name: name, cpus: cpus, memoryGiB: memoryGiB, deviceId: deviceId)
            } else {
                await model.createMacosComputer(name: name, cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB, deviceId: deviceId)
            }
            if model.actionError == nil { dismiss() }
        }
    }
}

struct ComputerResourcesPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var cpus = 1
    @State private var memoryGiB = 1
    @State private var maxCPUs = 1
    @State private var maxMemoryGiB = 1
    @State private var hostLimitsLoaded = false
    @State private var limitError: String?
    @State private var minCPUsValue = 2
    @State private var minMemoryValue = 4
    @State private var confirmsStop = false
    @State private var displayedConfiguration: ComputerConfiguration?

    private var isRunning: Bool { row.displayState == .running }

    var body: some View {
        ComputerPanel(title: "Resources", action: {
            ActionButton(isRunning ? "Save and stop" : "Save resources") {
                if isRunning { confirmsStop = true }
                else { save() }
            }
            .disabled(!hostLimitsLoaded || (cpus == currentCPUs && memoryGiB == currentMemory)
                      || (row.displayState != .running && row.displayState != .stopped))
        }) {
            VStack(alignment: .leading, spacing: 9) {
                if let limitError {
                    ComputerNotice(text: limitError, tone: .warning)
                } else if !hostLimitsLoaded {
                    ProgressView("Reading host limits…").font(CDS.sans(10))
                } else {
                    Stepper("CPU  ·  \(cpus) of \(maxCPUs)", value: $cpus, in: minCPUs...maxCPUs)
                    Stepper("Memory  ·  \(memoryGiB) GiB of \(maxMemoryGiB) GiB",
                            value: $memoryGiB, in: minMemory...maxMemoryGiB)
                }
                Text("Disk size stays fixed after creation.\(isRunning ? " Saving stops the computer; changes take effect the next time it starts." : "")")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
            }
        }
        .confirmationDialog("Stop \(row.name) and save resources?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop and save", role: .destructive) { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("CPU and memory changes apply the next time this computer starts.")
        }
        .onAppear {
            switch row {
            case .linux(let computer):
                cpus = computer.configuration.cpus
                memoryGiB = computer.configuration.memoryGiB
                maxCPUs = computer.configuration.maxCPUs
                maxMemoryGiB = computer.configuration.maxMemoryGiB
                displayedConfiguration = computer.configuration
                hostLimitsLoaded = true
            case .macos(let computer):
                cpus = Int(clamping: computer.cpus)
                memoryGiB = Int(clamping: computer.memoryGiB)
                maxCPUs = max(2, cpus)
                maxMemoryGiB = max(4, memoryGiB)
                hostLimitsLoaded = false
                Task { await loadMacosLimits() }
            }
        }
        .onChange(of: row.id) { _, _ in
            if case .macos(let computer) = row {
                cpus = Int(clamping: computer.cpus)
                memoryGiB = Int(clamping: computer.memoryGiB)
                hostLimitsLoaded = false
                Task { await loadMacosLimits() }
                return
            }
            guard case .linux(let computer) = row else { return }
            cpus = computer.configuration.cpus
            memoryGiB = computer.configuration.memoryGiB
            maxCPUs = computer.configuration.maxCPUs
            maxMemoryGiB = computer.configuration.maxMemoryGiB
            displayedConfiguration = computer.configuration
        }
    }

    private func loadMacosLimits() async {
        do {
            let limits = try await model.resourceLimits(for: .macos, deviceId: target.deviceId)
            maxCPUs = max(limits.maxCPUs, currentCPUs)
            maxMemoryGiB = max(limits.maxMemoryGiB, currentMemory)
            minCPUsValue = limits.minCPUs
            minMemoryValue = limits.minMemoryGiB
            limitError = nil
            hostLimitsLoaded = true
        } catch { limitError = error.localizedDescription }
    }

    private var currentCPUs: Int {
        switch row { case .linux(let c): c.configuration.cpus; case .macos(let c): Int(clamping: c.cpus) }
    }
    private var currentMemory: Int {
        switch row { case .linux(let c): c.configuration.memoryGiB; case .macos(let c): Int(clamping: c.memoryGiB) }
    }
    private var minCPUs: Int { row.kind == .macos ? min(minCPUsValue, currentCPUs) : 1 }
    private var minMemory: Int { row.kind == .macos ? min(minMemoryValue, currentMemory) : 1 }

    private func save() {
        Task {
            await model.updateResources(for: target, cpus: cpus, memoryGiB: memoryGiB,
                                        expectedConfiguration: displayedConfiguration)
        }
    }
}

struct ComputerUsePanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    private var state: SiloWireComputerUseState? { model.computerUseByComputer[target.key] }
    private var isAutomatic: Bool { state?.approval == .auto }

    var body: some View {
        ComputerPanel(title: "Computer use") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(state?.state?.rawValue.capitalized ?? "Checking readiness…")
                        .font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.secondary)
                    Spacer()
                    if state?.state == .failed || state?.state == .unavailable {
                        ActionButton("Set up") { Task { await model.setupComputerUse(target) } }
                    }
                }
                if let warning = state?.warning ?? state?.reason {
                    Text(warning).font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                }
                Toggle("Approve computer use automatically", isOn: Binding(get: { isAutomatic }, set: { newValue in
                    Task { await model.setComputerUseApproval(target, automatic: newValue) }
                }))
                .toggleStyle(.switch)
                .font(CDS.sans(11))
                Text("Approval controls agent prompts. It does not lock the screen or restrict other input.")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
            }
        }
    }
}

struct ComputerAgentToolsPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    private var status: SiloWireAgentToolsStatus? { model.agentTools(for: target) }
    private var setupMessage: String? { model.agentToolsSetupMessage[target.key] }

    var body: some View {
        ComputerPanel(title: "Agent tools") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(setupMessage != nil ? "Setting up…" : status.map(AgentToolsAdvice.headline)
                         ?? (row.displayState == .running ? "Checking…" : "Start the computer to check"))
                        .font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.secondary)
                    Spacer()
                    if setupMessage != nil {
                        ProgressView().controlSize(.small)
                    } else if let status, AgentToolsAdvice.needsSetup(status), row.displayState == .running {
                        ActionButton(AgentToolsAdvice.actionTitle(status)) {
                            Task { await model.setUpAgentTools(target, computerName: row.name) }
                        }
                    }
                }
                if let setupMessage {
                    Text(setupMessage).font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                } else if let status {
                    Text(AgentToolsAdvice.detail(status)).font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                    if AgentToolsAdvice.needsSetup(status), row.kind == .macos {
                        Text("Silo installs these on a Mac computer with its developer-tools setup; retry the setup from this computer's activity.")
                            .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                    }
                }
                if let error = model.agentToolsError[target.key] { ComputerNotice(text: error, tone: .danger) }
            }
        }
    }
}

struct ComputerFilesPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    private var listing: SiloWireFileListResult? { model.fileLists[target.key] }
    private var root: String? { ComputerFilesPath.root(for: row.kind) }
    private var path: String { model.filePaths[target.key] ?? root ?? "" }

    var body: some View {
        ComputerPanel(title: "Files", action: {
            if root != nil {
                HStack(spacing: 7) {
                    ActionButton("Upload") { chooseUpload() }
                    ActionButton("Refresh") { Task { await model.loadFiles(target, path: path) } }
                }
            }
        }) {
            if root == nil {
                Label("Mac file browsing is coming soon.", systemImage: "clock")
                    .font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.secondary)
                Text("The engine API does not define a macOS Files root yet.")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ActionButton("Up") {
                            if let parent = ComputerFilesPath.parent(of: path, kind: row.kind) {
                                Task { await model.loadFiles(target, path: parent) }
                            }
                        }
                        .disabled(path == root)
                        Text(path).font(CDS.sans(10).monospaced()).foregroundStyle(CDS.Text.muted).lineLimit(1)
                    }
                    .padding(.bottom, 10)
                    if let conflict = model.uploadConflict(for: target) {
                        VStack(alignment: .leading, spacing: 9) {
                            ComputerNotice(text: "Upload paused. Existing files: \(conflict.names.joined(separator: ", ")).",
                                           tone: .warning)
                            HStack(spacing: 7) {
                                ActionButton("Replace") {
                                    Task { await model.resolveUploadConflict(jobId: conflict.jobId, policy: .replace) }
                                }
                                ActionButton("Keep both") {
                                    Task { await model.resolveUploadConflict(jobId: conflict.jobId, policy: .keepBoth) }
                                }
                                ActionButton("Dismiss") {
                                    Task { await model.dismissUploadConflict(jobId: conflict.jobId) }
                                }
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    if let notice = model.uploadNotice(for: target) {
                        HStack(spacing: 8) {
                            ComputerNotice(text: notice.message, tone: .warning)
                            ActionButton("Dismiss") { Task { await model.dismissUploadNotice(jobId: notice.jobId) } }
                        }
                        .padding(.bottom, 10)
                    }
                    if let listing {
                        ForEach(listing.entries, id: \.path) { entry in
                            HStack(spacing: 9) {
                                Image(systemName: entry.kind == .folder ? "folder" : "doc.text")
                                    .foregroundStyle(CDS.Text.secondary).frame(width: 16)
                                if entry.kind == .folder {
                                    Button(entry.name) { Task { await model.loadFiles(target, path: entry.path) } }
                                        .buttonStyle(.plain).font(CDS.sans(11)).foregroundStyle(CDS.Text.primary)
                                    Spacer()
                                } else {
                                    Text(entry.name).font(CDS.sans(11)).foregroundStyle(CDS.Text.primary)
                                    Spacer()
                                    ActionButton("Download") { chooseDownload(entry) }
                                }
                            }
                            .padding(.vertical, 7)
                            SettingsDivider()
                        }
                        if let offset = listing.nextOffset {
                            ActionButton("Load more") {
                                Task { await model.loadFiles(target, path: path, offset: offset,
                                                             snapshotId: listing.snapshotId) }
                            }
                            .padding(.top, 9)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
                    }
                    Text("The engine limits viewer-origin uploads to Downloads.")
                        .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted).padding(.top, 9)
                }
            }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await model.uploadFiles(target, directory: path,
                                       paths: panel.urls.map(\.standardizedFileURL.path)) }
    }

    private func chooseDownload(_ entry: SiloWireFileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.downloadFile(target, path: entry.path, destination: url.standardizedFileURL.path) }
    }

}

struct ComputerNetworkPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var guestPort = "3000"
    @State private var hostPort = ""
    @State private var networkScheme = "http"
    @State private var sshPort = "2222"
    @State private var bindAddress = "127.0.0.1"
    @State private var sshKeys = ""
    @State private var sshEnabled = false
    private var state: SiloWireNetworkComputer? { model.networkByComputer[target.key] }
    private var sshState: SiloWireSSHAccessComputer? { model.sshAccessByComputer[target.key] }
    private var visiblePorts: [SiloWirePublishedPort] {
        (state?.ports ?? []).filter { !(row.kind == .linux && $0.port == ComputerNetworkPolicy.hiddenDesktopPort) }
    }

    var body: some View {
        ComputerPanel(title: "Network and SSH", action: {
            ActionButton("Publish port") { publish() }
                .disabled(!canPublish)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Guest port", text: $guestPort).frame(width: 92)
                    TextField("Host port (optional)", text: $hostPort).frame(width: 150)
                    Picker("Service type", selection: $networkScheme) {
                        Text("TCP").tag("tcp")
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                    }
                    .pickerStyle(.menu)
                    Spacer(minLength: 0)
                }
                .textFieldStyle(.roundedBorder)
                if row.kind == .linux && Int(guestPort) == ComputerNetworkPolicy.hiddenDesktopPort {
                    ComputerNotice(text: "Linux desktop traffic stays behind Open screen.", tone: .warning)
                }
                if let error = state?.error {
                    ComputerNotice(text: error, tone: .warning)
                }
                if !visiblePorts.isEmpty {
                    ForEach(visiblePorts, id: \.port) { port in
                        HStack(spacing: 8) {
                            let hostPort = port.hostPort ?? port.configuredHostPort
                            Text("\(String(port.port)) → \(hostPort.map(String.init) ?? "automatic")")
                                .font(CDS.sans(11).monospaced()).foregroundStyle(CDS.Text.primary)
                            SettingsStatusLine(text: port.state.rawValue.capitalized,
                                               color: port.state == .reachable ? Theme.green : Theme.amber)
                            if let message = port.message {
                                Text(message).font(CDS.sans(9)).foregroundStyle(CDS.Text.warning).lineLimit(1)
                            }
                            Spacer()
                            if port.configured {
                                if port.state == .reachable, port.scheme != nil {
                                    ActionButton("Open") { Task { await model.openPort(target, port: port.port) } }
                                        .disabled(ComputerRemoteLimit.openPort.unavailableReason(for: target) != nil)
                                }
                                ActionButton("Remove") { Task { await model.unpublishPort(target, port: port.port) } }
                            } else {
                                ActionButton("Publish") {
                                    Task { await model.publishPort(target, port: port.port,
                                                                  hostPort: port.configuredHostPort,
                                                                  scheme: port.scheme ?? selectedNetworkScheme) }
                                }
                            }
                        }
                    }
                } else {
                    Text("No listening services detected").font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
                }
                Text("Detected services stay private until you publish them. The Linux desktop port stays private behind Open screen.")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                if target.deviceId != nil {
                    Text("\(ComputerRemoteLimit.openPort.reason) \(ComputerRemoteLimit.terminal.reason)")
                        .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                }
                SettingsDivider().padding(.vertical, 3)
                HStack {
                    Text("SSH access").font(CDS.sans(12, .semibold)).foregroundStyle(CDS.Text.primary)
                    Spacer()
                    Toggle("Enable SSH access", isOn: $sshEnabled).toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: 8) {
                    TextField("Port", text: $sshPort).frame(width: 82)
                    TextField("Bind address", text: $bindAddress).frame(width: 150)
                    Spacer()
                    ActionButton("Save SSH access") { saveSSHAccess() }
                }
                .textFieldStyle(.roundedBorder)
                Text("IPv4 interface address or 127.0.0.1. Wildcard addresses are refused.")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted)
                Text("Authorized public keys").font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.secondary)
                TextEditor(text: $sshKeys)
                    .font(CDS.sans(10).monospaced())
                    .frame(minHeight: 58, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(CDS.Fill.field, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CDS.border, lineWidth: 1))
                if let sshState {
                    HStack {
                        SettingsStatusLine(text: sshState.message ?? "SSH \(sshState.state.rawValue)",
                                           color: sshState.state == .error ? Theme.red : Theme.green)
                        Spacer()
                        if sshState.state == .listening {
                            ActionButton("Open SSH in Terminal") {
                                Task { await model.openSSHAccessConnection(target) }
                            }
                            .disabled(ComputerRemoteLimit.terminal.unavailableReason(for: target) != nil)
                        }
                    }
                }
            }
        }
        .task {
            await model.loadSSHAccess(target)
            if let sshState {
                sshEnabled = sshState.enabled
                sshPort = String(sshState.port)
                bindAddress = sshState.bindAddress
                sshKeys = sshState.keys.joined(separator: "\n")
            }
        }
    }

    private func publish() {
        guard let port = Int(guestPort), (1...65_535).contains(port),
              !(row.kind == .linux && port == ComputerNetworkPolicy.hiddenDesktopPort) else { return }
        let host = hostPort.isEmpty ? nil : Int(hostPort)
        Task { await model.publishPort(target, port: port, hostPort: host,
                                       scheme: selectedNetworkScheme) }
    }

    private func saveSSHAccess() {
        guard let port = Int(sshPort), (1...65_535).contains(port) else { return }
        let keys = sshKeys.split(whereSeparator: \.isNewline).map(String.init)
        Task { await model.saveSSHAccess(target, enabled: sshEnabled, port: port,
                                         bindAddress: bindAddress, keys: keys) }
    }

    private var canPublish: Bool {
        guard let port = Int(guestPort), (1...65_535).contains(port),
              !(row.kind == .linux && port == ComputerNetworkPolicy.hiddenDesktopPort) else { return false }
        guard !hostPort.isEmpty else { return true }
        guard let host = Int(hostPort) else { return false }
        return (1...65_535).contains(host)
    }

    private var selectedNetworkScheme: SiloWireNetworkScheme? {
        switch networkScheme {
        case "http": .http
        case "https": .https
        default: nil
        }
    }
}

struct ComputerGitHubPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var token = ""
    private var state: SiloWireGitHubState? { model.githubState(for: target.deviceId) }
    private var policy: SiloWireGitHubPolicy? { state?.computers.first { $0.computerId == row.id } }

    var body: some View {
        ComputerPanel(title: "GitHub repositories", action: {
            ActionButton("Refresh repositories") { Task { await model.refreshGitHubRepositories(deviceId: target.deviceId) } }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SettingsStatusLine(text: state?.account ?? state?.state.rawValue.capitalized ?? "Loading GitHub",
                                       color: state?.state == .connected ? Theme.green : Theme.amber)
                    Spacer()
                    if state?.state == .connected {
                        SettingsSwitch("GitHub access", isOn: Binding(
                            get: { state?.accessEnabled ?? false },
                            set: { newValue in Task { await model.setGitHubAccess(newValue, deviceId: target.deviceId) } }))
                        ActionButton("Manage repositories") { Task { await model.manageGitHubRepositories(deviceId: target.deviceId) } }
                        ActionButton("Disconnect") { Task { await model.disconnectGitHub(deviceId: target.deviceId) } }
                    } else if state?.pendingAuthorizationUrl != nil {
                        ActionButton("Reopen sign in") { Task { await model.reopenGitHubAuthorization(deviceId: target.deviceId) } }
                    } else if state?.state == .connecting {
                        ActionButton("Connecting…") { }
                            .disabled(true)
                    } else {
                        ActionButton("Connect GitHub") { Task { await model.connectGitHub(deviceId: target.deviceId) } }
                    }
                }
                if state?.state != .connected {
                    HStack(spacing: 8) {
                        SecureField("GitHub personal token", text: $token).textFieldStyle(.roundedBorder)
                        ActionButton("Save token") { Task { await model.saveGitHubToken(token, deviceId: target.deviceId); token = "" } }
                            .disabled(token.isEmpty)
                    }
                } else if state?.personalToken.saved == true {
                    ActionButton("Remove saved token") { Task { await model.removeGitHubToken(deviceId: target.deviceId) } }
                }
                if state?.repositoryCatalog.isEmpty == true {
                    SettingsNote(state?.repositoryCatalogStatus.message ?? "No repositories available")
                }
                ForEach(state?.repositoryCatalog ?? [], id: \.self) { repository in
                    let selected = policy?.repositories.contains { $0.repository == repository } ?? false
                    Toggle(repository, isOn: Binding(get: { selected }, set: { on in
                        var selectedRepositories = policy?.repositories.map(\.repository) ?? []
                        if on, !selectedRepositories.contains(repository) { selectedRepositories.append(repository) }
                        if !on { selectedRepositories.removeAll { $0 == repository } }
                        Task { await model.setGitHubRepositories(target, repositories: selectedRepositories) }
                    }))
                    .toggleStyle(.checkbox)
                    .font(CDS.sans(11))
                }
                if !(policy?.repositories.isEmpty ?? true) {
                    Toggle("Allow pushes to selected repositories",
                           isOn: Binding(get: { policy?.repositories.allSatisfy(\.allowPushes) ?? false }, set: { enabled in
                        let repositories = policy?.repositories.map(\.repository) ?? []
                        Task { await model.setGitHubRepositories(target, repositories: repositories,
                                                                 allowPushes: enabled) }
                    }))
                    .toggleStyle(.checkbox)
                    .font(CDS.sans(11))
                }
                if let operation = state?.computerOperations.first(where: { $0.computerId == row.id }) {
                    SettingsStatusLine(text: operation.message,
                                       color: operation.status == .failed ? Theme.red : Theme.amber)
                    if operation.canRetry == true {
                        ActionButton("Retry apply") { Task { await model.retryGitHubConfiguration(target) } }
                    }
                }
            }
        }
    }
}

struct ComputerSecretsPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var editorPresentation: SecretEditorPresentation?
    @State private var removingSecret: SiloWireSecret?
    @State private var confirmsRemoval = false
    private var secrets: [SiloWireSecret] { model.secrets(for: target.deviceId) }

    var body: some View {
        ComputerPanel(title: "Secrets", action: {
            ActionButton("Add secret") { editorPresentation = SecretEditorPresentation(id: "add", secret: nil) }
        }) {
            if secrets.isEmpty {
                SettingsNote("No secrets saved on \(target.deviceId == nil ? "this Mac" : model.ownerName(target.deviceId)).")
            }
            ForEach(secrets, id: \.id) { secret in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(secret.name).font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.primary)
                            Text(secret.allowedDomains.isEmpty ? "No destinations" : secret.allowedDomains.joined(separator: ", "))
                                .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                        }
                        Spacer()
                        Toggle("Assigned", isOn: Binding(get: { secret.computerIds.contains(row.id) }, set: { assigned in
                            var ids = secret.computerIds
                            if assigned, !ids.contains(row.id) { ids.append(row.id) }
                            if !assigned { ids.removeAll { $0 == row.id } }
                            Task { await model.saveSecret(id: secret.id, name: secret.name, value: nil, computerIds: ids,
                                                          allowedDomains: secret.allowedDomains, allowAnyDestination: secret.allowedDomains.contains("*"),
                                                          deviceId: target.deviceId) }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(secret.computerIds.count <= 1 && secret.computerIds.contains(row.id))
                        ActionButton("Edit") {
                            editorPresentation = SecretEditorPresentation(id: "edit-\(secret.id)", secret: secret)
                        }
                        if secret.error != nil || secret.removing {
                            ActionButton("Retry") { Task { await model.retrySecret(id: secret.id, deviceId: target.deviceId) } }
                        }
                        ActionButton("Remove") {
                            removingSecret = secret
                            confirmsRemoval = true
                        }
                    }
                    if let error = secret.error {
                        ComputerNotice(text: error, tone: .warning)
                    } else if secret.pendingComputerIds.contains(row.id) {
                        SettingsNote("Changes apply on the next start for this computer.")
                    }
                }
                .padding(.vertical, 5)
            }
            Text("Values are write-only and stay out of activity and log records.")
                .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted).padding(.top, 6)
        }
        .sheet(item: $editorPresentation) { presentation in
            SecretEditorSheet(model: model, computerId: row.id, deviceId: target.deviceId, secret: presentation.secret)
        }
        .confirmationDialog("Remove secret?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove secret", role: .destructive) {
                if let removingSecret { Task { await model.removeSecret(id: removingSecret.id, deviceId: target.deviceId) } }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Fjord removes the saved value and retries revocation on computers that may still hold it.")
        }
    }
}

private struct SecretEditorPresentation: Identifiable {
    var id: String
    var secret: SiloWireSecret?
}

struct SecretEditorSheet: View {
    let model: ComputersModel
    let computerId: String
    let deviceId: String?
    let secret: SiloWireSecret?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var domains = "api.github.com"
    @State private var allowAnyDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(secret == nil ? "Add secret" : "Edit secret").font(CDS.sans(16, .semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).disabled(secret != nil)
            SecureField(secret == nil ? "Value" : "Replace value (leave blank to keep)", text: $value).textFieldStyle(.roundedBorder)
            TextField("Allowed host names, comma separated", text: $domains).textFieldStyle(.roundedBorder)
            Toggle("Allow any destination (*)", isOn: $allowAnyDestination).toggleStyle(.checkbox)
            if allowAnyDestination {
                Text("This sends the secret to any HTTPS destination. Confirm this scope deliberately.")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.warning)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                ActionButton("Save") { save() }.disabled(!canSave)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear {
            if let secret {
                name = secret.name
                domains = secret.allowedDomains.filter { $0 != "*" }.joined(separator: ", ")
                allowAnyDestination = secret.allowedDomains.contains("*")
            }
        }
    }

    private func save() {
        guard ComputerSecretValidation.domains(finalDomains, allowAnyDestination: allowAnyDestination) else { return }
        Task {
            model.actionError = nil
            await model.saveSecret(id: secret?.id, name: name, value: value.isEmpty ? nil : value,
                                   computerIds: Array(Set((secret?.computerIds ?? []) + [computerId])).sorted(),
                                   allowedDomains: finalDomains, allowAnyDestination: allowAnyDestination,
                                   deviceId: deviceId)
            if model.actionError == nil { dismiss() }
        }
    }

    private var parsedDomains: [String] {
        domains.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var finalDomains: [String] { allowAnyDestination ? ["*"] : parsedDomains }

    private var canSave: Bool {
        ComputerSecretValidation.name(name)
            && ComputerSecretValidation.domains(finalDomains, allowAnyDestination: allowAnyDestination)
            && (secret != nil || !value.isEmpty)
    }
}

struct ComputerActivityPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var query = ""
    @State private var source = SiloWireLogSource.all.rawValue
    @State private var since = ""
    @State private var until = ""
    @State private var aroundId = ""
    @State private var following = false

    var body: some View {
        ComputerPanel(title: "Activity and logs", action: {
            ActionButton("Refresh") { refreshLogs() }
        }) {
            HStack(spacing: 8) {
                TextField("Filter logs", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { refreshLogs() }
                Picker("Log source", selection: $source) {
                    ForEach([SiloWireLogSource.all, .stdout, .stderr, .output, .system, .runtime, .kernel], id: \.rawValue) { value in
                        Text(value.rawValue.capitalized).tag(value.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Log source")
                .frame(width: 110)
            }
            DisclosureGroup("Time range and context") {
                HStack(spacing: 8) {
                    TextField("Since (RFC 3339)", text: $since).textFieldStyle(.roundedBorder)
                    TextField("Until (RFC 3339)", text: $until).textFieldStyle(.roundedBorder)
                }
                TextField("Around record ID", text: $aroundId).textFieldStyle(.roundedBorder)
            }
            .font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.secondary)
            Toggle("Follow new output", isOn: $following)
                .toggleStyle(.switch).font(CDS.sans(10))
            if model.setupActivity(for: target.deviceId).isEmpty { SettingsNote("No setup activity recorded.") }
            ForEach(model.setupActivity(for: target.deviceId), id: \.requestId) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.phase).font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.secondary)
                    Text(item.message).font(CDS.sans(10)).foregroundStyle(CDS.Text.muted).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            SettingsDivider().padding(.vertical, 5)
            if let page = model.logsByComputer[target.key] {
                if page.unsupported == true { ComputerNotice(text: "This computer owner cannot serve logs.", tone: .warning) }
                if page.unreadableRecords == true { ComputerNotice(text: "Some log records could not be read.", tone: .warning) }
                ForEach(page.entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.occurredAt).font(CDS.sans(9).monospaced()).foregroundStyle(CDS.Text.muted)
                        Text(entry.line).font(CDS.sans(10).monospaced()).foregroundStyle(CDS.Text.secondary)
                            .textSelection(.enabled)
                        if entry.line == "[Sensitive runtime output hidden]" {
                            Text("Sensitive output hidden").font(CDS.sans(9, .medium)).foregroundStyle(CDS.Text.warning)
                        }
                        if entry.line.contains("[record over 1 MiB truncated]")
                            || entry.line.contains("[Execution log record over 1 MiB omitted]") {
                            Text("Oversized output truncated or omitted")
                                .font(CDS.sans(9, .medium)).foregroundStyle(CDS.Text.warning)
                        }
                    }.padding(.vertical, 4)
                }
                Text("\(page.totalMatches) matching records\(page.timestampEstimated ? " · guest timestamps estimated" : "")")
                    .font(CDS.sans(9)).foregroundStyle(CDS.Text.muted)
                if let cursor = page.nextCursor {
                    ActionButton("Load more logs") {
                        Task { await model.loadLogs(target, query: query.isEmpty ? nil : query,
                                                    cursor: cursor, source: selectedSource,
                                                    since: optional(since), until: optional(until), aroundId: optional(aroundId)) }
                    }
                    .padding(.top, 8)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            HStack {
                Spacer()
                ActionButton("Export logs") { exportLogs() }
            }
        }
        .task(id: following) {
            guard following else { return }
            if model.logsByComputer[target.key]?.snapshot == nil { await loadCurrentSearch() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard let snapshot = model.logsByComputer[target.key]?.snapshot else { continue }
                await model.loadLogs(target, query: query.isEmpty ? nil : query,
                                     source: selectedSource, since: optional(since), until: optional(until),
                                     aroundId: optional(aroundId), follow: snapshot)
            }
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(row.name)-logs.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportLogs(target, destination: url.path,
                                      query: query.isEmpty ? nil : query, source: selectedSource,
                                      since: optional(since), until: optional(until), aroundId: optional(aroundId)) }
    }

    private func refreshLogs() {
        following = false
        Task { await loadCurrentSearch() }
    }

    private func loadCurrentSearch() async {
        await model.loadLogs(target, query: query.isEmpty ? nil : query, source: selectedSource,
                             since: optional(since), until: optional(until), aroundId: optional(aroundId))
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var selectedSource: SiloWireLogSource { SiloWireLogSource(rawValue: source) ?? .all }
}

struct ComputerStoragePanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    private var storage: SiloWireStorageState? { model.storageByComputer[target.key] }

    var body: some View {
        ComputerPanel(title: "Storage", action: {
            ActionButton("Reclaim storage") { Task { await model.reclaimStorage(target) } }
        }) {
            if let storage {
                metric("Workspace used", storage.workspaceUsedBytes)
                metric("Workspace capacity", storage.workspaceCapacityBytes)
                metric("Workspace host allocation", storage.workspaceHostBytes)
                metric("Runtime host allocation", storage.runtimeHostBytes)
                metric("Checkpoint host allocation", storage.checkpointHostBytes)
                metricCount("Checkpoint count", storage.checkpointCount)
                if let bytes = storage.lastReclaimedBytes { metric("Last reclaimed", bytes) }
                if let error = storage.lastError { ComputerNotice(text: error, tone: .warning) }
                if !storage.history.isEmpty {
                    SettingsDivider().padding(.vertical, 6)
                    Text("Recent reclaim history").font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.secondary)
                    ForEach(Array(storage.history.prefix(5).enumerated()), id: \.offset) { item in
                        let entry = item.element
                        HStack(spacing: 8) {
                            Text(entry.trigger.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized)
                                .font(CDS.sans(10)).foregroundStyle(CDS.Text.secondary)
                            Spacer()
                            if let bytes = entry.reclaimedBytes {
                                Text(byteCount(bytes)).font(CDS.sans(10).monospaced()).foregroundStyle(CDS.Text.muted)
                            }
                        }
                        if let error = entry.error { Text(error).font(CDS.sans(9)).foregroundStyle(CDS.Text.warning) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
            }
        }
    }

    private func metric(_ title: String, _ bytes: UInt64?) -> some View {
        HStack {
            Text(title).font(CDS.sans(11)).foregroundStyle(CDS.Text.secondary)
            Spacer()
            Text(bytes.map(byteCount) ?? "Not reported").font(CDS.sans(11, .medium).monospaced()).foregroundStyle(CDS.Text.primary)
        }
    }

    private func metricCount(_ title: String, _ count: UInt64?) -> some View {
        HStack {
            Text(title).font(CDS.sans(11)).foregroundStyle(CDS.Text.secondary)
            Spacer()
            Text(count.map(String.init) ?? "Not reported")
                .font(CDS.sans(11, .medium).monospaced()).foregroundStyle(CDS.Text.primary)
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

struct ComputerExportPanel: View {
    let row: ComputerRow
    let target: GuestReference
    let model: ComputersModel
    @State private var newName = ""
    @State private var archivePath: String? = nil
    @State private var sourceName = ""
    @State private var operationToDismiss: SiloWireOperationClass?
    @State private var confirmsDismiss = false
    private var state: SiloWireBackupState? { model.exportState(for: target.deviceId) }
    /// Folders and archives are paths on the Mac that owns the computer, which this Mac's file panels cannot browse.
    private var isRemote: Bool { target.deviceId != nil }
    private var ownerName: String { model.ownerName(target.deviceId) }

    var body: some View {
        ComputerPanel(title: "Export and import", action: {
            HStack(spacing: 7) {
                ActionButton("Choose export folder") { chooseFolder() }
                    .disabled(isRemote)
                ActionButton("Export computer") { Task { await model.exportComputer(target) } }
                    .disabled(state?.destination == nil || state?.availability != .available)
            }
        }) {
            Text(state?.destination ?? (isRemote ? "No export folder is set on \(ownerName)." : "Choose a destination on this Mac."))
                .font(CDS.sans(10).monospaced()).foregroundStyle(CDS.Text.muted).lineLimit(2)
            if isRemote {
                SettingsNote("The export folder and archives are on \(ownerName). Choose the folder in Silo there; Fjord exports to it.")
            }
            HStack(spacing: 8) {
                ActionButton("Choose archive") { chooseArchive() }
                    .disabled(isRemote)
                Text(archivePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No archive selected")
                    .font(CDS.sans(10)).foregroundStyle(CDS.Text.muted).lineLimit(1)
            }
            if model.archiveInspection == nil, archivePath != nil { ProgressView("Inspecting archive…").font(CDS.sans(10)) }
            if let inspection = model.archiveInspection {
                if inspection.valid {
                    SettingsNote("Valid archive · \(inspection.archive.size) · \(inspection.archive.computers.count) computer(s)")
                    if inspection.archive.computers.count > 1 {
                        Picker("Computer to import", selection: $sourceName) {
                            ForEach(inspection.archive.computers, id: \.self) { name in Text(name).tag(name) }
                        }
                        .pickerStyle(.menu)
                    }
                    HStack(spacing: 8) {
                        TextField("Imported computer name", text: $newName).textFieldStyle(.roundedBorder)
                        ActionButton("Import computer") { importArchive() }
                            .disabled(!ComputerName.isValid(newName) || sourceName.isEmpty)
                    }
                } else {
                    ComputerNotice(text: inspection.reason ?? "This archive cannot be imported.", tone: .warning)
                }
            }
            if let message = state?.availabilityMessage { ComputerNotice(text: message, tone: .warning) }
            if let operation = state?.operation {
                VStack(alignment: .leading, spacing: 7) {
                    Text(operation.title ?? (operation.kind == .running ? "Export/import in progress" : "Export/import result"))
                        .font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.primary)
                    if operation.kind == .running {
                        if let progress = operation.progress { ProgressView(value: Double(progress), total: 100) }
                        Text(operation.phases?.map(\.detail).joined(separator: " · ") ?? operation.message ?? "Working")
                            .font(CDS.sans(10)).foregroundStyle(CDS.Text.secondary)
                    } else {
                        if let message = operation.message ?? operation.detail {
                            Text(message).font(CDS.sans(10)).foregroundStyle(CDS.Text.secondary)
                        }
                        if operation.outcome == .failed {
                            ComputerNotice(text: operation.message ?? operation.detail ?? "The export or import failed.", tone: .danger)
                        } else if operation.outcome == .cancelled {
                            ComputerNotice(text: operation.message ?? "The export or import was cancelled.", tone: .warning)
                        }
                        HStack(spacing: 8) {
                            if state?.resultUnseen == true {
                                ActionButton("Mark as seen") { Task { await model.acknowledgeExportResult(deviceId: target.deviceId) } }
                            }
                            ActionButton("Dismiss result") {
                                operationToDismiss = operation
                                confirmsDismiss = true
                            }
                        }
                    }
                }
            }
            if let archives = state?.archives, !archives.isEmpty {
                SettingsDivider().padding(.vertical, 6)
                Text("Recent archives").font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.secondary)
                ForEach(archives, id: \.archivePath) { archive in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(archive.name).font(CDS.sans(10, .medium)).foregroundStyle(CDS.Text.primary)
                            Text("\(archive.completedLabel) · \(archive.size)")
                                .font(CDS.sans(9)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                        }
                        Spacer()
                        if !isRemote {
                            ActionButton("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archive.archivePath)])
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Dismiss this export or import result?", isPresented: $confirmsDismiss,
                            titleVisibility: .visible) {
            Button("Dismiss result", role: .destructive) {
                if let operationToDismiss { Task { await model.dismissExportOperation(operationToDismiss, deviceId: target.deviceId) } }
                operationToDismiss = nil
            }
            Button("Cancel", role: .cancel) { operationToDismiss = nil }
        } message: {
            Text(operationToDismiss?.outcome == .failed
                ? "If a failed recovery still has a pending journal, dismissing it abandons that retry."
                : "This removes the current export or import result from the Computers panel.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setExportDestination(url.standardizedFileURL.path, deviceId: target.deviceId) }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "silo-backup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archivePath = url.standardizedFileURL.path
        model.archiveInspection = nil
        Task {
            await model.inspectExportArchive(path: url.standardizedFileURL.path, deviceId: target.deviceId)
            guard let inspection = model.archiveInspection, inspection.valid else { return }
            sourceName = inspection.archive.computers.first ?? ""
            let base = sourceName.isEmpty ? "imported-computer" : sourceName
            newName = ComputerName.unique(base, among: model.inventory(for: target.deviceId)?.allComputers.map(\.name) ?? [])
        }
    }

    private func importArchive() {
        guard let archivePath, let inspection = model.archiveInspection, inspection.valid,
              inspection.archive.computers.contains(sourceName), ComputerName.isValid(newName) else { return }
        Task { await model.importComputer(archivePath: archivePath, newName: newName, sourceName: sourceName, deviceId: target.deviceId) }
    }
}
