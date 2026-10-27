import Foundation
import AVFoundation
import CoreImage
@main struct PreviewTests {
    static func main() throws {
        let queue = DispatchQueue(label: "MenuCam.PhotoBenchmark")
        let writer = AdaptiveWriter(queue: queue)
        let file = URL(fileURLWithPath: "/private/tmp/menucam-photo-benchmark-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: file) }
        queue.sync { writer.begin(file: file) }
        let finished = DispatchSemaphore(value: 0)
        writer.onFinish = { _, _ in finished.signal() }
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let count = CVPixelBufferGetBytesPerRow(pixels) * 1080
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: (i * 13) ^ (i / 203)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<3 {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            let done = DispatchSemaphore(value: 0)
            var photo: Data?
            queue.sync { writer.process(sample!) }
            let start = ProcessInfo.processInfo.systemUptime
            queue.sync { writer.requestSnapshot { result in if case .success(let data) = result { photo = data }; done.signal() } }
            precondition(done.wait(timeout: .now() + 3) == .success)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            guard let photo, let image = CIImage(data: photo) else { fatalError("Photo encoding failed") }
            precondition(image.extent.width == 960 && image.extent.height == 540)
            precondition(photo.count < 300_000)
            print("PASS: 1080p -> 960x540 photo, \(photo.count) bytes, \(Int(elapsed * 1000)) ms (sample \(frame + 1))")
        }
        queue.sync { writer.finish() }
        precondition(finished.wait(timeout: .now() + 5) == .success)
    }
}
