import CoreML
import Vision

final class RoadTypeClassifier {

    private var model: VNCoreMLModel?
    private let confidenceThreshold: Float

    init(confidenceThreshold: Float = 0.6) {
        self.confidenceThreshold = confidenceThreshold
        loadModel()
    }

    private func loadModel() {
        guard
            let url = Bundle.main.url(forResource: "road_type_cls", withExtension: "mlmodelc")
                   ?? Bundle.main.url(forResource: "road_type_cls", withExtension: "mlmodel"),
            let ml  = try? MLModel(contentsOf: url),
            let vn  = try? VNCoreMLModel(for: ml)
        else {
            print("[RoadTypeClassifier] WARNING: road_type_cls model not found. Using stub.")
            return
        }
        self.model = vn
        print("[RoadTypeClassifier] Model loaded.")
    }

    struct Result {
        let roadType: RoadType
        let confidence: Float
        let isHighConfidence: Bool
    }

    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (Result?) -> Void) {
        guard let model else {
            // Stub: default to two-way (conservative)
            completion(Result(roadType: .twoWay, confidence: 0.5, isHighConfidence: false))
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] req, err in
            guard let self else { return }
            if let err { print("[RoadTypeClassifier] \(err)"); completion(nil); return }
            completion(self.parseResult(req.results))
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func parseResult(_ results: [VNObservation]?) -> Result? {
        guard let obs = results as? [VNClassificationObservation],
              let top = obs.first else { return nil }

        let roadType: RoadType
        let label = top.identifier.lowercased()
        if label.contains("one") || label.contains("1") || label.contains("oneway") {
            roadType = .oneWay
        } else {
            roadType = .twoWay
        }

        return Result(
            roadType: roadType,
            confidence: top.confidence,
            isHighConfidence: top.confidence >= confidenceThreshold
        )
    }
}
