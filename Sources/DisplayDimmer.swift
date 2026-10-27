import AppKit
import Darwin

struct DisplaySnapshot: Codable, Equatable {
    let uuid: String
    let brightness: Float
    let automatic: Bool?
}
protocol DisplaySettingsBackend {
    func capture() throws -> [DisplaySnapshot]
    func apply(_ snapshot: DisplaySnapshot, dimmed: Bool) -> Bool
}

/// Runtime-resolved Apple display controls, also used by display utility apps.
final class SystemDisplaySettings: DisplaySettingsBackend {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private typealias HasAutomatic = @convention(c) (UInt32) -> Bool
    private typealias GetAutomatic = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Void
    private typealias SetAutomatic = @convention(c) (UInt32, Bool) -> Void
    private let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private func function<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    private func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
    private func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }
    func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let get = function("DisplayServicesGetBrightness", GetBrightness.self) else { return nil }
        var value: Float = -1
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    private func automatic(_ id: CGDirectDisplayID) -> Bool? {
        guard let get = function("DisplayServicesAmbientLightCompensationEnabled", GetAutomatic.self) else { return nil }
        var value = false
        get(id, &value)
        return value
    }
    func capture() throws -> [DisplaySnapshot] {
        guard let has = function("DisplayServicesHasAmbientLightCompensation", HasAutomatic.self),
              function("DisplayServicesEnableAmbientLightCompensation", SetAutomatic.self) != nil,
              function("DisplayServicesSetBrightness", SetBrightness.self) != nil else {
            throw Self.error("屏幕亮度控制接口不可用")
        }
        var result: [DisplaySnapshot] = []
        for id in displays() {
            guard let value = brightness(id), let identifier = uuid(id) else {
                if CGDisplayIsBuiltin(id) != 0 { throw Self.error("无法读取内置屏幕亮度") }
                continue // Unsupported external screens are still covered by black windows.
            }
            let auto = has(id) ? automatic(id) : nil
            if has(id) && auto == nil { throw Self.error("无法读取自动亮度状态") }
            result.append(DisplaySnapshot(uuid: identifier, brightness: value, automatic: auto))
        }
        return result
    }
    func apply(_ snapshot: DisplaySnapshot, dimmed: Bool) -> Bool {
        guard let id = displays().first(where: { uuid($0) == snapshot.uuid }),
              let set = function("DisplayServicesSetBrightness", SetBrightness.self) else { return false }
        var okay = true
        if dimmed, snapshot.automatic != nil {
            if let setAuto = function("DisplayServicesEnableAmbientLightCompensation", SetAutomatic.self) {
                setAuto(id, false); okay = automatic(id) == false
            } else { okay = false }
        }
        let value: Float = dimmed ? 0 : snapshot.brightness
        okay = (set(id, value) == 0) && okay
        if !dimmed, let auto = snapshot.automatic {
            if let setAuto = function("DisplayServicesEnableAmbientLightCompensation", SetAutomatic.self) {
                setAuto(id, auto); okay = (automatic(id) == auto) && okay
            } else { okay = false }
        }
        return okay
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "MenuCam.Display", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Save before changing hardware. Unrestored displays remain in the journal for next launch.
final class DisplayDimmer {
    private let backend: DisplaySettingsBackend
    private let defaults: UserDefaults
    private let key = "MenuCam.displayRecovery.v1"
    init(backend: DisplaySettingsBackend = SystemDisplaySettings(), defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
    }
    func begin() throws {
        let previous = restore()
        guard previous.isEmpty else { throw NSError(domain: "MenuCam.Display", code: 2, userInfo: [NSLocalizedDescriptionKey: previous]) }
        let snapshots = try backend.capture()
        defaults.set(try JSONEncoder().encode(snapshots), forKey: key)
        guard defaults.synchronize() else { throw NSError(domain: "MenuCam.Display", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法保存亮度恢复记录"]) }
        for snapshot in snapshots where !backend.apply(snapshot, dimmed: true) {
            let recovery = restore()
            throw NSError(domain: "MenuCam.Display", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法关闭屏幕亮度／自动亮度。\(recovery)"])
        }
    }
    @discardableResult func restore() -> String {
        guard let data = defaults.data(forKey: key) else { return "" }
        guard let snapshots = try? JSONDecoder().decode([DisplaySnapshot].self, from: data) else { return "屏幕恢复记录无法读取" }
        let remaining = snapshots.filter { !backend.apply($0, dimmed: false) }
        if remaining.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(try? JSONEncoder().encode(remaining), forKey: key) }
        defaults.synchronize()
        return remaining.isEmpty ? "" : "屏幕亮度／自动亮度未完全恢复，保留记录待重试"
    }
}
