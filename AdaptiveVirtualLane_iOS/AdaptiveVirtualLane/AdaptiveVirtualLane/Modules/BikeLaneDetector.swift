import CoreML
import Vision
import CoreGraphics
import UIKit

final class BikeLaneDetector {

    private var model: VNCoreMLModel?
    private let confidenceThreshold: Float

    // Detection result
    struct Result {
        let detected: Bool
        let mask: CGImage?           // segmentation mask (640×640 grayscale)
        let confidence: Float
        let maskPixels: [[Bool]]?    // true = bike lane pixel, [row][col]
    }

    init(confidenceThreshold: Float = 0.5) {
        self.confidenceThreshold = confidenceThreshold
        loadModel()
    }

    private func loadModel() {
        // Load bike_lane_seg.mlmodel (YOLO26n-Seg compiled model)
        guard
            let modelURL = Bundle.main.url(forResource: "bike_lane_seg", withExtension: "mlmodelc")
                        ?? Bundle.main.url(forResource: "bike_lane_seg", withExtension: "mlmodel"),
            let coreMLModel = try? MLModel(contentsOf: modelURL),
            let vnModel = try? VNCoreMLModel(for: coreMLModel)
        else {
            print("[BikeLaneDetector] WARNING: bike_lane_seg model not found. Using stub.")
            return
        }
        self.model = vnModel
    }

    // MARK: - Inference

    func detect(pixelBuffer: CVPixelBuffer, completion: @escaping (Result) -> Void) {
        guard let model else {
            // Stub: no detection
            completion(Result(detected: false, mask: nil, confidence: 0, maskPixels: nil))
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self else { return }
            if let error { print("[BikeLaneDetector] \(error)"); completion(Result(detected: false, mask: nil, confidence: 0, maskPixels: nil)); return }
            self.handleResults(request.results, completion: completion)
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleResults(_ results: [VNObservation]?, completion: (Result) -> Void) {
        // For YOLO segmentation output — handle VNCoreMLFeatureValueObservation
        guard let observations = results as? [VNCoreMLFeatureValueObservation] else {
            // Fallback: try pixel buffer observation
            if let pixelObs = results?.first as? VNPixelBufferObservation {
                let mask = pixelObsToBoolMask(pixelObs)
                let hasLane = mask?.contains(where: { row in row.contains(true) }) ?? false
                completion(Result(detected: hasLane, mask: nil, confidence: hasLane ? 0.75 : 0, maskPixels: mask))
                return
            }
            completion(Result(detected: false, mask: nil, confidence: 0, maskPixels: nil))
            return
        }

        // Parse segmentation mask from feature value
        var bestConfidence: Float = 0
        var bestMask: [[Bool]]? = nil

        for obs in observations {
            if let multiArray = obs.featureValue.multiArrayValue {
                let (mask, conf) = parseMaskFromMultiArray(multiArray)
                if conf > bestConfidence {
                    bestConfidence = conf
                    bestMask = mask
                }
            }
        }

        let detected = bestConfidence >= confidenceThreshold
        completion(Result(
            detected: detected,
            mask: nil,
            confidence: bestConfidence,
            maskPixels: detected ? bestMask : nil
        ))
    }

    // MARK: - Mask Parsing

    private func parseMaskFromMultiArray(_ array: MLMultiArray) -> ([[Bool]], Float) {
        let shape = array.shape.map { $0.intValue }
        // Expected shape: [1, H, W] or [H, W]
        let height: Int
        let width: Int
        if shape.count >= 3 {
            height = shape[shape.count - 2]
            width  = shape[shape.count - 1]
        } else if shape.count == 2 {
            height = shape[0]
            width  = shape[1]
        } else {
            return ([], 0)
        }

        var mask = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
        var totalActive: Float = 0
        let total = Float(height * width)

        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                let val = array[idx].floatValue
                let active = val > 0.5
                mask[row][col] = active
                if active { totalActive += 1 }
            }
        }

        // Confidence ~ fraction of active pixels (capped) as proxy when no class score available
        let coverage = totalActive / total
        let confidence: Float = coverage > 0.01 ? min(0.5 + coverage * 2.0, 0.99) : 0
        return (mask, confidence)
    }

    private func pixelObsToBoolMask(_ obs: VNPixelBufferObservation) -> [[Bool]]? {
        let pb = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        for row in 0..<h {
            for col in 0..<w {
                mask[row][col] = ptr[row * bpr + col] > 127
            }
        }
        return mask
    }

    // MARK: - Geometry Helpers

    /// Find the rightmost and leftmost columns of the bike lane mask at a given row
    static func laneExtent(in mask: [[Bool]], atRow row: Int) -> (left: Int, right: Int)? {
        guard row < mask.count else { return nil }
        let cols = mask[row]
        guard let left = cols.firstIndex(of: true),
              let right = cols.lastIndex(of: true) else { return nil }
        return (left, right)
    }

    /// Returns center-x of the detected lane at 4 equally-spaced rows
    func anchorPoints(from mask: [[Bool]], frameSize: CGSize) -> (left: [CGPoint], right: [CGPoint]) {
        let h = mask.count
        let w = mask.first?.count ?? 640
        guard h > 0, w > 0 else { return ([], []) }

        // Find vertical extent of the mask
        var topRow = h - 1
        var botRow = 0
        for row in 0..<h {
            if mask[row].contains(true) {
                topRow = min(topRow, row)
                botRow = max(botRow, row)
            }
        }
        guard topRow < botRow else { return ([], []) }

        var leftPts  = [CGPoint]()
        var rightPts = [CGPoint]()

        let scaleX = frameSize.width  / CGFloat(w)
        let scaleY = frameSize.height / CGFloat(h)

        for i in 0..<4 {
            let row = topRow + i * (botRow - topRow) / 3
            guard row < h else { continue }
            if let extent = Self.laneExtent(in: mask, atRow: row) {
                leftPts.append(CGPoint(x: CGFloat(extent.left)  * scaleX, y: CGFloat(row) * scaleY))
                rightPts.append(CGPoint(x: CGFloat(extent.right) * scaleX, y: CGFloat(row) * scaleY))
            }
        }
        return (leftPts, rightPts)
    }
}
