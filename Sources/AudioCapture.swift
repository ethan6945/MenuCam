import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// Captures the microphone with a plain AVAudioEngine input tap and applies the
/// project's own uniform enhancer (see SpeechEnhancer). Delivers 48 kHz mono
/// float32 sample buffers stamped on the host clock, the same clock the camera
/// uses, so audio and video stay aligned. All callbacks are delivered on the
/// capture queue passed at init.
///
/// There is deliberately **one** audio path. An earlier version preferred
/// Apple's VoiceProcessingIO unit and fell back to the engine when it failed to
/// initialise; that had two problems: the unit applies its own voice detection
/// (noise suppression + AGC), which defeats the "amplify the whole room
/// uniformly" requirement, and once the microphone permission was re-granted
/// the unit initialised successfully yet delivered no samples at all, so
/// recordings came out with no audio track. One path, always the same one.
final class AudioCapture {
    private(set) var voiceProcessing = false
    private(set) var isRunning = false
    private(set) var channels = 1
    private(set) var sampleRate: Double = 48000
    private(set) var formatSummary = ""
    private(set) var framesDelivered: Int64 = 0
    private(set) var tapCount = 0
    private(set) var convertFailures = 0
    private(set) var backend = "none"
    private(set) var voiceProcessingFailure: String?
    var onSample: ((CMSampleBuffer) -> Void)?

    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    private var enhancer: SpeechEnhancer?
    private var lastTimestamp: CMTime?
    var enhancerGain: Float { enhancer?.currentGain ?? 1 }

    init(queue: DispatchQueue) { self.queue = queue }

    func start() throws {
        guard !isRunning else { return }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw Self.error("没有可用的麦克风输入格式（检查麦克风权限与输入设备）。")
        }
        sampleRate = format.sampleRate
        enhancer = SpeechEnhancer(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.handleEngineBuffer(buffer, when: when)
        }
        // Pull the input through the mixer so the graph renders (taps only fire
        // while rendering); volume 0 keeps microphone audio off the speakers.
        engine.mainMixerNode.outputVolume = 0
        _ = engine.outputNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            throw error
        }
        channels = 1
        isRunning = true
        voiceProcessing = false
        voiceProcessingFailure = nil
        backend = "AVAudioEngine"
        formatSummary = "\(Int(sampleRate)) Hz 单声道 · 整体增强"
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        isRunning = false
        lastTimestamp = nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MenuCam.AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func handleEngineBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        tapCount += 1
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            convertFailures += 1
            return
        }
        let frames = Int(buffer.frameLength)
        let sourceChannels = Int(buffer.format.channelCount)
        guard let stamp = when.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(when.hostTime) : lastTimestamp else {
            convertFailures += 1
            return
        }
        var mixed = [Float](repeating: 0, count: frames)
        if sourceChannels == 1 {
            mixed.withUnsafeMutableBufferPointer { output in
                if let base = output.baseAddress { base.update(from: channelData[0], count: frames) }
            }
        } else {
            let scale = 1 / Float(sourceChannels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<sourceChannels { sum += channelData[channel][frame] }
                mixed[frame] = sum * scale
            }
        }
        enhancer?.process(&mixed)
        mixed.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            deliver(data: UnsafeRawPointer(base), frames: frames, timestamp: stamp)
        }
    }

    // MARK: - Shared sample buffer construction

    private func deliver(data: UnsafeRawPointer, frames: Int, timestamp: CMTime) {
        guard let sample = makeSampleBuffer(data: data, frames: frames, timestamp: timestamp) else {
            convertFailures += 1
            return
        }
        lastTimestamp = timestamp
        framesDelivered += Int64(frames)
        let callback = onSample
        queue.async { callback?(sample) }
    }

    private func makeSampleBuffer(data: UnsafeRawPointer, frames: Int, timestamp: CMTime) -> CMSampleBuffer? {
        let byteCount = frames * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr, let description else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: description, sampleCount: frames,
                                                                   presentationTimeStamp: timestamp, packetDescriptions: nil,
                                                                   sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
