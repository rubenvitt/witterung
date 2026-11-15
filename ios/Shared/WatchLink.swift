import Foundation

/// Was das iPhone der Watch schickt (WatchConnectivity, `applicationContext`):
/// Server, Geräte-Token, Orte und den letzten Standort. Die Watch meldet sich
/// nicht selbst an (Pocket ID braucht einen Browser mit Passkey), lädt danach
/// aber direkt vom Server, auch ohne iPhone in der Nähe (WLAN oder Mobilfunk).
struct WatchLink: Equatable, Sendable {
    var server: URL
    var token: String?
    var places: [Place]
    var lastLocation: Coordinate?

    struct Coordinate: Equatable, Sendable {
        var lat: Double
        var lon: Double
    }

    private enum Key {
        static let server = "server"
        static let token = "token"
        static let places = "places"
        static let lat = "lat"
        static let lon = "lon"
    }

    /// Aktueller Stand aus App-Group-Defaults und Schlüsselbund.
    static var current: WatchLink {
        WatchLink(server: SharedStore.serverURL,
                  token: TokenStore.token,
                  places: SharedStore.places,
                  lastLocation: SharedStore.lastLocation.map { Coordinate(lat: $0.lat, lon: $0.lon) })
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = [Key.server: server.absoluteString]
        if let token { dict[Key.token] = token }
        if let data = try? JSONEncoder().encode(places) { dict[Key.places] = data }
        if let lastLocation {
            dict[Key.lat] = lastLocation.lat
            dict[Key.lon] = lastLocation.lon
        }
        return dict
    }

    init(server: URL, token: String?, places: [Place], lastLocation: Coordinate?) {
        self.server = server
        self.token = token
        self.places = places
        self.lastLocation = lastLocation
    }

    init?(_ dict: [String: Any]) {
        guard let server = (dict[Key.server] as? String).flatMap(URL.init(string:)) else { return nil }
        self.server = server
        token = dict[Key.token] as? String
        places = (dict[Key.places] as? Data).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
        if let lat = dict[Key.lat] as? Double, let lon = dict[Key.lon] as? Double {
            lastLocation = Coordinate(lat: lat, lon: lon)
        }
    }
}
