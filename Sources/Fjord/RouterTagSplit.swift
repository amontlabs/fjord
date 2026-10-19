import Foundation

// Where the tags of a message cut it, with no model (docs/design/spec/router.md, "Several places"). A tag addresses when it
// opens a line or a sentence (structure only: no word is ever read to decide it); the words up to the next addressing tag
// are its place's; tags side by side share them; the text no tag addresses is the armed reply's (or the pinned target's);
// items ⌘-clicked on the Brief each get the whole message. A sentence after the first of a tag's words is for Jev to check
// (is it for the tag's place?), by `Segment.check`; the cuts are byte-preserving offsets into the message, so what is
// assembled is always the user's own bytes.

enum RouterTagSplit {
    /// A pill that is a place: where its "@name" is (character offsets), and `session:<id>` or `project:<folder>`.
    struct Tag: Equatable {
        var range: Range<Int>
        var target: String
    }

    /// The words one place gets, as ranges of the message. `keep`: the tag (or the side-by-side group of them) and the
    /// segment's first sentence, or the first sentence of the lead of the chip or pin. `check`: the later sentences, each
    /// for Jev to say whether it is for `target`, against `anchor` (the segment's first sentence, past its pills; for a lead
    /// with no chip or pin, the message from the first tag on). Side-by-side tags have a segment each, all with the same
    /// `keep` and `check`: a sentence is checked once, and kept for none of them or all of them.
    struct Segment: Equatable {
        var target: String
        var keep: [Range<Int>]
        var check: [Range<Int>]
        var anchor: String
    }

    enum Result: Equatable {
        /// Not a message the tags divide: today's path.
        case none
        /// Items ⌘-clicked on the Brief: each gets the whole message.
        case broadcast([String])
        /// The tags decide, in message order: `target` is `answer:<card>` or the pinned target for the text before the
        /// first tag, `session:<id>` or `project:<folder>` for a tag's.
        case segments([Segment])
        /// Tags that don't each open a sentence or a line: the divider decides, limited to exactly these places
        /// (`RouterDivider.Mode.tags`): the chip's or pin's session (`session:<id>`, whichever card it is armed on), a
        /// session pill's, `new:<folder>` for a project pill's.
        case divider(fixed: [String])
    }

    /// What the tags of `text` do. `mentions`: its pills. `replyCard`: the card an armed reply is on. `pinned`: the target
    /// pinned over the composer. `recipients`: the items ⌘-clicked on the Brief (their targets).
    ///
    /// The tags path is taken with two places or more (the chip's, else the pin's, plus the session pills of sessions still
    /// there and the distinct project pills), or with a session pill alone (no chip or pin); a lone project pill stays on
    /// today's path. A pill in code is never a tag, and one that sits inside a sentence ("ask @B about the build") is one of
    /// its words, unless it is the only place.
    @MainActor static func plan(_ text: String, mentions: [RouterMention], replyCard: String?, pinned: String?,
                                recipients: [String], store: Store) -> Result {
        if !recipients.isEmpty { return .broadcast(recipients) }
        let c = Array(text)
        let tags = tags(c, mentions, store)
        guard !tags.isEmpty else { return .none }
        let base = replyCard.flatMap { id in store.router.cards.contains { $0.id == id } ? "answer:\(id)" : nil } ?? pinned
        var places: [String] = []
        for target in ([base].compactMap { $0 } + tags.map(\.target)).map({ place($0, store) }) where !places.contains(target) {
            places.append(target)
        }
        guard places.count >= 2 || (base == nil && tags.contains { $0.target.hasPrefix("session:") }) else { return .none }

        var (addresses, follows) = addressing(c, tags, force: false)
        if places.count >= 2, addresses.contains(false) { return .divider(fixed: places) }
        // The only place, named inside its sentence: the first pill is the address.
        if !addresses.contains(true) { (addresses, follows) = addressing(c, tags, force: true) }

        let leaders = tags.indices.filter { addresses[$0] && !follows[$0] }
        var segments: [Segment] = []
        let first = tags[leaders[0]].range.lowerBound
        var lead = sentences(c, in: 0..<first, mentions: mentions).filter { !blank(c, $0) }
        // The only place, named inside its sentence ("ask @B about the build"): what comes before the pill in that sentence is
        // its words too, not a sentence of its own to check.
        var from = first
        if !startsSentence(c, at: first), let fragment = lead.last, fragment.upperBound == first {
            lead.removeLast()
            from = fragment.lowerBound
        }
        if !lead.isEmpty {
            if let base {
                // The chip's or the pin's: its first sentence is its words, a later one is checked against it.
                segments.append(Segment(target: base, keep: [lead[0]], check: Array(lead.dropFirst()), anchor: String(c[lead[0]])))
            } else {
                segments.append(Segment(target: tags[leaders[0]].target, keep: [], check: lead, anchor: String(c[first...])))
            }
        }
        for (n, leader) in leaders.enumerated() {
            var last = leader
            while last + 1 < tags.count, follows[last + 1] { last += 1 }
            let start = n == 0 ? from : tags[leader].range.lowerBound, group = tags[last].range.upperBound
            let end = n + 1 < leaders.count ? tags[leaders[n + 1]].range.lowerBound : c.count
            let own = sentences(c, in: group..<end, mentions: mentions).filter { !blank(c, $0) }
            // The tag's own words are its first sentence; a tag with none keeps just itself.
            var keep = [start..<(own.first?.upperBound ?? end)]
            // Tags side by side across a line break: `Addressing.withoutLeadingPills` stops at the break and would leave the
            // later pills in the words, so the group's pills and the blanks after them are left out of the words instead.
            if tags[leader...last].indices.dropLast().contains(where: { c[tags[$0].range.upperBound..<tags[$0 + 1].range.lowerBound].contains(where: \.isNewline) }) {
                var words = group
                while words < c.count, c[words].isWhitespace { words += 1 }
                let to = own.first?.upperBound ?? words
                keep = words < to ? [words..<to] : []
            }
            let check = Array(own.dropFirst())
            let anchor = own.first.map { String(c[$0]) } ?? ""
            for tag in tags[leader...last] {
                segments.append(Segment(target: tag.target, keep: keep, check: check, anchor: anchor))
            }
        }
        return .segments(segments)
    }

    // MARK: Tags

    /// The pills that are places: a session still there or a project, outside code, in message order. A pill inside
    /// another is not one.
    @MainActor private static func tags(_ c: [Character], _ mentions: [RouterMention], _ store: Store) -> [Tag] {
        let code = Addressing.codeMask(c)
        var out: [Tag] = []
        for m in mentions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard m.range.lowerBound >= 0, m.range.upperBound <= c.count, !m.range.isEmpty, !code[m.range.lowerBound],
                  out.last.map({ $0.range.upperBound <= m.range.lowerBound }) ?? true else { continue }
            switch m.pointer {
            case .session(let id) where store.claudeSessions[id].map({ !$0.isArchived }) == true:
                out.append(Tag(range: m.range, target: "session:\(id)"))
            case .project(let folder):
                out.append(Tag(range: m.range, target: "project:\(folder)"))
            default: continue
            }
        }
        return out
    }

    /// The place a target stands for, to tell places apart: a card's answer is its session's, a project pill is a new
    /// session in it (what `RouterDivider` fixes it as).
    @MainActor private static func place(_ target: String, _ store: Store) -> String {
        if target.hasPrefix("answer:") {
            let id = String(target.dropFirst(7))
            return store.router.cards.first { $0.id == id }.map { "session:\($0.sessionID)" } ?? target
        }
        if target.hasPrefix("project:") { return "new:" + target.dropFirst(8) }
        return target
    }

    // MARK: Addressing

    /// Which tags address, and which of them only follow another (side by side: only whitespace or commas between them),
    /// sharing its words. `force`: the first one addresses whatever it follows.
    private static func addressing(_ c: [Character], _ tags: [Tag], force: Bool) -> (addresses: [Bool], follows: [Bool]) {
        var addresses = [Bool](repeating: false, count: tags.count), follows = addresses
        for (i, tag) in tags.enumerated() {
            if i > 0, addresses[i - 1],
               c[tags[i - 1].range.upperBound..<max(tag.range.lowerBound, tags[i - 1].range.upperBound)]
                   .allSatisfy({ $0.isWhitespace || $0 == "," }) {
                follows[i] = true
            }
            addresses[i] = follows[i] || (force && i == 0) || startsSentence(c, at: tag.range.lowerBound)
        }
        return (addresses, follows)
    }

    /// Whether `i` opens a line or a sentence: nothing but blanks before it on the text, or the last thing before it ends a
    /// sentence or a clause (`.` `!` `?` `;` `:`), a line, or a dash (the benchmark's `_starts_sentence`).
    static func startsSentence(_ c: [Character], at i: Int) -> Bool {
        var j = min(i, c.count)
        while j > 0, c[j - 1] == " " || c[j - 1] == "\t" { j -= 1 }
        guard j > 0 else { return true }
        let last = c[j - 1]
        return ".!?;:".contains(last) || last.isNewline || "—–-".contains(last)
    }

    // MARK: Sentences

    /// `r` of `c` cut into sentences: after a run of `.` `!` `?` (and any closing quote or bracket) that is followed by a
    /// blank or the end, or after a run of line breaks, each with the blanks that follow it (not the next line's
    /// indentation). Never inside code (`Addressing.codeMask`) nor a pill, and never in a word ("file.txt", ".gitignore").
    /// The ranges are in order and touch: together they are exactly `r`, whatever it holds.
    static func sentences(_ c: [Character], in r: Range<Int>, mentions: [RouterMention] = []) -> [Range<Int>] {
        guard !r.isEmpty else { return [] }
        var blocked = Addressing.codeMask(c)
        for m in mentions where m.range.lowerBound >= 0 && m.range.upperBound <= c.count {
            for k in m.range { blocked[k] = true }
        }
        var out: [Range<Int>] = []
        var start = r.lowerBound, i = start
        // Ends the sentence at `end` (not on a run of blanks alone: that goes with the next words).
        func cut(_ end: Int) {
            if !c[start..<end].contains(where: { !$0.isWhitespace }) { i = end; return }
            out.append(start..<end)
            start = end
            i = end
        }
        while i < r.upperBound {
            let ch = c[i]
            if blocked[i] { i += 1; continue }
            if ".!?".contains(ch) {
                var j = i
                while j < r.upperBound, !blocked[j], ".!?".contains(c[j]) { j += 1 }
                while j < r.upperBound, !blocked[j], "\"')]”’»".contains(c[j]) { j += 1 }
                guard j == r.upperBound || (c[j].isWhitespace && !blocked[j]) else { i = j; continue }
                var k = j
                while k < r.upperBound, c[k].isWhitespace, !blocked[k] { k += 1 }
                // The blanks go with the sentence up to the last line break; past it, they are the next line's indentation.
                if let nl = c[j..<k].lastIndex(where: \.isNewline) { k = nl + 1 }
                cut(k)
            } else if ch.isNewline {
                var j = i
                while j < r.upperBound, c[j].isNewline { j += 1 }
                // A break between two code lines is code's own.
                if i > r.lowerBound, blocked[i - 1], j < r.upperBound, blocked[j] { i = j; continue }
                cut(j)
            } else {
                i += 1
            }
        }
        if start < r.upperBound {
            if !c[start..<r.upperBound].contains(where: { !$0.isWhitespace }), let last = out.popLast() {
                out.append(last.lowerBound..<r.upperBound)
            } else {
                out.append(start..<r.upperBound)
            }
        }
        return out
    }

    private static func blank(_ c: [Character], _ r: Range<Int>) -> Bool { !c[r].contains { !$0.isWhitespace } }

    // MARK: Assembling

    /// The words of a part: `slices` of `text` (its keep, and the checked sentences that were kept), joined in message
    /// order (a range covered by an earlier one is left out), with `RouterModel.sendable`'s trim, and the pills among them
    /// moved to where they now stand: `mentions` whole inside a slice, and `pills`, the addresses among them
    /// (`RouterContext.pills`).
    static func assemble(_ text: String, _ slices: [Range<Int>], mentions: [RouterMention])
        -> (text: String, mentions: [RouterMention], pills: [Range<Int>]) {
        let c = Array(text)
        var out: [Character] = []
        var placed: [(from: Range<Int>, at: Int)] = []
        var covered = 0
        for r in slices.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let from = max(r.lowerBound, covered), to = min(r.upperBound, c.count)
            guard from < to else { continue }
            // A slice that touches the last one goes on from it, so a pill across the two is whole.
            if let last = placed.last, last.from.upperBound == from {
                placed[placed.count - 1].from = last.from.lowerBound..<to
            } else {
                placed.append((from..<to, out.count))
            }
            out += c[from..<to]
            covered = to
        }
        let (sent, lead) = RouterModel.sendableCut(String(out))
        let count = sent.count
        var moved: [RouterMention] = []
        for m in mentions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard let p = placed.first(where: { $0.from.lowerBound <= m.range.lowerBound && m.range.upperBound <= $0.from.upperBound })
            else { continue }
            let shift = p.at - p.from.lowerBound - lead
            let range = (m.range.lowerBound + shift)..<(m.range.upperBound + shift)
            guard range.lowerBound >= 0, range.upperBound <= count else { continue }
            moved.append(RouterMention(range: range, pointer: m.pointer, name: m.name))
        }
        return (sent, moved, moved.filter(\.pointer.addresses).map(\.range))
    }
}
