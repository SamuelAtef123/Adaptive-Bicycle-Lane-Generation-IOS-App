import CoreML
import Vision
import CoreGraphics

final class ObstacleDetector {

    private var model: VNCoreMLModel?
    private let confidenceThreshold: Float
    private var tracker: DeepSORTTracker

    // Classes we care about from MS COCO
    static let relevantClasses: [Int: String] = [
        0:  "person",
        1:  "bicycle",
        2:  "car",
        3:  "motorcycle",
        5:  "bus",
        7:  "truck",
        9:  "traffic light",
        11: "stop sign"
    ]

    init(confidenceThreshold: Float = 0.4) {
        self.confidenceThreshold = confidenceThreshold
        self.tracker = DeepSORTTracker()
        loadModel()
    }

    private func loadModel() {
        // Try to load yolo26n.mlmodelc — user must export from Ultralytics
        let candidates = ["yolo26n", "yolov8n", "YOLOv8n"]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                      ?? Bundle.main.url(forResource: name, withExtension: "mlmodel"),
               let mlModel = try? MLModel(contentsOf: url),
               let vn = try? VNCoreMLModel(for: mlModel) {
                self.model = vn
                print("[ObstacleDetector] Loaded \(name)")
                return
            }
        }
        print("[ObstacleDetector] WARNING: No obstacle model found. Using stub.")
    }

    // MARK: - Detection

    struct RawDetection {
        let classID: Int
        let className: String
        let boundingBox: CGRect   // normalized Vision coords (origin bottom-left)
        let confidence: Float
    }

    func detect(pixelBuffer: CVPixelBuffer,
                frameSize: CGSize,
                completion: @escaping ([TrackedObstacle]) -> Void) {
        guard let model else {
            completion([])
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] req, err in
            guard let self else { return }
            if let err { print("[ObstacleDetector] \(err)"); completion([]); return }
            let raws = self.parseDetections(req.results)
            let tracked = self.tracker.update(detections: raws, frameSize: frameSize)
            completion(tracked)
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func parseDetections(_ results: [VNObservation]?) -> [RawDetection] {
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            return []
        }

        var detections = [RawDetection]()
        for obs in observations {
            guard let topLabel = obs.labels.first else { continue }
            let conf = topLabel.confidence
            guard conf >= confidenceThreshold else { continue }

            // Map label identifier to COCO class ID
            let classID = cocoClassID(for: topLabel.identifier)
            guard let name = Self.relevantClasses[classID] else { continue }

            detections.append(RawDetection(
                classID: classID,
                className: name,
                boundingBox: obs.boundingBox,
                confidence: conf
            ))
        }
        return detections
    }

    private func cocoClassID(for identifier: String) -> Int {
        // Direct lookup table for common COCO class names
        let mapping: [String: Int] = [
            "person": 0, "bicycle": 1, "car": 2, "motorcycle": 3,
            "bus": 5, "truck": 7, "traffic light": 9, "stop sign": 11
        ]
        for (key, id) in mapping {
            if identifier.lowercased().contains(key) { return id }
        }
        return -1
    }
}

// MARK: - Simple DeepSORT Tracker (Kalman-based)

final class DeepSORTTracker {

    private var tracks: [Int: TrackState] = [:]
    private var nextID: Int = 1
    private let maxMissedFrames = 5
    private let iouThreshold: Float = 0.35

    struct TrackState {
        var trackID: Int
        var classID: Int
        var className: String
        var box: CGRect
        var velocity: CGSize
        var missedFrames: Int
        var confidence: Float

        mutating func predict() {
            box = CGRect(
                x: box.origin.x + velocity.width,
                y: box.origin.y + velocity.height,
                width: box.width,
                height: box.height
            )
        }

        mutating func update(with detection: ObstacleDetector.RawDetection) {
            let newBox = visionToScreen(detection.boundingBox)
            velocity = CGSize(width: newBox.midX - box.midX, height: newBox.midY - box.midY)
            box = newBox
            confidence = detection.confidence
            missedFrames = 0
        }

        static func visionToScreen(_ r: CGRect) -> CGRect {
            // Vision uses bottom-left origin; flip Y for UIKit (top-left origin)
            CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
    }

    func update(detections: [ObstacleDetector.RawDetection], frameSize: CGSize) -> [TrackedObstacle] {
        // Predict all existing tracks
        for id in tracks.keys { tracks[id]?.predict() }

        // Greedy IoU matching
        var matched = Set<Int>()
        var usedDetections = Set<Int>()

        for (id, track) in tracks {
            var bestIoU: Float = 0
            var bestDet: Int = -1
            for (di, det) in detections.enumerated() {
                guard !usedDetections.contains(di) else { continue }
                let detBox = TrackState.visionToScreen(det.boundingBox)
                let iou = iou(track.box, detBox)
                if iou > bestIoU && iou > iouThreshold {
                    bestIoU = iou
                    bestDet = di
                }
            }
            if bestDet >= 0 {
                tracks[id]?.update(with: detections[bestDet])
                matched.insert(id)
                usedDetections.insert(bestDet)
            } else {
                tracks[id]?.missedFrames += 1
            }
        }

        // Create new tracks for unmatched detections
        for (di, det) in detections.enumerated() {
            guard !usedDetections.contains(di) else { continue }
            let id = nextID; nextID += 1
            let box = TrackState.visionToScreen(det.boundingBox)
            tracks[id] = TrackState(trackID: id, classID: det.classID, className: det.className,
                                    box: box, velocity: .zero, missedFrames: 0, confidence: det.confidence)
        }

        // Remove stale tracks
        tracks = tracks.filter { $0.value.missedFrames < maxMissedFrames }

        // Build output
        return tracks.values.map { t in
            let pixelBox = CGRect(x: t.box.minX * frameSize.width,
                                  y: t.box.minY * frameSize.height,
                                  width: t.box.width * frameSize.width,
                                  height: t.box.height * frameSize.height)
            return TrackedObstacle(trackID: t.trackID, classID: t.classID, className: t.className,
                                   boundingBox: pixelBox, confidence: t.confidence, depthEstimate: 0)
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = Float(inter.width * inter.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
