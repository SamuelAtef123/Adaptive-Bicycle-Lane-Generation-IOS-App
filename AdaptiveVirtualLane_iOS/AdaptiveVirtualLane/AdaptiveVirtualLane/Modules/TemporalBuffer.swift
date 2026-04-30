import Foundation
import CoreGraphics

// MARK: - Temporal Buffer

final class TemporalBuffer {

    private let windowSize: Int

    // Categorical buffers
    private var roadTypeBuffer: [(RoadType, Float)] = []    // (type, confidence)
    private var bikeLaneBuffer: [(Bool, Float)] = []

    // Continuous buffers
    private var laneWidthBuffer: [Double] = []

    // Path point filters (8 points: 4 right + 4 left)
    private var rightAnchorFilters: [KalmanPoint] = Array(repeating: KalmanPoint(), count: 4)
    private var leftAnchorFilters:  [KalmanPoint] = Array(repeating: KalmanPoint(), count: 4)
    private var widthEuroFilter = OneEuroFilterScalar(minCutoff: 1.0, beta: 0.1, dCutoff: 1.0)

    // Drivable area pixel count for intersection detection
    private var drivablePixelCounts: [Int] = []

    init(windowSize: Int = 5) {
        self.windowSize = windowSize
    }

    // MARK: - Update

    func addRoadType(_ type: RoadType, confidence: Float) {
        roadTypeBuffer.append((type, confidence))
        if roadTypeBuffer.count > windowSize { roadTypeBuffer.removeFirst() }
    }

    func addBikeLane(detected: Bool, confidence: Float) {
        bikeLaneBuffer.append((detected, confidence))
        if bikeLaneBuffer.count > windowSize { bikeLaneBuffer.removeFirst() }
    }

    func addLaneWidth(_ width: Double) {
        laneWidthBuffer.append(width)
        if laneWidthBuffer.count > windowSize { laneWidthBuffer.removeFirst() }
    }

    func addDrivablePixelCount(_ count: Int) {
        drivablePixelCounts.append(count)
        if drivablePixelCounts.count > windowSize { drivablePixelCounts.removeFirst() }
    }

    // MARK: - Query (Majority Voting)

    var stableRoadType: RoadType {
        let oneWayCount = roadTypeBuffer.filter { $0.0 == .oneWay }.count
        let twoWayCount = roadTypeBuffer.count - oneWayCount
        return oneWayCount > twoWayCount ? .oneWay : .twoWay
    }

    var stableBikeLanePresence: Bool {
        let detectedCount = bikeLaneBuffer.filter { $0.0 }.count
        return detectedCount > bikeLaneBuffer.count / 2
    }

    // MARK: - One-Euro Filtered Lane Width

    func smoothedLaneWidth(_ raw: Double, dt: Double = 1.0/30.0) -> Double {
        widthEuroFilter.filter(value: raw, dt: dt)
    }

    // MARK: - Kalman-Filtered Anchor Points

    func smoothedRightAnchor(index: Int, measurement: CGPoint) -> CGPoint {
        guard index < rightAnchorFilters.count else { return measurement }
        return rightAnchorFilters[index].update(measurement: measurement)
    }

    func smoothedLeftAnchor(index: Int, measurement: CGPoint) -> CGPoint {
        guard index < leftAnchorFilters.count else { return measurement }
        return leftAnchorFilters[index].update(measurement: measurement)
    }

    // MARK: - Intersection Detection

    /// Returns true if current drivable pixel count has expanded >40% vs rolling average
    var isDrivableAreaExpanded: Bool {
        guard drivablePixelCounts.count >= 2 else { return false }
        let avg = Double(drivablePixelCounts.dropLast().reduce(0, +)) / Double(max(1, drivablePixelCounts.count - 1))
        let current = Double(drivablePixelCounts.last ?? 0)
        return avg > 0 && (current / avg) > 1.4
    }

    func reset() {
        roadTypeBuffer.removeAll()
        bikeLaneBuffer.removeAll()
        laneWidthBuffer.removeAll()
        drivablePixelCounts.removeAll()
        rightAnchorFilters = Array(repeating: KalmanPoint(), count: 4)
        leftAnchorFilters  = Array(repeating: KalmanPoint(), count: 4)
        widthEuroFilter = OneEuroFilterScalar(minCutoff: 1.0, beta: 0.1, dCutoff: 1.0)
    }
}

// MARK: - Kalman Filter for 2D Point

struct KalmanPoint {
    // State: [x, y, vx, vy]
    private var x: Double = 0, y: Double = 0
    private var vx: Double = 0, vy: Double = 0
    private var px: Double = 100, py: Double = 100
    private var pvx: Double = 10, pvy: Double = 10

    private let q: Double = 0.1   // process noise
    private let r: Double = 5.0   // measurement noise
    private var initialized = false

    mutating func update(measurement: CGPoint) -> CGPoint {
        if !initialized {
            x = measurement.x; y = measurement.y
            initialized = true
            return measurement
        }

        // Predict
        x += vx; y += vy
        px += q;  py += q
        pvx += q; pvy += q

        // Update X
        let kx = px / (px + r)
        x  = x  + kx * (Double(measurement.x) - x)
        vx = vx + kx * (Double(measurement.x) - x) * 0.1
        px = (1 - kx) * px

        // Update Y
        let ky = py / (py + r)
        y  = y  + ky * (Double(measurement.y) - y)
        vy = vy + ky * (Double(measurement.y) - y) * 0.1
        py = (1 - ky) * py

        return CGPoint(x: x, y: y)
    }
}

// MARK: - One-Euro Filter (scalar)

struct OneEuroFilterScalar {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double

    private var xPrev: Double = 0
    private var dxPrev: Double = 0
    private var initialized = false

    mutating func filter(value: Double, dt: Double) -> Double {
        if !initialized { xPrev = value; initialized = true; return value }

        let dValue = (value - xPrev) / dt
        let aDeriv = alpha(cutoff: dCutoff, dt: dt)
        let dx = aDeriv * dValue + (1 - aDeriv) * dxPrev
        dxPrev = dx

        let cutoff = minCutoff + beta * abs(dx)
        let a = alpha(cutoff: cutoff, dt: dt)
        let filtered = a * value + (1 - a) * xPrev
        xPrev = filtered
        return filtered
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
