import Foundation

// Typen nach docs/api.md und docs/schema.md. Explizite CodingKeys statt
// `.convertFromSnakeCase`: Die Strategie würde auch die Quellen-IDs in
// `by_source` umschreiben („open_meteo:icon_d2“ → „openMeteo:iconD2“).

struct Place: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var lat: Double
    var lon: Double
    var kind: String
    var notify: Bool
}

struct Forecast: Decodable, Sendable {
    let location: ForecastLocation
    let generatedAt: Date
    let sources: [SourceStatus]
    let now: Now
    let nowcast: Nowcast?
    let hourly: [HourRow]
    let daily: [DayRow]
    let alerts: [WeatherAlert]
    let attribution: [Attribution]

    enum CodingKeys: String, CodingKey {
        case location, sources, now, nowcast, hourly, daily, alerts, attribution
        case generatedAt = "generated_at"
    }
}

struct ForecastLocation: Decodable, Sendable {
    let id: Int?
    let name: String
    let lat: Double
    let lon: Double
    let kind: String
}

struct SourceStatus: Decodable, Sendable, Identifiable {
    let source: String
    let provider: String
    let ok: Bool
    let fetchedAt: Date?
    let stale: Bool
    let error: String?

    var id: String { source }

    enum CodingKeys: String, CodingKey {
        case source, provider, ok, stale, error
        case fetchedAt = "fetched_at"
    }
}

struct Now: Decodable, Sendable {
    let observed: ObservedWeather?
    let forecast: HourPoint?
}

struct ObservedWeather: Decodable, Sendable {
    let station: String
    let distanceM: Double
    let at: Date
    let tempC: Double?
    let humidityPct: Double?
    let windKmh: Double?
    let gustKmh: Double?
    let windDirDeg: Double?
    let pressureHpa: Double?
    let precipMm1h: Double?
    let cloudPct: Double?
    let visibilityM: Double?
    let condition: Condition?

    enum CodingKeys: String, CodingKey {
        case station, at, condition
        case distanceM = "distance_m"
        case tempC = "temp_c"
        case humidityPct = "humidity_pct"
        case windKmh = "wind_kmh"
        case gustKmh = "gust_kmh"
        case windDirDeg = "wind_dir_deg"
        case pressureHpa = "pressure_hpa"
        case precipMm1h = "precip_mm_1h"
        case cloudPct = "cloud_pct"
        case visibilityM = "visibility_m"
    }
}

struct Nowcast: Decodable, Sendable {
    let source: String
    let at: Date
    let points: [NowcastPoint]
}

struct NowcastPoint: Decodable, Sendable, Hashable {
    let at: Date
    let precipMmH: Double

    enum CodingKeys: String, CodingKey {
        case at
        case precipMmH = "precip_mm_h"
    }
}

struct HourPoint: Decodable, Sendable {
    let at: Date
    let tempC: Double
    let feelsLikeC: Double?
    let precipMm: Double
    let precipProbPct: Double?
    let windKmh: Double
    let gustKmh: Double?
    let windDirDeg: Double?
    let cloudPct: Double?
    let humidityPct: Double?
    let pressureHpa: Double?
    let condition: Condition
    let isDay: Bool?

    enum CodingKeys: String, CodingKey {
        case at, condition
        case tempC = "temp_c"
        case feelsLikeC = "feels_like_c"
        case precipMm = "precip_mm"
        case precipProbPct = "precip_prob_pct"
        case windKmh = "wind_kmh"
        case gustKmh = "gust_kmh"
        case windDirDeg = "wind_dir_deg"
        case cloudPct = "cloud_pct"
        case humidityPct = "humidity_pct"
        case pressureHpa = "pressure_hpa"
        case isDay = "is_day"
    }
}

struct DayPoint: Decodable, Sendable {
    let date: String
    let tempMinC: Double
    let tempMaxC: Double
    let precipMm: Double
    let precipProbPct: Double?
    let windMaxKmh: Double?
    let gustMaxKmh: Double?
    let condition: Condition
    let sunrise: Date?
    let sunset: Date?

    enum CodingKeys: String, CodingKey {
        case date, condition, sunrise, sunset
        case tempMinC = "temp_min_c"
        case tempMaxC = "temp_max_c"
        case precipMm = "precip_mm"
        case precipProbPct = "precip_prob_pct"
        case windMaxKmh = "wind_max_kmh"
        case gustMaxKmh = "gust_max_kmh"
    }
}

struct ValueRange: Decodable, Sendable, Hashable {
    let min: Double
    let max: Double
}

struct HourSpread: Decodable, Sendable {
    let tempC: ValueRange?
    let precipMm: ValueRange?
    let windKmh: ValueRange?
    let precipAgreementPct: Double?

    enum CodingKeys: String, CodingKey {
        case tempC = "temp_c"
        case precipMm = "precip_mm"
        case windKmh = "wind_kmh"
        case precipAgreementPct = "precip_agreement_pct"
    }
}

struct DaySpread: Decodable, Sendable {
    let tempMinC: ValueRange?
    let tempMaxC: ValueRange?
    let precipMm: ValueRange?
    let precipAgreementPct: Double?

    enum CodingKeys: String, CodingKey {
        case tempMinC = "temp_min_c"
        case tempMaxC = "temp_max_c"
        case precipMm = "precip_mm"
        case precipAgreementPct = "precip_agreement_pct"
    }
}

struct HourRow: Decodable, Sendable, Identifiable {
    let at: Date
    let nSources: Int
    let consensus: HourPoint
    let spread: HourSpread
    let bySource: [String: HourPoint]

    var id: Date { at }

    enum CodingKeys: String, CodingKey {
        case at, consensus, spread
        case nSources = "n_sources"
        case bySource = "by_source"
    }
}

struct DayRow: Decodable, Sendable, Identifiable {
    let date: String
    let nSources: Int
    let consensus: DayPoint
    let spread: DaySpread
    let bySource: [String: DayPoint]

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, consensus, spread
        case nSources = "n_sources"
        case bySource = "by_source"
    }
}

struct WeatherAlert: Decodable, Sendable, Identifiable {
    enum Severity: String, Decodable, Sendable, Comparable {
        case minor, moderate, severe, extreme

        private var rank: Int { [.minor, .moderate, .severe, .extreme].firstIndex(of: self)! }
        static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    let id: String
    let severity: Severity
    let event: String
    let headline: String
    let description: String
    let instruction: String?
    let onset: Date
    let expires: Date?
    let source: String
}

struct Attribution: Decodable, Sendable, Hashable {
    let source: String
    let text: String
    let url: String
}

struct RadarInfo: Decodable, Sendable {
    let wms: URL
    let layer: String
    let frames: [Date]
    /// Letztes Analysebild, danach Vorhersage.
    let nowIndex: Int?

    enum CodingKeys: String, CodingKey {
        case wms, layer, frames
        case nowIndex = "now_index"
    }

    var lastMeasured: Int {
        nowIndex.map { min(max($0, 0), frames.count - 1) } ?? frames.lastIndex { $0 <= .now } ?? 0
    }
}

enum Condition: String, Decodable, Sendable, CaseIterable {
    case clear, partlyCloudy = "partly_cloudy", cloudy, fog, drizzle, rain
    case heavyRain = "heavy_rain", snow, sleet, hail, thunderstorm, wind
    case unknown

    init(from decoder: any Decoder) throws {
        // Neue Bedingungen vom Server dürfen die App nicht lahmlegen.
        self = Condition(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

extension JSONDecoder {
    /// RFC 3339 mit und ohne Sekundenbruchteile (der Server ist in Rust).
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Kein RFC-3339-Zeitpunkt: \(text)"))
        }
        return decoder
    }()
}
