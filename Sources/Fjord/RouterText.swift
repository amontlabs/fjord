import SwiftUI

// Words and times as the Router draws them: a thread's inline Markdown, a plan, an age, and content redrawn on the minute.

/// Content redrawn on the minute and only then (ages, the status line): nothing else ticks for it.
struct MinuteTicking<Content: View>: View {
    /// Out of sight: it stops on the minute it was at, and catches up once shown.
    var paused = false
    @ViewBuilder let content: (Date) -> Content

    init(paused: Bool = false, @ViewBuilder content: @escaping (Date) -> Content) {
        self.paused = paused
        self.content = content
    }

    var body: some View {
        TimelineView(Minutes(paused: paused)) { context in content(context.date) }
    }
}

/// Every minute on the minute, as `.everyMinute`; paused, only the moment it started.
private struct Minutes: TimelineSchedule {
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let paused: Bool

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            if paused {
                upcoming = nil
            } else {
                let minute = (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
                upcoming = Date(timeIntervalSinceReferenceDate: minute + 60)
            }
            return date
        }
    }
}

/// A thread's words or a plan: inline Markdown (**bold**, `code`) as the sessions show it.
enum RouterText {
    /// Parsed once per text: the brief asks again on every redraw. Up to 1000 texts, 4 MB of them.
    private static let parsed = RenderCache<AttributedString>(countLimit: 1000, totalCostLimit: 4 << 20)

    static func inline(_ text: String) -> AttributedString {
        parsed.value(text, cost: text.utf8.count) {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }

    /// A plan's Markdown, line by line as written: headings in bold without their #, the rest with its inline styles.
    static func plan(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, raw) in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            if i > 0 { out += AttributedString("\n") }
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                var heading = inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                heading.inlinePresentationIntent = .stronglyEmphasized
                out += heading
            } else {
                out += inline(line)
            }
        }
        return out
    }
}

enum BriefAge {
    /// "now", "4m", "2h", "3d": a line's time where room is short.
    static func short(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    static func text(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }
}
