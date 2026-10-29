import AppKit
import SwiftUI
import Combine
import AVFoundation
import IOKit.pwr_mgt
import Darwin

final class Recorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published var phase = "Idle"
    @Published var busy = false
    @Published var recording = false
    @Published var elapsed = 0
    @Published var message = ""
    @Published var folder: URL
    @Published var quality: String { didSet { UserDefaults.standard.set(quality, forKey: "quality") } }
    @Published var cameraNote = ""
    @Published var audioActive = false
    @Published var lastFile: URL?
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

struct ControlWindow: View {
    @ObservedObject var server: RemoteServer
    var quit: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MenuCam").font(.headline)
                    Text(server.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit", action: quit).buttonStyle(.borderless)
                    .help("Save any active recording and quit MenuCam")
            }
            VStack(alignment: .leading, spacing: 10) {
                addressRow("Tailscale", address: server.controlAddress, link: server.controlURL)
                Divider()
                addressRow("This Mac", address: server.localAddress, link: server.localURL)
            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(copied ? "Copied" : "Copy Control Link") {
                    guard let link = server.controlURL ?? server.localURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }.disabled(server.controlURL == nil && server.localURL == nil)
                Spacer()
                Text("Close to keep running").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 390)
    }
    @ViewBuilder private func addressRow(_ title: String, address: String?, link: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let address, let link {
                Button(address) { NSWorkspace.shared.open(link) }
                    .buttonStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).help("Open authenticated web control")
                    .contextMenu {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                    }
            } else {
                Text("Waiting for connection…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Recorder()
    private var window: NSWindow!
    private var waitingToQuit = false
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 240),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MenuCam"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ControlWindow(server: model.remote, quit: { NSApp.terminate(nil) }))
        window.center()
        model.onFinished = { [weak self] in
            if self?.waitingToQuit == true {
                self?.waitingToQuit = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        model.remote.quitHandler = { NSApp.terminate(nil) }
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.junxian.MenuCam.reopen"), object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow() }
        model.startRemote()
        showWindow()
    }
    private func showWindow() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.restoreEnvironmentOnExit() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingToQuit { return .terminateLater }
        if model.recording || model.busy {
            // Preparation and snapshots must finish before restoring/exiting too.
            waitingToQuit = true
            if model.recording && !model.busy { model.stop() }
            else { waitForSafeQuit() }
            return .terminateLater
        }
        return .terminateNow
    }
    private func waitForSafeQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.waitingToQuit else { return }
            if self.model.busy { self.waitForSafeQuit() }
            else if self.model.recording { self.model.stop() }
            else { self.waitingToQuit = false; NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
}

@main
struct MenuCamApp {
    // Retain an advisory lock for the process lifetime, including simultaneous launches.
    private static var instanceLock: Int32 = -1
    static func main() {
        let app = NSApplication.shared
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuCam", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        instanceLock = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard instanceLock >= 0 else { return }
        guard flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.junxian.MenuCam.reopen"), object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
