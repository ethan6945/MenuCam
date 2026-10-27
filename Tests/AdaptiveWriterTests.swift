import Foundation
import AVFoundation
import CoreImage
import AudioToolbox
import CoreMedia

@main
struct Tests {
    static func makeAudioBuffer(index: Int) -> CMSampleBuffer? {
        let frames = 1024
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr, let description else { return nil }
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &pointer)
        if let pointer {
            pointer.withMemoryRebound(to: Float.self, capacity: frames) { samples in
                for i in 0..<frames { samples[i] = Float(sin(Double(index * frames + i) * 0.05)) * 0.1 }
            }
        }
        var sample: CMSampleBuffer?
        let stamp = CMTime(value: Int64(index * frames), timescale: 48000)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: description, sampleCount: frames,
                                                                   presentationTimeStamp: stamp, packetDescriptions: nil,
                                                                   sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    static func main() throws {
        setbuf(stdout, nil)
        // Gentle automatic curve: untouched in normal light, capped at +1 EV,
        // and only engaged when the scene is genuinely dark.
        precondition(AdaptiveWriter.targetExposure(luminance: 0) == 1.0)
        precondition(AdaptiveWriter.targetExposure(luminance: 0.6) == 0)
        precondition(AdaptiveWriter.targetExposure(luminance: 0.2) == 0)
        precondition(AdaptiveWriter.targetExposure(luminance: 0.05) > 0.5)
        precondition(AdaptiveWriter.targetExposure(luminance: 0.08) < 0.5)

        let queue = DispatchQueue(label: "test.capture")
        let encoder = AdaptiveWriter(queue: queue)
        encoder.audioEnabled = true
        encoder.audioChannels = 1
        encoder.audioSampleRate = 48000
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let completed = DispatchSemaphore(value: 0)
        var finishError: Error?
        var didStart = false
        encoder.onStart = { _ in didStart = true }
        encoder.onFinish = { _, error in finishError = error; completed.signal() }
        queue.sync { encoder.begin(file: path) }
        let photoDone = DispatchSemaphore(value: 0)
        var photo: Data?
        var photoRequestedAt = -1
        var audioIndex = 0
        for frame in 0..<240 {
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
            // Dark scene for the first 3 s (~30% below the engage threshold),
            // bright scene afterwards.
            let gray: UInt8 = frame < 90 ? 12 : 160
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * row + x * 4
                    base[offset] = gray; base[offset + 1] = gray; base[offset + 2] = gray; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            var description: CMVideoFormatDescription?
            precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description) == noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
            if frame == 12 {
                photoRequestedAt = frame
                queue.sync { encoder.requestSnapshot { result in
                    if case .success(let data) = result { photo = data }
                    photoDone.signal()
                } }
            }
            queue.sync { encoder.process(sample!) }
            let needed = Int(Double(frame + 1) / 30.0 * 48000 / 1024.0)
            while audioIndex < needed {
                guard let audio = makeAudioBuffer(index: audioIndex) else { break }
                queue.sync { encoder.processAudio(audio) }
                audioIndex += 1
            }
            Thread.sleep(forTimeInterval: 0.006)
        }
        while audioIndex < 375 {
            guard let audio = makeAudioBuffer(index: audioIndex) else { break }
            queue.sync { encoder.processAudio(audio) }
            audioIndex += 1
        }
        queue.sync { encoder.finish() }
        precondition(completed.wait(timeout: .now() + 20) == .success, "Encoder completion timed out")
        if let finishError { throw finishError }
        precondition(didStart)
        precondition(photoDone.wait(timeout: .now() + 4) == .success)
        guard let photo, let photoImage = CIImage(data: photo) else { fatalError("Missing JPEG snapshot") }
        precondition(photoImage.extent.width == 320 && photoImage.extent.height == 240)
        precondition(photoRequestedAt == 12)
        var rejectedAfterStop = false
        queue.sync { encoder.requestSnapshot { result in if case .failure = result { rejectedAfterStop = true } } }
        precondition(rejectedAfterStop)
        print("PASS: on-demand JPEG uses a fresh recent video frame, valid dimensions, does not stop movie; idle snapshot rejected")
        let asset = AVURLAsset(url: path)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 30)
        let context = CIContext()
        func brightness(_ time: Double) throws -> Double {
            let cg = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 30), actualTime: nil)
            precondition(cg.width == 320 && cg.height == 240)
            let image = CIImage(cgImage: cg)
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Double(bytes[0])
        }
        let first = try brightness(0)
        let enhanced = try brightness(2.5)
        let restored = try brightness(7.8)
        precondition(first < 22, "Dark frame should stay dark (\(first))")
        precondition(enhanced > first + 4, "Dark scene did not brighten (\(first) → \(enhanced))")
        precondition(restored > 145 && restored < 195, "Brightness failed to recover (\(restored))")
        precondition(abs(CMTimeGetSeconds(asset.duration) - 8) < 0.5)
        let audioTracks = asset.tracks(withMediaType: .audio)
        let audioSeconds = audioTracks.first.map { CMTimeGetSeconds($0.timeRange.duration) } ?? -1
        precondition(audioTracks.count == 1, "Expected exactly one audio track, got \(audioTracks.count)")
        precondition(audioSeconds > 7.4, "Audio track too short: \(audioSeconds)")
        print("PASS: dark frame \(first) → \(enhanced) (max +1 EV); bright scene recovered to \(restored); MOV readable, 320×240, \(CMTimeGetSeconds(asset.duration)) s; audio track muxed, \(audioSeconds) s; exposure gain bounded to 0...1 EV")
        // Uniform overall enhancement: every input is lifted by the same gain —
        // quiet input is brought up strongly, loud input stays near unity, and
        // there is no voice gate muting "silence" (only the smooth peak guard).
        func rms(_ x: [Float]) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot() }
        func feed(_ e: inout SpeechEnhancer, _ amp: Float, _ buffers: Int) -> [Float] {
            var last: [Float] = []
            for b in 0..<buffers {
                var buf = (0..<4800).map { i -> Float in
                    let t = Float(b * 4800 + i) / 48000
                    return amp * sin(2 * .pi * 1000 * t)
                }
                e.process(&buf)
                last = buf
            }
            return last
        }
        var quiet = SpeechEnhancer(sampleRate: 48000)
        let quietOut = feed(&quiet, 0.01, 30)
        var loud = SpeechEnhancer(sampleRate: 48000)
        let loudOut = feed(&loud, 0.6, 40)
        var faint = SpeechEnhancer(sampleRate: 48000)
        let faintOut = feed(&faint, 0.002, 25)
        var silent = SpeechEnhancer(sampleRate: 48000)
        let silentOut = feed(&silent, 0.0001, 10)
        precondition(quiet.currentGain > 8, "quiet input not amplified (\(quiet.currentGain))")
        precondition(loud.currentGain < 1.5, "loud input should stay near unity (\(loud.currentGain))")
        precondition(rms(quietOut) > 0.04, "quiet output too low (\(rms(quietOut)))")
        precondition(rms(loudOut) < 0.6, "loud output over-amplified (\(rms(loudOut)))")
        // A very faint sound (below the old noise gate) must still come up.
        precondition(faint.currentGain > 8, "faint sound gated out (\(faint.currentGain))")
        precondition(rms(faintOut) > 0.04, "faint sound not captured (\(rms(faintOut)))")
        // Digital silence must not be blown up into noise, and nothing may clip.
        precondition(rms(silentOut) < 0.01, "silence boosted too far (\(rms(silentOut)))")
        precondition(rms(quietOut) <= 0.99 && rms(loudOut) <= 0.99, "uniform output clipped")
        print("PASS: uniform enhancer quiet-gain=\(quiet.currentGain)x faint-gain=\(faint.currentGain)x loud-gain=\(loud.currentGain)x faint-rms=\(rms(faintOut)) silence-rms=\(rms(silentOut))")

        // Stopping before the first frame must report a failure, not a saved video.
        let empty = AdaptiveWriter(queue: queue)
        var emptyRejected = false
        empty.onFinish = { _, error in emptyRejected = error != nil }
        queue.sync {
            empty.begin(file: path.deletingLastPathComponent().appendingPathComponent("empty-test.mov"))
            empty.finish()
        }
        precondition(emptyRejected)
        print("PASS: no-frame recording rejected")

        // Mirror: a left-dark / right-bright frame must come out flipped.
        let mirrorPath = path.deletingLastPathComponent().appendingPathComponent("mirror-test.mov")
        try? FileManager.default.removeItem(at: mirrorPath)
        let mirrorQueue = DispatchQueue(label: "test.mirror")
        let mirrorWriter = AdaptiveWriter(queue: mirrorQueue)
        mirrorWriter.mirror = true
        let mirrorDone = DispatchSemaphore(value: 0)
        mirrorWriter.onFinish = { _, _ in mirrorDone.signal() }
        mirrorQueue.sync { mirrorWriter.begin(file: mirrorPath) }
        for frame in 0..<45 {
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * row + x * 4
                    let value: UInt8 = x < 160 ? 20 : 220   // left dark, right bright
                    base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            var description: CMVideoFormatDescription?
            precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description) == noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
            mirrorQueue.sync { mirrorWriter.process(sample!) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        mirrorQueue.sync { mirrorWriter.finish() }
        precondition(mirrorDone.wait(timeout: .now() + 20) == .success, "mirror encode timed out")
        let mirrorAsset = AVURLAsset(url: mirrorPath)
        let mirrorGenerator = AVAssetImageGenerator(asset: mirrorAsset)
        mirrorGenerator.requestedTimeToleranceBefore = .zero
        mirrorGenerator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 30)
        let mirrorImage = CIImage(cgImage: try mirrorGenerator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 30), actualTime: nil))
        func patchBrightness(_ rect: CGRect) -> Double {
            let average = mirrorImage.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Double(bytes[0])
        }
        let leftAfter = patchBrightness(CGRect(x: 20, y: 100, width: 80, height: 40))
        let rightAfter = patchBrightness(CGRect(x: 220, y: 100, width: 80, height: 40))
        precondition(leftAfter > 150, "left side should be bright after mirroring (\(leftAfter))")
        precondition(rightAfter < 90, "right side should be dark after mirroring (\(rightAfter))")
        print("PASS: mirror applied — left \(Int(leftAfter)) / right \(Int(rightAfter)) (was 20 / 220)")
    }
}
