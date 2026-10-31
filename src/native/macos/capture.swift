/** Native macOS bridge for the editor's line-oriented capture helper protocol. */
import AppKit
import ScreenCaptureKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/** Validated capture settings shared by selection, screenshots, and recording. */
struct CaptureOptions {
    let recording: Bool
    let source: String
    let delay: Int
    let cursor: Bool

    /** Rejects malformed helper requests before displaying native UI. */
    init(_ args: [String]) throws {
        guard args.count == 5, ["screenshot", "record"].contains(args[1]),
              ["screen", "window", "area"].contains(args[2]),
              let delay = Int(args[3]), (0...3600).contains(delay),
              ["cursor", "hidden"].contains(args[4]) else {
            throw NSError(domain: "Capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid capture arguments"])
        }
        recording = args[1] == "record"
        source = args[2]
        self.delay = delay
        cursor = args[4] == "cursor"
    }
}

/** Converts a bottom-left drag into a bounded top-left capture rectangle. */
func captureRectangle(_ first: CGPoint, _ last: CGPoint, in bounds: CGRect) -> CGRect {
    let drag = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(first.x - last.x), height: abs(first.y - last.y))
        .intersection(bounds)
    guard !drag.isNull else { return .zero }
    return CGRect(x: drag.minX, y: bounds.height - drag.maxY,
                  width: drag.width, height: drag.height)
}

/** Allows a borderless capture overlay to receive keyboard cancellation. */
final class RegionWindow: NSWindow {
    /** Accepts keyboard focus while the user selects an area. */
    override var canBecomeKey: Bool { true }
}

/** Transparent selection overlay; Escape cancels without capturing anything. */
final class RegionView: NSView {
    var origin: CGPoint?
    var current = CGPoint.zero
    var completion: ((CGRect?) -> Void)?
    /** Receives Escape while choosing an area. */
    override var acceptsFirstResponder: Bool { true }

    /** Draws a dimmed desktop with an outlined, undimmed selected region. */
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let origin else { return }
        let selection = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                               width: abs(origin.x - current.x), height: abs(origin.y - current.y))
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.systemTeal.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()
    }
    /** Begins a drag in overlay-local coordinates. */
    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = origin!
        needsDisplay = true
    }
    /** Updates the visible selection while dragging. */
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    /** Accepts only a nonempty region, with coordinates relative to the display. */
    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        let rectangle = captureRectangle(origin, convert(event.locationInWindow, from: nil), in: bounds)
        if rectangle.width >= 2 && rectangle.height >= 2 { completion?(rectangle) }
    }
    /** Cancels source selection when Escape is pressed. */
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion?(nil) }
    }
}

/** Owns the native picker, capture stream, temporary output, and signal lifecycle. */
@MainActor
final class CaptureController: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    let options: CaptureOptions
    var signals: [DispatchSourceSignal] = []
    var stream: SCStream?
    var recording: SCRecordingOutput?
    var overlay: NSWindow?
    var encoder: Process?
    var stage: URL?
    var output: URL?
    var started = false
    var stopping = false
    var cancelled = false
    var selected = false

    /** Retains validated arguments for one capture session. */
    init(options: CaptureOptions) { self.options = options }

    /** Flushes protocol messages immediately so the Sun UI can update. */
    func report(_ message: String) {
        print(message)
        fflush(stdout)
    }

    /** Installs stop/cancel handlers and presents the requested system picker. */
    func begin() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if number == SIGINT && self.started { self.stop() } else { self.cancel() }
            }
            source.resume()
            signals.append(source)
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = options.source == "window" ? .singleWindow : .singleDisplay
        configuration.allowsChangingSelectedContent = false
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        report("Choose a source in the macOS sharing picker…")
        picker.present(using: options.source == "window" ? .window : .display)
    }

    /** Discards a cancelled picker session. */
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancel() }
    }

    /** Reports permission and picker failures through the existing helper protocol. */
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    /** Starts selection or countdown once the system has authorized a source. */
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.select(filter) }
    }

    /** Applies an authorized selection on the UI thread. */
    func select(_ filter: SCContentFilter) {
        guard !selected && !cancelled else { return }
        selected = true
        if options.source == "area" {
            guard let display = filter.includedDisplays.first,
                  let screen = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                  }) else {
                fail(NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected display is no longer available"]))
                return
            }
            let window = RegionWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.completion = { [weak self] rectangle in
                guard let self else { return }
                self.overlay?.orderOut(nil)
                self.overlay = nil
                guard let rectangle else { self.cancel(); return }
                self.schedule(filter, region: rectangle)
            }
            window.contentView = view
            overlay = window
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            report("Drag to select an area. Press Escape to cancel.")
        } else {
            schedule(filter, region: nil)
        }
    }

    /** Counts down after source selection, then captures on the main actor. */
    func schedule(_ filter: SCContentFilter, region: CGRect?) {
        Task { @MainActor in
            do {
                for remaining in stride(from: options.delay, to: 0, by: -1) {
                    if cancelled { return }
                    report("Starting in \(remaining)…")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // Let the picker and selection overlay disappear before capture.
                try await Task.sleep(nanoseconds: 250_000_000)
                if !cancelled { try await capture(filter, region: region) }
            } catch { fail(error) }
        }
    }

    /** Captures PNG or starts a silent recording with matching cursor and crop settings. */
    func capture(_ filter: SCContentFilter, region: CGRect?) async throws {
        let manager = FileManager.default
        let directory = manager.urls(for: options.recording ? .moviesDirectory : .picturesDirectory,
                                     in: .userDomainMask)[0].appendingPathComponent("Sun Captures", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let temporary = directory.appendingPathComponent(".capture-\(identifier)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        stage = temporary
        output = directory.appendingPathComponent("Capture-\(identifier).\(options.recording ? "webm" : "png")")
        let configuration = SCStreamConfiguration()
        let size = region?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int(size.width * scale) / 2 * 2)
        configuration.height = max(2, Int(size.height * scale) / 2 * 2)
        configuration.showsCursor = options.cursor
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if let region { configuration.sourceRect = region }
        if !options.recording {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if cancelled { return }
            let png = temporary.appendingPathComponent("capture.png")
            guard let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create screenshot"])
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot save screenshot"])
            }
            try publish(png)
            return
        }
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = temporary.appendingPathComponent("capture.mp4")
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.recording = recording
        self.stream = stream
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
    }

    /** Enables Stop only once the native recording has actually started. */
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.started = true
            self.report("Recording…")
        }
    }

    /** Finishes the native file before converting or publishing it. */
    func stop() {
        guard !stopping, let stream else { return }
        stopping = true
        report("Saving recording…")
        Task { @MainActor in
            do { try await stream.stopCapture() } catch { fail(error) }
        }
    }

    /** Converts the completed native file to the editor's WebM format without blocking UI. */
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.encode() }
    }

    /** Encodes and publishes a fully finalized recording. */
    func encode() {
        if cancelled { finish(0); return }
        guard let stage else { return }
        let destination = stage.appendingPathComponent("capture.webm")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
                             "-i", stage.appendingPathComponent("capture.mp4").path,
                             "-an", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "6",
                             "-threads", "2", "-pix_fmt", "yuv420p", destination.path]
        process.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self else { return }
                if self.cancelled { self.finish(0); return }
                do {
                    guard child.terminationStatus == 0 else {
                        throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "FFmpeg could not encode the recording"])
                    }
                    try self.publish(destination)
                } catch { self.fail(error) }
            }
        }
        encoder = process
        do { try process.run() } catch { fail(error) }
    }

    /** Propagates recording errors without publishing partial media. */
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    /** Handles source disappearance or permission revocation. */
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    /** Atomically moves a finished capture to its unique destination. */
    func publish(_ file: URL) throws {
        guard !cancelled, let output else { finish(0); return }
        try FileManager.default.moveItem(at: file, to: output)
        report("Saved: \(output.path)")
        finish(0)
    }

    /** Cancels selection, countdown, recording, or encoding and removes partial files. */
    func cancel() {
        cancelled = true
        report("Capture cancelled.")
        overlay?.orderOut(nil)
        if let encoder, encoder.isRunning { encoder.terminate(); return }
        if stream != nil && started && !stopping { stop(); return }
        finish(0)
    }

    /** Gives permission failures an actionable message without bypassing system consent. */
    func fail(_ error: Error) {
        report("Capture failed: \(error.localizedDescription). Check macOS System Settings > Privacy & Security > Screen & System Audio Recording.")
        finish(1)
    }

    /** Releases owned temporary output and ends the helper process. */
    func finish(_ status: Int32) {
        SCContentSharingPicker.shared.isActive = false
        if let stage { try? FileManager.default.removeItem(at: stage) }
        exit(status)
    }
}

/** Runs deterministic argument/geometry checks without requesting screen access. */
func selfTest() throws {
    _ = try CaptureOptions(["capture", "record", "area", "3600", "hidden"])
    for arguments in [["capture"], ["capture", "record", "screen", "-1", "cursor"],
                      ["capture", "record", "screen", "0", "invalid"]] {
        do { _ = try CaptureOptions(arguments); fatalError("Invalid arguments accepted") }
        catch { }
    }
    let rect = captureRectangle(CGPoint(x: 80, y: 70), CGPoint(x: 20, y: 10),
                                in: CGRect(x: 0, y: 0, width: 100, height: 100))
    precondition(rect == CGRect(x: 20, y: 30, width: 60, height: 60))
    print("PASS macOS capture arguments and region coordinates")
}

/** Starts AppKit's event loop so the system picker and capture callbacks stay responsive. */
@main
struct CaptureMain {
    /** Validates requests before creating a capture session. */
    @MainActor static func main() {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
                try selfTest()
                return
            }
            let options = try CaptureOptions(CommandLine.arguments)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let controller = CaptureController(options: options)
            controller.begin()
            withExtendedLifetime(controller) { app.run() }
        } catch {
            print("Capture failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
