import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefMarkupReads {
    @Test func tagsBecomeHighlightsAndStrayTagsLeaveOnlyWords() {
        let text = #"<t id="th_1">The layout pick</t> waits; <b>bold</b> <t id="x">"#
        #expect(BriefMarkup.parse(text) == [.thread(id: "th_1", text: "The layout pick"), .text(" waits; bold ")])
        #expect(BriefMarkup.plain(text) == "The layout pick waits; bold ")
        #expect(BriefMarkup.ids(text) == ["th_1"])
        // An empty tag is only its (no) words.
        #expect(BriefMarkup.parse(#"a <t id="t"> </t>b"#) == [.text("a  b")])
    }

    @Test func aWordAfterAHighlightWithNoSpaceSitsAgainstIt() {
        let tokens = BriefMarkup.tokens(#"See <t id="t">the guide</t>, then go."#)
        #expect(tokens == [.word("See", tight: false), .thread(id: "t", text: "the guide", tight: false),
                           .word(",", tight: true), .word("then", tight: false), .word("go.", tight: false)])
    }

    @Test func onlyKnownThreadsKeepTheirTags() {
        let checked = BriefMarkup.checked(#"<t id="t1">One</t> and <t id="ghost">two</t>."#) { $0 == "t1" }
        #expect(checked == #"<t id="t1">One</t> and two."#)
    }

    @Test func theModelsNowKeepsTagsOfItsThreadsOnly() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .needsYou)])
        model.answer = { _ in
            #"{"now":["<t id=\"t1\">The pick</t> waits; <t id=\"ghost\">a ghost</t> too; <t id=\"coordinator\">its question</t>."],"needs_you":[],"decisions":[],"loose_ends":[]}"#
        }
        let engine = makeEngine(src, model)
        src.post("p", id: "c", kind: .card, thread: "t1", text: "Which?", options: ["a"])
        engine.itemsChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now == [#"<t id="t1">The pick</t> waits; a ghost too; <t id="coordinator">its question</t>."#])
    }

    @Test func theLeadKeepsTagsOfThreadsTheBriefsHold() {
        var doc = BriefDoc(project: "p")
        doc.threads = [briefThread("t1", .done)]
        let lead = GeneralBrief(forYou: #"<t id="p/t1">The guide</t> and <t id="p/ghost">a ghost</t>."#,
                                worthALook: #"<t id="q/t1">Elsewhere</t>"#)
        let checked = RouterBriefEngine.checkedLead(lead, docs: ["p": doc], at: 3)
        #expect(checked == GeneralBrief(forYou: #"<t id="p/t1">The guide</t> and a ghost."#, worthALook: "Elsewhere", at: 3))
    }

    @Test func theLeadIsWrittenFromTaggedThreadsByProject() {
        var doc = BriefDoc(project: "p")
        doc.now = [#"<t id="t1">The guide</t> is done."#]
        doc.threads = [briefThread("t1", .done, title: "Rewrite the guide")]
        let context = RouterBriefEngine.leadContext(["p": doc])
        #expect(context.contains(#"now: <t id="p/t1">The guide</t> is done."#))
        #expect(context.contains(#"finished: p/t1 "Rewrite the guide""#))
    }

    @Test func aSectionNamesEveryThreadThatWaitsOnYou() {
        var doc = BriefDoc(project: "p")
        doc.now = [#"<t id="t1">The pick</t> waits."#]
        let e1 = BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 0, source: .cloud, question: "Which?")
        let e2 = BriefEntry(project: "p", thread: "t2", kind: .plan, state: .needsYou, since: 0, source: .cloud, question: "Approve the <b>plan</b>?")
        let section = BriefPage.Section(name: "p", group: .needsYou, doc: doc, entries: [e1, e2], recent: [], finished: [])
        #expect(BriefSectionView.markup(section) == #"<t id="t1">The pick</t> waits. <t id="t2">Approve the plan?</t>"#)
        // With a title, the title: a few words, not the whole question.
        doc.threads = [briefThread("t2", .needsYou, title: "Move the briefs into router.db")]
        let titled = BriefPage.Section(name: "p", group: .needsYou, doc: doc, entries: [e1, e2], recent: [], finished: [])
        #expect(BriefSectionView.markup(titled).hasSuffix(#"<t id="t2">Move the briefs into router.db</t>"#))
    }

    @Test func forYouNamesEveryThreadThatWaitsOnYou() {
        let e1 = BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 0, source: .cloud, question: "Which?")
        let e2 = BriefEntry(project: "q", thread: "t2", kind: .plan, state: .needsYou, since: 0, source: .cloud, question: "Approve?")
        var dq = BriefDoc(project: "q")
        dq.threads = [briefThread("t2", .needsYou, title: "Ship it")]
        var page = BriefPage()
        page.lead = GeneralBrief(forYou: #"<t id="p/t1">The pick</t> waits."#)
        page.sections = [BriefPage.Section(name: "p", group: .needsYou, doc: BriefDoc(project: "p"), entries: [e1], recent: [], finished: []),
                         BriefPage.Section(name: "q", group: .needsYou, doc: dq, entries: [e2], recent: [], finished: [])]
        #expect(BriefLeadText.forYou(page) == #"<t id="p/t1">The pick</t> waits. Also: <t id="q/t2">Ship it</t>."#)
        page.lead = GeneralBrief()
        #expect(BriefLeadText.forYou(page) == #"<t id="p/t1">Which?</t>, <t id="q/t2">Ship it</t>."#)
    }

    @Test func linksStayOnlyOnAddressesTheModelWasGiven() {
        let text = #"See <a href="https://github.com/a/b/pull/1">the PR</a> and <a href="https://made.up/x">this</a>."#
        #expect(BriefMarkup.parse(text) == [.text("See "), .link(url: "https://github.com/a/b/pull/1", text: "the PR"), .text(" and "),
                                             .link(url: "https://made.up/x", text: "this"), .text(".")])
        let links = BriefMarkup.addresses("Pushed [#1](https://github.com/a/b/pull/1), see https://x.dev/y.")
        #expect(links == ["https://github.com/a/b/pull/1", "https://x.dev/y"])
        #expect(BriefMarkup.checked(text, known: { _ in false }, links: links) == #"See <a href="https://github.com/a/b/pull/1">the PR</a> and this."#)
    }

    @Test func theModelsLinksComeFromItsItems() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done)])
        model.answer = { _ in
            #"{"now":["<t id=\"t1\">The release</t> is out: <a href=\"https://github.com/a/b/releases/tag/v1\">v1</a>, <a href=\"https://github.com/a/b/releases/tag/v2\">v2</a>."],"needs_you":[],"decisions":[],"loose_ends":[]}"#
        }
        let engine = makeEngine(src, model)
        src.post("p", id: "m", kind: .message, thread: "t1", text: "Published [v1](https://github.com/a/b/releases/tag/v1).")
        engine.itemsChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now == [#"<t id="t1">The release</t> is out: <a href="https://github.com/a/b/releases/tag/v1">v1</a>, v2."#])
    }

    @Test func aBriefWrittenBeforeTagsIsWrittenAgainAtLaunch() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done)])
        model.answer = { _ in #"{"now":["Busy."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let store = MemoryBriefStore()
        let engine = makeEngine(src, model, store: store)
        src.post("p", id: "m", kind: .message, thread: "t1", text: "go")
        engine.itemsChanged("p"); await engine.idle()
        #expect(RouterBriefEngine.untagged(engine.docs["p"]!))
        let calls = model.contexts.count
        model.answer = { _ in #"{"now":["<t id=\"t1\">It</t> is done."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let again = makeEngine(src, model, store: store)
        again.start(); await again.idle()
        #expect(model.contexts.count == calls + 1)
        #expect(again.docs["p"]?.now == [#"<t id="t1">It</t> is done."#])
        // Tagged now: the next launch calls nothing.
        let third = makeEngine(src, model, store: store)
        third.start(); await third.idle()
        #expect(model.contexts.count == calls + 1)
    }

    @Test func aHoveredPanelStaysWhileThePointerIsOnItOrYouType() async throws {
        let briefs = RouterBriefs()
        let t = BriefTarget(project: "p", thread: "t1")
        briefs.hover("k", t, inside: true)
        #expect(briefs.hovered == "k" && briefs.hoveredTarget == t)
        // Off the highlight and onto its panel: it stays.
        briefs.hover("k", t, inside: false)
        briefs.hover("k", t, inside: true)
        try await Task.sleep(for: .milliseconds(RouterBriefs.hoverGrace + 120))
        #expect(briefs.hovered == "k")
        // Typing holds it with the pointer away; done typing, it goes.
        briefs.hold(true)
        briefs.hover("k", t, inside: false)
        try await Task.sleep(for: .milliseconds(RouterBriefs.hoverGrace + 120))
        #expect(briefs.hovered == "k")
        briefs.hold(false)
        #expect(briefs.hovered == nil && briefs.hoveredTarget == nil)
        // Left for good: gone after the grace.
        briefs.hover("k", t, inside: true)
        briefs.hover("k", t, inside: false)
        try await Task.sleep(for: .milliseconds(RouterBriefs.hoverGrace + 120))
        #expect(briefs.hovered == nil)
    }

    @Test func theHistoryGroupsLinesByDay() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        func line(_ id: String, _ hoursAgo: Double) -> RouterDrawer.Line {
            RouterDrawer.Line(id: id, at: now.addingTimeInterval(-hoursAgo * 3600), kind: .answer, text: id)
        }
        let days = RouterDrawer.days([line("a", 1), line("b", 3), line("c", 20), line("d", 60)], now: now, calendar: cal)
        #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(days.map { $0.lines.map(\.id) } == [["a", "b"], ["c"], ["d"]])
    }

    @Test func aMessagesPlaceIsItsThreadOrItsProject() {
        #expect(RouterDrawer.place("claude-thread:chan_a/th_1").thread == BriefTarget(project: "chan_a", thread: "th_1"))
        #expect(RouterDrawer.place("claude-project:chan_a").project == "chan_a")
        #expect(RouterDrawer.place(nil).thread == nil)
    }
}
