import CoreImage

struct CameraFrameReadiness {
    private var first: TimeInterval?
    private var previous: Double?
    private var stableFrames = 0
    static func isBlack(_ luminance: Double) -> Bool { luminance < 0.5 / 255 }
    mutating func accepts(luminance: Double, now: TimeInterval, exposureAdjusting: Bool) -> Bool {
        if first == nil { first = now }
        let elapsed = now - first!
        guard !Self.isBlack(luminance) else { stableFrames = 0; previous = nil; return false }
        if let previous, abs(previous - luminance) <= max(2 / 255, previous * 0.15) { stableFrames += 1 }
        else { stableFrames = 0 }
        previous = luminance
        return elapsed >= 0.35 && ((!exposureAdjusting && stableFrames >= 3) || elapsed >= 1.2)
    }
    static func luminance(of image: CIImage, context: CIContext) -> Double {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}
