import Foundation

/// What a working thread is doing, in two registers (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6 "Working"):
/// - **Summaries.** Short lines the Router's model writes about the run ("Filtering T3's own messages out of queued rows;
///   tests next"). The newest is the line's sentence; the card lists them newest first, each with its clock time. The
///   model writes one when the agent writes something new or its to-do step changes, at most about once a minute.
/// - **The raw detail.** The command or tool running now and the last few that ran, as T3 has them: the working peek's.
///
/// The records fill it: the summaries from the verdict file (`RouterRecords.summary`), the raw detail from the thread's live
/// projection (`RouterDetail`). A thread with no summary of its run yet keeps the code's line (the running step, the
/// agent's words, the command). The demo's are `RouterDemo.work(at:)`.
struct RouterWork: Equatable {
    struct Summary: Equatable, Identifiable, Codable {
        var id: Int
        var text: String
        /// When the model wrote it.
        var at: Date
        /// The run it is about: the line reads only its own run's.
        var run: String?
        /// What it was written from (`RouterRecords.summaryPrint`): the same facts aren't summed up twice.
        var print: String?
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
    /// The line reads the newest summary now (not one streaming in, nor the code's words): the card lists the ones
    /// before it. A flag, not the sentence, so the card doesn't redraw as words stream.
    var lineReadsNewest = false
    /// The command or tool running now.
    var now: Step?
    /// The ones that ran before it, newest first: a few.
    var recent: [Step] = []
    /// The run working now: its summaries are the current ones; an earlier run's are listed after a quiet break.
    var run: String?

    /// Summaries of the run working now (a restarted thread's earlier runs aren't its current step).
    var current: Bool { summaries.first.map { $0.run == run } ?? false }

    var isEmpty: Bool { summaries.isEmpty && now == nil && recent.isEmpty }
    /// The raw detail the peek lists: the running step and the ones before it.
    var hasSteps: Bool { now != nil || !recent.isEmpty }
}
