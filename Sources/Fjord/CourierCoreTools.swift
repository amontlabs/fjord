import Foundation

// routerd.py's tools: the tab acts once, then reads the settings (or lists the projects) to prove it. The small shared helpers are
// ported here; the steps themselves are stubs for slice 4, with the Python signatures (routerd.py lines 1334-1560).

extension CourierCore {
    /// Adds to what the intent's result holds: `before` and `acted`.
    @discardableResult
    func keep(_ run: Run, _ result: [(String, JSON)]) -> JSON {
        let intent = sql.intent(run.id)
        var merged = intent.obj("result").asObject ?? JSONObject()
        for (k, v) in result { merged[k] = v }
        return sql.update(clock(), run.id, [("result", .object(merged))])
    }

    func issue(_ run: Run, _ kind: String, _ fields: [(String, JSON)] = []) {
        run["command"] = .string(command(kind, fields))
        run["command_page"] = [.int(pages), instance ?? .null]  // the document and script it is handed to (`replay`)
        deadline(run)
    }

    /// The run moves to its next stage. What the last stage sent, opened, read or cut off is behind it.
    func goto(_ run: Run, _ stage: String) {
        run.update([("stage", .string(stage)), ("command", .null), ("opened", false), ("mark", .null), ("cut", false), ("open_wait", false), ("open_error", false)])  // an erred open is the last stage's
    }

    /// `there`: the tab shows the place. Until it does, the place is opened, once per stage. The projects page counts as shown once
    /// its open is done, since nothing else says so.
    func reach(_ run: Run, _ project: String?, there thereIn: Bool = false) -> Bool {
        var there = thereIn
        if project == nil { there = run.flag("opened") && !run.flag("command") }
        if !there && !run.flag("opened") && !run.flag("command") && !run.flag("open_wait") {  // `open_wait`: an erred open's deadline
            run["opened"] = true
            moves += 1
            issue(run, "open", [("project", JSON(project)), ("thread", .null)])
            run["reach_open"] = run["command"]  // its `done` is an open's (`tool_done`)
        }
        return there
    }

    /// One read of the project's settings. The one that counts is the first to arrive after this.
    func read(_ run: Run, _ intent: JSON) {
        run["mark"] = .int(reads[intent.str("project") ?? "", default: 0])
        issue(run, "read_settings", [("project", intent["project"] ?? .null)])
    }

    /// The stage's read has arrived.
    func hasRead(_ run: Run, _ intent: JSON) -> Bool {
        run.get("mark") != nil && reads[intent.str("project") ?? "", default: 0] > (run["mark"]?.asInt ?? 0)
    }

    /// Reading shares the tab with the sends: it waits while another run is acting, or another tool's command is in the page (tool
    /// commands have no side: two reads, or a read and an act, would replace or disturb each other). A run that hasn't begun (at `start`,
    /// nothing sent, nothing opened) isn't acting, as in `tab_held`: a send that arrived meanwhile must not hold the read it waits behind.
    func tabFree(_ run: Run) -> Bool {
        !toolBusy(run) && !goingBack(run) && !lookingNow(run) && !runs.pairs.contains { $0.key != run.id && !yielded($0.value) && !$0.value.flag("paused") && acting($0.value) }
    }

    /// A tool has the page's dialog open or may open it: a command of its own is in the page, or it opened its project to read and
    /// hasn't read yet (its open's `done` comes before the tab says it arrived: a run that yielded, in `prove`, may still be reading); or
    /// a dev command is in the page (it may have the settings dialog open). Words typed meanwhile could land in the dialog's fields:
    /// sends wait for it to end, and for a finished read still closing the dialog too. `run`: a tool asking about the others, which
    /// doesn't wait for a close (its own open closes a dialog left open).
    func toolBusy(_ run: Run? = nil) -> Bool {
        (run == nil && !closing.isEmpty) || !dev.isEmpty || runs.values.contains { o in
            o !== run && o.flag("tool") && (inPage(o) || (Self.proving.contains(o.str("stage") ?? "") && o.flag("opened") && o.get("mark") == nil))
        }
    }

    /// Why a tool never started (`composes`; a tool waits for no settled chat): the tab never showed the place, or never its composer,
    /// or another tool's command held the page.
    func unstarted(_ intent: JSON) -> String {
        let board = self.board()
        guard let project = intent.str("project"), shows(board, Place(project, nil)) else { return "the page never showed that place" }
        if !composes(board, project) { return "the page showed that place but never its composer" }
        return "another tool's step held the page"
    }

    /// An act that erred after it committed says its error too.
    func notConfirmed(_ run: Run) -> String {
        run.flag("act_error") ? "\(CourierDo.notConfirmed): \(run["act_error"]!.pyStr)" : CourierDo.notConfirmed
    }

    // ---- slice 4: the steps (stubs; the signatures are Python's)

    /// A tool run: the tab shows the place, then the act is sent once. A setting's act reads what it changes first (kept as `before`), and
    /// then proves it by a read.
    func advanceTool(_ run: Run, _ intent: JSON, _ late: Bool) {
        finish(run, "failed", "tools aren't ported yet")
    }

    func stepTool(_ run: Run, _ intent: JSON) {}
    func proveRead(_ run: Run, _ intent: JSON) {}
    func act(_ run: Run, _ intent: JSON) {}
    func toolLate(_ run: Run, _ intent: JSON) {}

    /// A tool's `done` (the act's, a read's, or an open's).
    func toolDone(_ run: Run, _ event: JSON) {}

    func readBefore(_ run: Run, _ intent: JSON, _ event: JSON) -> JSON? { nil }
    func already(_ run: Run, _ intent: JSON, _ before: JSON?) {}
    func unanswered(_ run: Run, _ intent: JSON, _ error: String) {}

    /// A tool that was done but not confirmed is confirmed by a later read that shows it (a later list of projects, for a create). A full
    /// list without the name, seen ACCEPTED_WAIT after the create, says it never took (the server refused it): its name is free again.
    /// Sooner, the server may only be slow, and freeing the name would let a second create make a duplicate.
    func reconcile(_ kind: String, _ project: String?, complete: Bool = false) {}

    /// One of the Router's tools by name, as an explicit project send is: no model. `preapprove_folder` is `awaiting` until `confirm`.
    func tool(_ tool: String, args: [(String, JSON)] = [], reply: @escaping (JSON) -> Void = { _ in }, finished: @escaping (JSON) -> Void = { _ in }) {
        reply(["event": "error", "error": "tools aren't ported yet"])
    }

    /// `decide.start_step`: a queued step whose earlier step is confirmed, checked against the Board now.
    func startStep(_ intent: JSON) -> JSON { intent }
}
