import Foundation
import SwiftUI

// Items for the palette's shots (`palette-fixture`): one of every icon, dot, subtitle and date the rows can have, so the
// look can be read whatever the sources hold. Not shipped data: only `--window-shots` makes them.

@MainActor
enum PaletteFixture {
    /// Every combination the rows draw, newest first, and a ranker that finds the query in titles (with the ranges to
    /// highlight) so the rows show their highlight without the matcher.
    static func sources(_ store: Store) -> PaletteSources {
        let now = Date()
        func action(_ title: String, _ caps: [String] = [], destructive: Bool = false) -> PaletteAction {
            PaletteAction(id: title, title: title, symbol: destructive ? "archivebox" : "arrow.up.right", caps: caps,
                          destructive: destructive, run: {})
        }
        let open = [action("Open", ["↩"]), action("Open on GitHub", ["⌘", "O"]), action("Copy link", ["⌘", "⇧", "C"]),
                    action("Archive", ["⌘", "⌫"], destructive: true)]
        func item(_ id: String, _ kind: PaletteItem.Kind, _ title: String, _ subtitle: String? = nil, icon: PaletteIcon,
                  dot: PaletteDot? = nil, age: TimeInterval? = nil) -> PaletteItem {
            PaletteItem(id: id, kind: kind, title: title, subtitle: subtitle, icon: icon, dot: dot,
                        date: age.map { now.addingTimeInterval(-$0) }, actions: open)
        }
        var items = [
            item("thread:p/1", .thread, "Which branch should the transfer land on?", "Question · transfer", icon: .symbol("questionmark.bubble"),
                 dot: .attention, age: 90),
            item("thread:p/2", .thread, "Plan: split the ownership migration in two", "Plan · lookout", icon: .symbol("list.bullet.rectangle"),
                 dot: .attention, age: 20 * 60),
            item("entry:1", .entry, "Fix flaky reconnect test", "fjord#482", icon: .symbol("arrow.triangle.pull"), dot: .attention,
                 age: 3 * 3600),
            item("entry:2", .entry, "Bump the Silo client to the current schema", "silo#17", icon: .symbol("exclamationmark.circle"),
                 age: 26 * 3600),
            item("entry:3", .entry, "CI: Release workflow failed on main", "fjord · Release", icon: .symbol("xmark.octagon"),
                 dot: .attention, age: 3 * 86_400),
            item("project:1", .project, "lookout", "~/code/projects/lookout", icon: .symbol("folder.fill", tint: .orange),
                 age: 12 * 86_400),
            item("category:1", .category, "Reviews requested", "Inbox category", icon: .symbol("eye", tint: CDS.Text.accent)),
            item("page:router", .page, "Router", icon: .symbol("sparkles")),
            item("page:archive", .page, "Archive", "Page", icon: .symbol("archivebox")),
            item("setting:notifications.desktop", .setting, "Desktop notifications", "Settings · Notifications",
                 icon: .symbol("gearshape")),
            item("command:refresh", .command, "Refresh now", "Command", icon: .symbol("arrow.clockwise")),
            item("snippet:1", .snippet, "Explain this failure and propose the smallest fix", "Snippet", icon: .symbol("text.quote"),
                 age: 400 * 86_400),
            item("entry:long", .entry, "A very long pull request title that goes on and on until it cannot fit on a single line of the palette at all",
                 "owner/repo#12345", icon: .symbol("arrow.triangle.pull"), age: 40 * 86_400),
        ]
        for (n, row) in store.allAgentRows.prefix(3).enumerated() {
            items.insert(item("session:\(row.id)", .session, row.session.title, row.projectName, icon: .session(row.id),
                              dot: n == 0 ? .running : (n == 1 ? .attention : nil), age: Double(n + 1) * 600), at: 2)
        }
        let send = PaletteItem(id: "send", kind: .send, title: "Send to the Router", subtitle: nil, icon: .symbol("paperplane"),
                               actions: [action("Send", ["↩"])])
        var sources = PaletteSources.fixed(items, needsYou: Array(items.prefix(5)), send: send)
        sources.rank = { query, index, limit in
            let q = query.lowercased()
            return index.items.compactMap { item -> PaletteHit? in
                guard let range = item.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
                return PaletteHit(item: item, ranges: [range])
            }.prefix(limit).map { $0 }
        }
        return sources
    }
}
