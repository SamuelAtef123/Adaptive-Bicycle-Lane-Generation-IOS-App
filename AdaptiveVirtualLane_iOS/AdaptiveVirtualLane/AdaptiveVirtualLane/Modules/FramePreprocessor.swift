import CoreImage
import CoreVideo
import UIKit
import Accelerate

final class FramePreprocessor {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    static let modelInputSize = CGSize(width: 640, height: 640)

    // MARK: - Public API

    /// Returns a 640×640 CVPixelBuffer suitable for CoreML inference
    func preprocess(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Step 1: Color correction (auto-levels / CLAHE approximation via CoreImage)
        ciImage = applyColorCorrection(to: ciImage)

        // Step 2: Resize to 640×640
        guard let resized = resize(ciImage, to: Self.modelInputSize) else { return nil }

        return resized
    }

    /// Returns a UIImage for display / debugging
    func preprocessToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciImage = applyColorCorrection(to: ciImage)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Color Correction

    private func applyColorCorrection(to image: CIImage) -> CIImage {
        // Vibrance + Exposure adjustment for low-light/high-brightness robustness
        var result = image

        // Auto-exposure via histogram
        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(result, forKey: kCIInputImageKey)
            exposureFilter.setValue(0.3, forKey: kCIInputEVKey)
            if let out = exposureFilter.outputImage { result = out }
        }

        // Tone curve for HDR-like flattening
        if let toneFilter = CIFilter(name: "CIToneCurve") {
            toneFilter.setValue(result, forKey: kCIInputImageKey)
            toneFilter.setValue(CIVector(x: 0, y: 0),       forKey: "inputPoint0")
            toneFilter.setValue(CIVector(x: 0.25, y: 0.20), forKey: "inputPoint1")
            toneFilter.setValue(CIVector(x: 0.5,  y: 0.50), forKey: "inputPoint2")
            toneFilter.setValue(CIVector(x: 0.75, y: 0.78), forKey: "inputPoint3")
            toneFilter.setValue(CIVector(x: 1, y: 1),       forKey: "inputPoint4")
            if let out = toneFilter.outputImage { result = out }
        }

        // Contrast / saturation
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(result, forKey: kCIInputImageKey)
            colorFilter.setValue(1.05, forKey: kCIInputContrastKey)
            colorFilter.setValue(1.10, forKey: kCIInputSaturationKey)
            if let out = colorFilter.outputImage { result = out }
        }

        return result
    }

    // MARK: - Resize

    private func resize(_ image: CIImage, to size: CGSize) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &outputBuffer)

        guard let buffer = outputBuffer else { return nil }

        let scaleX = size.width  / image.extent.width
        let scaleY = size.height / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        ciContext.render(scaled, to: buffer)
        return buffer
    }

    // MARK: - Pixel Buffer → Float Array (normalized 0..1, RGB)

    func toNormalizedFloatArray(_ pixelBuffer: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var result = [Float](repeating: 0, count: width * height * 3)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = y * bytesPerRow + x * 4
                let b = Float(ptr[pixelOffset])     / 255.0
                let g = Float(ptr[pixelOffset + 1]) / 255.0
                let r = Float(ptr[pixelOffset + 2]) / 255.0
                let base = (y * width + x) * 3
                result[base]     = r
                result[base + 1] = g
                result[base + 2] = b
            }
        }
        return result
    }
}
