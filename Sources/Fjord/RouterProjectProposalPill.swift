import SwiftUI

// The proposal to start a project, as the Router's own pill over the composer (RouterCourierPill's look): the mark, "New project
// "name"" and what it is at, then under a rule what would be made (folder, repo, instructions) and what happens to your message.
// Return creates it, Escape drops it; typing in the composer revises it. Once the project is made its name and the made pieces
// are fixed, and the pill says so; while the engine waits on claude.ai it says why, and goes on by itself.

struct RouterProjectProposalPill: View {
    let proposal: RouterProjectProposal
    /// Proposals for later messages waiting for this one to end.
    var queued = 0
    /// The ×: the composer's drop (the message back in it, `RouterModel.dropProposal`).
    var onDrop: () -> Void = {}

    var body: some View {
        let f = proposal.fields
        VStack(alignment: .leading, spacing: 0) {
            head(f).padding(.horizontal, 12).frame(height: 34)
            Rectangle().fill(CDS.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                row("Folder", f.folder.map(Self.shown) ?? "none", made: proposal.made.contains(.folder))
                row("Repo", f.repo ?? "none", made: proposal.made.contains(.repo))
                if !f.instructions.isEmpty { row("Instructions", f.instructions, lines: 2, made: proposal.made.contains(.instructions)) }
                foot
                if let waiting = Self.queuedLine(queued) {
                    Text(waiting).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1)
                }
            }
            .opacity(proposal.phase == .revising ? 0.55 : 1)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .flightPillGround()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.label(proposal))
        .motion(.fade, value: "\(proposal.fields)\(proposal.phase)\(proposal.reviseNote ?? "")")
    }

    // MARK: Parts

    private func head(_ f: RouterProjectFields) -> some View {
        HStack(spacing: 8) {
            mark.frame(width: 14, height: 14)
            Text(Self.title(proposal)).cdsText((13, 18), .regular, CDS.Text.primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let status = Self.status(proposal) {
                Text(status).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    .id(status).transition(.opacity)
            }
            Spacer(minLength: 0)
            switch proposal.phase {
            case .proposed:
                ClaudeButton("Create", primary: true, size: .sm, shortcut: ["↩"]) { proposal.confirm() }.fixedSize()
                ChipClose(label: "Drop the project") { onDrop() }
            case .revising:
                ChipClose(label: "Drop the project") { onDrop() }
            case .failed:
                ClaudeButton("Try again", primary: true, size: .sm, shortcut: ["↩"]) { proposal.confirm() }.fixedSize()
                ChipClose(label: "Drop the project") { onDrop() }
            case .waiting:
                ChipClose(label: "Drop the project") { onDrop() }
            case .creating, .created:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var mark: some View {
        switch proposal.phase {
        case .waiting: Image(systemName: "pause.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.warning)
        case .revising, .creating: FjordLoader(color: CDS.Text.secondary, label: Self.status(proposal) ?? "")
        case .created: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.Text.accent)
        case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.warning)
        case .proposed: Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .medium)).foregroundStyle(CDS.Text.accent)
        }
    }

    @ViewBuilder private var foot: some View {
        switch proposal.phase {
        case .failed(let cause), .waiting(let cause):
            Text(cause).cdsText((13, 18), .regular, CDS.Text.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 2)
        case .created:
            Text("Your message is on its way there.").cdsText((12, 16), .regular, CDS.Text.muted).padding(.top, 2)
        default:
            if let note = proposal.reviseNote {
                Text(note).cdsText((12, 16), .regular, CDS.Text.warning).lineLimit(2).padding(.top, 2)
            } else if proposal.nameFixed {
                Text("It's made: type to change only what isn't made yet.")
                    .cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).padding(.top, 2)
            } else {
                Text("Your message goes there once it's made. Type to change anything.")
                    .cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).padding(.top, 2)
            }
        }
    }

    private func row(_ label: String, _ value: String, lines: Int = 1, made: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).cdsText((12, 16), .regular, CDS.Text.muted).frame(width: 78, alignment: .leading)
            Text(value).cdsText((13, 18), .regular, value == "none" ? CDS.Text.muted : CDS.Text.secondary)
                .lineLimit(lines).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if made { Text("made").cdsText((12, 16), .regular, CDS.Text.muted).fixedSize() }
        }
    }

    // MARK: Words

    /// What the head says after the name.
    static func status(_ p: RouterProjectProposal) -> String? {
        switch p.phase {
        case .proposed: p.changed.isEmpty ? nil : "changed " + p.changed.joined(separator: ", ")
        case .revising: "revising…"
        case .creating(let what): what + "…"
        case .waiting: "waiting on claude.ai"
        case .created: "created"
        case .failed: "stopped"
        }
    }

    /// "New project “name”", or "Project “name”" once it is made (or may be): its name is fixed then.
    static func title(_ p: RouterProjectProposal) -> String {
        p.nameFixed ? "Project “\(p.fields.name)”" : "New project “\(p.fields.name)”"
    }

    /// The line under the proposal when others wait their turn.
    static func queuedLine(_ queued: Int) -> String? {
        queued == 0 ? nil : queued == 1 ? "1 more message waits for a new project after this one."
            : "\(queued) more messages wait for a new project after this one."
    }

    static func label(_ p: RouterProjectProposal) -> String {
        let f = p.fields
        return [title(p), status(p), "folder \(f.folder ?? "none")", "repo \(f.repo ?? "none")", f.instructions.isEmpty ? nil : f.instructions]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// A path as the owner reads it: the home folder as ~.
    static func shown(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
