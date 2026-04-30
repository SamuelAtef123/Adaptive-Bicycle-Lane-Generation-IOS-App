import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var destination: String = ""
    @Published var isNavigating: Bool = false
    @Published var tomTomAPIKey: String = UserDefaults.standard.string(forKey: "tomtom_api_key") ?? ""
    @Published var keyframeInterval: Int = 5
    @Published var bikeLaneConfidenceThreshold: Float = 0.5
    @Published var obstacleConfidenceThreshold: Float = 0.4
    @Published var roadTypeConfidenceThreshold: Float = 0.6

    func saveSettings() {
        UserDefaults.standard.set(tomTomAPIKey, forKey: "tomtom_api_key")
        UserDefaults.standard.set(keyframeInterval, forKey: "keyframe_interval")
        UserDefaults.standard.set(bikeLaneConfidenceThreshold, forKey: "bike_lane_conf")
        UserDefaults.standard.set(obstacleConfidenceThreshold, forKey: "obstacle_conf")
        UserDefaults.standard.set(roadTypeConfidenceThreshold, forKey: "road_type_conf")
    }

    func loadSettings() {
        tomTomAPIKey = UserDefaults.standard.string(forKey: "tomtom_api_key") ?? ""
        keyframeInterval = UserDefaults.standard.integer(forKey: "keyframe_interval").nonZero ?? 5
        bikeLaneConfidenceThreshold = UserDefaults.standard.float(forKey: "bike_lane_conf").nonZero ?? 0.5
        obstacleConfidenceThreshold = UserDefaults.standard.float(forKey: "obstacle_conf").nonZero ?? 0.4
        roadTypeConfidenceThreshold = UserDefaults.standard.float(forKey: "road_type_conf").nonZero ?? 0.6
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension Float {
    var nonZero: Float? { self == 0 ? nil : self }
}
