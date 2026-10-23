import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite(.serialized) struct SiloAPIClientTests {
    @Test func checkedInSchemaFixturesDecodeWithGeneratedCodableTypes() throws {
        let inventory = try JSONDecoder().decode(SiloWireComputersListResult.self, from: fixture("computers-list.json"))
        #expect(inventory.linux.computers.isEmpty)
        #expect(inventory.macos.supported)
        #expect(inventory.macos.minDiskGiB == 64)

        let handshake = try JSONDecoder().decode(SiloWireHandshakeResult.self, from: fixture("handshake-result.json"))
        #expect(handshake.handshakeResultProtocol == 1)
        #expect(handshake.capabilities.contains("operations.*"))

        let progress = try JSONDecoder().decode(SiloWireJobProgress.self, from: fixture("job-progress.json"))
        #expect(progress.source == .lifecycle)
        #expect(progress.data.computerId == "computer-1")
        #expect(progress.data.step == "network")

        let event = try JSONDecoder().decode(SiloWireEventEnvelope.self, from: fixture("job-progress-event.json"))
        #expect(event.event == .operationsJobProgress)
        #expect(event.seq == 7)
        #expect(event.subscription == "sub-1")
        let eventPayload = try #require(event.payload)
        let eventProgress = try JSONDecoder().decode(SiloWireJobProgress.self, from: JSONEncoder().encode(eventPayload))

        let finished = try JSONDecoder().decode(SiloWireJobFinished.self, from: fixture("job-finished.json"))
        #expect(finished.jobId == "job:123")
        #expect(finished.result != nil)
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("schemas/silo-api/schema.json")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let jobId = try #require(definitions["JobId"] as? [String: Any])
        let schemaJobIDPattern = try #require(jobId["pattern"] as? String)
        #expect([progress.jobId, eventProgress.jobId, finished.jobId].allSatisfy {
            $0.range(of: schemaJobIDPattern, options: .regularExpression) != nil
        })
    }

    @Test func generatedGuestClientAdaptsGuestCallsAndWatches() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            let params = (try? JSONSerialization.jsonObject(with: request.params)) as? [String: Any] ?? [:]
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "controller", "name": "Fake",
                                                                     "protocol": 6, "capabilities": ["guest.*", "events.*"]]])
            case "guest.account":
                try? socket.write(["id": request.id, "result": ["home": "/home/g", "uid": 1000, "user": "g"]])
            case "guest.exec":
                let argv = params["argv"] as? [String] ?? []
                let stdout = argv.contains(where: { $0.contains("fjord-account-probe") })
                    ? Data("node=/opt/node/bin/node\nclaude=/home/g/.local/bin/claude\nos=Linux\narch=aarch64\n".utf8)
                    : Data("x".utf8)
                try? socket.write(["id": request.id, "result": ["exitCode": 0, "stdout": Array(stdout), "stderr": [Int]()]])
            case "guest.files.read":
                if params["path"] as? String == "/missing" {
                    try? socket.write(["id": request.id, "error": ["code": "not_found", "message": "missing"]])
                } else {
                    try? socket.write(["id": request.id, "result": ["data": [65, 66], "inode": 9,
                                                                          "mode": 420, "mtimeMs": 1234, "size": 2]])
                }
            case "guest.files.list":
                try? socket.write(["id": request.id, "result": ["entries": [["name": "file", "type": "file", "size": 2, "mtimeMs": 1234],
                                                                                 ["name": "folder", "type": "dir", "size": 0, "mtimeMs": 0]]]])
            case "guest.files.write":
                try? socket.write(["id": request.id, "result": ["inode": 10, "mtimeMs": 1235, "size": 2]])
            case "guest.files.remove":
                try? socket.write(["id": request.id, "result": ["removed": params["paths"] ?? []]])
            case "guest.files.watch":
                try? socket.write(["id": request.id, "result": ["subscriptionId": "guest-watch"]])
            case "events.subscribe":
                try? socket.write(["id": request.id, "result": ["subscription": "events-watch"]])
                try? socket.write(["event": "guest.files.changed", "subscription": "events-watch", "deviceId": "owner-1", "seq": 1,
                                   "payload": ["subscriptionId": "guest-watch", "path": "/watch/path"]])
            case "guest.sshAlias.ensure":
                try? socket.write(["id": request.id, "result": ["alias": "ssh-computer-1", "configPath": "/home/g/.ssh/config",
                                                                      "home": "/home/g", "includeInstalled": true,
                                                                      "includeLine": "Include config.d/*", "user": "g"]])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let engine = SocketEngineClient(path: server.path)
        let client = SiloGuestClient(engine: engine)
        let computer = GuestReference(deviceId: "owner-1", computerId: "computer-1")

        let account = try await client.account(for: computer)
        #expect(account == GuestAccount(home: "/home/g", uid: 1000, operatingSystem: .linux, architecture: "aarch64",
                                        nodeExecutable: "/opt/node/bin/node", claudeExecutable: "/home/g/.local/bin/claude"))
        let execution = try await client.exec(GuestExecRequest(computer: computer, argv: ["printf", "x"], cwd: "/home/g", timeoutSeconds: 2))
        #expect(execution == GuestExecResult(exitCode: 0, stdout: Data("x".utf8), stderr: Data()))
        let read = try await client.filesRead(computer: computer, path: "/file", offset: 0, length: 2)
        #expect(read == GuestFileReadResult(data: Data("AB".utf8), size: 2, mtimeMs: 1234, inode: 9, mode: 0o644))
        #expect(try await client.filesList(computer: computer, path: "/watch").map(\.type) == [.file, .directory])
        let write = try await client.filesWrite(.init(computer: computer, path: "/write", data: Data("AB".utf8), mode: 0o600,
                                                       replace: .ifSHA256("deadbeef")))
        #expect(write == GuestFileWriteResult(size: 2, mtimeMs: 1235, inode: 10))
        #expect(try await client.filesRemove(computer: computer, paths: ["/write"]) == ["/write"])
        #expect(try await client.sshAliasEnsure(computer: computer, installInclude: true)
                == GuestSSHAlias(alias: "ssh-computer-1", ownerName: "g", home: "/home/g"))
        try await client.sshAliasRemove(computer: computer)
        let watch = try await client.filesWatch(computer: computer, paths: ["/watch"])
        var iterator = watch.events.makeAsyncIterator()
        #expect(await iterator.next() == GuestFileEvent(subscriptionId: "guest-watch", path: "/watch/path"))
        do {
            _ = try await client.filesRead(computer: computer, path: "/missing", offset: nil, length: nil)
            Issue.record("The generated not_found error must stay a GuestClientFailure.")
        } catch let failure as GuestClientFailure {
            #expect(failure == .notFound("/missing"))
        }

        try await engine.engineDisconnect()
        let requests = await server.requestLog.requests
        #expect(requests.map(\.method) == ["engine.handshake", "guest.account", "guest.exec", "guest.exec", "guest.files.read",
                                             "guest.files.list", "guest.files.write", "guest.files.remove", "guest.sshAlias.ensure",
                                             "guest.sshAlias.remove", "guest.files.watch", "events.subscribe", "guest.files.read",
                                             "engine.disconnect"])
        let writeParams = try #require(requests.first(where: { $0.method == "guest.files.write" }))
        let writeJSON = try #require(try JSONSerialization.jsonObject(with: writeParams.params) as? [String: Any])
        #expect(writeJSON["deviceId"] as? String == "owner-1")
        #expect(writeJSON["computerId"] as? String == "computer-1")
        #expect(writeJSON["expectedSha256"] as? String == "deadbeef")
        #expect(writeJSON["replace"] as? String == "ifSha256")
        for request in requests where request.method.hasPrefix("guest.") {
            let params = try #require(try JSONSerialization.jsonObject(with: request.params) as? [String: Any])
            #expect(params["deviceId"] as? String == "owner-1")
            #expect(params["computerId"] as? String == "computer-1")
        }
    }

    @Test func guestExecGetCarriesTheOwnerDeviceId() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "controller", "name": "Fake",
                                                                     "protocol": 6, "capabilities": ["guest.*"]]])
            case "guest.exec.get":
                try? socket.write(["id": request.id, "result": ["firstRetainedSeq": 0, "output": [], "state": "running"]])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let engine = SocketEngineClient(path: server.path)
        let client = SiloGuestClient(engine: engine)

        _ = try await client.execGet(computer: GuestReference(deviceId: "owner-1", computerId: "computer-1"),
                                     jobId: "job:7", sinceSequence: 0)
        _ = try await client.execGet(computer: GuestReference(deviceId: nil, computerId: "computer-1"),
                                     jobId: "job:8", sinceSequence: 0)

        let gets = await server.requestLog.requests.filter { $0.method == "guest.exec.get" }
        #expect(gets.count == 2)
        let first = try #require(try JSONSerialization.jsonObject(with: gets[0].params) as? [String: Any])
        #expect(first["deviceId"] as? String == "owner-1")
        #expect(first["jobId"] as? String == "job:7")
        let second = try #require(try JSONSerialization.jsonObject(with: gets[1].params) as? [String: Any])
        #expect(second["deviceId"] == nil || second["deviceId"] is NSNull)
        try await engine.engineDisconnect()
    }

    @Test func execInputAndDisplayResizeParamsCarryTheOwnerDeviceId() throws {
        let input = SiloWireGuestExecInputParams(close: true, data: nil, deviceId: "owner-1", jobId: "job:7")
        let inputJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        #expect(inputJSON["deviceId"] as? String == "owner-1")
        #expect(inputJSON["jobId"] as? String == "job:7")
        #expect(SiloGeneratedMethods.guestExecInput(input).name == "guest.exec.input")
    }

    @Test func remoteErrorCodesBecomeCodedClientErrors() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "controller", "name": "Fake",
                                                                     "protocol": 6, "capabilities": []]])
            default:
                try? socket.write(["id": request.id, "error": ["code": "desktop_update_required", "message": "old"]])
            }
        }
        defer { server.stop() }
        let engine = SocketEngineClient(path: server.path)
        do {
            try await engine.operationsCancel(jobId: "job:1", deviceId: nil)
            Issue.record("The error must propagate.")
        } catch let error as EngineClientError {
            #expect(error == .coded(code: "desktop_update_required", message: "old"))
            #expect(error.errorDescription?.contains("Update desktop") == true)
        }
        try? await engine.engineDisconnect()
    }

    @Test func unixSocketHandshakesCorrelatesRequestsAndResyncsEventGaps() async throws {
        let server = try FakeSiloUnixServer()
        defer { server.stop() }
        let deliveries = SocketDeliveryRecorder()
        let client = SocketEngineClient(path: server.path, protocolRange: SiloWireProtocolRange(max: 7, min: 6))

        let subscription = try await client.eventsSubscribe(events: ["computers.*", "operations.*"]) { delivery in
            deliveries.append(delivery)
        }
        await deliveries.waitForCount(3)
        #expect(subscription != "sub-1")
        #expect(deliveries.values.count == 3)
        guard case .event(let progressSequence, .jobProgress(let progress, _)) = deliveries.values[0] else {
            Issue.record("The fake server's first event must decode as job progress.")
            return
        }
        #expect(progressSequence == 1)
        #expect(progress.source == .lifecycle)
        guard case .event(let finishedSequence, .jobFinished(let finished, _)) = deliveries.values[1] else {
            Issue.record("The fake server's second event must decode as job finished.")
            return
        }
        #expect(finishedSequence == 2)
        #expect(finished.jobId == "job:123")
        #expect(deliveries.values[2] == .reconnected)

        async let firstSnapshot = client.operationsJobGet(jobId: "job:first", deviceId: nil)
        async let secondSnapshot = client.operationsJobGet(jobId: "job:second", deviceId: nil)
        let snapshots = try await [firstSnapshot, secondSnapshot]
        #expect(snapshots.map(\.jobId) == ["job:first", "job:second"])
        #expect(snapshots.allSatisfy { $0.state == .finished && $0.outcome?.result != nil })
        try await client.operationsJobAcknowledge(jobId: "job:first", deviceId: nil)
        await client.eventsUnsubscribe(subscription: subscription)
        try await client.engineDisconnect()

        let requests = await server.requestLog.requests
        #expect(requests.map(\.method) == ["engine.handshake", "events.subscribe", "operations.job.get", "operations.job.get",
                                            "operations.job.acknowledge", "events.unsubscribe", "engine.disconnect"])
        #expect(Set(requests.map(\.id)).count == requests.count)
        #expect(requests.first?.protocolMin == 6)
        #expect(requests.first?.protocolMax == 7)
        #expect(Set(requests.filter { $0.method == "operations.job.get" }.compactMap(\.jobId)) == ["job:first", "job:second"])
        #expect(requests.first(where: { $0.method == "operations.job.acknowledge" })?.jobId == "job:first")
    }

    @Test func failedSubscriptionRestorationDoesNotPoisonTheNextReconnect() async throws {
        let scenario = ReconnectPoisonScenario()
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["computers.*"]]])
            case "events.subscribe":
                let attempt = await scenario.nextSubscriptionAttempt()
                if attempt == 1 {
                    try? socket.write(["id": request.id, "result": ["subscription": "sub-initial"]])
                    socket.close()
                } else if attempt == 2 {
                    try? socket.write(["id": request.id, "error": ["code": "internal", "message": "restore failed"]])
                } else {
                    try? socket.write(["id": request.id, "result": ["subscription": "sub-restored"]])
                }
            case "operations.job.get":
                try? socket.write(["id": request.id, "result": ["jobId": request.jobId ?? "job:123", "state": "running"]])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let deliveries = SocketDeliveryRecorder()
        _ = try await client.eventsSubscribe(events: ["computers.*"]) { deliveries.append($0) }

        await server.requestLog.waitForCount(6)
        await deliveries.waitForDelivery(.reconnected)
        let restored = try await client.operationsJobGet(jobId: "job:123", deviceId: nil)

        #expect(restored.jobId == "job:123")
        #expect(await server.requestLog.requests.filter { $0.method == "engine.handshake" }.count >= 3)
        try await client.engineDisconnect()
    }

    @Test func blockedSocketWriteDoesNotPreventDisconnectFromClosingTheTransport() async throws {
        let stopReading = FakeSiloGate()
        let server = try FakeSiloUnixServer(handler: { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["operations.*"]]])
            case "engine.disconnect":
                try? socket.write(["id": request.id, "result": NSNull()])
            default:
                break
            }
        }, readGate: { request in
            if request.method == "engine.handshake" { await stopReading.wait() }
        })
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let oversizedId = String(repeating: "x", count: 3_500_000)
        let writes = (0..<4).map { _ in
            Task { try await client.operationsCancel(jobId: oversizedId, deviceId: nil) }
        }
        await server.requestLog.waitForCount(1)
        try await Task.sleep(for: .milliseconds(150))

        let completion = AsyncCompletionFlag()
        let disconnect = Task {
            try? await client.engineDisconnect()
            await completion.markComplete()
        }
        try await Task.sleep(for: .milliseconds(250))
        let didDisconnectPromptly = await completion.isComplete
        await stopReading.release()
        server.stop()
        _ = await disconnect.result
        for write in writes { _ = await write.result }

        #expect(didDisconnectPromptly)
    }

    @Test func restoredEventsWaitForTheReconnectResyncSignal() async throws {
        let closeInitialConnection = FakeSiloGate()
        let restoreSecondSubscription = FakeSiloGate()
        let scenario = TwoSubscriptionRestoreScenario()
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["computers.*"]]])
            case "events.subscribe":
                let attempt = await scenario.nextAttempt()
                let isOperationsSubscription = request.events?.contains("operations.*") == true
                switch attempt {
                case 1:
                    try? socket.write(["id": request.id,
                                       "result": ["subscription": isOperationsSubscription ? "sub-initial-operations" : "sub-initial-computers"]])
                case 2:
                    try? socket.write(["id": request.id,
                                       "result": ["subscription": isOperationsSubscription ? "sub-initial-operations" : "sub-initial-computers"]])
                    if !isOperationsSubscription {
                        await closeInitialConnection.wait()
                        socket.close()
                    }
                case 3:
                    let subscription = isOperationsSubscription ? "sub-restored-operations" : "sub-restored-computers"
                    try? socket.write(["id": request.id, "result": ["subscription": subscription]])
                    if isOperationsSubscription {
                        try? socket.write(["event": "operations.job.progress", "subscription": subscription,
                                           "deviceId": "device-1", "seq": 1,
                                           "payload": ["jobId": "job:123", "source": "lifecycle",
                                                       "data": ["computerId": "computer-1", "action": "start", "step": "boot"]]])
                    } else {
                        try? socket.write(["event": "computers.changed", "subscription": subscription,
                                           "deviceId": "device-1", "seq": 1,
                                           "payload": ["linux": ["activities": [], "computers": [], "github": NSNull(),
                                                                    "repositoryPushOperations": [], "secrets": []]]])
                    }
                case 4:
                    await restoreSecondSubscription.wait()
                    try? socket.write(["id": request.id,
                                       "result": ["subscription": isOperationsSubscription ? "sub-restored-operations" : "sub-restored-computers"]])
                default:
                    try? socket.write(["id": request.id, "result": ["subscription": "sub-extra"]])
                }
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let first = SocketDeliveryRecorder()
        let second = SocketDeliveryRecorder()
        _ = try await client.eventsSubscribe(events: ["operations.*"]) { first.append($0) }
        _ = try await client.eventsSubscribe(events: ["computers.*"]) { second.append($0) }
        await closeInitialConnection.release()

        await server.requestLog.waitForCount(6)
        try await Task.sleep(for: .milliseconds(100))
        let eventWasDeliveredDuringRestore = [first.values, second.values].contains { values in
            values.contains { if case .event = $0 { return true }; return false }
        }
        let resyncWasSentDuringRestore = [first.values, second.values].contains { $0.contains(.reconnected) }

        await restoreSecondSubscription.release()
        await first.waitForDelivery(.reconnected)
        await second.waitForDelivery(.reconnected)
        await first.waitForCount(2)
        await second.waitForCount(2)

        #expect(!eventWasDeliveredDuringRestore)
        #expect(!resyncWasSentDuringRestore)
        let resyncIndex = first.values.firstIndex(of: .reconnected)
        let firstEventIndex = first.values.firstIndex { if case .event = $0 { return true }; return false }
        let secondResyncIndex = second.values.firstIndex(of: .reconnected)
        let secondEventIndex = second.values.firstIndex { if case .event = $0 { return true }; return false }
        #expect((resyncIndex != nil && firstEventIndex != nil && resyncIndex! < firstEventIndex!) ||
                (secondResyncIndex != nil && secondEventIndex != nil && secondResyncIndex! < secondEventIndex!))
        try await client.engineDisconnect()
    }

    @Test func callerCancellationResumesPromptlyAndIgnoresTheLateReply() async throws {
        let scenario = CancelledRequestScenario()
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["operations.*"]]])
            case "operations.job.get":
                await scenario.handle(request, socket: socket)
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let cancelledStatus = AsyncRequestStatus()
        let cancelled = Task {
            do {
                _ = try await client.operationsJobGet(jobId: "job:123", deviceId: nil)
                await cancelledStatus.finish(wasCancelled: false)
            } catch {
                await cancelledStatus.finish(wasCancelled: error is CancellationError)
            }
        }
        await server.requestLog.waitForCount(2)
        cancelled.cancel()
        // The late reply is only sent once the next request arrives: the cancelled call must finish without it.
        var watchdog = Watchdog()
        while await !cancelledStatus.didFinish, !watchdog.expired() { try await Task.sleep(for: .milliseconds(10)) }
        let resumedAsCancelled = await cancelledStatus.wasCancelled

        let second = try await client.operationsJobGet(jobId: "job:456", deviceId: nil)
        _ = await cancelled.result

        let beforeSendGate = FakeSiloGate()
        let alreadyCancelledStatus = AsyncRequestStatus()
        let alreadyCancelled = Task {
            await beforeSendGate.wait()
            do {
                try await client.operationsCancel(jobId: "job:789", deviceId: nil)
                await alreadyCancelledStatus.finish(wasCancelled: false)
            } catch {
                await alreadyCancelledStatus.finish(wasCancelled: error is CancellationError)
            }
        }
        alreadyCancelled.cancel()
        await beforeSendGate.release()
        _ = await alreadyCancelled.result
        let rejectedBeforeSend = await alreadyCancelledStatus.wasCancelled

        #expect(resumedAsCancelled)
        #expect(second.jobId == "job:456")
        #expect(rejectedBeforeSend)
        #expect(await server.requestLog.requests.filter { $0.method == "operations.cancel" }.isEmpty)
        try await client.engineDisconnect()
    }

    @Test func disconnectDuringHandshakeClosesTheOpeningSocketBeforeDomainCalls() async throws {
        let finishHandshake = FakeSiloGate()
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                await finishHandshake.wait()
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["operations.*"]]])
            case "operations.job.get":
                try? socket.write(["id": request.id, "result": ["jobId": request.jobId ?? "job:123", "state": "running"]])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let request = Task { try await client.operationsJobGet(jobId: "job:123", deviceId: nil) }
        await server.requestLog.waitForCount(1)

        let completion = AsyncCompletionFlag()
        let disconnect = Task {
            try? await client.engineDisconnect()
            await completion.markComplete()
        }
        try await Task.sleep(for: .milliseconds(100))
        let disconnectReturned = await completion.isComplete
        await finishHandshake.release()
        let domainRequestWasSent: Bool
        do {
            _ = try await request.value
            domainRequestWasSent = true
        } catch {
            domainRequestWasSent = false
        }
        _ = await disconnect.result
        let requests = await server.requestLog.requests

        #expect(disconnectReturned)
        #expect(!domainRequestWasSent)
        #expect(requests.allSatisfy { $0.method == "engine.handshake" })
    }

    @Test func unsubscribeDuringRestorationRemovesTheNewServerSubscription() async throws {
        let finishRestoration = FakeSiloGate()
        let scenario = SingleSubscriptionRestoreScenario()
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["computers.*"]]])
            case "events.subscribe":
                if await scenario.nextAttempt() == 1 {
                    try? socket.write(["id": request.id, "result": ["subscription": "sub-before-loss"]])
                    socket.close()
                } else {
                    await finishRestoration.wait()
                    try? socket.write(["id": request.id, "result": ["subscription": "sub-restored"]])
                }
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let deliveries = SocketDeliveryRecorder()
        let localId = try await client.eventsSubscribe(events: ["computers.*"]) { deliveries.append($0) }

        await server.requestLog.waitForCount(4)
        await client.eventsUnsubscribe(subscription: localId)
        await finishRestoration.release()
        await server.requestLog.waitForCount(5)
        try await Task.sleep(for: .milliseconds(100))
        let requests = await server.requestLog.requests

        #expect(requests.contains { $0.method == "events.unsubscribe" && $0.subscription == "sub-restored" })
        #expect(!deliveries.values.contains(.reconnected))
        try await client.engineDisconnect()
    }

    @Test func ignoredEventsAdvanceSequencesWithoutHidingRealGaps() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["computers.*", "operations.*"]]])
            case "events.subscribe":
                try? socket.write(["id": request.id, "result": ["subscription": "sub-sequences"]])
                try? socket.write(Self.progressEvent(subscription: "sub-sequences", sequence: 1))
                try? socket.write(["event": "computers.unexpectedChange", "subscription": "sub-sequences",
                                   "deviceId": "device-1", "seq": 2, "payload": NSNull()])
                try? socket.write(Self.finishedEvent(subscription: "sub-sequences", sequence: 3))
                try? socket.write(["event": "computers.unexpectedChange", "subscription": "sub-sequences",
                                   "deviceId": "device-1", "seq": 4, "payload": NSNull()])
                try? socket.write(Self.finishedEvent(subscription: "sub-sequences", sequence: 6))
                try? socket.write(Self.finishedEvent(subscription: "sub-sequences", sequence: 7))
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let deliveries = SocketDeliveryRecorder()
        let localId = try await client.eventsSubscribe(events: ["computers.*", "operations.*"]) { deliveries.append($0) }
        await deliveries.waitForCount(4)
        try await Task.sleep(for: .milliseconds(100))

        #expect(deliveries.values == [
            .event(sequence: 1, event: .jobProgress(OperationJobProgress(
                jobId: "job:123", source: .lifecycle,
                data: .lifecycle(LifecycleJobProgressData(computerId: "computer-1", action: "start", step: "boot"))),
                deviceId: "device-1")),
            .sequenceAdvanced(sequence: 2),
            .event(sequence: 3, event: .jobFinished(OperationJobFinished(jobId: "job:123"), deviceId: "device-1")),
            .sequenceAdvanced(sequence: 4),
            .reconnected,
            .event(sequence: 7, event: .jobFinished(OperationJobFinished(jobId: "job:123"), deviceId: "device-1")),
        ])
        await client.eventsUnsubscribe(subscription: localId)
        try await client.engineDisconnect()
    }

    @Test func terminalResultsPreserveExplicitNullOverTheSocket() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                     "protocol": 6, "capabilities": ["operations.*"]]])
            case "events.subscribe":
                try? socket.write(["id": request.id, "result": ["subscription": "sub-null"]])
                try? socket.write(["event": "operations.job.finished", "subscription": "sub-null",
                                   "deviceId": "device-1", "seq": 1,
                                   "payload": ["jobId": "job:123", "result": NSNull()]])
            case "operations.job.get":
                try? socket.write(["id": request.id,
                                   "result": ["jobId": "job:123", "state": "finished",
                                               "outcome": ["result": NSNull()]]])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)
        let deliveries = SocketDeliveryRecorder()
        _ = try await client.eventsSubscribe(events: ["operations.*"]) { deliveries.append($0) }
        await deliveries.waitForCount(1)
        let snapshot = try await client.operationsJobGet(jobId: "job:123", deviceId: nil)
        let eventResult: SiloJSONValue?
        if let first = deliveries.values.first, case .event(_, .jobFinished(let finished, _)) = first {
            eventResult = finished.result
        } else {
            eventResult = nil
        }
        let explicitFinished = try JSONDecoder().decode(SiloWireJobFinished.self,
                                                        from: Data(#"{"jobId":"job:123","result":null}"#.utf8))
        let omittedFinished = try JSONDecoder().decode(SiloWireJobFinished.self,
                                                      from: Data(#"{"jobId":"job:123"}"#.utf8))
        let explicitOutcome = try JSONDecoder().decode(SiloWireJobOutcome.self,
                                                       from: Data(#"{"result":null}"#.utf8))
        let omittedOutcome = try JSONDecoder().decode(SiloWireJobOutcome.self, from: Data("{}".utf8))

        #expect(eventResult == .null)
        #expect(snapshot.outcome?.result == .null)
        #expect(explicitFinished.result == .null)
        #expect(omittedFinished.result == nil)
        #expect(explicitOutcome.result == .null)
        #expect(omittedOutcome.result == nil)
        try await client.engineDisconnect()
    }

    @Test func fragmentedFrameHeadersAndBodiesAreReassembled() async throws {
        let server = try FakeSiloUnixServer { request, socket in
            switch request.method {
            case "engine.handshake":
                try? socket.writeFragmented(["id": request.id,
                                             "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                         "protocol": 6, "capabilities": ["operations.*"]]],
                                            chunks: [1, 1, 1, 1, 2, 1, 3])
            case "operations.job.get":
                try? socket.writeFragmented(["id": request.id,
                                             "result": ["jobId": request.jobId ?? "job:123", "state": "finished"]],
                                            chunks: [2, 1, 1, 3, 2, 1])
            default:
                try? socket.write(["id": request.id, "result": NSNull()])
            }
        }
        defer { server.stop() }
        let client = SocketEngineClient(path: server.path)

        let snapshot = try await client.operationsJobGet(jobId: "job:123", deviceId: nil)

        #expect(snapshot.jobId == "job:123")
        #expect(snapshot.state == .finished)
        try await client.engineDisconnect()
    }

    nonisolated private static func progressEvent(subscription: String, sequence: Int) -> [String: Any] {
        ["event": "operations.job.progress", "subscription": subscription, "deviceId": "device-1", "seq": sequence,
         "payload": ["jobId": "job:123", "source": "lifecycle",
                     "data": ["computerId": "computer-1", "action": "start", "step": "boot"]]]
    }

    nonisolated private static func finishedEvent(subscription: String, sequence: Int) -> [String: Any] {
        ["event": "operations.job.finished", "subscription": subscription, "deviceId": "device-1", "seq": sequence,
         "payload": ["jobId": "job:123"]]
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SiloAPI/\(name)")
        return try Data(contentsOf: url)
    }
}

@MainActor
private final class SocketDeliveryRecorder {
    private(set) var values: [EngineEventDelivery] = []

    func append(_ delivery: EngineEventDelivery) { values.append(delivery) }

    func waitForCount(_ count: Int, attempts: Int = 300) async {
        for _ in 0..<attempts {
            if values.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForDelivery(_ expected: EngineEventDelivery) async {
        for _ in 0..<300 {
            if values.contains(expected) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ReconnectPoisonScenario {
    private var subscriptionAttempt = 0
    func nextSubscriptionAttempt() -> Int {
        subscriptionAttempt += 1
        return subscriptionAttempt
    }
}

private actor TwoSubscriptionRestoreScenario {
    private var count = 0
    func nextAttempt() -> Int {
        count += 1
        return count
    }
}

private actor SingleSubscriptionRestoreScenario {
    private var count = 0
    func nextAttempt() -> Int {
        count += 1
        return count
    }
}

private actor AsyncCompletionFlag {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

private actor AsyncRequestStatus {
    private(set) var didFinish = false
    private(set) var wasCancelled = false
    func finish(wasCancelled: Bool) {
        self.wasCancelled = wasCancelled
        didFinish = true
    }
}

private actor CancelledRequestScenario {
    private var delayed: (FakeSiloRequest, FakeSiloSocket)?

    func handle(_ request: FakeSiloRequest, socket: FakeSiloSocket) {
        guard let previous = delayed else {
            delayed = (request, socket)
            return
        }
        delayed = nil
        try? previous.1.write(["id": previous.0.id,
                               "result": ["jobId": previous.0.jobId ?? "job:123", "state": "running"]])
        try? socket.write(["id": request.id,
                           "result": ["jobId": request.jobId ?? "job:456", "state": "finished"]])
    }
}
