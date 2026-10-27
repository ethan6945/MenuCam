import AppKit
final class FakeBlackoutDisplays: DisplaySettingsBackend {
    var dimmed = false
    func capture() throws -> [DisplaySnapshot] { [DisplaySnapshot(uuid: "fake", brightness: 0.5, automatic: true)] }
    func apply(_ value: DisplaySnapshot, dimmed: Bool) -> Bool { self.dimmed = dimmed; return true }
}
@main struct Tests {
    static func main() {
        let modifierTest = CommandLine.arguments.contains("--modifier")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "MenuCam.BlackoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let backend = FakeBlackoutDisplays()
        let mode = BlackoutMode(dimmer: DisplayDimmer(backend: backend, defaults: defaults))
        let directory = URL(fileURLWithPath: "/private/tmp/menucam-blackout-server-\(UUID().uuidString)")
        let server = RemoteServer(port: 18769)
        var stops = 0
        server.start(directory: directory) { _ in (200, ["recording": mode.active, "busy": false]) }
        mode.onStop = { stops += 1; mode.end() }
        DispatchQueue.main.async {
            do {
                try mode.begin()
                precondition(mode.active && backend.dimmed)
                let screens = NSScreen.screens
                let windows = app.windows.filter { $0.isVisible && $0.level.rawValue == Int(CGWindowLevelForKey(.screenSaverWindow)) }
                precondition(windows.count == screens.count)
                precondition(screens.allSatisfy { screen in windows.contains { $0.frame == screen.frame && $0.isOpaque && $0.backgroundColor == .black } })
                if let window = windows.first {
                    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "/private/tmp/menucam-blackout-preview.png"]
                    try capture.run(); capture.waitUntilExit()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let event = NSEvent.keyEvent(with: modifierTest ? .flagsChanged : .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windows[0].windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: modifierTest ? 57 : 7)!
                    app.postEvent(event, atStart: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let success = stops == 1 && !mode.active && !backend.dimmed && windows.allSatisfy { !$0.isVisible }
                        mode.end()
                        defaults.removePersistentDomain(forName: suite)
                        precondition(success, "Keyboard did not stop and restore black-screen mode")
                        guard let host = RemoteServer.tailAddresses().first else { fatalError("Tailscale required for server continuity test") }
                        var request = URLRequest(url: URL(string: "http://\(host):18769/api/status")!)
                        request.setValue("Bearer " + server.accessKey, forHTTPHeaderField: "Authorization")
                        URLSession.shared.dataTask(with: request) { data, response, error in
                            precondition(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
                            let state = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
                            precondition(state["recording"] as? Bool == false)
                            try? FileManager.default.removeItem(at: directory)
                            print("PASS: full-display pure black windows, ordinary key stops once, windows removed, brightness restored; authenticated web server remains reachable after keyboard stop")
                            exit(0)
                        }.resume()
                    }
                }
            } catch { mode.end(); fatalError("Blackout setup: \(error)") }
        }
        app.run()
    }
}
