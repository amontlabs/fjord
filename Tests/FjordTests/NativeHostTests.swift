import Darwin
import Foundation
import Testing
@testable import Fjord

@Suite struct NativeHostTests {
    private func pipe2() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        return (fds[0], fds[1])
    }

    private func temporaryFolder() -> URL {
        let url = URL(fileURLWithPath: "/tmp/fjnh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The engine's sockets are non-blocking: a line longer than the socket's buffer goes out whole once the reader drains it.
    @Test func aLongLineReachesANonBlockingSocketWhole() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK)
        let data = Data(repeating: 0x61, count: 1 << 20)
        var received = 0
        let reader = Thread {
            Thread.sleep(forTimeInterval: 0.2)  // the writer fills the buffer first
            var buffer = [UInt8](repeating: 0, count: 65536)
            while received < data.count {
                let n = read(pair[1], &buffer, buffer.count)
                if n <= 0 { break }
                received += n
            }
        }
        reader.start()
        #expect(NativeHost.writeAll(pair[0], data))
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        #expect(received == data.count)
    }

    @Test func framingRoundTrips() {
        let body = Data(#"{"kind":"snapshot"}"#.utf8)
        let framed = NativeHost.frame(body)
        #expect(framed.count == 4 + body.count)
        #expect(framed.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == UInt32(body.count))
        let (r, w) = pipe2()
        #expect(NativeHost.writeAll(w, framed))
        close(w)
        #expect(NativeHost.readFrame(r) == body)
        #expect(NativeHost.readFrame(r) == nil)  // closed
        close(r)
    }

    @Test func truncatedFrameEnds() {
        let (r, w) = pipe2()
        _ = NativeHost.writeAll(w, NativeHost.frame(Data("hello".utf8)).dropLast(2))
        close(w)
        #expect(NativeHost.readFrame(r) == nil)
        close(r)
    }

    @Test func linesAreCompactJSONAndNonJSONIsDropped() {
        #expect(NativeHost.line(fromFrame: Data(#"{ "a": 1,  "b": "x/y" }"#.utf8)) == Data("{\"a\":1,\"b\":\"x/y\"}\n".utf8))
        #expect(NativeHost.line(fromFrame: Data("not json".utf8)) == nil)
    }

    @Test func socketPathHonoursTheEnvironment() {
        #expect(NativeHost.socketPath(environment: ["FJORD_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(NativeHost.socketPath(environment: [:]).hasSuffix("/router.sock"))
    }

    @Test func manifestNamesTheLauncherAndTheExtension() throws {
        let launcher = URL(fileURLWithPath: "/x/Fjord/native-host")
        let json = try #require(JSONSerialization.jsonObject(with: NativeHostManifest.manifestJSON(launcher: launcher)) as? [String: Any])
        #expect(json["name"] as? String == "dev.fjord.router")
        #expect(json["path"] as? String == "/x/Fjord/native-host")
        #expect(json["type"] as? String == "stdio")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://\(NativeHost.extensionID)/"])
    }

    @Test func installWritesOnlyFromABundleAndOnlyOnChange() throws {
        let home = temporaryFolder(), support = home.appendingPathComponent("support")
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = "/Apps/Fjord.app/Contents/MacOS/Fjord"
        #expect(!NativeHostManifest.install(bundlePath: "/repo/.build/debug", executable: exe, home: home, support: support))
        #expect(!FileManager.default.fileExists(atPath: NativeHostManifest.manifestURL(home: home).path))

        #expect(NativeHostManifest.install(bundlePath: "/Apps/Fjord.app", executable: exe, home: home, support: support))
        let launcher = try String(contentsOf: NativeHostManifest.launcherURL(support: support), encoding: .utf8)
        #expect(launcher == "#!/bin/sh\nexec \"\(exe)\" --native-host\n")
        #expect(FileManager.default.isExecutableFile(atPath: NativeHostManifest.launcherURL(support: support).path))
        #expect(!NativeHostManifest.install(bundlePath: "/Apps/Fjord.app", executable: exe, home: home, support: support))
        #expect(NativeHostManifest.install(bundlePath: "/Other/Fjord.app", executable: "/Other/Fjord.app/Contents/MacOS/Fjord", home: home, support: support))
    }

    /// The built binary against a socket of ours: Chrome's frame arrives as a line, and a line comes back as a frame.
    @Test func binaryRelaysBothWays() throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/Fjord")
        let exe = ProcessInfo.processInfo.environment["FJORD_TEST_BINARY"] ?? binary.path
        guard FileManager.default.isExecutableFile(atPath: exe) else { return }
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("r.sock").path

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0 && listen(server, 1) == 0)
        defer { close(server) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["--native-host", "chrome-extension://abc/"]
        process.environment = ["FJORD_SOCKET": path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let client = accept(server, nil, nil)
        #expect(client >= 0)
        defer { close(client) }
        // On connecting, the host asks the page for a snapshot.
        #expect(NativeHost.readFrame(stdout.fileHandleForReading.fileDescriptor) == Data(#"{"kind":"snapshot"}"#.utf8))

        stdin.fileHandleForWriting.write(NativeHost.frame(Data(#"{"kind":"hello"}"#.utf8)))
        #expect(NativeHost.readLine(client) == #"{"kind":"hello"}"#)

        _ = NativeHost.writeAll(client, Data("{\"kind\":\"type\"}\n".utf8))
        #expect(NativeHost.readFrame(stdout.fileHandleForReading.fileDescriptor) == Data(#"{"kind":"type"}"#.utf8))

        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private extension NativeHost {
    static func readLine(_ descriptor: Int32) -> String? {
        var line = Data()
        var byte: UInt8 = 0
        while read(descriptor, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }
}
