import Foundation
import Testing
@testable import Fjord

/// `Fjord --form-hook`, run in a folder of the test's own with its stdin, stdout and clock stood in for.
@Suite struct FormHookRuns {
    private final class Box: @unchecked Sendable {
        var output = Data()
        var sleeps = 0
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
    }

    private func request(transcript: URL?, tool: String = "AskUserQuestion", event: String = "PermissionRequest",
                         input: [String: Any] = sampleInput) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "session_id": "cli-1", "transcript_path": transcript?.path ?? "", "cwd": "/code/app",
            "hook_event_name": event, "tool_name": tool, "tool_input": input, "permission_mode": "default",
        ] as [String: Any])
    }

    private func planRequest(transcript: URL? = nil) -> Data {
        request(transcript: transcript, tool: "ExitPlanMode", input: planInput)
    }

    private func line(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj) + Data("\n".utf8)
    }

    private func toolUse(_ id: String, tool: String = "AskUserQuestion", input: [String: Any] = sampleInput) -> Data {
        line(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": id, "name": tool, "input": input],
        ]]])
    }

    /// The decision the run printed.
    private func decision(_ box: Box) throws -> [String: Any] {
        let obj = try #require(try JSONSerialization.jsonObject(with: box.output) as? [String: Any])
        let specific = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        return try #require(specific["decision"] as? [String: Any])
    }

    /// This helper records the form held during a plan hook's run when Fjord decides it at the third wait.
    private func decidePlan(_ dir: TempDir, _ decision: PendingForm.PlanDecision) -> (FormHook.Outcome, Box, PendingForm?) {
        var held: PendingForm?
        let (outcome, box) = run(dir, input: planRequest(), step: { n, forms in
            guard n == 3, let form = FormBridge.read(dir: forms, alive: { $0 == 4242 })["cli-1"] else { return }
            held = form
            try! FormBridge.answer(form, plan: decision, in: forms)
        })
        return (outcome, box, held)
    }

    private func toolResult(_ id: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": id, "content": "answered"],
        ]]])
    }

    private func append(_ data: Data, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(data)
        try! handle.close()
    }

    /// A run where `step` is called at each wait (with the count so far), in a forms folder with the marker unless not `enabled`.
    private func run(_ dir: TempDir, input: Data, enabled: Bool = true, parentAlive: @escaping () -> Bool = { true },
                     stopped: @escaping () -> Bool = { false }, step: @escaping (Int, URL) -> Void = { _, _ in }) -> (FormHook.Outcome, Box) {
        let forms = dir.path("forms")
        if enabled { try! FormBridge.setEnabled(true, dir: forms) }
        let box = Box()
        let env = FormHook.Environment(
            forms: forms, input: input, output: { box.output.append($0) }, pid: 4242,
            now: { box.clock },
            sleep: { interval in
                box.sleeps += 1
                box.clock += interval
                step(box.sleeps, forms)
            },
            parentAlive: parentAlive, stopped: stopped, interval: 0.25, maxWait: 3600)
        return (FormHook.run(env), box)
    }

    private func pendingFiles(_ dir: TempDir) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path("forms").path)) ?? []).filter { $0 != ".enabled" }
    }

    @Test func anAnswerFromFjordIsPrintedAsTheDecision() throws {
        let dir = TempDir()
        var seenPending: PendingForm?
        let (outcome, box) = run(dir, input: request(transcript: nil), step: { n, forms in
            guard n == 3 else { return }
            let found = FormBridge.read(dir: forms) { $0 == 4242 }
            seenPending = found["cli-1"]
            if let form = seenPending {
                try! FormBridge.answer(form, answers: ["Which database?": "SQLite", "Which features?": "Auth, Billing"], in: forms)
            }
        })
        #expect(outcome == .answered)
        let form = try #require(seenPending)
        #expect(form.questions.count == 2)
        // One line of JSON, and nothing else.
        let text = String(decoding: box.output, as: UTF8.self)
        #expect(text.hasSuffix("}\n") && text.filter { $0 == "\n" }.count == 1)
        let obj = try #require(try JSONSerialization.jsonObject(with: box.output) as? [String: Any])
        let specific = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Which database?": "SQLite", "Which features?": "Auth, Billing"])
        #expect((updated["questions"] as? [Any])?.count == 2)
        #expect(pendingFiles(dir).isEmpty)
    }

    @Test func anApprovedPlanIsAllowedWithItsInputAsItCame() throws {
        let dir = TempDir()
        let (outcome, box, held) = decidePlan(dir, .init(approve: true))
        #expect(outcome == .answered)
        let form = try #require(held)
        #expect(form.isPlan && form.plan == planInput["plan"] as? String)
        // Claude Code ignores a bare allow for ExitPlanMode: the input goes back with it, unchanged.
        let decision = try decision(box)
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? NSDictionary)?.isEqual(to: planInput) == true)
        #expect(decision["message"] == nil && pendingFiles(dir).isEmpty)
    }

    @Test func aPlanSentBackIsDeniedWithClaudeCodesWordsAndTheNote() throws {
        let dir = TempDir()
        let (outcome, box, _) = decidePlan(dir, .init(approve: false, feedback: "Split step 2 in two"))
        #expect(outcome == .answered)
        let decision = try decision(box)
        #expect(decision["behavior"] as? String == "deny" && decision["updatedInput"] == nil)
        #expect(decision["message"] as? String == FormHook.rejectedWithNote + "Split step 2 in two")
        // Not interrupted: the session goes on planning.
        #expect(decision["interrupt"] == nil)

        let bare = TempDir()
        let (_, plain, _) = decidePlan(bare, .init(approve: false))
        #expect(try self.decision(plain)["message"] as? String == FormHook.rejected)
    }

    @Test func anAnswerOfTheWrongKindDecidesNothing() {
        #expect(FormHook.decision(tool: "ExitPlanMode", input: planInput, answer: ["answers": ["Q": "A"]]) == nil)
        #expect(FormHook.decision(tool: "AskUserQuestion", input: sampleInput, answer: ["plan": ["approve": true]]) == nil)
        #expect(FormHook.decision(tool: "ExitPlanMode", input: planInput, answer: ["plan": ["feedback": "no verdict"]]) == nil)
    }

    @Test func aPlanApprovedInTheAppLeavesQuietly() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        // A question with the plan's input isn't its call: only an ExitPlanMode call is.
        try (toolUse("ask", input: planInput) + toolUse("plan", tool: "ExitPlanMode", input: planInput)).write(to: transcript)
        var held: PendingForm?
        let (outcome, box) = run(dir, input: planRequest(transcript: transcript), step: { n, forms in
            if n == 1 { held = FormBridge.read(dir: forms, alive: { $0 == 4242 })["cli-1"] }
            if n == 2 { self.append(self.toolResult("ask"), to: transcript) }
            if n == 4 { self.append(self.toolResult("plan"), to: transcript) }
        })
        #expect(held?.toolUseID == "plan" && held?.isPlan == true)
        #expect(outcome == .answeredElsewhere && box.sleeps == 4 && box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func thePendingFileIsPrivate() throws {
        let dir = TempDir()
        var checked = false
        let (outcome, _) = run(dir, input: request(transcript: nil), parentAlive: { !checked }, step: { _, forms in
            let files = (try? FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil)) ?? []
            let pending = files.first { $0.pathExtension == "json" }
            #expect(pending.flatMap(mode) == 0o600)
            checked = true
        })
        #expect(outcome == .parentGone && checked)
        #expect(pendingFiles(dir).isEmpty)
    }

    @Test func answeredInTheAppItLeavesQuietly() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        // An older, identical question already answered; this hook's call, then the result split across reads.
        try (toolUse("old") + toolResult("old") + toolUse("mine")).write(to: transcript)
        let result = toolResult("mine")
        let (outcome, box) = run(dir, input: request(transcript: transcript), step: { n, _ in
            if n == 2 { self.append(Data(result.prefix(20)), to: transcript) }
            if n == 4 { self.append(Data(result.dropFirst(20)), to: transcript) }
        })
        #expect(outcome == .answeredElsewhere)
        #expect(box.sleeps == 4)
        #expect(box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func answeredInTheAppBeforeTheFirstLookItLeavesAtOnce() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        try (toolUse("mine") + toolResult("mine")).write(to: transcript)
        let (outcome, box) = run(dir, input: request(transcript: transcript))
        #expect(outcome == .answeredElsewhere && box.sleeps == 0)
        #expect(box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func anOlderQuestionsResultSplitAcrossTheFirstReadsDoesNotEndTheWait() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        let old = toolResult("old")
        try (toolUse("old") + toolUse("mine") + Data(old.prefix(25))).write(to: transcript)
        var watch = FormHook.TranscriptWatch(path: transcript.path, input: sampleInput as NSDictionary)
        let first = watch.answered()
        // The last line is incomplete: nothing is decided yet.
        #expect(!first && watch.id == nil)
        append(Data(old.dropFirst(25)), to: transcript)
        let second = watch.answered()
        #expect(!second && watch.id == "mine")
        append(toolResult("mine"), to: transcript)
        let third = watch.answered()
        #expect(third)
    }

    @Test func theOlderAnsweredQuestionAloneDoesNotEndIt() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        try (toolUse("old") + toolResult("old") + toolUse("mine")).write(to: transcript)
        var parent = true
        let (outcome, box) = run(dir, input: request(transcript: transcript), parentAlive: { parent }, step: { n, _ in
            if n == 5 { parent = false }
        })
        #expect(outcome == .parentGone && box.sleeps == 5 && box.output.isEmpty)
    }

    @Test func notTurnedOnItStepsAsideAtOnce() {
        let dir = TempDir()
        let (outcome, box) = run(dir, input: request(transcript: nil), enabled: false)
        #expect(outcome == .disabled && box.sleeps == 0 && box.output.isEmpty)
        #expect(pendingFiles(dir).isEmpty)
    }

    private func permissionFiles(_ dir: TempDir) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir.path("permissions"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    @Test func anOrdinaryToolsPromptIsNotedAndNothingIsPrintedOrWaitedFor() throws {
        let dir = TempDir()
        let (outcome, box) = run(dir, input: request(transcript: nil, tool: "Bash", input: ["command": "git push"]))
        #expect(outcome == .observed)
        #expect(box.output.isEmpty && box.sleeps == 0)
        // No form is held for it.
        #expect(pendingFiles(dir).isEmpty)
        let note = try #require(permissionFiles(dir).first)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as? [String: Any])
        #expect(obj["tool_name"] as? String == "Bash" && obj["session_id"] as? String == "cli-1")
        #expect((obj["tool_input"] as? [String: Any])?["command"] as? String == "git push")
        #expect(note.lastPathComponent.hasPrefix("cli-1-"))
    }

    @Test func aPromptIsNotNotedWhileTheRouterIsOff() {
        let dir = TempDir()
        let (outcome, box) = run(dir, input: request(transcript: nil, tool: "Edit"), enabled: false)
        #expect(outcome == .disabled && box.output.isEmpty && permissionFiles(dir).isEmpty)
    }

    @Test func theFormToolsAreStillHeldAndNotNoted() {
        let dir = TempDir()
        let (outcome, _, _) = decidePlan(dir, .init(approve: true))
        #expect(outcome == .answered)
        #expect(permissionFiles(dir).isEmpty)
    }

    @Test func otherHooksAndBadInputAreIgnored() {
        let dir = TempDir()
        #expect(run(dir, input: request(transcript: nil, event: "PreToolUse")).0 == .ignored)
        #expect(run(dir, input: Data("not json".utf8)).0 == .ignored)
        #expect(run(dir, input: Data()).0 == .ignored)
        #expect(pendingFiles(dir).isEmpty)
    }

    @Test func turningTheRouterOffEndsTheWait() {
        let dir = TempDir()
        let (outcome, box) = run(dir, input: request(transcript: nil), step: { n, forms in
            if n == 2 { try! FormBridge.setEnabled(false, dir: forms) }
        })
        #expect(outcome == .disabled && box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func aSignalEndsTheWait() {
        let dir = TempDir()
        var signalled = false
        let (outcome, box) = run(dir, input: request(transcript: nil), stopped: { signalled }, step: { n, _ in
            if n == 2 { signalled = true }
        })
        #expect(outcome == .stopped && box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func itGivesUpAfterItsCap() {
        let dir = TempDir()
        let (outcome, box) = run(dir, input: request(transcript: nil))
        #expect(outcome == .timedOut && box.sleeps == 3600 * 4 && box.output.isEmpty && pendingFiles(dir).isEmpty)
    }

    @Test func anOversizedCallFarFromTheEndIsFoundAndFollowed() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        // The call's own record is bigger than a read's chunk, and more than a chunk of other lines follows it.
        let big = String(repeating: "y", count: Int(FormHook.TranscriptWatch.chunk) + 4096)
        let call = line(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "text", "text": big],
            ["type": "tool_use", "id": "mine", "name": "AskUserQuestion", "input": sampleInput],
        ]]])
        let filler = line(["type": "user", "message": ["content": [["type": "text", "text": String(repeating: "x", count: 4096)]]]])
        var after = Data()
        while after.count < Int(FormHook.TranscriptWatch.chunk) + 8192 { after.append(filler) }
        try (toolUse("old") + call + after).write(to: transcript)
        var watch = FormHook.TranscriptWatch(path: transcript.path, input: sampleInput as NSDictionary)
        let before = watch.answered()
        #expect(!before && watch.id == "mine")
        // Another call's result doesn't end it; its own does.
        append(toolResult("old"), to: transcript)
        let other = watch.answered()
        #expect(!other)
        append(toolResult("mine"), to: transcript)
        let answered = watch.answered()
        #expect(answered)
    }

    @Test func stdinIsReadWholeButNeverWaitedOnForever() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]) }
        let request = Data("{\"a\":1}".utf8)
        _ = request.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        // Held open: a signal ends the read.
        var polls = 0
        let started = Date()
        let held = FormHook.readInput(fd: fds[0], stopped: { polls += 1; return polls > 3 })
        // Ended by the signal, not by its own 60 s limit (a watchdog bound: any runner is far quicker).
        #expect(held == nil && Date().timeIntervalSince(started) < 50)
        // Or the time limit.
        #expect(FormHook.readInput(fd: fds[0], timeout: 0.3, stopped: { false }) == nil)
        // Closed: what was written.
        _ = request.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        close(fds[1])
        #expect(FormHook.readInput(fd: fds[0], stopped: { false }) == request)
        // Too much: given up on.
        let dir = TempDir()
        let big = dir.path("big")
        try Data(repeating: 0x20, count: 256 * 1024).write(to: big)
        let fd = open(big.path, O_RDONLY)
        defer { close(fd) }
        #expect(FormHook.readInput(fd: fd, limit: 64 * 1024, stopped: { false }) == nil)
    }

    /// The real binary, its stdin held open and never written: SIGTERM ends it at once, quietly.
    @Test func theBinaryLeavesQuietlyOnSIGTERMWhileStdinIsHeldOpen() throws {
        let exe = Bundle(for: Box.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Fjord")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path))
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--form-hook"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { Self.reap(process) }
        // Ready once it catches SIGTERM: before that (the binary still loading), the signal would kill it outright.
        let ready = Self.waitUntil { Self.catches(SIGTERM, pid: process.processIdentifier) || !process.isRunning }
        #expect(ready && process.isRunning)
        process.terminate()
        let quit = Self.waitForExit(process)
        Self.reap(process)
        try? stdin.fileHandleForWriting.close()
        #expect(quit && process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    /// A watchdog, not a timing budget: the outcome is what's checked.
    private static func waitForExit(_ process: Process) -> Bool {
        waitUntil { !process.isRunning }
    }

    /// `waitUntil` for these synchronous tests, against the same watchdog; whether `done` held is the test's to check.
    private static func waitUntil(_ done: () -> Bool) -> Bool {
        var watchdog = Watchdog()
        while !done() && !watchdog.expired() { Thread.sleep(forTimeInterval: 0.01) }
        return done()
    }

    /// Whether the process has a handler installed for `signal` (the kernel's `p_sigcatch`).
    private static func catches(_ signal: Int32, pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_sigcatch & (1 << (signal - 1)) != 0
    }

    /// Kills a child that didn't end and waits for it, so its stdout reaches its end and nothing outlives the test.
    private static func reap(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    /// The real binary: the hook mode comes before the app, and prints nothing for a hook that isn't its own.
    @Test func theBinaryRunsTheHookModeBeforeTheApp() throws {
        let exe = Bundle(for: Box.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Fjord")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path))
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--form-hook"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { Self.reap(process) }
        stdin.fileHandleForWriting.write(request(transcript: nil, tool: "Bash"))
        try stdin.fileHandleForWriting.close()
        let quit = Self.waitForExit(process)
        Self.reap(process)
        #expect(quit && process.terminationStatus == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test func aRecordStillBeingWrittenIsWaitedForBeforeTheCallIsChosen() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        // An identical older question, answered; this hook's call only half written.
        let mine = toolUse("mine")
        try (toolUse("old") + toolResult("old") + Data(mine.prefix(30))).write(to: transcript)
        var watch = FormHook.TranscriptWatch(path: transcript.path, input: sampleInput as NSDictionary)
        let first = watch.answered()
        #expect(!first && watch.id == nil)
        append(Data(mine.dropFirst(30)), to: transcript)
        let second = watch.answered()
        #expect(!second && watch.id == "mine")
        append(toolResult("mine"), to: transcript)
        let third = watch.answered()
        #expect(third)
    }

    @Test func theHookNamesItsCallInThePendingFileOnceFound() throws {
        let dir = TempDir()
        let transcript = dir.path("t.jsonl")
        try toolUse("toolu_mine").write(to: transcript)
        var named: String?
        var parent = true
        let (outcome, _) = run(dir, input: request(transcript: transcript), parentAlive: { parent }, step: { n, forms in
            named = FormBridge.read(dir: forms) { $0 == 4242 }["cli-1"]?.toolUseID
            // Written again with its call: still private.
            #expect(mode(forms.appendingPathComponent(try! FileManager.default.contentsOfDirectory(atPath: forms.path)
                .first { $0.hasSuffix(".json") }!)) == 0o600)
            if n == 2 { parent = false }
        })
        #expect(outcome == .parentGone && named == "toolu_mine")
    }
}
