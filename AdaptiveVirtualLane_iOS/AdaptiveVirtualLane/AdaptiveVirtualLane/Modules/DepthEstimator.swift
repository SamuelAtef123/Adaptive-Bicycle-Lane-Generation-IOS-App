import CoreML
import Vision
import UIKit

final class DepthEstimator {

    private var model: VNCoreMLModel?
    private let cameraFOV: Float   // horizontal FOV in radians

    struct Result {
        /// Relative depth map [row][col] with values in meters (after scale-shift alignment)
        let depthMap: [[Float]]
        let mapWidth: Int
        let mapHeight: Int
        /// Estimated available road width in meters at the lower-third scan line
        let availableWidthMeters: Double
        /// Whether road is too narrow for safe cycling (<1.2m)
        let isNarrowRoad: Bool

        static let minimumSafeWidth: Double = 1.2
    }

    init(horizontalFOV: Float = Float(65 * Double.pi / 180)) {
        self.cameraFOV = horizontalFOV
        loadModel()
    }

    private func loadModel() {
        let candidates = ["DepthAnythingV2Small", "depth_anything_v2_small", "DepthAnythingV2"]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                      ?? Bundle.main.url(forResource: name, withExtension: "mlmodel"),
               let ml = try? MLModel(contentsOf: url),
               let vn = try? VNCoreMLModel(for: ml) {
                self.model = vn
                print("[DepthEstimator] Loaded \(name)")
                return
            }
        }
        print("[DepthEstimator] WARNING: No depth model. Using synthetic depth.")
    }

    // MARK: - Inference

    func estimate(pixelBuffer: CVPixelBuffer,
                  drivableMask: [[Bool]],
                  maskSize: CGSize,
                  frameSize: CGSize,
                  completion: @escaping (Result) -> Void) {

        guard let model else {
            // Synthetic fallback: assume road at 3m depth, compute width from mask
            let result = computeWidthFromMask(drivableMask,
                                              maskSize: maskSize,
                                              depthMap: nil,
                                              assumedDepth: 3.0,
                                              frameWidth: Int(frameSize.width))
            completion(result)
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] req, err in
            guard let self else { return }
            if let err { print("[DepthEstimator] \(err)") }
            self.handleResult(req.results,
                              drivableMask: drivableMask,
                              maskSize: maskSize,
                              frameSize: frameSize,
                              completion: completion)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleResult(_ results: [VNObservation]?,
                               drivableMask: [[Bool]],
                               maskSize: CGSize,
                               frameSize: CGSize,
                               completion: (Result) -> Void) {
        var depthMap: [[Float]]? = nil

        if let pbObs = results?.first as? VNDepthObservation {
            depthMap = depthPixelBufferToArray(pbObs.depthMap)
        } else if let featObs = results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
                  let arr = featObs.featureValue.multiArrayValue {
            depthMap = multiArrayToDepthMap(arr)
        }

        // Scale-shift alignment: align predicted relative depth to ground-plane reference
        if var map = depthMap {
            alignDepthMap(&map, drivableMask: drivableMask)
            let result = computeWidthFromMask(drivableMask,
                                              maskSize: maskSize,
                                              depthMap: map,
                                              assumedDepth: nil,
                                              frameWidth: Int(frameSize.width))
            completion(result)
        } else {
            let result = computeWidthFromMask(drivableMask,
                                              maskSize: maskSize,
                                              depthMap: nil,
                                              assumedDepth: 3.0,
                                              frameWidth: Int(frameSize.width))
            completion(result)
        }
    }

    // MARK: - Width Computation (Pinhole Model)
    // W_available = W_pixels × (D × 2 × tan(θ/2)) / W_image

    private func computeWidthFromMask(_ mask: [[Bool]],
                                       maskSize: CGSize,
                                       depthMap: [[Float]]?,
                                       assumedDepth: Double?,
                                       frameWidth: Int) -> Result {
        let h = Int(maskSize.height)
        let w = Int(maskSize.width)
        // Scan line at lower third
        let scanRow = Int(Double(h) * 0.75)

        // Count drivable pixels at scan row
        var leftCol = w, rightCol = 0
        guard scanRow < mask.count else {
            return makeResult(depthMap: depthMap ?? [], widthMeters: 5.0)
        }
        for col in 0..<w {
            if col < mask[scanRow].count && mask[scanRow][col] {
                leftCol  = min(leftCol, col)
                rightCol = max(rightCol, col)
            }
        }
        let pixelWidth = max(0, rightCol - leftCol)

        // Get depth at scan row center
        let depthAtScanRow: Double
        if let depthMap = depthMap, scanRow < depthMap.count {
            let centerCol = (leftCol + rightCol) / 2
            let col = min(centerCol, depthMap[scanRow].count - 1)
            depthAtScanRow = Double(depthMap[scanRow][col])
        } else {
            depthAtScanRow = assumedDepth ?? 3.0
        }

        // Pinhole projection
        let theta = Double(cameraFOV)
        let widthMeters = Double(pixelWidth) * (depthAtScanRow * 2.0 * tan(theta / 2)) / Double(w)

        return makeResult(depthMap: depthMap ?? [], widthMeters: widthMeters)
    }

    private func makeResult(depthMap: [[Float]], widthMeters: Double) -> Result {
        let h = depthMap.count
        let w = depthMap.first?.count ?? 0
        return Result(
            depthMap: depthMap,
            mapWidth: w, mapHeight: h,
            availableWidthMeters: widthMeters,
            isNarrowRoad: widthMeters < Result.minimumSafeWidth
        )
    }

    // MARK: - Depth at Specific Row (for path projection)

    func depthAtRow(_ row: Int, col: Int, depthMap: [[Float]]) -> Double {
        guard row < depthMap.count, col < depthMap[row].count else { return 3.0 }
        return Double(depthMap[row][col])
    }

    /// Convert metric lane width to pixels at a given row
    func metersToPixels(meters: Double, atRow row: Int, depthMap: [[Float]], imageWidth: Int) -> Int {
        let depth = depthAtRow(row, col: imageWidth / 2, depthMap: depthMap)
        let theta = Double(cameraFOV)
        let pixels = meters * Double(imageWidth) / (depth * 2.0 * tan(theta / 2))
        return max(1, Int(pixels))
    }

    // MARK: - Scale-Shift Alignment

    private func alignDepthMap(_ map: inout [[Float]], drivableMask: [[Bool]]) {
        // Collect ground-plane depth values (drivable pixels in lower quarter)
        let h = map.count
        let startRow = Int(Double(h) * 0.70)
        var groundValues = [Float]()

        for row in startRow..<h {
            guard row < drivableMask.count else { continue }
            for col in 0..<map[row].count {
                if col < drivableMask[row].count && drivableMask[row][col] {
                    groundValues.append(map[row][col])
                }
            }
        }

        guard !groundValues.isEmpty else { return }

        // Median of ground values
        let sorted = groundValues.sorted()
        let median = sorted[sorted.count / 2]

        // Target: ground plane at approximately 3m
        let targetDepth: Float = 3.0
        let scale = median > 0 ? targetDepth / median : 1.0

        // Apply scale
        for row in 0..<h {
            for col in 0..<map[row].count {
                map[row][col] *= scale
            }
        }
    }

    // MARK: - Array Conversion

    private func depthPixelBufferToArray(_ pb: CVPixelBuffer) -> [[Float]] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w   = CVPixelBufferGetWidth(pb)
        let h   = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        var map = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)
        for row in 0..<h {
            let rowOffset = row * bpr / MemoryLayout<Float32>.size
            for col in 0..<w { map[row][col] = ptr[rowOffset + col] }
        }
        return map
    }

    private func multiArrayToDepthMap(_ arr: MLMultiArray) -> [[Float]] {
        let shape = arr.shape.map { $0.intValue }
        let h = shape.count >= 2 ? shape[shape.count - 2] : 256
        let w = shape.count >= 1 ? shape[shape.count - 1] : 256
        var map = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)
        for row in 0..<h {
            for col in 0..<w { map[row][col] = arr[row * w + col].floatValue }
        }
        return map
    }
}
