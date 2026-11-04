import Foundation

/// The location chosen for future sessions in one Router project.
enum ProjectPlacement: Codable, Equatable, Hashable, Sendable {
    case thisMac(path: String)
    case computer(deviceId: String?, computerId: String, guestPath: String)

    var location: SessionLocation {
        switch self {
        case .thisMac: .thisMac
        case .computer(let deviceId, let computerId, _): .computer(deviceId: deviceId, computerId: computerId)
        }
    }

    var root: String {
        switch self {
        case .thisMac(let path): path
        case .computer(_, _, let guestPath): guestPath
        }
    }
}

/// Execution location is distinct from a display folder or a Desktop session id.
enum SessionLocation: Codable, Equatable, Hashable, Sendable {
    case thisMac
    case computer(deviceId: String?, computerId: String)

    var key: String {
        switch self {
        case .thisMac: "local"
        case .computer(let deviceId, let computerId): "\(deviceId ?? "local")/\(computerId)"
        }
    }
}

struct RunsOnProject: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Existing folder key used to resolve Router's local project row. It never identifies a guest session.
    var sourceFolder: String
    var placement: ProjectPlacement

    init(id: UUID = UUID(), name: String, sourceFolder: String, placement: ProjectPlacement) {
        self.id = id
        self.name = name
        self.sourceFolder = sourceFolder
        self.placement = placement
    }
}

struct PendingDesktopStart: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable { case readyInClaude, matched }

    var id: UUID
    var projectID: UUID
    var location: SessionLocation
    var alias: String
    var folder: String
    var prompt: String
    var openedAt: Date
    var state: State
    var desktopSessionID: String?
    var guestSessionID: String?

    init(id: UUID = UUID(), projectID: UUID, location: SessionLocation, alias: String, folder: String,
         prompt: String, openedAt: Date = Date(), state: State = .readyInClaude,
         desktopSessionID: String? = nil, guestSessionID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.location = location
        self.alias = alias
        self.folder = folder
        self.prompt = prompt
        self.openedAt = openedAt
        self.state = state
        self.desktopSessionID = desktopSessionID
        self.guestSessionID = guestSessionID
    }
}

enum GuestFolderPath {
    /// Guest roots are passed to SSH unchanged. No host normalization, expansion, realpath, or existence check applies.
    static func validate(_ path: String) throws -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.absolutePathRequired }
        return path
    }

    enum Failure: LocalizedError, Equatable {
        case absolutePathRequired
        var errorDescription: String? { "Enter an absolute folder path in the computer." }
    }
}

extension Store {
    /// The controller folder is an input to the Runs on picker; the matched session's actual guest folder remains in its
    /// PendingDesktopStart. Use this identity only when relating a session back to a tagged Router project.
    func routerProjectFolder(sessionID: String, fallback: String? = nil) -> String {
        if let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == sessionID && $0.state == .matched }),
           let project = router.runsOnProjects.first(where: { $0.id == start.projectID }) {
            return project.sourceFolder
        }
        return fallback ?? claudeSessions[sessionID]?.folderKey ?? ""
    }

    func routerSessionMatchesProject(_ sessionID: String, folder: String) -> Bool {
        routerProjectFolder(sessionID: sessionID) == folder
    }

    func routerCardMatchesProject(_ card: RouterCard, folder: String) -> Bool {
        routerProjectFolder(sessionID: card.sessionID, fallback: card.folder) == folder
    }
}
