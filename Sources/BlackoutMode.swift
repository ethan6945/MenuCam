import AppKit

private final class BlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless full-display windows avoid Space transition animations and cover all attached screens.
final class BlackoutMode {
    private let dimmer: DisplayDimmer
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var previousPresentation: NSApplication.PresentationOptions?
    private var previousApp: NSRunningApplication?
    private var cursorHidden = false
    private(set) var active = false
    var onStop: (() -> Void)?
    init(dimmer: DisplayDimmer = DisplayDimmer()) { self.dimmer = dimmer }
    @discardableResult func recover() -> String { dimmer.restore() }
    func begin() throws {
        guard !active else { return }
        // Key handling is app-local; no Accessibility/Input Monitoring permission required.
        active = true
        previousApp = NSWorkspace.shared.frontmostApplication
        previousPresentation = NSApp.presentationOptions
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .systemDefined]) { [weak self] event in
            guard let self, self.active else { return event }
            // Include modifier transitions (even Caps Lock toggling off) and media-key presses.
            let mediaKeyDown = event.type == .systemDefined && event.subtype.rawValue == 8 && ((event.data1 >> 8) & 0xff) == 0x0a
            if event.type == .keyDown || event.type == .flagsChanged || mediaKeyDown {
                self.onStop?()
            }
            return nil
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        for screen in NSScreen.screens {
            let window = BlackoutWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = true; window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        let topology = NSScreen.screens.map { screen in
            "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""):\(screen.frame)"
        }.sorted()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            let current = NSScreen.screens.map { screen in
                "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""):\(screen.frame)"
            }.sorted()
            // Hiding Dock/menu bar changes visibleFrame too; only react to actual display changes.
            if current != topology { self?.onStop?() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.onStop?()
        }
        NSCursor.hide(); cursorHidden = true
        guard active else { return }
        do { try dimmer.begin() }
        catch { _ = end(); throw error }
    }
    @discardableResult func end() -> String {
        let wasActive = active
        active = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        let problem = dimmer.restore()
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        if let presentation = previousPresentation { NSApp.presentationOptions = presentation; previousPresentation = nil }
        if wasActive, let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate(options: [.activateIgnoringOtherApps]) }
        previousApp = nil
        return problem
    }
}
