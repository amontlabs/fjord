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
    /// The run working now: its summaries are the current ones; an earlier run's are listed under what started it.
    var run: String?
    /// What started each run, by its id (`RouterDetail.starts`, from the run's message as T3 marks it). A run missing
    /// here started from something not known: the card shows nothing for it.
    var starts: [String: Start] = [:]
    /// A shot's or the demo's pose for the card's timeline (`RouterWorkTimeline`): nil in the app.
    var pose: Pose?

    /// What started a run, from T3's fields on its message, never from its words (docs/design/router-v2/DESIGN.md R6).
    enum Start: Equatable, Codable {
        /// Your message (`createdBy: "user"`, from T3, the phone or Fjord): the card quotes it under the run's summaries.
        case asked(String)
        /// Delegated tasks or subagents ended (`delegatedCompletion`, a `subagent` notification): their titles, as T3
        /// has them on the subagents; empty when it doesn't name them.
        case subagents([String])
        /// A command left running in the background ended (a `command` notification): the command, when T3 names it.
        case command(String?)
        /// T3 sent "continue" itself once the usage limit reset (`UsageLimitRecoveryWorker`'s `limit-resume:` message).
        case usageLimit
        /// T3 woke the agent another way (a monitor, a restart, a pull request it watches, the provider's own wake).
        case woken
    }

    /// Where the card's timeline is held for a shot or the demo: scrolled so `scrolledTo` (a summary's id) is at its top,
    /// with the newest `newer` summaries held back behind the new pill; `toTop` bumped: the pill pressed.
    struct Pose: Equatable {
        var scrolledTo: Int?
        var newer = 0
        var toTop = 0
    }

    /// Summaries of the run working now (a restarted thread's earlier runs aren't its current step).
    var current: Bool { summaries.first.map { $0.run == run } ?? false }

    var isEmpty: Bool { summaries.isEmpty && now == nil && recent.isEmpty }
    /// The raw detail the peek lists: the running step and the ones before it.
    var hasSteps: Bool { now != nil || !recent.isEmpty }
}
