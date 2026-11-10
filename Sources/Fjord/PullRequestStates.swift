import Foundation

/// Where a pull request stands on GitHub. Merged and closed are final.
enum PRState: String, Codable, Sendable, Hashable {
    case open, merged, closed, unknown

    var isFinal: Bool { self == .merged || self == .closed }
}

/// A pull request, named by its repository and number (not by the spelling of the URL it was found in).
struct PullRequestRef: Hashable, Sendable, Codable {
    let owner: String
    let repo: String
    let number: Int

    var url: URL { URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")! }
    var apiPath: String { "/repos/\(owner)/\(repo)/pulls/\(number)" }

    /// Every pull request URL in `text` (`https://github.com/owner/repo/pull/N`), once each, in order of appearance. A trailing
    /// punctuation mark, `/files`, `#issuecomment-…` or `?query` does not matter. Owners and repos compare case-insensitively.
    static func extract(from text: String) -> [PullRequestRef] {
        var seen = Set<PullRequestRef>()
        var out: [PullRequestRef] = []
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let o = Range(m.range(at: 1), in: text), let r = Range(m.range(at: 2), in: text),
                  let n = Range(m.range(at: 3), in: text), let number = Int(text[n]), number > 0 else { continue }
            let ref = PullRequestRef(owner: String(text[o]).lowercased(), repo: String(text[r]).lowercased(), number: number)
            if seen.insert(ref).inserted { out.append(ref) }
        }
        return out
    }

    // The number ends at the first non-digit; the host must not be a longer one (`notgithub.com`) or a subdomain.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.-])github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)/pull/([0-9]+)(?![0-9A-Za-z_])"#,
        options: [.caseInsensitive])
}

/// `GET /repos/o/r/pulls/N`, as far as the state needs it.
struct GHPullState: Decodable {
    let state: String
    let merged: Bool?
    let mergedAt: Date?

    var prState: PRState {
        if merged == true || mergedAt != nil { return .merged }
        switch state {
        case "open": return .open
        case "closed": return .closed
        default: return .unknown
        }
    }
}

extension GitHubClient {
    /// The pull request's state. The client's ETags make an unchanged one a 304, which costs no quota.
    func pullRequestState(_ ref: PullRequestRef) async throws -> PRState {
        try await get(ref.apiPath, as: GHPullState.self).prState
    }
}

/// Remembers pull request states and refreshes them on request. No timers: whoever builds a board asks. A merged or closed
/// pull request is never fetched again; an open or unknown one is, at most once per `minInterval`. Concurrent asks for the
/// same pull request share one fetch.
actor PullRequestStates {
    typealias Fetch = @Sendable (PullRequestRef) async throws -> PRState

    private let fetch: Fetch
    private let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var onChange: (@Sendable ([PullRequestRef: PRState]) -> Void)?
    private var known: [PullRequestRef: PRState] = [:]
    private var checkedAt: [PullRequestRef: Date] = [:]
    private var inFlight: [PullRequestRef: Task<Void, Never>] = [:]

    /// `onChange` gets the pull requests whose state is new or different after a refresh (first sightings included).
    init(minInterval: TimeInterval = 30,
         now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping Fetch,
         onChange: (@Sendable ([PullRequestRef: PRState]) -> Void)? = nil) {
        self.minInterval = minInterval
        self.now = now
        self.fetch = fetch
        self.onChange = onChange
    }

    /// Backed by GitHub through `client`.
    init(client: GitHubClient, minInterval: TimeInterval = 30,
         onChange: (@Sendable ([PullRequestRef: PRState]) -> Void)? = nil) {
        self.init(minInterval: minInterval, fetch: { try await client.pullRequestState($0) }, onChange: onChange)
    }

    func setOnChange(_ handler: (@Sendable ([PullRequestRef: PRState]) -> Void)?) { onChange = handler }

    /// What is known now (`.unknown` for a pull request not seen yet), at once. Starts a background refresh of the ones
    /// that are not final and due; the result arrives through `onChange`.
    func states(for refs: [PullRequestRef]) -> [PullRequestRef: PRState] {
        let due = refs.filter(isDue)
        if !due.isEmpty { Task { await self.refresh(due) } }
        return Dictionary(refs.map { ($0, known[$0] ?? .unknown) }, uniquingKeysWith: { a, _ in a })
    }

    /// Fetches what is due and waits for it (and for fetches already running for the same pull requests). Failed fetches keep
    /// the previous state.
    @discardableResult
    func refresh(_ refs: [PullRequestRef]) async -> [PullRequestRef: PRState] {
        var tasks: [Task<Void, Never>] = []
        for ref in Set(refs) {
            if let running = inFlight[ref] { tasks.append(running); continue }
            guard isDue(ref) else { continue }
            let fetch = self.fetch
            let task = Task { [weak self] in
                let result = try? await fetch(ref)
                await self?.finish(ref, result)
            }
            inFlight[ref] = task
            tasks.append(task)
        }
        for task in tasks { await task.value }
        return Dictionary(refs.map { ($0, known[$0] ?? .unknown) }, uniquingKeysWith: { a, _ in a })
    }

    private func isDue(_ ref: PullRequestRef) -> Bool {
        if inFlight[ref] != nil { return false }
        if known[ref]?.isFinal == true { return false }
        if let last = checkedAt[ref], now().timeIntervalSince(last) < minInterval { return false }
        return true
    }

    private func finish(_ ref: PullRequestRef, _ result: PRState?) {
        inFlight[ref] = nil
        checkedAt[ref] = now()
        guard let result else { return }
        let before = known[ref]
        known[ref] = result
        if before != result { onChange?([ref: result]) }
    }
}
