import Foundation

// The briefs on demo data (RouterBriefView.swift's shots): five projects, one with a question card and a plan, a local
// session whose form Fjord's hook holds (the demo's `cli-demo-lcu`), one working, one that finished, one quiet.

@MainActor
extension Demo {
    enum BriefVariant { case home, stale, quiet }

    static let briefLocalThread = "local:cli-demo-lcu"
    static let briefLocalSession = "cse_demo_lcu"

    static func briefs(_ store: Store, now: Date = Date(), _ variant: BriefVariant = .home) {
        let t = now.timeIntervalSince1970
        let briefs = store.routerBriefs
        briefs.clock = { now }
        briefs.names = ["chan_demo_fjord": "fjord", "local:lcu": "lcu", "chan_demo_silo": "silo",
                        "chan_demo_docs": "docs-site", "chan_demo_evals": "router-evals"]
        briefs.sessions = [briefLocalThread: briefLocalSession]
        briefs.clis = [briefLocalSession: "cli-demo-lcu"]

        var fjord = BriefDoc(project: "chan_demo_fjord")
        fjord.purpose = "A Mac app that keeps your Claude threads, local and on claude.ai, in one place."
        fjord.now = ["<t id=\"th_settings\">The Settings layout</t> waits on your pick, and <t id=\"th_migrate\">the briefs migration plan</t> is ready to approve.",
                     "<t id=\"th_handover\">The tab handover</t> is being built; <t id=\"th_bar\">the bar's needs-you count</t> landed."]
        fjord.threads = [
            BriefThread(id: "th_settings", title: "Redesign the Settings window", status: .needsYou, age: t - 240),
            BriefThread(id: "th_migrate", title: "Move the briefs into router.db", status: .needsYou, age: t - 1_500),
            BriefThread(id: "th_handover", title: "Hand the tab over without a gap", status: .working, age: t - 90),
            BriefThread(id: "th_bar", title: "Count untold needs-you on the bar", status: .done, age: t - 3_000),
            BriefThread(id: "th_old", title: "Drop the canvas layout", status: .done, age: t - 3 * 86_400),
        ]
        fjord.needsYou = [
            BriefEntry(project: fjord.project, thread: "th_migrate", kind: .plan, state: .needsYou, since: t - 1_500, source: .cloud,
                       question: "Add a `briefs` table, copy the digest's rows over once at launch, then drop the old table.",
                       options: ["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"], card: "row_plan_1"),
            BriefEntry(project: fjord.project, thread: "th_settings", kind: .question, state: .needsYou, since: t - 240, source: .cloud,
                       question: "Which layout should the Settings window use?",
                       options: ["A sidebar with sections", "One scrolling page", "Tabs across the top"], card: "row_q_1"),
        ]
        fjord.decisions = [BriefDecision(thread: BriefDoc.yourSend, text: "Keep the composer at the bottom of every page.")]
        fjord.looseEnds = ["The old Now page is still compiled; a later step deletes it."]
        fjord.sent = [SentLine(intent: "41", words: "keep the composer where it is, and match Claude's spacing", state: "delivered")]
        fjord.watch = "live"

        var lcu = BriefDoc(project: "local:lcu")
        lcu.now = ["<t id=\"\(briefLocalThread)\">The updater</t> asks how updates should install."]
        lcu.threads = [BriefThread(id: briefLocalThread, title: "Ship the updater", status: .needsYou, age: t - 120, source: .local)]
        lcu.needsYou = [BriefEntry(project: lcu.project, thread: briefLocalThread, kind: .question, state: .needsYou, since: t - 120,
                                   source: .local)]

        var silo = BriefDoc(project: "chan_demo_silo")
        silo.now = ["<t id=\"th_snap\">The snapshot API</t> and <t id=\"th_vm\">booting from a checkpoint</t> are being built; <t id=\"th_flaky\">the flaky disk test</t> stopped."]
        silo.threads = [
            BriefThread(id: "th_snap", title: "Snapshot API: restore by id", status: .working, age: t - 300),
            BriefThread(id: "th_vm", title: "Boot the Linux VM from a checkpoint", status: .working, age: t - 900),
            BriefThread(id: "th_flaky", title: "Find the flaky disk test", status: .paused, age: t - 7_200),
        ]
        silo.watch = "live"

        var docs = BriefDoc(project: "chan_demo_docs")
        docs.now = ["<t id=\"th_guide\">The install guide</t> was rewritten for the new setup; the PR is open."]
        docs.threads = [BriefThread(id: "th_guide", title: "Rewrite the install guide", status: .done, age: t - 600)]
        docs.sent = [SentLine(intent: "39", words: "rewrite the install guide for the Chrome setup", state: "delivered")]
        docs.watch = "live"

        var evals = BriefDoc(project: "chan_demo_evals")
        evals.now = ["Nothing new since <t id=\"th_eval\">yesterday's scoring run</t>."]
        evals.threads = [BriefThread(id: "th_eval", title: "Score the decider on last week's moments", status: .done, age: t - 2 * 86_400)]
        evals.watch = "live"

        switch variant {
        case .home:
            break
        case .stale:
            silo.watch = "stale:\(t - 12 * 60)"
            silo.threads = silo.threads.map { var th = $0; th.asOf = t - 12 * 60; return th }
            fjord.watch = "stale:\(t - 25 * 60)"
            fjord.threads = fjord.threads.map { var th = $0; th.asOf = t - 25 * 60; return th }
            fjord.needsYou = fjord.needsYou.map { var e = $0; e.asOf = t - 25 * 60; return e }
            fjord.proseStale = true
        case .quiet:
            fjord.needsYou = []
            fjord.now = ["Everything here is finished; <t id=\"th_old\">the canvas removal</t> landed yesterday."]
            fjord.threads = [BriefThread(id: "th_old", title: "Drop the canvas layout", status: .done, age: t - 30 * 3_600)]
            fjord.sent = []
            lcu.needsYou = []
            lcu.now = ["<t id=\"\(briefLocalThread)\">The updater</t> shipped."]
            lcu.threads = [BriefThread(id: briefLocalThread, title: "Ship the updater", status: .done, age: t - 2 * 86_400, source: .local)]
            silo.now = ["Quiet since <t id=\"th_snap\">the snapshot API</t> merged."]
            silo.threads = [BriefThread(id: "th_snap", title: "Snapshot API: restore by id", status: .done, age: t - 3 * 86_400)]
            docs.threads = [BriefThread(id: "th_guide", title: "Rewrite the install guide", status: .done, age: t - 4 * 86_400)]
            docs.sent = []
        }

        briefs.demoDocs = [fjord.project: fjord, lcu.project: lcu, silo.project: silo, docs.project: docs, evals.project: evals]
        briefs.demoGeneral = variant == .quiet
            ? GeneralBrief(worthALook: "Every project is quiet; <t id=\"chan_demo_fjord/th_old\">the canvas removal</t> landed yesterday.", at: t - 60)
            : GeneralBrief(forYou: "Three things first: <t id=\"chan_demo_fjord/th_settings\">the Settings layout</t>, <t id=\"chan_demo_fjord/th_migrate\">the migration plan</t> and <t id=\"local:lcu/\(briefLocalThread)\">how updates install</t>.",
                           worthALook: "<t id=\"chan_demo_docs/th_guide\">The install guide</t> is rewritten, and <t id=\"chan_demo_fjord/th_bar\">the bar's count</t> landed.",
                           at: t - 60)
        briefs.demoVersions = [
            fjord.project: [
                BriefVersion(project: fjord.project, version: 1, at: t - 1_500, prose: BriefDoc.Prose(), diff: "+ now: <t id=\"th_migrate\">The briefs migration plan</t> is ready to approve.", items: [], cursor: 0),
                BriefVersion(project: fjord.project, version: 2, at: t - 240, prose: BriefDoc.Prose(), diff: "+ now: The Settings redesign waits on your pick of a layout.", items: [], cursor: 0),
            ],
            docs.project: [BriefVersion(project: docs.project, version: 1, at: t - 600, prose: BriefDoc.Prose(), diff: "+ now: The install guide was rewritten for the new setup; the PR is open.", items: [], cursor: 0)],
        ]
    }
}
