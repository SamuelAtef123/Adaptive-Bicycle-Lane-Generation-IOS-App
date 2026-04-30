import CoreGraphics
import Foundation

final class PathGenerator {

    private let depthEstimator: DepthEstimator

    init(depthEstimator: DepthEstimator) {
        self.depthEstimator = depthEstimator
    }

    // MARK: - Main Path Generation

    struct Input {
        let drivableMask: [[Bool]]
        let maskSize: CGSize
        let depthMap: [[Float]]
        let laneWidthMeters: Double
        let obstacles: [TrackedObstacle]
        let frameSize: CGSize
        let cameraFOV: Float
        let intersectionMode: Bool
        let upcomingManeuver: ManeuverType
        let topRow: Int
        let bottomRow: Int
    }

    func generate(input: Input, temporalBuffer: TemporalBuffer) -> VirtualLanePath? {
        guard input.bottomRow > input.topRow else { return nil }

        // Step 1: Extract 4 scan-line rows
        let scanRows = makeScanRows(top: input.topRow, bottom: input.bottomRow)

        // Step 2: Right boundary anchor points
        var rightAnchors = extractRightAnchors(
            mask: input.drivableMask,
            maskSize: input.maskSize,
            frameSize: input.frameSize,
            scanRows: scanRows,
            intersectionMode: input.intersectionMode,
            maneuver: input.upcomingManeuver
        )

        guard rightAnchors.count == 4 else { return nil }

        // Step 3: Compute pixel lane width at each scan row using depth
        let pixelWidths = computePixelWidths(
            metersWidth: input.laneWidthMeters,
            scanRows: scanRows,
            depthMap: input.depthMap,
            maskSize: input.maskSize,
            frameSize: input.frameSize,
            cameraFOV: input.cameraFOV
        )

        // Step 4: Obstacle avoidance — shift right anchors
        var isNarrow = false
        for (i, _) in rightAnchors.enumerated() {
            let (adjusted, narrow) = applyObstacleAvoidance(
                rightAnchor: rightAnchors[i],
                scanRow: scanRows[i],
                laneWidthPixels: pixelWidths[i],
                obstacles: input.obstacles,
                depthMap: input.depthMap,
                maskSize: input.maskSize,
                frameSize: input.frameSize,
                cameraFOV: input.cameraFOV
            )
            rightAnchors[i] = adjusted
            if narrow { isNarrow = true }
        }

        // Step 5: Left boundary = right − width
        var leftAnchors = zip(rightAnchors, pixelWidths).map { pt, pw in
            CGPoint(x: max(0, pt.x - CGFloat(pw)), y: pt.y)
        }

        // Step 6: Kalman smoothing
        rightAnchors = rightAnchors.enumerated().map { temporalBuffer.smoothedRightAnchor(index: $0.offset, measurement: $0.element) }
        leftAnchors  = leftAnchors.enumerated().map  { temporalBuffer.smoothedLeftAnchor(index: $0.offset, measurement: $0.element) }

        return VirtualLanePath(
            rightAnchors: rightAnchors,
            leftAnchors: leftAnchors,
            laneWidthMeters: input.laneWidthMeters,
            isNarrowCorridor: isNarrow,
            frameSize: input.frameSize
        )
    }

    // MARK: - Bike Lane Branch

    func generateFromBikeLaneMask(leftPts: [CGPoint],
                                   rightPts: [CGPoint],
                                   frameSize: CGSize,
                                   temporalBuffer: TemporalBuffer) -> VirtualLanePath? {
        guard leftPts.count == 4, rightPts.count == 4 else { return nil }
        let right = rightPts.enumerated().map { temporalBuffer.smoothedRightAnchor(index: $0.offset, measurement: $0.element) }
        let left  = leftPts.enumerated().map  { temporalBuffer.smoothedLeftAnchor(index: $0.offset, measurement: $0.element) }
        return VirtualLanePath(rightAnchors: right, leftAnchors: left,
                               laneWidthMeters: 1.5, isNarrowCorridor: false, frameSize: frameSize)
    }

    // MARK: - Helpers

    private func makeScanRows(top: Int, bottom: Int) -> [Int] {
        (0..<4).map { i in top + i * (bottom - top) / 3 }
    }

    private func extractRightAnchors(mask: [[Bool]],
                                      maskSize: CGSize,
                                      frameSize: CGSize,
                                      scanRows: [Int],
                                      intersectionMode: Bool,
                                      maneuver: ManeuverType) -> [CGPoint] {
        let scaleX = frameSize.width  / maskSize.width
        let scaleY = frameSize.height / maskSize.height
        let mH = Int(maskSize.height)
        let mW = Int(maskSize.width)

        return scanRows.enumerated().compactMap { idx, maskRow in
            guard maskRow < mH, maskRow < mask.count else { return nil }
            let row = mask[maskRow]

            // For TURN_LEFT: use leftmost boundary in upper anchors
            if intersectionMode && maneuver == .turnLeft && idx < 2 {
                if let leftCol = row.firstIndex(of: true) {
                    return CGPoint(x: CGFloat(leftCol) * scaleX, y: CGFloat(maskRow) * scaleY)
                }
            }
            // For TURN_RIGHT: constrain to right half
            if intersectionMode && maneuver == .turnRight {
                let halfCol = mW / 2
                for col in stride(from: mW - 1, through: halfCol, by: -1) {
                    if col < row.count && row[col] {
                        return CGPoint(x: CGFloat(col) * scaleX, y: CGFloat(maskRow) * scaleY)
                    }
                }
            }
            // Default: rightmost drivable pixel
            for col in stride(from: mW - 1, through: 0, by: -1) {
                if col < row.count && row[col] {
                    return CGPoint(x: CGFloat(col) * scaleX, y: CGFloat(maskRow) * scaleY)
                }
            }
            return nil
        }
    }

    private func computePixelWidths(metersWidth: Double,
                                     scanRows: [Int],
                                     depthMap: [[Float]],
                                     maskSize: CGSize,
                                     frameSize: CGSize,
                                     cameraFOV: Float) -> [Int] {
        let imageWidth = Int(frameSize.width)
        let theta = Double(cameraFOV)
        let depthScaleRow = maskSize.height / frameSize.height

        return scanRows.map { frameRow in
            let maskRow = Int(Double(frameRow) * Double(depthScaleRow))
            let depth: Double
            if !depthMap.isEmpty && maskRow < depthMap.count {
                let midCol = min(depthMap[maskRow].count / 2, depthMap[maskRow].count - 1)
                depth = Double(depthMap[maskRow][max(0, midCol)])
            } else {
                // Estimate depth from row position (perspective: lower = closer)
                let normalizedRow = Double(frameRow) / frameSize.height
                depth = 1.5 + (1.0 - normalizedRow) * 8.0
            }
            let pixels = metersWidth * Double(imageWidth) / (depth * 2.0 * tan(theta / 2.0))
            return max(30, Int(pixels))
        }
    }

    private func applyObstacleAvoidance(rightAnchor: CGPoint,
                                         scanRow: Int,
                                         laneWidthPixels: Int,
                                         obstacles: [TrackedObstacle],
                                         depthMap: [[Float]],
                                         maskSize: CGSize,
                                         frameSize: CGSize,
                                         cameraFOV: Float) -> (CGPoint, Bool) {
        let safetyMarginMeters = 0.5
        let theta = Double(cameraFOV)
        let rowDepth: Double = {
            let maskRow = Int(Double(scanRow) * maskSize.height / frameSize.height)
            if !depthMap.isEmpty && maskRow < depthMap.count {
                return Double(depthMap[maskRow][depthMap[maskRow].count / 2])
            }
            return 3.0
        }()
        let safetyPixels = safetyMarginMeters * Double(Int(frameSize.width)) / (rowDepth * 2.0 * tan(theta / 2.0))

        var adjustedX = rightAnchor.x
        let rowBand = CGFloat(frameSize.height) / 4.0
        let rowTop  = CGFloat(scanRow) - rowBand / 2
        let rowBot  = CGFloat(scanRow) + rowBand / 2

        for obs in obstacles {
            let box = obs.boundingBox
            // Only obstacles within this scan row band
            guard box.maxY > rowTop && box.minY < rowBot else { continue }
            // If obstacle overlaps proposed lane corridor
            let laneLeft = rightAnchor.x - CGFloat(laneWidthPixels)
            if box.minX < rightAnchor.x && box.maxX > laneLeft {
                // Shift right boundary left of obstacle
                adjustedX = min(adjustedX, box.minX - CGFloat(safetyPixels))
            }
        }

        let isNarrow = (rightAnchor.x - adjustedX) < CGFloat(laneWidthPixels) * 0.5
        return (CGPoint(x: max(0, adjustedX), y: rightAnchor.y), isNarrow)
    }
}
