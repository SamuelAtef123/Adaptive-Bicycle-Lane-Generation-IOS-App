import AVFoundation
import CoreVideo
import UIKit

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput pixelBuffer: CVPixelBuffer, frameIndex: Int)
}

final class CameraManager: NSObject {

    weak var delegate: CameraManagerDelegate?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.avl.camera.session", qos: .userInteractive)
    private let outputQueue  = DispatchQueue(label: "com.avl.camera.output",  qos: .userInteractive)

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var frameIndex: Int = 0

    // MARK: - Setup

    func requestPermissionAndSetup(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { completion(false); return }
            self?.sessionQueue.async {
                self?.configureSession()
                completion(true)
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Input
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input  = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { session.commitConfiguration(); return }
        session.addInput(input)

        // Configure device for best quality
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()

        // Output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration(); return
        }
        session.addOutput(videoOutput)

        // Orientation
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        // Preview layer
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.connection?.videoOrientation = .portrait
        DispatchQueue.main.async { self.previewLayer = preview }
    }

    // MARK: - Controls

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Horizontal field of view in radians from the active capture device
    var horizontalFOV: Float {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else {
            return Float(65 * Double.pi / 180) // fallback 65°
        }
        return device.activeFormat.videoFieldOfView * Float.pi / 180
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let idx = frameIndex
        frameIndex += 1
        delegate?.cameraManager(self, didOutput: pixelBuffer, frameIndex: idx)
    }
}
