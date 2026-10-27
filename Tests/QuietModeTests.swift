import Foundation
@main struct QuietTests {
    static func main() {
        let suite = "MenuCam.QuietTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let quiet = QuietMode(defaults: defaults)
        precondition(quiet.restore().isEmpty)
        let note = quiet.begin()
        print("Quiet mode: \(note)")
        precondition(defaults.dictionary(forKey: "MenuCam.quietRecovery.v1") != nil)
        let problem = quiet.restore()
        precondition(problem.isEmpty, "Restore failed (journal retained): \(problem)")
        precondition(defaults.dictionary(forKey: "MenuCam.quietRecovery.v1") == nil)
        precondition(quiet.restore().isEmpty)
        defaults.set(["device": UInt32.max, "uid": "missing-test-device", "mute": 0], forKey: "MenuCam.quietRecovery.v1")
        precondition(!quiet.restore().isEmpty)
        precondition(defaults.dictionary(forKey: "MenuCam.quietRecovery.v1") != nil)
        print("PASS: quiet-mode capture/restore, idempotent restore, unavailable-device recovery journal retained")
    }
}
