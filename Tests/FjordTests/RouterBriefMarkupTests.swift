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
    }
}
