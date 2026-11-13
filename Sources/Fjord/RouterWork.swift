import Foundation

/// What a working thread is doing, in two registers (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6 "Working"):
/// - **Summaries.** Short lines the Router's model writes about the run ("Filtering T3's own messages out of queued rows;
///   tests next"). The newest is the line's sentence; the card lists them newest first, each with its clock time. The
///   model writes one when the agent writes something new or its to-do step changes, at most about once a minute.
/// - **The raw detail.** The command or tool running now and the last few that ran, as T3 has them: the working peek's.
///
/// The demo fills it (`RouterDemo.work(at:)`); the real summaries aren't wired yet, and a thread without any keeps the
/// code's line (the running step, the agent's words, the command).
struct RouterWork: Equatable {
    struct Summary: Equatable, Identifiable {
        var id: Int
        var text: String
        /// When the model wrote it.
        var at: Date
    }

    /// One tool call or command: its words (a command in mono) and when it started.
    struct Step: Equatable, Identifiable {
        var id: Int
        var text: String
        var mono = false
        var at: Date
    }

    /// Newest first.
    var summaries: [Summary] = []
    /// The command or tool running now.
    var now: Step?
    /// The ones that ran before it, newest first: a few.
    var recent: [Step] = []

    var isEmpty: Bool { summaries.isEmpty && now == nil && recent.isEmpty }
    /// The raw detail the peek lists: the running step and the ones before it.
    var hasSteps: Bool { now != nil || !recent.isEmpty }
}
