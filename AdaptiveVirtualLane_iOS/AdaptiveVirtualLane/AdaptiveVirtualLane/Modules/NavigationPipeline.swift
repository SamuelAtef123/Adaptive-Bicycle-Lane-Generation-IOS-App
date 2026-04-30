import Foundation
import CoreVideo
import CoreLocation
import Combine

final class NavigationPipeline: NSObject, ObservableObject {

    // MARK: - Modules
    private let preprocessor    = FramePreprocessor()
    private let bikeLaneDetector: BikeLaneDetector
    private let obstacleDetector: ObstacleDetector
    private let drivableSegmentor = DrivableAreaSegmentor()
    private let depthEstimator:   DepthEstimator
    private let roadTypeClassifier: RoadTypeClassifier
    private let pathGenerator:    PathGenerator
    private let flowWarper        = OpticalFlowWarper()
    private let temporalBuffer    = TemporalBuffer(windowSize: 5)
    private let voiceService      = VoiceGuidanceService()

    // MARK: - Services
    let locationService = LocationService()
    private var tomTomService: TomTomService

    // MARK: - Configuration
    private var keyframeInterval: Int = 5
    private var frameCount: Int = 0

    // MARK: - Cached keyframe state
    private var lastDrivableMask: [[Bool]] = []
    private var lastMaskSize: CGSize = .zero
    private var lastDepthMap: [[Float]] = []
    private var lastDrivablePixelCount: Int = 0
    private var lastTopRow: Int = 0
    private var lastBottomRow: Int = 0
    private var lastRightAnchors: [CGPoint] = []
    private var lastLeftAnchors: [CGPoint] = []
    private var lastObstacles: [TrackedObstacle] = []
    private var lastLaneWidth: Double = 1.4

    // MARK: - Navigation state
    private var destinationCoord: CLLocationCoordinate2D?
    private var intersectionMode: Bool = false
    private var intersectionDeactivationDistance: Double = 10  // meters past waypoint
    private var upcomingManeuver: ManeuverType = .unknown
    private var wasNear20m = false

    // MARK: - Published state for UI
    @Published var renderState = FrameRenderState()
    @Published var navigationStatus: String = "Idle"
    @Published var isRouteLoaded: Bool = false

    // MARK: - Camera
    private(set) var cameraFOV: Float = Float(65 * Double.pi / 180)

    // MARK: - Init

    init(apiKey: String, keyframeInterval: Int = 5,
         bikeLaneConf: Float = 0.5, obstacleConf: Float = 0.4, roadTypeConf: Float = 0.6) {
        self.keyframeInterval    = keyframeInterval
        self.tomTomService       = TomTomService(apiKey: apiKey)
        self.bikeLaneDetector    = BikeLaneDetector(confidenceThreshold: bikeLaneConf)
        self.obstacleDetector    = ObstacleDetector(confidenceThreshold: obstacleConf)
        self.roadTypeClassifier  = RoadTypeClassifier(confidenceThreshold: roadTypeConf)
        self.depthEstimator      = DepthEstimator()
        self.pathGenerator       = PathGenerator(depthEstimator: DepthEstimator())
        super.init()
    }

    func updateAPIKey(_ key: String) { tomTomService.updateAPIKey(key) }
    func updateCameraFOV(_ fov: Float) { self.cameraFOV = fov }

    // MARK: - Start Navigation

    func startNavigation(destination: String, currentLocation: CLLocationCoordinate2D) {
        navigationStatus = "Geocoding destination..."
        tomTomService.geocode(address: destination) { [weak self] coord in
            guard let self, let coord else {
                self?.navigationStatus = "Could not geocode destination"
                return
            }
            self.destinationCoord = coord
            self.fetchRoute(from: currentLocation, to: coord)
        }
    }

    private func fetchRoute(from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) {
        navigationStatus = "Loading route..."
        tomTomService.fetchRoute(from: origin, to: dest) { [weak self] maneuvers in
            guard let self else { return }
            self.isRouteLoaded = !maneuvers.isEmpty
            self.navigationStatus = maneuvers.isEmpty ? "Route unavailable (offline mode)" : "Route loaded — \(maneuvers.count) waypoints"
        }
    }

    func stopNavigation() {
        temporalBuffer.reset()
        frameCount = 0
        intersectionMode = false
        upcomingManeuver = .unknown
        navigationStatus = "Idle"
        isRouteLoaded = false
        voiceService.stop()
    }

    // MARK: - Main Frame Processing Entry Point

    func processFrame(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, frameSize: CGSize) {
        frameCount += 1
        let isKeyframe = (frameCount % keyframeInterval) == 0

        // Always preprocess
        guard let processed = preprocessor.preprocess(pixelBuffer) else { return }

        if isKeyframe {
            processKeyframe(processed, frameSize: frameSize)
        } else {
            processNonKeyframe(pixelBuffer, frameSize: frameSize)
        }

        // Update GPS / intersection / traffic asynchronously
        updateNavigationContext()
    }

    // MARK: - Keyframe Processing

    private func processKeyframe(_ pixelBuffer: CVPixelBuffer, frameSize: CGSize) {
        let dispatchGroup = DispatchGroup()
        var bikeLaneResult: BikeLaneDetector.Result?
        var obstacles: [TrackedObstacle] = []

        // Run bike lane + obstacle detection in parallel
        let perceptionQ = DispatchQueue(label: "com.avl.perception", attributes: .concurrent)

        dispatchGroup.enter()
        perceptionQ.async { [weak self] in
            guard let self else { dispatchGroup.leave(); return }
            self.bikeLaneDetector.detect(pixelBuffer: pixelBuffer) { result in
                bikeLaneResult = result
                dispatchGroup.leave()
            }
        }

        dispatchGroup.enter()
        perceptionQ.async { [weak self] in
            guard let self else { dispatchGroup.leave(); return }
            self.obstacleDetector.detect(pixelBuffer: pixelBuffer, frameSize: frameSize) { result in
                obstacles = result
                dispatchGroup.leave()
            }
        }

        dispatchGroup.wait()
        lastObstacles = obstacles

        // Update temporal buffer
        let bikeLaneDetected = bikeLaneResult?.detected ?? false
        temporalBuffer.addBikeLane(detected: bikeLaneDetected, confidence: bikeLaneResult?.confidence ?? 0)

        if bikeLaneDetected, let mask = bikeLaneResult?.maskPixels {
            // === BIKE LANE BRANCH ===
            let (leftPts, rightPts) = bikeLaneDetector.anchorPoints(from: mask, frameSize: frameSize)
            if let path = pathGenerator.generateFromBikeLaneMask(leftPts: leftPts, rightPts: rightPts,
                                                                   frameSize: frameSize,
                                                                   temporalBuffer: temporalBuffer) {
                lastRightAnchors = path.rightAnchors
                lastLeftAnchors  = path.leftAnchors
                publishRenderState(path: path, obstacles: obstacles, bikeLaneDetected: true)
            }
        } else {
            // === OPEN ROAD BRANCH ===
            runOpenRoadBranch(pixelBuffer: pixelBuffer, frameSize: frameSize, obstacles: obstacles)
        }
    }

    private func runOpenRoadBranch(pixelBuffer: CVPixelBuffer, frameSize: CGSize, obstacles: [TrackedObstacle]) {
        // Sequential: Drivable Area → Depth → Road Type → Width → Path
        drivableSegmentor.segment(pixelBuffer: pixelBuffer) { [weak self] segResult in
            guard let self else { return }
            self.lastDrivableMask = segResult.mask
            self.lastMaskSize     = segResult.maskSize
            self.lastTopRow       = segResult.topRow
            self.lastBottomRow    = segResult.bottomRow
            self.lastDrivablePixelCount = segResult.drivablePixelCount
            self.temporalBuffer.addDrivablePixelCount(segResult.drivablePixelCount)

            self.depthEstimator.estimate(pixelBuffer: pixelBuffer,
                                          drivableMask: segResult.mask,
                                          maskSize: segResult.maskSize,
                                          frameSize: frameSize) { [weak self] depthResult in
                guard let self else { return }
                self.lastDepthMap = depthResult.depthMap

                self.roadTypeClassifier.classify(pixelBuffer: pixelBuffer) { [weak self] roadResult in
                    guard let self else { return }

                    if let r = roadResult, r.isHighConfidence {
                        self.temporalBuffer.addRoadType(r.roadType, confidence: r.confidence)
                    }

                    let roadType    = self.temporalBuffer.stableRoadType
                    let traffic     = self.tomTomService.currentTrafficData?.level ?? .medium
                    let widthDecision = LaneWidthDecision.decide(
                        roadType: roadType, traffic: traffic, available: depthResult.availableWidthMeters)
                    let smoothedWidth = self.temporalBuffer.smoothedLaneWidth(widthDecision.finalWidth)
                    self.lastLaneWidth = smoothedWidth

                    let pathInput = PathGenerator.Input(
                        drivableMask: segResult.mask,
                        maskSize: segResult.maskSize,
                        depthMap: depthResult.depthMap,
                        laneWidthMeters: smoothedWidth,
                        obstacles: obstacles,
                        frameSize: frameSize,
                        cameraFOV: self.cameraFOV,
                        intersectionMode: self.intersectionMode,
                        upcomingManeuver: self.upcomingManeuver,
                        topRow: segResult.topRow,
                        bottomRow: segResult.bottomRow
                    )

                    if let path = self.pathGenerator.generate(input: pathInput, temporalBuffer: self.temporalBuffer) {
                        self.lastRightAnchors = path.rightAnchors
                        self.lastLeftAnchors  = path.leftAnchors
                        self.publishRenderState(path: path, obstacles: obstacles,
                                                bikeLaneDetected: false,
                                                laneDecision: widthDecision,
                                                roadType: roadType,
                                                traffic: traffic,
                                                depthResult: depthResult)
                    }
                }
            }
        }
    }

    // MARK: - Non-Keyframe Processing

    private func processNonKeyframe(_ pixelBuffer: CVPixelBuffer, frameSize: CGSize) {
        // Warp previous anchors via optical flow
        let (wRight, wLeft) = flowWarper.warpAnchorsSimple(
            rightAnchors: lastRightAnchors,
            leftAnchors: lastLeftAnchors,
            currentBuffer: pixelBuffer,
            frameSize: frameSize
        )

        // Check proximity warnings
        var warnings = Set<WarningType>()
        let obstaclesNearPath = lastObstacles.filter { obs in
            let pathRegion = CGRect(x: wLeft.map(\.x).min() ?? 0,
                                   y: wLeft.map(\.y).min() ?? 0,
                                   width: (wRight.map(\.x).max() ?? frameSize.width) - (wLeft.map(\.x).min() ?? 0),
                                   height: frameSize.height)
            return obs.boundingBox.intersects(pathRegion)
        }
        if !obstaclesNearPath.isEmpty { warnings.insert(.obstacleAhead) }

        // Reconstruct path with warped anchors
        let path = VirtualLanePath(
            rightAnchors: wRight, leftAnchors: wLeft,
            laneWidthMeters: lastLaneWidth, isNarrowCorridor: false, frameSize: frameSize
        )
        var state = FrameRenderState()
        state.virtualPath = path
        state.obstacles = lastObstacles
        state.bikeLaneDetected = temporalBuffer.stableBikeLanePresence
        state.intersectionMode = intersectionMode
        state.upcomingManeuver = upcomingManeuver
        state.warnings = warnings
        DispatchQueue.main.async { self.renderState = state }
    }

    // MARK: - Render State Publisher

    private func publishRenderState(path: VirtualLanePath,
                                     obstacles: [TrackedObstacle],
                                     bikeLaneDetected: Bool,
                                     laneDecision: LaneWidthDecision? = nil,
                                     roadType: RoadType? = nil,
                                     traffic: TrafficLevel? = nil,
                                     depthResult: DepthEstimator.Result? = nil) {
        var warnings = Set<WarningType>()
        if path.isNarrowCorridor  { warnings.insert(.narrowCorridor) }
        if depthResult?.isNarrowRoad == true { warnings.insert(.narrowRoad) }
        if intersectionMode { warnings.insert(.intersectionAhead) }
        if !obstacles.isEmpty { warnings.insert(.obstacleAhead) }

        // Voice warnings
        if warnings.contains(.narrowRoad)     { voiceService.announceNarrowRoad() }
        if warnings.contains(.obstacleAhead)  { voiceService.announceObstacleAhead() }

        var state = FrameRenderState()
        state.virtualPath     = path
        state.obstacles       = obstacles
        state.laneDecision    = laneDecision
        state.roadType        = roadType
        state.trafficLevel    = traffic
        state.bikeLaneDetected = bikeLaneDetected
        state.intersectionMode = intersectionMode
        state.upcomingManeuver = upcomingManeuver
        state.warnings        = warnings
        state.availableWidthMeters = depthResult?.availableWidthMeters ?? 0

        DispatchQueue.main.async { self.renderState = state }
    }

    // MARK: - Navigation Context (GPS / Traffic / Intersection)

    private var lastTrafficCheck: Date = .distantPast
    private let trafficQ = DispatchQueue(label: "com.avl.traffic", qos: .utility)

    private func updateNavigationContext() {
        guard let loc = locationService.currentLocation else { return }

        // Check intersection proximity
        let nearWaypoint = tomTomService.isNearNextWaypoint(currentLocation: loc, threshold: 20)
        let drivableExpanded = temporalBuffer.isDrivableAreaExpanded

        if nearWaypoint && drivableExpanded && !intersectionMode {
            intersectionMode = true
            if let maneuver = tomTomService.upcomingManeuver(currentLocation: loc) {
                upcomingManeuver = maneuver.type
                voiceService.announceApproaching(maneuver.type)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.voiceService.announceAtIntersection(maneuver.type)
                }
            }
        } else if nearWaypoint == false && intersectionMode {
            // Check if we've passed the waypoint by 10m
            if let next = tomTomService.upcomingManeuver(currentLocation: loc) {
                let dist = tomTomService.distance(from: loc,
                                                   to: CLLocationCoordinate2D(latitude: next.latitude, longitude: next.longitude))
                if dist > intersectionDeactivationDistance { intersectionMode = false }
            }
        }

        // Approaching pre-announcement
        if nearWaypoint && !wasNear20m {
            if let maneuver = tomTomService.upcomingManeuver(currentLocation: loc) {
                voiceService.announceApproaching(maneuver.type)
            }
        }
        wasNear20m = nearWaypoint

        // Traffic refresh (async, every 60s)
        trafficQ.async { [weak self] in
            guard let self else { return }
            self.tomTomService.fetchTraffic(at: loc) { _ in }
        }

        // Re-route if deviated
        if tomTomService.hasDeviated(from: loc), let dest = destinationCoord {
            fetchRoute(from: loc, to: dest)
        }
    }
}
