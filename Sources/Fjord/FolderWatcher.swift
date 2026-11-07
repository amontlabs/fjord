import CoreServices
import Foundation

/// FSEvents on a few folders (recursive), coalesced. Events arrive on a utility queue, where `relevant` filters
/// them; only a relevant batch hops to the main queue to call `handler`.
final class FolderWatcher {
    /// What the stream's callback holds (retained by the stream itself, so a callback in flight never outlives it).
    private final class Callbacks {
        let relevant: (([String]) -> Bool)?
        let handler: () -> Void
        init(relevant: (([String]) -> Bool)?, handler: @escaping () -> Void) {
            self.relevant = relevant
            self.handler = handler
        }
    }

    private static let queue = DispatchQueue(label: "fjord.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(_ urls: [URL], latency: TimeInterval = 0.2, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: nil, handler: handler))
    }

    /// Per-file events: `relevant` gets the paths that changed (off the main thread), so the handler only runs for
    /// the ones that matter.
    init(_ urls: [URL], latency: TimeInterval = 0.2, relevant: @escaping ([String]) -> Bool, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: relevant, handler: handler))
    }

    private func start(_ urls: [URL], latency: TimeInterval, _ callbacks: Callbacks) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callbacks).toOpaque(),
                                           retain: nil, release: { info in
            if let info { Unmanaged<Callbacks>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let callbacks = Unmanaged<Callbacks>.fromOpaque(info).takeUnretainedValue()
            if let relevant = callbacks.relevant,
               !relevant(unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []) { return }
            DispatchQueue.main.async { callbacks.handler() }
        }
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        if callbacks.relevant != nil {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, urls.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged.passUnretained(callbacks).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
