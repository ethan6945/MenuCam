import Foundation
import CoreAudio
import Darwin

/// Each successful mutation is journaled first; the next launch can recover after a crash.
final class QuietMode {
    private let defaults: UserDefaults
    private let key = "MenuCam.quietRecovery.v1"
    private var keyboardID: UInt64 = 1
    private var keyboard: NSObject?
    private var library: UnsafeMutableRawPointer?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        library = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        if let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let client = type.init(), selector = NSSelectorFromString("copyKeyboardBacklightIDs")
            if client.responds(to: selector), let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber], let id = ids.first {
                keyboard = client; keyboardID = id.uint64Value
            }
        }
    }
    private func brightness() -> Float? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let keyboard, keyboard.responds(to: sel) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let value = unsafeBitCast(keyboard.method(for: sel), to: Get.self)(keyboard, sel, keyboardID)
        return value.isFinite && value >= 0 && value <= 1 ? value : nil
    }
    private func setBrightness(_ value: Float) -> Bool {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let keyboard, keyboard.responds(to: sel) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Void
        unsafeBitCast(keyboard.method(for: sel), to: Set.self)(keyboard, sel, value, keyboardID)
        return brightness().map { abs($0 - value) < 0.02 } ?? false
    }
    private func automaticBrightness() -> Bool? {
        let sel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        guard let keyboard, keyboard.responds(to: sel) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        return unsafeBitCast(keyboard.method(for: sel), to: Get.self)(keyboard, sel, keyboardID)
    }
    private func setAutomaticBrightness(_ enabled: Bool) -> Bool {
        let sel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        guard let keyboard, keyboard.responds(to: sel) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Void
        unsafeBitCast(keyboard.method(for: sel), to: Set.self)(keyboard, sel, enabled, keyboardID)
        return automaticBrightness() == enabled
    }
    private func address(_ selector: AudioObjectPropertySelector, _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private func read<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32 = 0, into value: inout T) -> Bool {
        var a = address(selector, element), size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr
    }
    private func write<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32 = 0, value: T) -> Bool {
        var a = address(selector, element), v = value
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
    private func writable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32 = 0) -> Bool {
        var a = address(selector, element), settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }
    private func uid(_ device: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
    private func findDevice(uid expected: String, previous: AudioDeviceID) -> AudioDeviceID? {
        if uid(previous) == expected { return previous }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? devices.first { uid($0) == expected } : nil
    }
    private func save(_ journal: [String: Any]) { defaults.set(journal, forKey: key); defaults.synchronize() }
    func begin() -> String {
        let recovery = restore()
        guard defaults.dictionary(forKey: key) == nil else { return recovery }
        var journal: [String: Any] = [:]
        var result: [String] = []
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr, let id = uid(device) {
            journal["device"] = device; journal["uid"] = id
            var muted: UInt32 = 0
            if writable(device, kAudioDevicePropertyMute), read(device, kAudioDevicePropertyMute, into: &muted) {
                var originalVolumes: [String: Float] = [:]
                for element: UInt32 in [0, 1, 2] where writable(device, kAudioDevicePropertyVolumeScalar, element) {
                    var value: Float = 0
                    if read(device, kAudioDevicePropertyVolumeScalar, element, into: &value) { originalVolumes[String(element)] = value }
                }
                // Master and per-channel setters can interact: use master alone when available.
                if let master = originalVolumes["0"] { originalVolumes = ["0": master] }
                journal["channels"] = originalVolumes
                journal["mute"] = muted; save(journal)
                result.append(write(device, kAudioDevicePropertyMute, value: UInt32(1)) ? "Audio output muted" : "Unable to mute audio output")
            } else {
                var channels: [String: Float] = [:]
                // Prefer master volume, otherwise mute each output channel.
                var count: UInt32 = 0
                var stream = address(kAudioDevicePropertyStreamConfiguration)
                if AudioObjectGetPropertyDataSize(device, &stream, 0, nil, &count) == noErr, count > 0 {
                    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(count), alignment: MemoryLayout<AudioBufferList>.alignment)
                    defer { buffer.deallocate() }
                    if AudioObjectGetPropertyData(device, &stream, 0, nil, &count, buffer) == noErr {
                        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
                        let total = list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
                        let elements: [UInt32] = writable(device, kAudioDevicePropertyVolumeScalar) ? [0] : (total > 0 ? Array(1...total) : [])
                        for e in elements {
                            var value: Float = 0
                            if writable(device, kAudioDevicePropertyVolumeScalar, e), read(device, kAudioDevicePropertyVolumeScalar, e, into: &value) { channels[String(e)] = value }
                        }
                        if channels.count != elements.count { channels = [:] }
                    }
                }
                journal["channels"] = channels; save(journal)
                let success = !channels.isEmpty && channels.map { write(device, kAudioDevicePropertyVolumeScalar, UInt32($0.key)!, value: Float(0)) }.allSatisfy { $0 }
                result.append(success ? "Output volume set to zero" : "This output device cannot be muted automatically")
            }
        } else { result.append("Unable to read the output device") }
        if let value = brightness(), let automatic = automaticBrightness() {
            journal["brightness"] = value; journal["automatic"] = automatic; journal["keyboardID"] = keyboardID; save(journal)
            let autoOff = setAutomaticBrightness(false)
            result.append(autoOff && setBrightness(0) ? "Keyboard backlight off" : "Keyboard backlight controls unavailable")
        } else { result.append("Keyboard backlight controls are not supported on this Mac") }
        save(journal)
        return result.joined(separator: " · ")
    }
    @discardableResult func restore() -> String {
        guard var journal = defaults.dictionary(forKey: key) else { return "" }
        var failures: [String] = []
        if let id = journal["keyboardID"] as? NSNumber { keyboardID = id.uint64Value }
        if let value = journal["brightness"] as? NSNumber {
            if setBrightness(value.floatValue) { journal.removeValue(forKey: "brightness") }
            else { failures.append("Unable to restore keyboard backlight") }
        }
        if let automatic = journal["automatic"] as? NSNumber {
            if setAutomaticBrightness(automatic.boolValue) { journal.removeValue(forKey: "automatic") }
            else { failures.append("Unable to restore keyboard automatic brightness") }
        }
        if let number = journal["device"] as? NSNumber, let expected = journal["uid"] as? String {
            if let device = findDevice(uid: expected, previous: number.uint32Value) {
                if let value = journal["mute"] as? NSNumber {
                    if write(device, kAudioDevicePropertyMute, value: value.uint32Value) { journal.removeValue(forKey: "mute") }
                    else { failures.append("Unable to restore audio mute settings") }
                }
                if let channels = journal["channels"] as? [String: NSNumber] {
                    var remaining = channels
                    for (e, v) in channels where write(device, kAudioDevicePropertyVolumeScalar, UInt32(e)!, value: v.floatValue) { remaining.removeValue(forKey: e) }
                    if remaining.isEmpty { journal.removeValue(forKey: "channels") }
                    else { journal["channels"] = remaining; failures.append("Unable to restore output volume") }
                }
            } else if journal["mute"] != nil || (journal["channels"] as? [String: NSNumber])?.isEmpty == false { failures.append("Original output device unavailable. Recovery will be retried.") }
        }
        if failures.isEmpty { defaults.removeObject(forKey: key); defaults.synchronize() } else { save(journal) }
        return failures.joined(separator: " · ")
    }
}
