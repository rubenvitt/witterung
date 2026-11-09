import Foundation
import Security

/// Was App und Widget teilen: Einstellungen und Orte in den App-Group-Defaults,
/// die letzte Vorhersage je Ort als JSON im App-Group-Container.
enum SharedStore {
    static let appGroup = "group.dev.rubeen.witterung"
    static let defaultServer = URL(string: "https://witterung.rubeen.dev")!

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    private enum Key {
        static let server = "serverURL"
        static let places = "places"
        static let lastLat = "lastLocation.lat"
        static let lastLon = "lastLocation.lon"
    }

    static var serverURL: URL {
        get { defaults.string(forKey: Key.server).flatMap(URL.init(string:)) ?? defaultServer }
        set { defaults.set(newValue.absoluteString, forKey: Key.server) }
    }

    /// Spiegel der Orte für das Widget (Konfiguration ohne Netz).
    static var places: [Place] {
        get { defaults.data(forKey: Key.places).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.places) }
    }

    /// Letzter bekannter Standort, damit das Widget „Mein Standort“ auch ohne
    /// eigenen Standortzugriff zeigen kann.
    static var lastLocation: (lat: Double, lon: Double)? {
        get {
            guard defaults.object(forKey: Key.lastLat) != nil else { return nil }
            return (defaults.double(forKey: Key.lastLat), defaults.double(forKey: Key.lastLon))
        }
        set {
            defaults.set(newValue?.lat, forKey: Key.lastLat)
            defaults.set(newValue?.lon, forKey: Key.lastLon)
        }
    }
}

/// Welche Vorhersage: gespeicherter Ort oder aktueller Standort.
enum PlaceRef: Hashable, Sendable {
    case saved(Int)
    case current

    var cacheKey: String {
        switch self {
        case let .saved(id): "place-\(id)"
        case .current: "current"
        }
    }
}

enum ForecastCache {
    static var directory: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Forecasts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ ref: PlaceRef) -> URL {
        directory.appendingPathComponent("\(ref.cacheKey).json")
    }

    /// Speichert die Serverantwort unverändert; gelesen wird sie wie frisch geladen.
    static func store(_ data: Data, for ref: PlaceRef) {
        try? data.write(to: url(ref), options: .atomic)
    }

    static func load(_ ref: PlaceRef) -> Forecast? {
        guard let data = try? Data(contentsOf: url(ref)) else { return nil }
        return try? JSONDecoder.api.decode(Forecast.self, from: data)
    }

    static func remove(_ ref: PlaceRef) {
        try? FileManager.default.removeItem(at: url(ref))
    }
}

/// Geräte-Token im Schlüsselbund. Ohne `kSecAttrAccessGroup`: Der erste Eintrag
/// von `keychain-access-groups` (…dev.rubeen.witterung.shared) ist die Standardgruppe,
/// App und Widget teilen ihn.
enum TokenStore {
    private static var base: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.rubeen.witterung",
        kSecAttrAccount as String: "device-token",
    ] }

    static var token: String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        delete()
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        // Widget lädt auch bei gesperrtem Gerät (nach dem ersten Entsperren); nicht ins Backup.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError.keychain(status) }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
