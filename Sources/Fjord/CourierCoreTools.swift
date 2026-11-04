import Foundation

// routerd.py's tools: the tab acts once, then reads the settings (or lists the projects) to prove it. The small shared helpers are
// ported here; the steps themselves are stubs for slice 4, with the Python signatures (routerd.py lines 1334-1560).

extension CourierCore {
    /// Adds to what the intent's result holds: `before` and `acted`.
    @discardableResult
    func keep(_ run: Run, _ result: [(String, JSON)]) throws -> JSON {
        let intent = try sql.intent(run.id)
        var merged = intent.obj("result").asObject ?? JSONObject()
        for (k, v) in result { merged[k] = v }
        return try sql.update(clock(), run.id, [("result", .object(merged))])
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

    // ---- the steps

    /// A tool run: the tab shows the place, then the act is sent once. A setting's act reads what it changes first (kept as `before`), and
    /// the server's answer to its save proves it; with no answer, or for a create, a later read proves it. Once the act is sent it is never
    /// sent again: with no proof there is one more look, then `failed`.
    func advanceTool(_ run: Run, _ intent: JSON, _ lateIn: Bool) throws {
        var late = lateIn
        let board = self.board()
        let project: String? = intent.str("project").flatMap { $0.isEmpty ? nil : $0 }
        // Only a read after the act proves it, and never a goal's: the dialog shows the tab's copy of it, which may be what was typed.
        if Self.acted.contains(run.str("stage") ?? "") && intent.str("tool") != "set_goal" && (project == nil || reads[project!, default: 0] > (run.num("acted").map { Int($0) } ?? 0)) {
            let (holds, cause) = CourierDo.toolProved(board, intent)
            if let cause { return try finish(run, "failed", cause) }
            if holds { return try finish(run, "confirmed", changes: project == nil ? [("project", .string(CourierDo.created(board, intent["proof"] ?? .null).first ?? ""))] : []) }
            if run.str("stage") == "prove" && run.flag("unsaved") {  // the page saw no save, and a read taken after the act lacks it: it didn't take
                return try finish(run, "failed", run.str("act_error"))
            }
        }
        if let pause = CourierDo.pause(board["health"] ?? .null) {
            run["paused"] = true; run["deadline"] = .null
            pauses[run.id] = pause
            return try mark(intent, "paused", CourierDo.sentence(pause))
        }
        pauses[run.id] = nil
        if run.flag("paused") {
            run["paused"] = false; late = false
            try mark(intent, "pending", nil)
            if Self.acted.contains(run.str("stage") ?? "") {  // the act is in the page, or done: only the wait goes on
                deadline(run)
            } else {
                if let c = run.str("command") { command("cancel", [("target", .string(c))]) }
                goto(run, "start")
            }
        }
        if late { return try toolLate(run, intent) }
        try stepTool(run, intent)
    }

    /// What the run's stage does next, from the Board and the events so far.
    func stepTool(_ run: Run, _ intent: JSON) throws {
        let board = self.board(), project = intent.str("project"), stage = run.str("stage") ?? "", create = intent.str("tool") == "create_project"
        if stage == "start" && toolBusy(run) { return }  // another run's proving read is in the page: an open or act now would close its dialog under it
        if stage == "start" && (goingBack(run) || lookingNow(run)) {  // a taken send's open will move the tab, or its look
            run["waits_tab"] = true  // holds it (`looking_now`): its `done`, or the look's end in the same pass, advances this run
            return
        }
        if stage == "start" && create {  // the projects page is where the New project dialog is
            if let taken = CourierDo.nameTaken(board, intent["args"]?["name"]?.pyStr ?? "") { return try finish(run, "refused", taken) }
            if reach(run, nil) { try act(run, intent) }
        } else if stage == "start" {  // a setting's act opens the settings fresh itself and reads what it changes before changing it
            if reach(run, project, there: project.map { composes(board, $0) } ?? false) { try act(run, intent) }
        } else if stage == "prove" && !create {  // a create's proof is a projects list, which comes by itself
            if run.get("mark") == nil { proveRead(run, intent) }
        } else if stage == "look" && create {  // the second look is the projects page itself: its open's `done` may come before its list
            if !tabFree(run) { return deadline(run) }
            if run.get("mark") == nil { run["mark"] = .int(lists) }
            if reach(run, nil) && lists > (run["mark"]?.asInt ?? 0) { try finish(run, "failed", notConfirmed(run)) }
        } else if stage == "look" {
            if run.get("mark") == nil {
                proveRead(run, intent)
            } else if hasRead(run, intent) {
                try finish(run, "failed", notConfirmed(run))
            }
        }
    }

    /// A read that proves the act. A send that went on while this run waited may have moved the tab: it goes back to the project first.
    func proveRead(_ run: Run, _ intent: JSON) {
        if !tabFree(run) { return deadline(run) }  // the deadline is the wake-up: at it the run takes its look, or reads now if the tab is free
        let project = intent.str("project")
        if reach(run, project, there: project.map { shows(board(), Place($0, nil)) } ?? false) { read(run, intent) }
    }

    /// The one act. From here the run is past `act`: it is proved or failed, never sent again. A setting's act may find it already so
    /// and change nothing; until it says so, it counts as done.
    func act(_ run: Run, _ intent: JSON) throws {
        let (kind, fields) = CourierDo.actCommand(intent)
        try sql.update(clock(), run.id, [("status", "pending"), ("attempts", 1), ("cause", .null)])
        // A goal is proved by its save's answer alone. `act`: the command's id, so that a `done` a later start replays is known as its.
        try keep(run, [("acted", true), ("act", .string(nextID()))] + (intent.str("tool") == "set_goal" ? [("provable", false)] : []))
        goto(run, "act")
        run["acted"] = .int(reads[intent.str("project") ?? "", default: 0])  // the reads the page had sent before the act: the one before it is old
        issue(run, kind, fields.asObject?.pairs.map { ($0.key, $0.value) } ?? [])
    }

    /// The deadline passed. A page step that is still waiting is cut off: it knows what it lacked and says so in its `done`. In `prove`
    /// the run takes its one more look; any other stage, or a second deadline, ends the run.
    func toolLate(_ run: Run, _ intent: JSON) throws {
        let stage = run.str("stage") ?? ""
        if stage != "start" && inPage(run) && !run.flag("cut") {
            run["cut"] = true
            command("cancel", [("target", run["command"] ?? .null)])
            return deadline(run)
        }
        if run.flag("open_wait") {  // its open erred (`tool_done`): it opens again now, once more
            run["open_wait"] = false
            deadline(run)
            return try stepTool(run, intent)
        }
        if stage == "prove" {
            goto(run, "look")
            return try stepTool(run, intent)
        }
        if stage == "look" && run.get("mark") == nil && !run.flag("opened") { return try stepTool(run, intent) }  // another run held the tab: the look hasn't been taken yet
        if stage == "act" && intent.str("tool") == "set_goal" {  // its save got no answer: no read can prove it, now or later
            staleGoal[intent.str("project") ?? ""] = try keep(run, [("provable", false)])
            return try finish(run, "failed", "the page never finished the step")
        }
        try finish(run, "failed", stage == "start" ? unstarted(intent) : stage == "act" ? "the page never finished the step" : notConfirmed(run))
    }

    /// The page's report of a tool step. A setting's act reports what its fresh open read (`before`), then either that it was already
    /// so (`already`: nothing done) or the server's answer to its save (`saved`, the HTTP status), which proves it. An act that errs
    /// before it committed is the answer; one that errs after (`committed`: no answer to the save, a dialog stuck closing) may have
    /// taken, so it is proved by a read, its error kept for the cause, except a goal, which no read can prove. A refusal (`refused`) is
    /// the page not offering what was asked.
    func toolDone(_ run: Run, _ event: JSON) throws {
        let error = (event.get("error").map { $0.isTruthy ? $0.pyStr : "" }).flatMap { $0.isEmpty ? nil : $0 } ?? "the page reported a failure"
        let stage = run.str("stage") ?? ""
        run["command"] = .null
        var intent = try sql.intent(run.id)
        if event.get("id") == run.get("reach_open") {  // its open's: as a send's open, a page error opens again at the deadline, a second fails it
            run["reach_open"] = .null
            if event.flag("ok") {
                run["open_error"] = false
            } else if error != "superseded" && stage != "prove" {  // a proving open's error waits for the deadline's look, as before
                if run.flag("open_error") { return try finish(run, "failed", error) }
                run["open_error"] = true; run["opened"] = false; run["open_wait"] = true
                return deadline(run)
            }
        }
        let setting = stage == "act" && intent.str("tool") != "create_project"
        let before: JSON? = setting && event.has("before") ? try readBefore(run, intent, event) : nil
        if event.flag("ok") {
            if setting && event.get("already") == .bool(true) { return try already(run, intent, before) }
            if stage == "act" && !(run["ms"]?.asObject?.has("clicked") ?? false) { run.put("ms", "clicked", .int(ms(run))) }
            if setting, let saved = event.get("saved"), saved.isPyInt, let s = saved.numeric, s >= 200 && s < 300 {  // the server took it: nothing to read
                if intent.str("tool") == "set_goal" {
                    try keep(run, [("provable", true)])
                    staleGoal.pop(intent.str("project") ?? "")  // the tab shows the goal the server has
                }
                return try finish(run, "confirmed")
            }
            if setting { return try unanswered(run, intent, "the page reported no answer to the save") }  // done, but no answer to its save was reported: as an act that committed with none
            if stage == "act" {  // a create: a later list of the projects proves it
                goto(run, "prove")
                deadline(run)
            }
            return
        }
        if error == "superseded" && stage != "act" {  // another run moved the tab or read: this one opens and reads again
            run["opened"] = false; run["mark"] = .null
            return
        }
        if stage == "prove" && run.flag("cut") {  // routerd cut it off at the deadline: this is its report, and the look follows at once
            goto(run, "look")
            return try stepTool(run, intent)
        }
        if stage == "prove" { return deadline(run) }  // a proving open or read that broke on its own: the deadline's look decides
        if stage == "act" && event.flag("committed") && !event.flag("refused") {
            if !(run["ms"]?.asObject?.has("clicked") ?? false) { run.put("ms", "clicked", .int(ms(run))) }
            // A folder or repository pressed with no save seen by the page's short wait: the fresh read that follows answers, not the look.
            run["unsaved"] = .bool(event.flag("unsaved") && ["add_repo", "preapprove_folder"].contains(intent.str("tool") ?? ""))
            return try unanswered(run, intent, error)
        }
        if stage == "act" && !event.flag("committed") {  // the page step erred before its one change: nothing was done
            intent = try keep(run, [("acted", false)] + (intent.str("tool") == "set_goal" ? [("provable", true)] : []))
        }
        if stage == "act" && !event.flag("committed") && intent.str("tool") == "set_goal" { staleGoal[intent.str("project") ?? ""] = intent }  // the tab may show the goal the server refused
        if event.flag("refused") {
            let path = intent.get("args")?.get("path")
            let missing = intent.str("tool") == "preapprove_folder" && pyStartsWith(error, "no folder option")  // its list was there and lacked it
            return try finish(run, "refused", missing ? "connect \(path?.pyStr ?? "None") in the Claude app first" : error)
        }
        try finish(run, "failed", stage == "look" ? "\(CourierDo.notConfirmed): \(error)" : error)
    }

    /// What the act's own open read, kept as `before`. A goal is the tab's copy: one the tab shows that differs from a goal marked as
    /// refused means the marked one is gone from it.
    func readBefore(_ run: Run, _ intent: JSON, _ event: JSON) throws -> JSON? {
        let before = CourierDo.before(event["before"], intent), goal = intent.str("tool") == "set_goal"
        try keep(run, [("before", before)] + (goal ? [("before_is", "the tab's copy, maybe older")] : []))
        if goal, let marked = staleGoal[intent.str("project") ?? ""], case .string = before, !CourierDo.shows(marked.obj("proof"), before) {
            staleGoal.pop(intent.str("project") ?? "")
        }
        return before
    }

    /// The act found it already so and changed nothing: it was never acted on. A goal is said as the tab knows it (an unchanged field
    /// saves nothing, so it can't be written again); one the server refused, which the tab still shows (it shows what was typed), is not so.
    func already(_ run: Run, _ intent: JSON, _ before: JSON?) throws {
        var result = JSONObject()
        for (k, v) in try sql.intent(run.id).obj("result").asObject ?? JSONObject() where k != "acted" && k != "provable" { result[k] = v }
        try sql.update(clock(), run.id, [("result", .object(result))])
        if !CourierDo.shows(intent.obj("proof"), before) {  // what the page read says otherwise: nothing was done, and nothing is known
            return try finish(run, "failed", "the page said it was already so, but what it read differs")
        }
        if intent.str("tool") != "set_goal" { return try finish(run, "confirmed", "it was already so") }
        if let marked = staleGoal[intent.str("project") ?? ""] {
            let unknown = marked.obj("result").get("provable") == .bool(false)
            return try finish(run, "refused", unknown ? "Fjord can't tell whether the server took this goal: reload the tab first"
                                                  : "the server refused this goal earlier and Fjord's tab still shows it: reload the tab first")
        }
        try finish(run, "confirmed", "it was already so, as far as Fjord's tab knows")
    }

    /// The act committed its change but no answer to its save came. The proving read and the look decide, except for a goal: the
    /// dialog shows the goal as the tab last knew it (the typed one, even if the server refused it), so only the answer to its save
    /// proves a goal, and without it no read can, now or later.
    func unanswered(_ run: Run, _ intent: JSON, _ error: String) throws {
        if intent.str("tool") == "set_goal" {
            let kept = try keep(run, [("provable", false)])
            staleGoal[kept.str("project") ?? ""] = kept  // the tab shows the typed goal whether or not the server has it
            return try finish(run, "failed", "\(CourierDo.notConfirmed): \(error)")
        }
        goto(run, "prove")
        run["act_error"] = .string(error)
        try sql.update(clock(), run.id, [("cause", .string(error))])
        deadline(run)
    }

    /// A tool that was done but not confirmed is confirmed by a later read that shows it (a later list of projects, for a create). A full
    /// list without the name, seen ACCEPTED_WAIT after the create, says it never took (the server refused it): its name is free again.
    /// Sooner, the server may only be slow, and freeing the name would let a second create make a duplicate.
    func reconcile(_ kind: String, _ project: String?, complete: Bool = false) throws {
        let board = self.board()
        for intentID in unproved.sorted() {
            let intent = try sql.intent(intentID)
            if (intent.str("tool") == "create_project") != (kind == "projects") || (kind == "settings" && intent.str("project") != project) { continue }
            let (holds, cause) = CourierDo.toolProved(board, intent)
            if !holds && complete && intent.str("tool") == "create_project" && clock() - (intent.num("at") ?? 0) >= Self.acceptedWait {
                unproved.remove(intentID)
                var r = intent.obj("result").asObject ?? JSONObject()
                r["acted"] = false
                try sql.update(clock(), intentID, [("result", .object(r))])
                continue
            }
            if holds && cause == nil {
                unproved.remove(intentID)
                let found: [(String, JSON)] = intent.str("tool") == "create_project" ? [("project", .string(CourierDo.created(board, intent["proof"] ?? .null).first ?? ""))] : []
                try confirmLate(intent, "confirmed by a later read", columns: found)
            }
        }
    }

    // ---- decide.py's tool parts

    /// One of the Router's tools by name, as an explicit project send is: no model. `preapprove_folder` is `awaiting` until `confirm`.
    func tool(_ tool: String, args: [(String, JSON)] = [], reply: @escaping (JSON) -> Void = { _ in }, finished: @escaping (JSON) -> Void = { _ in }) throws {
        let t0 = clock()
        try begin(try toolIntent(board(), tool, .object(JSONObject(args))), t0, reply, finished, ["by": "explicit"])
    }

    /// (project id, cause): checked arguments against the Board now. The project must be on the page, and a new name free: `unproved` are
    /// the ids of the tools that acted but were never proved, so a create among them that took holds its name.
    func toolCheck(_ board: JSON, _ tool: String, _ clean: JSON) throws -> (project: String?, cause: String?) {
        var project: String?, cause: String?
        if let name = clean["project"] {
            if let p = CourierBoard.projectNamed(board, name.asString ?? ""), pyStartsWith(p.str("id") ?? "", "chan_") {
                (project, cause) = (p.str("id"), nil)
            } else {
                (project, cause) = (nil, "no project named \(name.pyStr) on the page")
            }
        }
        if cause == nil && tool == "create_project" {
            cause = CourierDo.nameTaken(board, clean["name"]?.pyStr ?? "")
            let earlier = try unproved.contains(where: { id in
                let i = try sql.intent(id)
                return i.str("tool") == tool && i.obj("args").get("name") == clean["name"] && i.obj("result").flag("acted")
            })
            if cause == nil && earlier {
                cause = "an earlier create of \(clean["name"]?.pyStr ?? "") took, but isn't confirmed yet"
            }
        }
        return (project, cause)
    }

    func toolStatus(_ tool: String, _ cause: String?) -> String {
        cause != nil ? "refused" : CourierDo.confirm.contains(tool) ? "awaiting" : "pending"
    }

    /// (intent, created) for one tool. Whatever is wrong with it is refused here, so nothing reaches the page. A permission grant waits for `confirm`.
    func addTool(_ board: JSON, _ tool: String, _ args: JSON, words: String? = nil, more: [(String, JSON)] = []) throws -> (intent: JSON, created: Bool) {
        let (clean, cause0) = CourierDo.toolArgs(tool, args)
        var project: String?, cause = cause0
        if cause == nil { (project, cause) = try toolCheck(board, tool, clean!) }
        let text = words ?? (clean.map { c in c[CourierDo.primary[tool] ?? ""]?.pyStr ?? "" } ?? "")
        let storedArgs: JSON? = (clean?.isTruthy ?? false) ? clean : (args.asObject != nil ? args : nil)
        return try sql.addIntent(clock(), tool, words: text, project: project, thread: nil, args: storedArgs,
                             proof: cause != nil ? nil : CourierDo.toolProof(tool, clean ?? .null, board), status: toolStatus(tool, cause),
                             more: [("cause", JSON(cause))] + more)
    }

    func toolIntent(_ board: JSON, _ tool: String, _ args: JSON, words: String? = nil, more: [(String, JSON)] = []) throws -> JSON {
        try addTool(board, tool, args, words: words, more: more).intent
    }

    /// One intent per step, in order. The first is checked now. A later one is `queued` until the step before it is confirmed and is checked
    /// then, since it may name the project an earlier step creates. Arguments that are wrong refuse every step, so nothing is half done.
    func toolSteps(_ board: JSON, _ stepsIn: [JSON], _ words: String, more: [(String, JSON)] = []) throws -> [JSON] {
        var steps = stepsIn.map { s -> JSON in if case .object = s { return s } else { return .object(JSONObject()) } }
        if steps.isEmpty { steps = [.object(JSONObject())] }
        func toolOf(_ s: JSON) -> String { (s.get("tool")?.isTruthy ?? false) ? s["tool"]!.pyStr : "" }
        func argsOf(_ s: JSON) -> JSON { (s.get("args")?.isTruthy ?? false) ? s["args"]! : .object(JSONObject()) }
        if steps.count == 1 { return [try toolIntent(board, toolOf(steps[0]), argsOf(steps[0]), words: words, more: more)] }
        let checked = try steps.map { CourierDo.toolArgs(toolOf($0), argsOf($0)) }
        let bad: Int? = checked.firstIndex { $0.cause != nil }.map { $0 + 1 }
        var out: [JSON] = []
        for (n0, step) in steps.enumerated() {
            let n = n0 + 1
            let tool = toolOf(step), args = argsOf(step)
            var cause = checked[n0].cause
            if n == 1 && bad == nil {
                let (first, created) = try addTool(board, tool, args, words: words, more: [("result", ["step": 1])] + more)
                if !created { return [first] }  // the same request again: its steps are under way
                out.append(first)
                continue
            }
            if let bad, n != bad {
                let name = (steps[bad - 1].get("tool")?.isTruthy ?? false) ? steps[bad - 1]["tool"]!.pyStr : "?"
                cause = "step \(bad) (\(name)) refused: \(checked[bad - 1].cause ?? "None")"
            } else if bad == nil && out[0].str("status") == "refused" {
                cause = after(out[0])
            }
            let clean = checked[n0].args
            out.append(try sql.addIntent(clock(), tool, words: words, args: (clean?.isTruthy ?? false) ? clean : (args.asObject != nil ? args : nil),
                                     status: cause != nil ? "refused" : "queued", dup: false,
                                     more: [("cause", JSON(cause)), ("result", ["step": .int(n)])] + more).intent)
        }
        return out
    }

    /// A queued step whose earlier step is confirmed, checked against the Board now, as a first step is at decide time.
    func startStep(_ intent: JSON) throws -> JSON {
        let (project, cause) = try toolCheck(board(), intent.str("tool") ?? "", intent["args"] ?? .null)
        let tool = intent.str("tool") ?? ""
        return try sql.update(clock(), intent["id"]?.asInt ?? 0, [("project", JSON(project)), ("status", .string(toolStatus(tool, cause))), ("cause", JSON(cause)),
                                                             ("proof", cause != nil ? .null : CourierDo.toolProof(tool, intent["args"] ?? .null, board()))])
    }
}
