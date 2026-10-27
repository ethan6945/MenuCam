import AVFoundation
import CoreImage
import ImageIO

/// A short camera-only session. No file output, microphone or recording-environment changes.
final class IdlePhotoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "MenuCam.idlePhoto", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var completion: ((Result<Data, Error>) -> Void)?
    private var frames = 0
    private var readiness = CameraFrameReadiness()
    private var camera: AVCaptureDevice?
    private var capturing = false
    private var requestID = UUID()
    func capture(_ callback: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            guard self.completion == nil else { callback(.failure(Self.error("The camera is taking a photo"))); return }
            let requestID = UUID(); self.requestID = requestID
            self.completion = callback; self.frames = 0; self.capturing = false; self.readiness = CameraFrameReadiness()
            do {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) ?? AVCaptureDevice.default(for: .video) else { throw Self.error("No camera found") }
                self.camera = camera
                self.session.beginConfiguration()
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input) else { throw Self.error("The camera is in use by another app") }
                    self.session.addInput(input)
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(self.output) else { throw Self.error("Unable to create photo output") }
                    self.session.addOutput(self.output)
                    self.session.commitConfiguration()
                } catch { self.session.commitConfiguration(); throw error }
                self.session.startRunning()
                guard self.session.isRunning else { throw Self.error("The camera could not start") }
                self.queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.completion != nil, self.requestID == requestID else { return }
                    self.finish(.failure(Self.error("No valid camera image received. Check the camera and lighting, then retry.")))
                }
            } catch { self.finish(.failure(error)) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard completion != nil, !capturing, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        frames += 1
        let image = CIImage(cvPixelBuffer: buffer).oriented(.upMirrored)
        let luminance = CameraFrameReadiness.luminance(of: image, context: context)
        guard readiness.accepts(luminance: luminance, now: ProcessInfo.processInfo.systemUptime, exposureAdjusting: camera?.isAdjustingExposure ?? false) else { return }
        capturing = true
        let scale = min(1, 960 / max(image.extent.width, image.extent.height))
        let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let data = context.jpegRepresentation(of: preview, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [quality: 0.65])
        queue.async { self.finish(data.map { .success($0) } ?? .failure(Self.error("Unable to generate the photo"))) }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let callback = completion else { return }
        completion = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        camera = nil
        callback(result) // Camera is released before delivering the photo.
    }
    private static func error(_ message: String) -> NSError { NSError(domain: "MenuCam.IdlePhoto", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
