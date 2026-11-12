import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// Dev entry for filming the app's window: `--record <out.mov>` (with `--window`) records the app's own window, and only
// it, to a .mov; `--record-seconds N` ends the recording (and the app) after N seconds, else the demo ends it with
// `WindowRecorder.finish()`. `scripts/record-window.sh` wraps this and cuts the mp4s.
//
// The capture is `SCContentFilter(desktopIndependentWindow:)`: the window's own pixels, whatever is in front of it or
// around it, never a screen rectangle, so no other window can come into the picture. It needs the Screen Recording
// permission of the app the binary runs under (see `WindowRecorder.Failure.permission`).

@MainActor
final class WindowRecorder {
    /// Posted (on the main thread) once frames are being written: a demo script that should be filmed from its first move
    /// starts on it.
    static let startedNotification = Notification.Name("FjordWindowRecorderStarted")
    /// Posted by `finish()`: the recording stops, the file is closed, the app quits.
    static let finishNotification = Notification.Name("FjordWindowRecorderFinish")

    enum Failure: LocalizedError {
        case permission
        case windowNotFound
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .permission:
                return """
                Screen Recording is not allowed for the app this binary runs under. In System Settings > Privacy & Security > \
                Screen & System Audio Recording, allow the app that launched Fjord (Terminal, iTerm, Claude, the editor…), \
                quit it fully and open it again, then rerun. Nothing outside Fjord's own window is recorded.
                """
            case .windowNotFound:
                return "ScreenCaptureKit does not list the window (it must be on screen, not minimized)."
            case .writer(let why):
                return "The movie file could not be written: \(why)"
            }
        }
    }

    private var stream: SCStream?
    private var sink: FrameSink?
    private(set) var isRecording = false

    /// The recorder `--record` makes; `finish()` and the finish notification stop it.
    private(set) static var current: WindowRecorder?

    /// Records `window` (and only it) at 2x and 60 fps to `url` (replaced if it exists), until `stop()`.
    /// `NSApplication.shared` must have been initialised.
    func start(window: NSWindow, to url: URL) async throws {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
        let scWindow = try await Self.shareableWindow(number: window.windowNumber)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        // 2x the window's size in points, whatever the screen's own scale, so a recording looks the same everywhere.
        let width = Self.even(scWindow.frame.width * 2)
        let height = Self.even(scWindow.frame.height * 2)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        // Behind the window's rounded corners: the page's ground, not black wedges.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            configuration.backgroundColor = NSColor(CDS.Surface.s1).cgColor
        }
        // The window's top-left corner as it is before it is shared (macOS draws a sharing badge over the traffic lights
        // of a window being captured): the cut lays it back over the film.
        Self.writeCornerPatch(of: window, beside: url)

        let sink = try FrameSink(url: url, width: width, height: height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        do {
            try await stream.startCapture()
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw Failure.permission }
            throw error
        }
        self.sink = sink
        self.stream = stream
        isRecording = true
        NotificationCenter.default.post(name: Self.startedNotification, object: nil)
    }

    /// Ends the capture and closes the file; the file is complete when this returns.
    func stop() async {
        guard isRecording, let stream, let sink else { return }
        isRecording = false
        try? await stream.stopCapture()
        await sink.finish()
        self.stream = nil
        self.sink = nil
    }

    private static func even(_ points: CGFloat) -> Int { max(2, Int(points.rounded()) / 2 * 2) }

    /// The corner the sharing badge covers, in points.
    static let corner = CGSize(width: 150, height: 44)

    /// `<movie>.corner.png`: the window's top-left corner at the film's 2x, from the window server's picture of the app's
    /// own window (no permission needed, and no badge: nothing is shared yet). `scripts/record-window.sh` overlays it.
    private static func writeCornerPatch(of window: NSWindow, beside url: URL) {
        guard window.windowNumber > 0,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
              image.width > 0 else { return }
        let scale = CGFloat(image.width) / window.frame.width
        guard let cut = image.cropping(to: CGRect(x: 0, y: 0, width: corner.width * scale, height: corner.height * scale).integral),
              let context = CGContext(data: nil, width: Int(corner.width * 2), height: Int(corner.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: corner.width * 2, height: corner.height * 2))
        guard let patch = context.makeImage() else { return }
        let png = NSBitmapImageRep(cgImage: patch).representation(using: .png, properties: [:])
        try? png?.write(to: url.appendingPathExtension("corner.png"))
    }

    /// The window can take a moment to show up in the window server's list after it is ordered in.
    private static func shareableWindow(number: Int) async throws -> SCWindow {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let found = content.windows.first(where: { Int($0.windowID) == number }) { return found }
            if attempt < 19 { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        throw Failure.windowNotFound
    }

    // MARK: Launch flags

    /// The `--record` target, if the launch has one.
    static var requestedURL: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }

    static var requestedSeconds: Double? {
        guard let i = CommandLine.arguments.firstIndex(of: "--record-seconds"), i + 1 < CommandLine.arguments.count else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }

    /// Whether the launch asks for a recording: a demo script waits for `startedNotification` then, and starts at once
    /// otherwise.
    static var isRequested: Bool { requestedURL != nil }

    /// Stops the recording, closes the file and quits the app. The demo calls it when its script is over.
    static func finish() {
        NotificationCenter.default.post(name: finishNotification, object: nil)
    }

    /// `--record <out.mov> [--record-seconds N]`: records `window` once it is on screen and the window's motion is over.
    /// Does nothing without the flag. A failure (the permission above all) is printed and ends the app with status 1.
    static func runIfRequested(window: @escaping () -> NSWindow?) {
        guard let url = requestedURL else { return }
        let recorder = WindowRecorder()
        current = recorder
        var finishing = false
        let end = {
            guard !finishing else { return }
            finishing = true
            Task { @MainActor in
                await recorder.stop()
                FileHandle.standardError.write(Data("Recorded \(url.path)\n".utf8))
                NSApp.terminate(nil)
            }
        }
        NotificationCenter.default.addObserver(forName: finishNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        }
        // The window is on screen once the current run-loop pass is over, and still while its opening morph plays.
        DispatchQueue.main.async {
            MotionGate.whenStill {
                Task { @MainActor in
                    guard let window = window() else {
                        fail(Failure.windowNotFound)
                        return
                    }
                    do {
                        try await recorder.start(window: window, to: url)
                    } catch {
                        fail(error)
                        return
                    }
                    if let seconds = requestedSeconds {
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        end()
                    }
                }
            }
        }
    }

    private static func fail(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        FileHandle.standardError.write(Data("record: \(text)\n".utf8))
        exit(1)
    }
}

/// Writes the stream's frames to the movie, on its own queue.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "fjord.window-recorder")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var lastBuffer: CVPixelBuffer?

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw WindowRecorder.Failure.writer("the video input is refused") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WindowRecorder.Failure.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        lastBuffer = pixels
        if input.isReadyForMoreMediaData { adaptor.append(pixels, withPresentationTime: time) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("record: the capture stopped: \(error.localizedDescription)\n".utf8))
    }

    /// ScreenCaptureKit also sends status-only buffers (idle, blank, suspended): only `complete` ones carry a picture.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Frames come only when the picture changes, so the last one is held to the stop's time: the movie lasts as long as
    /// the recording did.
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard started else {
                    writer.cancelWriting()
                    done.resume()
                    return
                }
                let end = CMClockGetTime(CMClockGetHostTimeClock())
                if let lastBuffer, input.isReadyForMoreMediaData { adaptor.append(lastBuffer, withPresentationTime: end) }
                input.markAsFinished()
                writer.endSession(atSourceTime: end)
                writer.finishWriting {
                    if self.writer.status == .failed {
                        FileHandle.standardError.write(Data("record: \(self.writer.error?.localizedDescription ?? "write failed")\n".utf8))
                    }
                    done.resume()
                }
            }
        }
    }
}
