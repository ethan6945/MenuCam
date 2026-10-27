import AppKit
import SwiftUI
import Combine
import AVFoundation
import IOKit.pwr_mgt

final class Recorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published var phase = "Idle"
    @Published var busy = false
    @Published var recording = false
    @Published var elapsed = 0
    @Published var message = ""
    @Published var folder: URL
    @Published var quality: String { didSet { UserDefaults.standard.set(quality, forKey: "quality") } }
    @Published var iconName: String { didSet {
        UserDefaults.standard.set(iconName, forKey: "iconName")
        onChange?()
    } }
    @Published var cameraNote = ""
    @Published var audioActive = false
    @Published var lastFile: URL?
    func menuImage() -> NSImage? {
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "MenuCam") ?? NSImage(systemSymbolName: "link", accessibilityDescription: "MenuCam")
        image?.size = NSSize(width: 17, height: 17)
        image?.isTemplate = true
        return image
    }
    @Published var quietNote = ""
    let remote = RemoteServer()
    private let quiet = QuietMode()
    private let blackout = BlackoutMode()
    private let idlePhoto = IdlePhotoCapture()
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "MenuCam.capture")
    private lazy var audio = AudioCapture(queue: queue)
    private lazy var adaptiveWriter: AdaptiveWriter = {
        let writer = AdaptiveWriter(queue: queue)
        writer.onStart = { [weak self] url in self?.didStart(url) }
        writer.onFinish = { [weak self] url, error in self?.didFinish(url, error: error) }
        return writer
    }()
    private var activeCamera: AVCaptureDevice?
    private var previousFocus: AVCaptureDevice.FocusMode?
    private var previousExposure: AVCaptureDevice.ExposureMode?
    private var focusObservation: NSKeyValueObservation?
    private var focusFallback: DispatchWorkItem?
    private var takeHasAudio = false
    private var takeAudioProblem: String?
    private var timer: Timer?
    private var started: TimeInterval?
    private var assertion: IOPMAssertionID = 0
    private var holdsAssertion = false
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    var onFinished: (() -> Void)?

    override init() {
        let defaults = UserDefaults.standard
        folder = defaults.url(forKey: "folder") ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuCam", isDirectory: true)
        quality = "1080p"
        iconName = "link"
        super.init()
        quietNote = [quiet.restore(), blackout.recover()].filter { !$0.isEmpty }.joined(separator: " · ")
        blackout.onStop = { [weak self] in self?.stop() }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption((note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "A camera error occurred")
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.handleInterruption("Camera interrupted. Finishing the current recording.")
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }
            self.message = "Mac is going to sleep. Saving the recording; start a new take after waking."
            self.stop()
        })
    }

    func chooseFolder() {
        guard !busy && !recording else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let selected = panel.url {
            folder = selected
            UserDefaults.standard.set(selected, forKey: "folder")
        }
    }

    func start() {
        guard !busy && !recording else { return }
        busy = true
        phase = "Preparing"
        message = "Checking camera, microphone and save location…"
        quietNote = quiet.begin()
        onChange?()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: requestAudio()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.requestAudio() }
                    else { self.fail("Camera access is required. Allow MenuCam in System Settings > Privacy & Security > Camera.") }
                }
            }
        default: fail("Camera access is disabled. Allow MenuCam in System Settings > Privacy & Security > Camera.")
        }
    }

    private func requestAudio() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configure(audioAllowed: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { self.configure(audioAllowed: granted) }
            }
        default:
            configure(audioAllowed: false)
        }
    }

    private func configure(audioAllowed: Bool) {
        let destination = folder
        let selectedQuality = quality
        queue.async {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let probe = destination.appendingPathComponent(".menucam-\(UUID().uuidString)")
                try Data().write(to: probe, options: .atomic)
                try FileManager.default.removeItem(at: probe)
                let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let free = values.volumeAvailableCapacityForImportantUsage, free < 512 * 1024 * 1024 {
                    throw NSError(domain: "MenuCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough disk space. Keep at least 512 MB available."])
                }
                // Always the Mac's own camera: never a Continuity Camera phone or
                // an external/USB device, even when one is set as the system
                // default video device.
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    ?? AVCaptureDevice.default(for: .video)
                guard let camera else {
                    throw NSError(domain: "MenuCam", code: 2, userInfo: [NSLocalizedDescriptionKey: "No built-in camera found."])
                }

                // Audio is captured separately from the capture session by
                // AudioCapture (AVAudioEngine + uniform enhancer), so it never
                // blocks the video stream.
                var audioReady = false
                var audioProblem: String?
                if audioAllowed {
                    do {
                        self.audio.onSample = { [weak self] sample in self?.adaptiveWriter.processAudio(sample) }
                        try self.audio.start()
                        audioReady = true
                    } catch {
                        audioProblem = "Microphone unavailable. This recording has no audio."
                    }
                } else {
                    audioProblem = "Microphone access is disabled. Recording without audio. Allow MenuCam in System Settings > Privacy & Security > Microphone."
                }
                self.takeHasAudio = audioReady
                self.takeAudioProblem = audioProblem
                self.adaptiveWriter.audioEnabled = audioReady
                self.adaptiveWriter.audioChannels = self.audio.channels
                self.adaptiveWriter.audioSampleRate = self.audio.sampleRate

                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                let input: AVCaptureDeviceInput
                do { input = try AVCaptureDeviceInput(device: camera) }
                catch { self.session.commitConfiguration(); throw error }
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "MenuCam", code: 3, userInfo: [NSLocalizedDescriptionKey: "Camera unavailable. Close other apps using it."])
                }
                self.session.addInput(input)
                var preset: AVCaptureSession.Preset = selectedQuality == "720p" ? .hd1280x720 : .hd1920x1080
                if !self.session.canSetSessionPreset(preset) { preset = .hd1280x720 }
                guard self.session.canSetSessionPreset(preset) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "MenuCam", code: 4, userInfo: [NSLocalizedDescriptionKey: "This camera does not support 720p or higher."])
                }
                self.session.sessionPreset = preset
                self.session.outputs.forEach { self.session.removeOutput($0) }
                guard self.session.canAddOutput(self.adaptiveWriter.captureOutput) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "MenuCam", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to create recording output."])
                }
                self.session.addOutput(self.adaptiveWriter.captureOutput)
                self.session.commitConfiguration()
                self.configureCamera(camera)
                self.session.startRunning()
                guard self.session.isRunning else { throw NSError(domain: "MenuCam", code: 6, userInfo: [NSLocalizedDescriptionKey: "Camera could not start. Check whether another app is using it."]) }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let file = destination.appendingPathComponent("MenuCam_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mov")
                self.adaptiveWriter.begin(file: file)
            } catch {
                self.session.stopRunning()
                self.audio.onSample = nil
                self.audio.stop()
                self.restoreCamera()
                DispatchQueue.main.async { self.fail(error.localizedDescription) }
            }
        }
    }

    func stop() {
        guard recording && !busy else { return }
        busy = true
        phase = "Saving"
        freezeRecordingClock()
        restoreQuiet()
        onChange?()
        queue.async {
            self.audio.onSample = nil
            self.audio.stop()
            self.adaptiveWriter.finish()
        }
    }

    private func didStart(_ fileURL: URL) {
        DispatchQueue.main.async {
            self.busy = false
            self.recording = true
            self.phase = "Recording"
            self.elapsed = 0
            self.audioActive = self.takeHasAudio
            self.started = ProcessInfo.processInfo.systemUptime
            self.message = self.takeAudioProblem ?? ""
            do { try self.blackout.begin() }
            catch {
                self.message = "Unable to start blackout mode: \(error.localizedDescription)"
                self.stop()
                return
            }
            if self.takeHasAudio {
                // Watchdog: a take must never come out silent without saying so.
                // If the microphone delivers nothing shortly after the start,
                // surface it in the panel instead of discovering it later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.recording, self.audio.framesDelivered == 0 else { return }
                    self.message = "No microphone audio received. This recording may be silent; check the input device."
                    self.audioActive = false
                }
            }
            self.holdsAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MenuCam is recording" as CFString, &self.assertion) == kIOReturnSuccess
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let date = self.started else { return }
                self.elapsed = Int(ProcessInfo.processInfo.systemUptime - date)
            }
            self.onChange?()
        }
    }

    private func didFinish(_ fileURL: URL, error: Error?) {
        queue.async {
            self.session.stopRunning()
            self.audio.onSample = nil
            self.audio.stop()
            self.restoreCamera()
            DispatchQueue.main.async { self.completeFinish(fileURL, error: error) }
        }
    }

    private func freezeRecordingClock() {
        if let started { elapsed = max(0, Int(ProcessInfo.processInfo.systemUptime - started)) }
        timer?.invalidate(); timer = nil; started = nil
    }
    private func completeFinish(_ fileURL: URL, error: Error?) {
        freezeRecordingClock()
        let duration = Self.formatClock(elapsed)
        elapsed = 0
        let environmentProblem = restoreQuiet()
        do {
            self.timer?.invalidate()
            self.timer = nil
            if self.holdsAssertion { IOPMAssertionRelease(self.assertion); self.holdsAssertion = false }
            self.recording = false
            self.busy = false
            self.audioActive = false
            let nsError = error as NSError?
            let success = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            self.phase = success ? "Saved" : "Interrupted"
            self.lastFile = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
            self.message = success ? "Saved\nDuration: \(duration)\nSaved to:\n\(Self.displaySavePath(fileURL))" : "Recording error: \(error?.localizedDescription ?? "Unknown error"). Check whether the saved file is playable.\nDuration: \(duration)"
            if !environmentProblem.isEmpty { self.message += " · " + environmentProblem }
            self.onChange?()
            self.onFinished?()
        }
    }

    // macOS exposes no lens-position or focus-range controls, so the closest
    // honest behaviour is: one autofocus pass, then hold that focus steady.
    private func configureCamera(_ camera: AVCaptureDevice) {
        activeCamera = camera
        var note = ""
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                previousExposure = camera.exposureMode
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isFocusModeSupported(.locked) && camera.isFocusModeSupported(.autoFocus) {
                previousFocus = camera.focusMode
                camera.focusMode = .autoFocus
                focusObservation = camera.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, _ in
                    guard let self, !device.isAdjustingFocus else { return }
                    self.lockFocus(device, note: "Focus: locked after one autofocus pass.")
                }
                let fallback = DispatchWorkItem { [weak self] in
                    self?.lockFocus(camera, note: "Focus: current focus locked.")
                }
                focusFallback = fallback
                queue.asyncAfter(deadline: .now() + 6, execute: fallback)
                note = "Focus: autofocusing, then locking."
            } else if camera.isFocusModeSupported(.locked) {
                previousFocus = camera.focusMode
                camera.focusMode = .locked
                note = "Focus: single autofocus unsupported; current focus locked."
            } else if camera.isFocusModeSupported(.continuousAutoFocus) {
                note = "Focus: hardware autofocus."
            } else {
                note = "Focus: fixed-focus camera."
            }
            note += " Low light: gentle automatic lift in dark scenes, up to +1 EV."
        } catch {
            note = "Focus: using camera defaults. Low-light enhancement remains available."
        }
        let result = note
        DispatchQueue.main.async { self.cameraNote = result }
    }

    private func lockFocus(_ camera: AVCaptureDevice, note: String) {
        guard activeCamera === camera else { return }
        focusFallback?.cancel()
        focusFallback = nil
        focusObservation = nil
        guard camera.focusMode != .locked else {
            DispatchQueue.main.async { self.cameraNote = note }
            return
        }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
            camera.unlockForConfiguration()
            DispatchQueue.main.async { self.cameraNote = note }
        } catch { /* Device may have been unplugged. */ }
    }

    private func restoreCamera() {
        focusFallback?.cancel()
        focusFallback = nil
        focusObservation = nil
        defer { activeCamera = nil; previousFocus = nil; previousExposure = nil }
        guard let camera = activeCamera else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let focus = previousFocus, camera.isFocusModeSupported(focus) { camera.focusMode = focus }
            if let exposure = previousExposure, camera.isExposureModeSupported(exposure) { camera.exposureMode = exposure }
        } catch { /* Device may have been unplugged. */ }
    }

    private func handleInterruption(_ reason: String) {
        guard recording || busy else { return }
        message = reason
        _ = blackout.end()
        if recording { stop() }
        else if busy {
            queue.async {
                self.adaptiveWriter.finish(error: NSError(domain: "MenuCam", code: 7, userInfo: [NSLocalizedDescriptionKey: reason]))
            }
        }
    }

    private func fail(_ reason: String) {
        restoreQuiet()
        busy = false
        recording = false
        audioActive = false
        phase = "Unable to Start"
        message = reason
        onChange?()
        onFinished?()
    }

    @discardableResult private func restoreQuiet() -> String {
        let problem = [blackout.end(), quiet.restore()].filter { !$0.isEmpty }.joined(separator: " · ")
        quietNote = problem.isEmpty ? "Recording settings restored" : problem
        if !problem.isEmpty { message = problem }
        return problem
    }
    func restoreEnvironmentOnExit() { restoreQuiet() }
    func startRemote() {
        remote.snapshotHandler = { [weak self] completion in
            guard let self, !self.busy else { completion(409, nil); return }
            if self.recording {
                // Read-only live-frame request: never stop/reconfigure capture or alter blackout state.
                self.queue.async {
                    self.adaptiveWriter.requestSnapshot { result in
                        switch result { case .success(let image): completion(200, image); case .failure: completion(503, nil) }
                    }
                }
            } else {
                self.busy = true
                self.phase = "Taking Photo"
                let finish: (Int, Data?) -> Void = { [weak self] code, data in
                    DispatchQueue.main.async {
                        self?.busy = false; self?.phase = "Idle"
                        completion(code, data)
                    }
                }
                let capture = {
                    self.idlePhoto.capture { result in
                        switch result { case .success(let image): finish(200, image); case .failure: finish(503, nil) }
                    }
                }
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: capture()
                case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { allowed in
                    if allowed { capture() } else { finish(403, nil) }
                }
                default: finish(403, nil)
                }
            }
        }
        remote.start { [weak self] path in
            guard let self else { return (503, ["error": "Unavailable"]) }
            var code = 200
            if path == "/api/start" {
                if self.busy { code = 409 }
                else if !self.recording { self.start() }
            } else if path == "/api/stop" {
                if self.busy { code = 409 }
                else if self.recording { self.stop() }
            }
            return (code, ["recording": self.recording, "busy": self.busy, "phase": self.phase,
                           "clock": self.clock, "elapsed": self.elapsed, "message": self.message])
        }
    }
    static func displaySavePath(_ file: URL) -> String {
        let components = file.standardizedFileURL.pathComponents
        if let index = components.firstIndex(of: "Movies") { return components[index...].joined(separator: "/") }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
    }
    static func formatClock(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    var clock: String { Self.formatClock(elapsed) }
}

struct Panel: View {
    @ObservedObject var model: Recorder
    var quit: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            RemoteFooter(server: model.remote)
            Spacer(minLength: 0)
            Button("Quit", action: quit).buttonStyle(.borderless).font(.system(size: 11))
        }.padding(10).frame(width: 250).fixedSize(horizontal: false, vertical: true)
    }
}

struct RemoteFooter: View {
    @ObservedObject var server: RemoteServer
    var body: some View {
        Group {
            if let address = server.controlAddress, let link = server.controlURL {
                Button(address) { NSWorkspace.shared.open(link) }
                    .buttonStyle(.plain)
                    .help("Open remote control; right-click to copy the link")
                    .contextMenu {
                        Button("Copy Control Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                    }
            } else { Text(server.status) }
        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Recorder()
    var item: NSStatusItem!
    let popover = NSPopover()
    var panelController: NSViewController?
    var waitingToQuit = false
    var outsideMonitor: Any?
    var resignObserver: NSObjectProtocol?
    private var sizingSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Tight fixed width, icon only: a fixed length keeps the popover anchor
        // stable when the symbol or recording state changes.
        item = NSStatusBar.system.statusItem(withLength: 26)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = false
        // A plain AppKit container owns the popover size. SwiftUI only draws its content.
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 280))
        let hostingView = NSHostingView(rootView: Panel(model: model, quit: { NSApp.terminate(nil) }))
        hostingView.frame = controller.view.bounds
        hostingView.autoresizingMask = [.width, .height]
        controller.view.addSubview(hostingView)
        panelController = controller
        popover.contentViewController = controller
        model.onChange = { [weak self] in self?.updateIcon() }
        model.onFinished = { [weak self] in
            if self?.waitingToQuit == true { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        // Dismiss like every other macOS popover: a click that lands anywhere
        // outside this app (other apps, the desktop) closes the panel, and so
        // does the app losing focus. Clicks on our own menu bar icon still go
        // through toggle() instead.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        sizingSubscription = model.objectWillChange.merge(with: model.remote.objectWillChange)
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] in self?.resizePanel() }
        model.startRemote()
        updateIcon()
        toggle()
    }
    func updateIcon() {
        item.button?.image = model.menuImage()
        item.button?.contentTintColor = model.recording ? .systemRed : nil
        item.button?.toolTip = "MenuCam · \(model.phase)"
    }
    private func resizePanel() {
        let size = panelSize()
        if abs(popover.contentSize.height - size.height) > 1 || abs(popover.contentSize.width - size.width) > 1 { apply(size: size) }
    }
    private func panelSize() -> NSSize {
        let screen = item.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 720) - 32
        // Measure unconstrained SwiftUI content, not the controller's already-sized view.
        // NSHostingController.fittingSize otherwise reports its current height after updates.
        let measurement = NSHostingView(rootView: Panel(model: model, quit: {}))
        let measured = measurement.fittingSize.height
        return NSSize(width: 250, height: min(ceil(measured > 0 ? measured : 280), available))
    }
    private func apply(size: NSSize) {
        popover.contentSize = size
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            let size = panelSize()
            apply(size: size)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model.restoreEnvironmentOnExit() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.recording || model.busy {
            if model.busy && !model.recording { return .terminateCancel }
            waitingToQuit = true
            model.stop()
            return .terminateLater
        }
        return .terminateNow
    }
}

@main
struct MenuCamApp {
    static func main() {
        let app = NSApplication.shared
        // Check before constructing Recorder: a second copy must not restore the active take's journal.
        let identifier = Bundle.main.bundleIdentifier ?? "local.junxian.MenuCam"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
