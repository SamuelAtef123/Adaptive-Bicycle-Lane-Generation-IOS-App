import Foundation
import CoreGraphics
import simd

// MARK: - Road Classification

enum RoadType: String, Codable {
    case oneWay = "one_way"
    case twoWay = "two_way"
}

enum TrafficLevel: String, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    init(fromRatio rho: Double) {
        if rho < 0.3 { self = .low }
        else if rho < 0.65 { self = .medium }
        else { self = .high }
    }
}

// MARK: - Lane Width

struct LaneWidthDecision {
    let roadType: RoadType
    let trafficLevel: TrafficLevel
    let targetWidth: Double       // in meters
    let availableWidth: Double    // in meters
    let finalWidth: Double        // min(target, available)
    let isNarrowRoad: Bool        // available < 1.2m

    static let minimumSafeWidth: Double = 1.2

    static func decide(roadType: RoadType, traffic: TrafficLevel, available: Double) -> LaneWidthDecision {
        let target: Double
        switch (roadType, traffic) {
        case (.oneWay, .low):              target = 1.8
        case (.oneWay, .medium),
             (.oneWay, .high):             target = 1.6
        case (.twoWay, .low):             target = 1.4
        case (.twoWay, .medium),
             (.twoWay, .high):            target = 1.2
        }
        let final = min(target, available)
        return LaneWidthDecision(
            roadType: roadType,
            trafficLevel: traffic,
            targetWidth: target,
            availableWidth: available,
            finalWidth: final,
            isNarrowRoad: available < minimumSafeWidth
        )
    }
}

// MARK: - Obstacle

struct TrackedObstacle {
    let trackID: Int
    let classID: Int
    let className: String
    let boundingBox: CGRect      // normalized 0..1
    let confidence: Float
    let depthEstimate: Float     // meters, 0 if unknown
}

// MARK: - Path

struct VirtualLanePath {
    let rightAnchors: [CGPoint]  // 4 points in pixel coords
    let leftAnchors: [CGPoint]   // 4 points in pixel coords
    let laneWidthMeters: Double
    let isNarrowCorridor: Bool
    let frameSize: CGSize
}

// MARK: - Navigation

enum ManeuverType: String {
    case goStraight = "GO_STRAIGHT"
    case turnLeft   = "TURN_LEFT"
    case turnRight  = "TURN_RIGHT"
    case unknown    = "UNKNOWN"
}

struct RouteManeuver {
    let type: ManeuverType
    let latitude: Double
    let longitude: Double
    let distanceFromStart: Double
    let instruction: String
}

struct TrafficFlowData {
    let currentSpeed: Double     // m/s
    let freeFlowSpeed: Double    // m/s
    var densityRatio: Double { max(0, 1.0 - currentSpeed / max(freeFlowSpeed, 1)) }
    var level: TrafficLevel { TrafficLevel(fromRatio: densityRatio) }
}

// MARK: - System State (rendered per frame)

struct FrameRenderState {
    var virtualPath: VirtualLanePath?
    var obstacles: [TrackedObstacle] = []
    var laneDecision: LaneWidthDecision?
    var roadType: RoadType?
    var trafficLevel: TrafficLevel?
    var bikeLaneDetected: Bool = false
    var intersectionMode: Bool = false
    var upcomingManeuver: ManeuverType = .unknown
    var warnings: Set<WarningType> = []
    var availableWidthMeters: Double = 0
}

enum WarningType: Hashable {
    case narrowRoad
    case narrowCorridor
    case obstacleAhead
    case intersectionAhead
}

// MARK: - Bezier

struct BezierCurve {
    let p0, p1, p2, p3: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }

    func points(steps: Int = 30) -> [CGPoint] {
        (0...steps).map { point(at: CGFloat($0) / CGFloat(steps)) }
    }

    static func from(_ pts: [CGPoint]) -> BezierCurve? {
        guard pts.count == 4 else { return nil }
        return BezierCurve(p0: pts[0], p1: pts[1], p2: pts[2], p3: pts[3])
    }
}
