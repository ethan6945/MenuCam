import AppKit
final class FakeDisplays: DisplaySettingsBackend {
    var states = [DisplaySnapshot(uuid: "screen-A", brightness: 0.7, automatic: true), DisplaySnapshot(uuid: "screen-B", brightness: 0.4, automatic: false)]
    var missing = Set<String>()
    var failDim = false
    func capture() throws -> [DisplaySnapshot] { states }
    func apply(_ value: DisplaySnapshot, dimmed: Bool) -> Bool {
        guard !missing.contains(value.uuid), !(dimmed && failDim) else { return false }
        if let index = states.firstIndex(where: { $0.uuid == value.uuid }) {
            states[index] = dimmed ? DisplaySnapshot(uuid: value.uuid, brightness: 0, automatic: false) : value
        }
        return true
    }
}
@main struct Tests {
    static func main() throws {
        let suite = "MenuCam.DisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeDisplays(), original = backend.states
        let dimmer = DisplayDimmer(backend: backend, defaults: defaults)
        try dimmer.begin()
        precondition(backend.states.allSatisfy { $0.brightness == 0 && $0.automatic == false })
        precondition(dimmer.restore().isEmpty && backend.states == original)
        precondition(dimmer.restore().isEmpty)
        try dimmer.begin()
        // Simulate restart with the same journal, preserving the exact automatic on/off states.
        let recovered = DisplayDimmer(backend: backend, defaults: defaults)
        precondition(recovered.restore().isEmpty && backend.states == original)
        backend.failDim = true
        do { try dimmer.begin(); fatalError("Expected failure") } catch { }
        precondition(backend.states == original)
        backend.failDim = false
        try dimmer.begin(); backend.missing.insert("screen-B")
        precondition(!dimmer.restore().isEmpty)
        backend.missing.removeAll()
        precondition(dimmer.restore().isEmpty && backend.states == original)
        print("PASS: brightness zero, automatic disabled, exact restoration, idempotence, crash recovery, setup-failure rollback, disconnected-display retry")
        if CommandLine.arguments.contains("--hardware") {
            let system = SystemDisplaySettings(), values = try system.capture()
            guard !values.isEmpty else { fatalError("No controllable display") }
            let hardware = DisplayDimmer(backend: system, defaults: defaults)
            defer { hardware.restore() }
            try hardware.begin()
            Thread.sleep(forTimeInterval: 0.3)
            let dark = try system.capture()
            precondition(dark.allSatisfy { $0.brightness < 0.02 && $0.automatic != true })
            precondition(hardware.restore().isEmpty)
            let restored = try system.capture()
            precondition(values.allSatisfy { before in restored.contains { $0.uuid == before.uuid && abs($0.brightness - before.brightness) < 0.03 && $0.automatic == before.automatic } })
            print("PASS: actual display brightness/automatic readback at zero and original values after restore")
        }
    }
}
