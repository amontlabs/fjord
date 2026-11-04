import Darwin
import Foundation

/// Chrome's native messaging host for the Router's extension: `Fjord --native-host`. Chrome's length-prefixed JSON on
/// stdin and stdout on one side, JSON lines on the Router's Unix socket on the other. Chrome starts it and closes stdin
/// to end it; it keeps nothing but the line it is relaying. A port of poc/router/native_host.py. No app, no Dock icon,
/// no Keychain: `main.swift` runs it before any AppKit setup.
enum NativeHost {
    /// Chrome refuses a message from a host larger than this.
    static let limit = 1024 * 1024
    /// The name Chrome knows the host by, and the manifest's file name.
    static let name = "dev.fjord.router"
    /// The extension's fixed id (its manifest's `key`, in poc/router/extension).
    static let extensionID = "fphdgojechminkmbgkbipmfmlnnemejd"

    /// The Router's socket: `FJORD_SOCKET`, else `router.sock` in Fjord's folder.
    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["FJORD_SOCKET"], !path.isEmpty { return path }
        return AppIdentity.supportDirectory().appendingPathComponent("router.sock").path
    }

    // MARK: Framing

    /// A message in Chrome's framing: its length in native byte order (4 bytes), then the body.
    static func frame(_ body: Data) -> Data {
        var length = UInt32(truncatingIfNeeded: body.count)
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    /// The next message from `descriptor`, or nil when it was closed (or ended inside a message).
    static func readFrame(_ descriptor: Int32) -> Data? {
        guard let header = readExactly(descriptor, 4) else { return nil }
        let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return readExactly(descriptor, Int(count))
    }

    static func readExactly(_ descriptor: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var have = 0
        while have < count {
            let got = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + have, count - have) }
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return nil }
            have += got
        }
        return data
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { bytes in
            while sent < data.count {
                let wrote = write(descriptor, bytes.baseAddress! + sent, data.count - sent)
                if wrote < 0 && errno == EINTR { continue }
                if wrote <= 0 { return false }
                sent += wrote
            }
            return true
        }
    }

    /// Chrome's frame as one JSON line for the socket; nil for a frame that isn't JSON.
    static func line(fromFrame body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return nil }
        return data + Data([0x0A])
    }

    // MARK: Relay

    private final class Link: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32 = -1
        private let out: Int32
        private let outLock = NSLock()

        init(out: Int32) { self.out = out }

        func set(_ new: Int32) { lock.lock(); descriptor = new; lock.unlock() }

        /// To the socket; dropped when the Router isn't up (the page sends a snapshot when it is).
        func send(_ line: Data) {
            lock.lock(); defer { lock.unlock() }
            if descriptor >= 0 { _ = writeAll(descriptor, line) }
        }

        func toChrome(_ body: Data) {
            outLock.lock(); defer { outLock.unlock() }
            _ = writeAll(out, frame(body))
        }
    }

    /// Relays until Chrome closes `input`. `path` is the Router's socket.
    static func run(path: String = socketPath(), input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        signal(SIGPIPE, SIG_IGN)
        let link = Link(out: output)
        let thread = Thread { serve(path: path, link: link) }
        thread.stackSize = 1 << 20
        thread.start()
        while let body = readFrame(input) {
            if let line = line(fromFrame: body) {
                link.send(line)
            } else {
                FileHandle.standardError.write(Data("native_host: dropped a frame that is not JSON\n".utf8))
            }
        }
    }

    /// Connects to the socket, and again when it goes away; waits on its folder while it isn't there.
    private static func serve(path: String, link: Link) {
        let folder = (path as NSString).deletingLastPathComponent
        while true {
            let watch = DirectoryWatch(folder)  // armed before the attempt, so a socket that appears during it is not missed
            let descriptor = connect(path)
            guard descriptor >= 0 else {
                watch.wait()
                continue
            }
            link.set(descriptor)
            // The Router has just started or come back: have the page say what it shows.
            link.toChrome(Data(#"{"kind":"snapshot"}"#.utf8))
            relayLines(from: descriptor, to: link)
            link.set(-1)
            close(descriptor)
        }
    }

    /// The Router's lines become Chrome's frames. A line Chrome would refuse for its size is dropped.
    private static func relayLines(from descriptor: Int32, to link: Link) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let got = read(descriptor, &chunk, chunk.count)
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return }
            pending.append(chunk, count: got)
            while let newline = pending.firstIndex(of: 0x0A) {
                let raw = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                let text = raw.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
                guard !text.isEmpty else { continue }
                let trimmed = Data(text.reversed().drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }.reversed())
                if trimmed.count > limit {
                    FileHandle.standardError.write(Data("native_host: dropped a line over 1 MB\n".utf8))
                    continue
                }
                link.toChrome(trimmed)
            }
        }
    }

    private static func connect(_ path: String) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(descriptor); return -1 }
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    /// Entry point of `--native-host`: runs until Chrome closes stdin, then exits.
    static func main() -> Never {
        run()
        exit(0)
    }
}

/// A kqueue wait for a folder to change (poc/router/kwatch.py): armed before a pass and waited on after it. A folder that is
/// missing, or a watch that can't be set, makes the wait also wake every 30 seconds, for that case only.
final class DirectoryWatch {
    static let slow: TimeInterval = 30
    private let queue = kqueue()
    private var folder: Int32 = -1
    private var isSlow = false

    init(_ path: String) {
        folder = open(path, O_RDONLY)
        guard folder >= 0, queue >= 0 else { isSlow = true; return }
        var event = kevent(ident: UInt(folder), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_EXTEND), data: 0, udata: nil)
        if kevent(queue, &event, 1, nil, 0, nil) < 0 { isSlow = true }
    }

    func wait() {
        guard queue >= 0 else { sleep(UInt32(Self.slow)); return }
        var out = kevent()
        var timeout = timespec(tv_sec: Int(Self.slow), tv_nsec: 0)
        _ = isSlow ? kevent(queue, nil, 0, &out, 1, &timeout) : kevent(queue, nil, 0, &out, 1, nil)
    }

    deinit {
        if folder >= 0 { close(folder) }
        if queue >= 0 { close(queue) }
    }
}
