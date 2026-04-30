import CoreML
import Vision
import CoreGraphics
import UIKit

final class DrivableAreaSegmentor {

    private var model: VNCoreMLModel?

    struct Result {
        /// Bool mask [row][col], true = drivable. Dimensions match model output (typically 640×360 or 640×640)
        let mask: [[Bool]]
        let maskSize: CGSize
        /// Pixel count of drivable area
        let drivablePixelCount: Int
        /// Bounding rows of drivable area
        let topRow: Int
        let bottomRow: Int
    }

    init() { loadModel() }

    private func loadModel() {
        let candidates = ["TwinLiteNetPlusMedium", "TwinLiteNetPlus", "TwinLiteNet"]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                      ?? Bundle.main.url(forResource: name, withExtension: "mlmodel"),
               let ml = try? MLModel(contentsOf: url),
               let vn = try? VNCoreMLModel(for: ml) {
                self.model = vn
                print("[DrivableAreaSegmentor] Loaded \(name)")
                return
            }
        }
        print("[DrivableAreaSegmentor] WARNING: No model found. Using heuristic fallback.")
    }

    // MARK: - Inference

    func segment(pixelBuffer: CVPixelBuffer, completion: @escaping (Result) -> Void) {
        guard let model else {
            // Heuristic fallback: assume bottom 60% of frame is drivable
            let h = 640, w = 640
            let topRow = Int(Double(h) * 0.40)
            var mask = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
            for row in topRow..<h {
                for col in 0..<w { mask[row][col] = true }
            }
            let count = (h - topRow) * w
            completion(Result(mask: mask, maskSize: CGSize(width: w, height: h),
                              drivablePixelCount: count, topRow: topRow, bottomRow: h - 1))
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] req, err in
            if let err { print("[DrivableAreaSegmentor] \(err)") }
            self?.handleResult(req.results, completion: completion)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleResult(_ results: [VNObservation]?, completion: (Result) -> Void) {
        // Handle pixel buffer output
        if let pbObs = results?.first as? VNPixelBufferObservation {
            let mask = pixelBufferToBoolMask(pbObs.pixelBuffer)
            let stats = computeStats(mask)
            completion(Result(mask: mask,
                              maskSize: CGSize(width: mask.first?.count ?? 640, height: mask.count),
                              drivablePixelCount: stats.count,
                              topRow: stats.top, bottomRow: stats.bottom))
            return
        }

        // Handle MLMultiArray output
        if let featureObs = results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let arr = featureObs.featureValue.multiArrayValue {
            let mask = multiArrayToBoolMask(arr)
            let stats = computeStats(mask)
            completion(Result(mask: mask,
                              maskSize: CGSize(width: mask.first?.count ?? 640, height: mask.count),
                              drivablePixelCount: stats.count,
                              topRow: stats.top, bottomRow: stats.bottom))
            return
        }

        // Fallback
        segment(pixelBuffer: CVPixelBuffer.empty640(), completion: completion)
    }

    // MARK: - Helpers

    private func pixelBufferToBoolMask(_ pb: CVPixelBuffer) -> [[Bool]] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        for row in 0..<h {
            for col in 0..<w {
                // Grayscale: >127 = drivable
                mask[row][col] = ptr[row * bpr + col] > 127
            }
        }
        return mask
    }

    private func multiArrayToBoolMask(_ arr: MLMultiArray) -> [[Bool]] {
        let shape = arr.shape.map { $0.intValue }
        let h = shape.count >= 2 ? shape[shape.count - 2] : 640
        let w = shape.count >= 1 ? shape[shape.count - 1] : 640
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        for row in 0..<h {
            for col in 0..<w {
                mask[row][col] = arr[row * w + col].floatValue > 0.5
            }
        }
        return mask
    }

    private func computeStats(_ mask: [[Bool]]) -> (count: Int, top: Int, bottom: Int) {
        var count = 0, top = mask.count, bottom = 0
        for (r, row) in mask.enumerated() {
            let rowActive = row.filter { $0 }.count
            if rowActive > 0 {
                top    = min(top, r)
                bottom = max(bottom, r)
                count += rowActive
            }
        }
        return (count, top == mask.count ? 0 : top, bottom)
    }

    // MARK: - Scan-line anchor extraction

    /// Returns 4 right-boundary anchor points in pixel coords (scaled to frameSize)
    func rightBoundaryAnchors(from mask: [[Bool]],
                               maskSize: CGSize,
                               topRow: Int,
                               bottomRow: Int,
                               frameSize: CGSize) -> [CGPoint] {
        let h = Int(maskSize.height)
        let w = Int(maskSize.width)
        let scaleX = frameSize.width  / maskSize.width
        let scaleY = frameSize.height / maskSize.height
        var anchors = [CGPoint]()

        for i in 0..<4 {
            let row = topRow + i * max(1, (bottomRow - topRow)) / 3
            guard row < h else { continue }
            // Find rightmost drivable pixel in this row
            var rightCol = -1
            for col in stride(from: w - 1, through: 0, by: -1) {
                if row < mask.count && col < mask[row].count && mask[row][col] {
                    rightCol = col; break
                }
            }
            if rightCol >= 0 {
                anchors.append(CGPoint(x: CGFloat(rightCol) * scaleX, y: CGFloat(row) * scaleY))
            }
        }
        return anchors
    }
}

// MARK: - CVPixelBuffer helper

extension CVPixelBuffer {
    static func empty640() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 640, kCVPixelFormatType_OneComponent8, nil, &pb)
        return pb!
    }
}
