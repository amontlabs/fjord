import Foundation
import Testing
@testable import Fjord

/// Preparing a message (the addressing taken out of your own words, by rules), running a CLI once, and the pieces of
/// starting a session.
@Suite struct RouterPrepare {
    // MARK: Your words, without their addressing

    /// Where each "@name" stands in `message`, whole: the pills the composer would have recorded.
    private func pills(_ message: String, _ names: [String] = ["lookout"]) -> [Range<Int>] {
        let chars = Array(message)
        var out: [Range<Int>] = []
        for i in chars.indices where chars[i] == "@" {
            for name in names {
                let tag = Array("@" + name), end = i + tag.count
                guard end <= chars.count, Array(chars[i..<end]) == tag else { continue }
                if end < chars.count, chars[end].isLetter || chars[end].isNumber || "./-_".contains(chars[end]) { continue }
                out.append(i..<end)
            }
        }
        return out
    }

    private func edit(_ message: String, pills given: [Range<Int>]? = nil) throws -> String {
        try Addressing.edit(message, pills: given ?? pills(message)).text
    }

    @Test func theLeadingPillsAndTheAsidesAreTakenOutOfYourOwnWords() throws {
        #expect(try edit("@lookout add a badge") == "add a badge")
        #expect(try edit("@lookout: add a badge") == "add a badge")
        #expect(try edit("@lookout @lookout: rotate the keys") == "rotate the keys")
        #expect(try edit("Bump the version and push (@router this one is slow, don't wait on it)") == "Bump the version and push")
        #expect(try edit("Ship it [@router quietly]") == "Ship it")
        #expect(try edit("Ship it\n@router then wait\nand tag it") == "Ship it\nand tag it")
        #expect(try edit("Ship it (@router)!") == "Ship it!")
        #expect(try edit("Ship it (@router see (a) first) now") == "Ship it now")
        // An indented block after the colon keeps its indent.
        #expect(try edit("@lookout:\n    let x = 1\n    let y = 2") == "    let x = 1\n    let y = 2")
        // Nothing to take out: byte for byte, unmarked.
        let plain = try Addressing.edit("  Lookout is slow: profile it  ", pills: [])
        #expect(plain == Prepared(text: "  Lookout is slow: profile it  ", original: "  Lookout is slow: profile it  ", rephrased: false))
        #expect(try edit("Fix @lookout.js") == "Fix @lookout.js")
        // A pill alone, or in the middle: your words.
        #expect(try edit("@lookout") == "@lookout")
        #expect(try edit("ask @lookout about it") == "ask @lookout about it")
        #expect(throws: Addressing.NothingLeft.self) { try edit("@router what needs me?") }
    }

    @Test func aPastedBodyKeepsItsOwnTrailingCommaAndSemicolon() {
        let one = "@lookout start a session to explain why this returns a tuple:\n    return value,"
        #expect(SessionStart.task(from: one, pills: [0..<8], projects: ["lookout"]) == "explain why this returns a tuple:\n    return value,")
        let two = "start a session to fix this;\nlet x = 1;"
        #expect(SessionStart.task(from: two) == "fix this;\nlet x = 1;")
        // A comma left where a settings clause was cut from the end of the request still goes.
        #expect(SessionStart.task(from: "start a session to fix the tests, with opus,") == "fix the tests")
    }

    @Test func aPillInCodeIsTheCodesTextAndNeverTakenOut() throws {
        // A project named "cache": the decorator of an indented or fenced method is the code's, pill or not.
        for message in ["    @cache\n    def f(self):\n        return 1", "```\n@cache\ndef f(): pass\n```", "`@cache` it"] {
            let at = pills(message, ["cache"])
            #expect(!at.isEmpty)
            #expect(try edit(message, pills: at) == message, "\(message)")
            #expect(SessionStart.task(from: message, pills: at, projects: ["cache"]) == message, "\(message)")
        }
        #expect(try edit("@cache\n    @cache\n    def f(): pass", pills: pills("@cache\n    @cache", ["cache"]))
                == "\n    @cache\n    def f(): pass")
    }

    @Test func onlyAPillIsATagAndAnAddressGoesAsYouWroteIt() throws {
        // "@lookout" typed, not a pill: your words.
        #expect(try edit("@lookout add a badge", pills: []) == "@lookout add a badge")
        // No session's or project's name is looked for: what is said to it goes whole.
        for message in ["tell lookout to bump the version", "tell it to bump the version", "lookout: add a badge",
                        "for lookout, add a badge", "tell lookout not to delete the database"] {
            #expect(try edit(message) == message, "\(message)")
        }
        // A session titled to swallow a condition can't: only the pill goes.
        #expect(try edit("@lookout only if backup succeeds: delete the database")
                == "only if backup succeeds: delete the database")
        // A new session's task was already taken out of its request: only the asides go.
        #expect(try Addressing.edit("@lookout rotate the keys (@router soon)", pills: [0..<8], envelope: false).text
                == "@lookout rotate the keys")
    }

    @Test func nothingIsEverAddedOrReworded() throws {
        // Whatever comes out is your message with parts taken out: every character of it is yours, in order.
        for message in ["@lookout bump the version", "ask it if the tests pass", "@lookout: add a badge; api: rotate the keys",
                        "Ship it (@router quietly) then push", "@lookout — run the tests"] {
            let out = try edit(message)
            var rest = Substring(message)
            for c in out {
                guard let i = rest.firstIndex(of: c) else { Issue.record("\(out) isn't taken out of \(message)"); break }
                rest = rest[rest.index(after: i)...]
            }
        }
    }

    @Test func pastedCodeKeepsItsAsides() throws {
        #expect(try edit("Run `(@router x)` now (@router soon)") == "Run `(@router x)` now")
        #expect(try edit("Try:\n```\n@router for help\n```\nthen push (@router later)") == "Try:\n```\n@router for help\n```\nthen push")
        #expect(try edit("Look at\n    @router help\nplease") == "Look at\n    @router help\nplease")
    }

    @Test func anAsideWithCodeInItIsStillTakenOut() throws {
        #expect(try edit("Bump the version and push (@router this one is slow; don't wait on `CI`)") == "Bump the version and push")
        // Brackets in its code neither close it nor leave it open: only its own count.
        #expect(try edit("Ship it (@router see `f(x)` and `)` first) now") == "Ship it now")
        #expect(try edit("Ship it [@router not `]` yet] now") == "Ship it now")
        // Its bracket left open outside code: text, as written.
        #expect(try edit("Ship it (@router see `)`") == "Ship it (@router see `)`")
        #expect(RouterTools.hasRouterAside("Ship it (@router wait on `CI`)"))
    }

    @Test func anAsideOpenedInADoubleQuotedSpanIsTheQuotesText() throws {
        for text in ["Change the composer placeholder to \"(@router no rush)\"", "Change the placeholder to “(@router no rush)”",
                     "Set it to \"see [@router later]\" and push"] {
            #expect(try edit(text) == text, "\(text)")
            #expect(!RouterTools.hasRouterAside(text), "\(text)")
        }
        // Outside the quotes, or with a quote left open or an apostrophe: an aside, as before.
        #expect(try edit("Change it to \"x\" (@router no rush)") == "Change it to \"x\"")
        #expect(try edit("Use a 5\" pipe (@router no rush)") == "Use a 5\" pipe")
        #expect(try edit("Don't ship it (@router no rush)") == "Don't ship it")
        #expect(try edit("Say \"hi\nthere\" (@router soon)") == "Say \"hi\nthere\"")
    }

    @Test func aRouterMentionThatIsntAnExplicitAsideGoesAsWritten() throws {
        // In code or quotes of any kind, in prose, glued to punctuation, or in a bracket left open: never cut, never refused.
        for text in ["print(f'ask @router for {name}')", "print(‘ask @router’)", "print('ask @router for help')",
                     "print(\"ask @router for help\")", "Tell them 'ask @router for help' later", "Ship it @router quietly",
                     "Ship it, @router then wait", "**@router quietly**", ";@router quietly", "Ship it (@router later",
                     "Ship it (@router (later)", "f(x, '@router')", "say “ask @router”"] {
            #expect(try edit(text) == text, "\(text)")
            #expect(!RouterTools.hasRouterAside(text), "\(text)")
        }
    }

    // MARK: Running a CLI once

    /// A stand-in for Claude Code: keeps its arguments and stdin, then prints `output`.
    private func fake(_ dir: TempDir, output: String, sleep: Double = 0) -> String {
        let path = dir.path("claude").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(dir.path("args").path)'
        cat > '\(dir.path("stdin").path)'
        sleep \(sleep)
        cat <<'EOF'
        \(output)
        EOF
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    @Test func aRunTakesItsInputAndGivesBackItsResult() async throws {
        let dir = TempDir()
        let binary = fake(dir, output: #"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#)
        let out = try await OneShot.run(binary, ["-p"], cwd: dir.url, input: Data("hello".utf8), timeout: 120)
        #expect(try OneShot.result(out) == "done")
        #expect(try String(contentsOf: dir.path("stdin"), encoding: .utf8) == "hello")
    }

    @Test func aFailedOrSlowRunIsAnError() async throws {
        let dir = TempDir()
        let failed = fake(dir, output: #"{"type":"result","is_error":true,"errors":["Model not available"]}"#)
        await #expect(throws: RouterTools.Failure.self) {
            try OneShot.result(try await OneShot.run(failed, [], cwd: dir.url, timeout: 120))
        }
        let slow = TempDir()
        let binary = fake(slow, output: "{}", sleep: 5)
        let start = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            try await OneShot.run(binary, [], cwd: slow.url, timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 60)
    }

    // MARK: Starting a session

    @Test func theBootstrapRenamesAndMakesNoModelCall() throws {
        // No permission mode: the app gives the imported session the one in the user's settings.
        let args = SessionStart.bootstrapArguments(uuid: "u-1", title: "Bump the version")
        #expect(args == ["-p", "/rename Bump the version", "--session-id", "u-1", "--output-format", "json", "--setting-sources", ""])
        #expect(SessionStart.importURL(uuid: "abc")?.absoluteString == "claude://resume?session=abc")
        #expect(SessionStart.cleanTitle("  Bump\nthe   version  ") == "Bump the version")
    }

    @Test func aNewSessionIsWaitedForOnlyUntilTheAppHasItNotUntilItRuns() async throws {
        let dir = TempDir()
        // Whether the app has it: its file under the app's sessions folder (account/org/local_<uuid>.json).
        let root = dir.path("claude-code-sessions")
        let org = root.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? Data("{}".utf8).write(to: org.appendingPathComponent("local_u-9.json"))
        }
        // No process is looked for: the app having the session is all there is to wait for.
        try await SessionStart.waitForImport(uuid: "u-9", timeout: 120, root: root)
        await #expect(throws: RouterTools.Failure.self) { try await SessionStart.waitForImport(uuid: "other", timeout: 0.5, root: root) }
        // Stop, a reset or the Router off ends the wait as itself.
        struct Stopped: Error {}
        await #expect(throws: Stopped.self) { try await SessionStart.waitForImport(uuid: "other", timeout: 120, root: root, check: { throw Stopped() }) }
        // Whether the app has it: its file under the app's sessions folder (account/org/local_<uuid>.json).
        #expect(!SessionStart.imported("u-1", root: root))
        try Data("{}".utf8).write(to: org.appendingPathComponent("local_u-1.json"))
        #expect(SessionStart.imported("u-1", root: root) && !SessionStart.imported("u-2", root: root))
    }

    // MARK: One run, bounded

    private func script(_ dir: TempDir, _ name: String, _ body: String) -> String {
        let path = dir.path(name).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    private func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    @Test func aProgramThatNeverReadsItsInputDoesntHoldTheRun() async throws {
        let dir = TempDir()
        // 4 MB of input it never reads; it answers and exits.
        let path = script(dir, "deaf", "echo done")
        let out = try await OneShot.run(path, [], cwd: dir.url, input: Data(count: 4 << 20), timeout: 120)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "done\n" && out.status == 0)
        // Never reading and never exiting: the deadline ends it, covering the blocked write too.
        let stuck = script(dir, "stuck", "exec sleep 30")
        let handle = OneShot.Handle()
        let start = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            try await OneShot.run(stuck, [], cwd: dir.url, input: Data(count: 4 << 20), timeout: 1, handle: handle)
        }
        #expect(Date().timeIntervalSince(start) < 60)
        #expect(handle.pid > 0 && !handle.isActive && !alive(handle.pid))
    }

    @Test func aChildLeftHoldingTheOutputDoesntHoldTheRun() async throws {
        let dir = TempDir()
        // It exits at once, but leaves a child that keeps its stdout and stderr open for 30 s.
        let path = script(dir, "leaver", "sleep 30 & echo $! > '\(dir.path("child.pid").path)'; echo answer")
        let start = Date()
        let out = try await OneShot.run(path, [], cwd: dir.url, timeout: 120)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "answer\n")
        // Not held by the child (it holds the pipes for 30 s).
        #expect(Date().timeIntervalSince(start) < 25)
        if let child = Int32((try? String(contentsOf: dir.path("child.pid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            kill(child, SIGKILL)
        }
    }

    @Test func cancellingEndsTheProgramEvenIfItIgnoresSIGTERM() async throws {
        let dir = TempDir()
        let path = script(dir, "stubborn", #"exec /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; sleep 1 while 1'"#)
        let handle = OneShot.Handle()
        let running = Task { try await OneShot.run(path, [], cwd: dir.url, timeout: 60, handle: handle) }
        await waitUntilAnywhere { handle.isRunning }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = handle.pid
        let start = Date()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!alive(pid) && !handle.isRunning && Date().timeIntervalSince(start) < 25)
        // Ended before it started: never run.
        let early = OneShot.Handle()
        early.cancel()
        await #expect(throws: CancellationError.self) { try await OneShot.run(path, [], cwd: dir.url, timeout: 60, handle: early) }
        #expect(early.pid == 0)
    }

    // MARK: Reading the pipes

    @Test func aReadUnderWayIsWaitedForBeforeThePipeCloses() throws {
        let pipe = Pipe()
        let reader = OneShot.PipeReader(pipe.fileHandleForReading)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = FormWriter.Flag()
        // The reader's first read is held in flight.
        reader.aroundRead = {
            guard !first.isSet else { return }
            first.set()
            entered.signal()
            release.wait()
        }
        reader.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        #expect(entered.wait(timeout: .now() + waitWatchdog) == .success)
        reader.stop()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { reader.waitDone(); done.signal() }
        // While its read is under way, stopping doesn't count as done: the pipe can't be closed under it.
        #expect(done.wait(timeout: .now() + 0.2) == .timedOut)
        release.signal()
        #expect(done.wait(timeout: .now() + waitWatchdog) == .success)
        // Now it's safe to close; what was read is kept.
        try pipe.fileHandleForReading.close()
        #expect(reader.data == Data("hello".utf8))
    }

    @Test func aDescendantFeedingThePipeForeverDoesntHoldTheRun() async throws {
        let dir = TempDir()
        // It leaves a child that writes to the shared output without end, then exits.
        let path = script(dir, "flood", "(while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done) & echo $! > '\(dir.path("flood.pid").path)'; echo answer")
        defer {
            if let pid = Int32(((try? String(contentsOf: dir.path("flood.pid"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }
        let start = Date()
        let out = try await OneShot.run(path, [], cwd: dir.url, timeout: 120)
        // Returned past the grace and a bounded last drain, not held by the child; and the output is capped.
        #expect(Date().timeIntervalSince(start) < 60)
        #expect(out.stdout.range(of: Data("answer".utf8)) != nil)
        #expect(out.stdout.count <= OneShot.PipeReader.maxBytes)
    }

    @Test func aDescendantHoldingStdinDoesntKeepTheInputAlive() async throws {
        let dir = TempDir()
        // It leaves a child holding its stdin (checked with lsof: fd 0 is the pipe) that never reads, and exits at once; the input is far more than a pipe holds.
        let path = script(dir, "holder", "sleep 600 <&0 & echo $! > '\(dir.path("holder.pid").path)'; echo done")
        defer {
            if let pid = Int32(((try? String(contentsOf: dir.path("holder.pid"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }
        let handle = OneShot.Handle()
        let start = Date()
        let out = try await OneShot.run(path, [], cwd: dir.url, input: Data(count: 8 << 20), timeout: 120, handle: handle)
        // The child holds the pipe as its stdin (`<&0`) for 10 minutes: a writer that blocked would hold the run as long.
        #expect(Date().timeIntervalSince(start) < 120)
        #expect(out.stdout.range(of: Data("done".utf8)) != nil)
        // By the time the run returns, its input was given up and the pipe closed: nothing left writing.
        #expect(handle.isInputClosed)
    }
}

