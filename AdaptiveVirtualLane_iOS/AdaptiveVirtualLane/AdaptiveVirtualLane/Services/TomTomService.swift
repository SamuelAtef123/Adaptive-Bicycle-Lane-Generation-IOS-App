import Foundation
import CoreLocation

final class TomTomService {

    private var apiKey: String
    private let session: URLSession

    // Cached data
    private(set) var currentRoute: [RouteManeuver] = []
    private(set) var currentTrafficData: TrafficFlowData?
    private(set) var lastTrafficUpdate: Date?
    private let trafficRefreshInterval: TimeInterval = 60
    private let routeDeviationThreshold: Double = 30 // meters

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    func updateAPIKey(_ key: String) { self.apiKey = key }

    // MARK: - Geocoding

    func geocode(address: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        guard !apiKey.isEmpty else { completion(nil); return }
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        let urlStr = "https://api.tomtom.com/search/2/search/\(encoded).json?key=\(apiKey)&limit=1"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        session.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let pos = first["position"] as? [String: Double],
                  let lat = pos["lat"], let lon = pos["lon"]
            else { DispatchQueue.main.async { completion(nil) }; return }
            DispatchQueue.main.async { completion(CLLocationCoordinate2D(latitude: lat, longitude: lon)) }
        }.resume()
    }

    // MARK: - Bicycle Routing

    func fetchRoute(from origin: CLLocationCoordinate2D,
                    to destination: CLLocationCoordinate2D,
                    completion: @escaping ([RouteManeuver]) -> Void) {
        guard !apiKey.isEmpty else { completion([]); return }

        let urlStr = """
        https://api.tomtom.com/routing/1/calculateRoute/\
        \(origin.latitude),\(origin.longitude):\(destination.latitude),\(destination.longitude)\
        /json?key=\(apiKey)&travelMode=bicycle&instructionsType=coded&sectionType=traffic
        """
        guard let url = URL(string: urlStr) else { completion([]); return }

        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { DispatchQueue.main.async { completion([]) }; return }

            let maneuvers = self.parseManeuvers(from: json)
            DispatchQueue.main.async {
                self.currentRoute = maneuvers
                completion(maneuvers)
            }
        }.resume()
    }

    private func parseManeuvers(from json: [String: Any]) -> [RouteManeuver] {
        guard
            let routes = json["routes"] as? [[String: Any]],
            let route  = routes.first,
            let legs   = route["legs"] as? [[String: Any]],
            let leg    = legs.first,
            let instructions = leg["instructions"] as? [[String: Any]]
        else { return [] }

        return instructions.compactMap { inst -> RouteManeuver? in
            guard
                let point = inst["maneuverPoint"] as? [String: Double],
                let lat = point["latitude"],
                let lon = point["longitude"],
                let maneuverStr = inst["maneuverType"] as? String
            else { return nil }

            let maneuver: ManeuverType
            let m = maneuverStr.uppercased()
            if m.contains("LEFT")     { maneuver = .turnLeft }
            else if m.contains("RIGHT"){ maneuver = .turnRight }
            else                       { maneuver = .goStraight }

            let instruction = inst["message"] as? String ?? maneuver.rawValue
            let dist = inst["routeOffsetInMeters"] as? Double ?? 0

            return RouteManeuver(type: maneuver, latitude: lat, longitude: lon,
                                 distanceFromStart: dist, instruction: instruction)
        }
    }

    // MARK: - Traffic Flow

    func fetchTraffic(at coordinate: CLLocationCoordinate2D,
                      completion: @escaping (TrafficFlowData?) -> Void) {
        guard !apiKey.isEmpty else { completion(nil); return }

        // Throttle refreshes
        if let last = lastTrafficUpdate, Date().timeIntervalSince(last) < trafficRefreshInterval {
            completion(currentTrafficData)
            return
        }

        let urlStr = "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json?point=\(coordinate.latitude),\(coordinate.longitude)&key=\(apiKey)"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let flow = json["flowSegmentData"] as? [String: Any],
                  let currentSpeed  = flow["currentSpeed"]  as? Double,
                  let freeFlowSpeed = flow["freeFlowSpeed"] as? Double
            else { DispatchQueue.main.async { completion(nil) }; return }

            let traffic = TrafficFlowData(currentSpeed: currentSpeed / 3.6,   // km/h → m/s
                                          freeFlowSpeed: freeFlowSpeed / 3.6)
            DispatchQueue.main.async {
                self.currentTrafficData = traffic
                self.lastTrafficUpdate  = Date()
                completion(traffic)
            }
        }.resume()
    }

    // MARK: - Navigation Helpers

    /// Returns the upcoming maneuver given current GPS position
    func upcomingManeuver(currentLocation: CLLocationCoordinate2D) -> RouteManeuver? {
        currentRoute.first { maneuver in
            let d = distance(from: currentLocation, to: CLLocationCoordinate2D(latitude: maneuver.latitude, longitude: maneuver.longitude))
            return d > 0   // return closest upcoming
        }
    }

    /// Returns true if within `threshold` meters of a waypoint
    func isNearNextWaypoint(currentLocation: CLLocationCoordinate2D, threshold: Double = 20) -> Bool {
        guard let next = upcomingManeuver(currentLocation: currentLocation) else { return false }
        let d = distance(from: currentLocation,
                         to: CLLocationCoordinate2D(latitude: next.latitude, longitude: next.longitude))
        return d <= threshold
    }

    /// Haversine distance in meters
    func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let x = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
        return R * 2 * atan2(sqrt(x), sqrt(1-x))
    }

    /// Check if user has deviated from planned route
    func hasDeviated(from location: CLLocationCoordinate2D) -> Bool {
        guard !currentRoute.isEmpty else { return false }
        let minDist = currentRoute.map { maneuver in
            distance(from: location, to: CLLocationCoordinate2D(latitude: maneuver.latitude, longitude: maneuver.longitude))
        }.min() ?? 0
        return minDist > routeDeviationThreshold
    }
}
