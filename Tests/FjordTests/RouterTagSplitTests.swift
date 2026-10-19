import Foundation
import Testing
@testable import Fjord

/// What the tags of a message do to it, with no model (docs/design/spec/router.md, "Several places"): a tag addresses when it
/// opens a line or a sentence, side-by-side tags share their words, an armed reply takes the text no tag addresses, and the
/// cuts are the user's own bytes.
@MainActor
@Suite(.serialized) struct RouterTagSplitting {
    typealias S = RouterTagSplit

    private enum Piece {
        case words(String)
        case pill(RouterPointer, String)
    }

    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.claudeSessions = [
            "ci": ClaudeSession(id: "ci", title: "CI", folder: "/code/ci", lastActivity: Date(), running: true),
            "docs": ClaudeSession(id: "docs", title: "Docs", folder: "/code/docs", lastActivity: Date(), running: true),
            "old": ClaudeSession(id: "old", title: "Old", folder: "/code/old", lastActivity: Date(), running: false),
        ]
        s.claudeSessions["old"]?.isArchived = true
        s.router.cards = [RouterCard(id: "ci#1", sessionID: "ci", kind: .question, title: "CI", folder: "/code/ci",
                                     text: "Which version?", createdAt: Date())]
        return s
    }

    /// The message the composer would send: words with each pill written as "@name", and where each stands.
    private func message(_ pieces: [Piece]) -> (text: String, mentions: [RouterMention]) {
        var text = ""
        var mentions: [RouterMention] = []
        for piece in pieces {
            switch piece {
            case .words(let w): text += w
            case .pill(let pointer, let name):
                let start = text.count
                text += "@" + name
                mentions.append(RouterMention(range: start..<text.count, pointer: pointer, name: name))
            }
        }
        return (text, mentions)
    }

    private func ci(_ n: String = "CI") -> Piece { .pill(.session("ci"), n) }
    private func docs(_ n: String = "Docs") -> Piece { .pill(.session("docs"), n) }

    private func plan(_ pieces: [Piece], reply: String? = nil, pinned: String? = nil, recipients: [String] = [],
                      in s: Store? = nil) -> (S.Result, String, [RouterMention]) {
        let (text, mentions) = message(pieces)
        return (S.plan(text, mentions: mentions, replyCard: reply, pinned: pinned, recipients: recipients, store: s ?? store()),
                text, mentions)
    }

    /// `ranges` of `text`, as words.
    private func said(_ text: String, _ ranges: [Range<Int>]) -> String {
        let c = Array(text)
        return ranges.map { String(c[$0]) }.joined()
    }

    private func segments(_ r: S.Result) -> [S.Segment] {
        if case .segments(let s) = r { return s }
        Issue.record("not segments: \(r)")
        return []
    }

    // MARK: Segments

    @Test func twoTagsThatOpenSentencesAreTwoSegments() {
        let (r, text, _) = plan([ci(), .words(" fix it. "), docs(), .words(" add the page")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:ci", "session:docs"])
        #expect(said(text, s[0].keep) == "@CI fix it. " && s[0].check.isEmpty)
        #expect(said(text, s[1].keep) == "@Docs add the page" && s[1].check.isEmpty)
    }

    @Test func tagsOnTheirOwnLinesAreAddresses() {
        let (r, text, _) = plan([ci(), .words(" fix it\n"), docs(), .words(" add the page")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:ci", "session:docs"])
        #expect(said(text, s[0].keep) == "@CI fix it\n")
    }

    @Test func whatNoTagAddressesIsTheArmedReplys() {
        let (r, text, _) = plan([.words("yes. "), docs(), .words(" add the page")], reply: "ci#1")
        let s = segments(r)
        #expect(s.map(\.target) == ["answer:ci#1", "session:docs"])
        #expect(said(text, s[0].keep) == "yes. " && s[0].check.isEmpty)
        #expect(said(text, s[1].keep) == "@Docs add the page")
    }

    @Test func aPinnedTargetTakesTheLeadAsTheChipWould() {
        let (r, text, _) = plan([.words("check the logs. "), docs(), .words(" add the page")], pinned: "new:/code/lookout")
        let s = segments(r)
        #expect(s.map(\.target) == ["new:/code/lookout", "session:docs"])
        #expect(said(text, s[0].keep) == "check the logs. ")
    }

    @Test func sideBySideTagsShareTheirWords() {
        let (r, text, mentions) = plan([ci(), .words(" "), docs(), .words(" pull main")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:ci", "session:docs"])
        #expect(s[0].keep == s[1].keep && s[0].check == s[1].check)
        for segment in s {
            let part = S.assemble(text, segment.keep, mentions: mentions)
            #expect(part.text == "@CI @Docs pull main" && part.pills == [0..<3, 4..<9])
            #expect(Addressing.withoutLeadingPills(part.text, part.pills) == "pull main")
        }
        // Commas between them are the same.
        let (r2, text2, _) = plan([ci(), .words(", "), docs(), .words(": pull main")])
        #expect(segments(r2).count == 2 && said(text2, segments(r2)[1].keep) == "@CI, @Docs: pull main")
    }

    @Test func sideBySideTagsAcrossALineBreakShareWordsWithNoPillsLeftInThem() {
        // The addressing edit stops at a line break, so the group's pills are left out of the words rather than half-stripped.
        let (r, text, mentions) = plan([ci(), .words("\n"), docs(), .words(" pull main. Then rest.")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:ci", "session:docs"] && s[0].keep == s[1].keep && s[0].check == s[1].check)
        for segment in s {
            let part = S.assemble(text, segment.keep, mentions: mentions)
            #expect(part.text == "pull main." && part.pills.isEmpty && part.mentions.isEmpty)
            #expect(Addressing.withoutLeadingPills(part.text, part.pills) == nil)
        }
        // A group with nothing after it has no words.
        let (r2, text2, mentions2) = plan([ci(), .words("\n"), docs()])
        #expect(segments(r2).allSatisfy { S.assemble(text2, $0.keep, mentions: mentions2).text.isEmpty })
    }

    @Test func aLaterSentenceIsForJevToCheckAgainstTheFirst() {
        let (r, text, _) = plan([ci(), .words(" rerun the build. Mute notifications for an hour. And be quick.")])
        let s = segments(r)
        #expect(s.count == 1 && s[0].target == "session:ci")
        #expect(said(text, s[0].keep) == "@CI rerun the build. ")
        #expect(said(text, s[0].check) == "Mute notifications for an hour. And be quick.")
        #expect(s[0].check.map { said(text, [$0]) } == ["Mute notifications for an hour. ", "And be quick."])
        #expect(s[0].anchor == " rerun the build. ")
    }

    @Test func aLoneSessionPillInsideASentenceHasALeadToCheck() {
        let (r, text, _) = plan([.words("ask "), docs(), .words(" about the build")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:docs", "session:docs"])
        #expect(s[0].keep.isEmpty && said(text, s[0].check) == "ask " && s[0].anchor == "@Docs about the build")
        #expect(said(text, s[1].keep) == "@Docs about the build")
    }

    @Test func theLeadBeforeTheFirstTagIsCheckedAgainstItWhenNothingIsArmed() {
        let (r, text, _) = plan([.words("The build is red. "), ci(), .words(" rerun it. "), docs(), .words(" add the page")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:ci", "session:ci", "session:docs"])
        #expect(s[0].keep.isEmpty && said(text, s[0].check) == "The build is red. ")
        #expect(s[0].anchor == "@CI rerun it. @Docs add the page")
    }

    @Test func aProjectPillIsATagWithAChipOrAnotherPlace() {
        let (r, text, _) = plan([.words("yes. "), .pill(.project("/code/lookout"), "lookout"), .words(" add the page")], reply: "ci#1")
        let s = segments(r)
        #expect(s.map(\.target) == ["answer:ci#1", "project:/code/lookout"])
        #expect(said(text, s[1].keep) == "@lookout add the page")
        let (r2, _, _) = plan([ci(), .words(" fix it. "), .pill(.project("/code/lookout"), "lookout"), .words(" start on it")])
        #expect(segments(r2).map(\.target) == ["session:ci", "project:/code/lookout"])
    }

    // MARK: The divider

    @Test func tagsThatDontEachOpenASentenceGoToTheDivider() {
        let (r, _, _) = plan([.words("tell "), ci(), .words(" or "), docs(), .words(" to rebase")])
        #expect(r == .divider(fixed: ["session:ci", "session:docs"]))
        let (r2, _, _) = plan([ci(), .words(" and "), docs(), .words(": rerun, and add the page")])
        #expect(r2 == .divider(fixed: ["session:ci", "session:docs"]))
    }

    @Test func theDividerIsLimitedToTheChipsAndThePillsPlaces() {
        // The chip's session, whichever of its cards the reply is on, a session pill, a project pill as a new session.
        let (r, _, _) = plan([.words("yes, and ask "), docs(), .words(" about it, then "), .pill(.project("/code/lookout"), "lookout"),
                              .words(" too")], reply: "ci#1")
        #expect(r == .divider(fixed: ["session:ci", "session:docs", "new:/code/lookout"]))
        let (r2, _, _) = plan([.words("then "), docs(), .words(" too")], pinned: "change_fjord")
        #expect(r2 == .divider(fixed: ["change_fjord", "session:docs"]))
    }

    // MARK: What isn't the tags path

    @Test func aLoneProjectPillStaysOnTodaysPath() {
        let (r, _, _) = plan([.pill(.project("/code/lookout"), "lookout"), .words(" fix the build")])
        #expect(r == .none)
        let (r2, _, _) = plan([.pill(.project("/code/lookout"), "lookout"), .words(" and "), .pill(.project("/code/lookout"), "lookout")])
        #expect(r2 == .none)
        let (r3, _, _) = plan([.pill(.project("/code/lookout"), "lookout"), .words(" fix it")], pinned: "new:/code/lookout")
        #expect(r3 == .none)
    }

    @Test func noTagsOrOnlyThePlacesOfTheChipIsNotTheTagsPath() {
        #expect(plan([.words("yes please")], reply: "ci#1").0 == .none)
        #expect(plan([.words("yes. "), ci(), .words(" go on")], reply: "ci#1").0 == .none)
        #expect(plan([.words("fix it"), .pill(.notification("pr:a/b#1"), "a/b#1")], pinned: "session:ci").0 == .none)
        #expect(plan([.words("fix it")], pinned: "session:ci").0 == .none)
    }

    @Test func aPillOfAnArchivedSessionIsNotATag() {
        let (r, _, _) = plan([.pill(.session("old"), "Old"), .words(" fix it. "), docs(), .words(" add the page")])
        // Its words are the lead, for Jev to check against the one tag there is.
        let s = segments(r)
        #expect(s.map(\.target) == ["session:docs", "session:docs"] && s[0].keep.isEmpty && s[0].check.count == 1)
        #expect(plan([.pill(.session("old"), "Old"), .words(" fix it")]).0 == .none)
    }

    @Test func aPillInCodeIsNotATag() {
        let fenced = plan([.words("```\n"), ci(), .words("\n```\nfix it")]).0
        #expect(fenced == .none)
        let (r, text, _) = plan([docs(), .words(" add the page\n```\n"), ci(), .words("\n```\nthen stop")])
        let s = segments(r)
        #expect(s.map(\.target) == ["session:docs"])
        #expect(s[0].check.map { said(text, [$0]) } == ["```\n@CI\n```\n", "then stop"])
        #expect(plan([.words("run `"), ci(), .words("` now")]).0 == .none)
    }

    @Test func recipientsGetTheWholeMessage() {
        let (r, _, _) = plan([ci(), .words(" fix it. "), docs(), .words(" add the page")], recipients: ["session:a", "answer:b"])
        #expect(r == .broadcast(["session:a", "answer:b"]))
        #expect(plan([.words("hello")], recipients: ["session:a"]).0 == .broadcast(["session:a"]))
    }

    // MARK: Sentences

    private func cuts(_ text: String) -> [String] {
        let c = Array(text)
        return S.sentences(c, in: 0..<c.count).map { String(c[$0]) }
    }

    @Test func sentencesKeepEveryByte() {
        let inputs = [
            ".gitignore", "...\n", "...", "", "   ", "\n\n", "a. b! c? d", "Done...  Next", "see file.txt. ok", "v1.2 is out. now",
            "He said \"done.\" Then left.", "a.\n```\nx. y\n\nz\n```\nb. c", "one\ntwo\n\n  three\n", "trailing   \n  ",
            "a?!. b", "ends with dot.", "line\r\nnext line. more",
        ]
        for input in inputs {
            #expect(cuts(input).joined() == input, "\(input.debugDescription)")
        }
    }

    @Test func sentencesCutAfterStopsAndLineBreaksOnly() {
        #expect(cuts("Fix it. Then ship!  Why?\nBecause.") == ["Fix it. ", "Then ship!  ", "Why?\n", "Because."])
        #expect(cuts(".gitignore is wrong") == [".gitignore is wrong"])
        #expect(cuts("update file.txt and v1.2") == ["update file.txt and v1.2"])
        #expect(cuts("Wait... what\n\nok") == ["Wait... ", "what\n\n", "ok"])
        #expect(cuts("He said \"done.\" Then left") == ["He said \"done.\" ", "Then left"])
        // The next line's indentation is the next sentence's.
        #expect(cuts("a.\n  b") == ["a.\n", "  b"])
        #expect(cuts("   ") == ["   "])
    }

    @Test func sentencesNeverCutInsideCodeOrAPill() {
        #expect(cuts("run `a. b` now. Then stop") == ["run `a. b` now. ", "Then stop"])
        #expect(cuts("x.\n```\nfoo. bar\n\nbaz.\n```\ny. z") == ["x.\n", "```\nfoo. bar\n\nbaz.\n```\n", "y. ", "z"])
        let c = Array("ask @Fix. the bug now. Then go")
        let pill = RouterMention(range: 4..<13, pointer: .session("ci"), name: "Fix. the bug")
        #expect(S.sentences(c, in: 0..<c.count, mentions: [pill]).map { String(c[$0]) } == ["ask @Fix. the bug now. ", "Then go"])
    }

    @Test func startsSentenceIsThePortOfTheBenchmarksRule() {
        func at(_ text: String) -> Bool {
            let c = Array(text)
            return S.startsSentence(c, at: c.firstIndex(of: "@") ?? 0)
        }
        for yes in ["@a", "  @a", "x. @a", "x! @a", "x? @a", "x; @a", "x: @a", "x\n@a", "x\n  @a", "x — @a", "x - @a", "x–@a"] {
            #expect(at(yes), "\(yes.debugDescription)")
        }
        for no in ["x @a", "tell @a", "x, @a", "(@a", "\"@a", "x.y@a"] {
            #expect(!at(no), "\(no.debugDescription)")
        }
    }

    // MARK: Assembling

    @Test func assembleJoinsInMessageOrderAndMovesThePills() {
        let (text, mentions) = message([.words("yes. "), ci(), .words(" fix it. Skip this. "), docs(), .words(" later")])
        // "@CI fix it. " and " later"-side words, the sentence between left out, given out of order.
        let c = Array(text)
        let ciStart = 5, skip = ciStart + 12, docsStart = skip + 11
        let part = S.assemble(text, [docsStart..<c.count, 0..<skip], mentions: mentions)
        #expect(part.text == "yes. @CI fix it. @Docs later")
        #expect(part.mentions.map(\.name) == ["CI", "Docs"] && part.mentions.map(\.range) == [5..<8, 17..<22])
        #expect(part.pills == [5..<8, 17..<22])
        // A pill cut in two, or left out, goes.
        let some = S.assemble(text, [0..<7, ciStart..<c.count], mentions: mentions)
        #expect(some.text == text && some.mentions.count == 2)
        let cut = S.assemble(text, [0..<7], mentions: mentions)
        #expect(cut.text == "yes. @C" && cut.mentions.isEmpty && cut.pills.isEmpty)
    }

    @Test func assembleTrimsLikeASentMessageAndRebasesPastTheTrim() {
        let (text, mentions) = message([.words("first. \n\n"), ci(), .words(" go on  \n")])
        let part = S.assemble(text, [8..<Array(text).count], mentions: mentions)
        #expect(part.text == "@CI go on" && part.pills == [0..<3])
        #expect(S.assemble(text, [], mentions: mentions).text.isEmpty)
        #expect(S.assemble(text, [0..<Array(text).count], mentions: mentions).text == "first. \n\n@CI go on")
    }
}
