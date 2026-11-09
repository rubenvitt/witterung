import Foundation

extension Condition {
    func label(isDay: Bool = true) -> String {
        switch self {
        case .clear: isDay ? "Sonnig" : "Klar"
        case .partlyCloudy: "Leicht bewölkt"
        case .cloudy: "Bewölkt"
        case .fog: "Nebel"
        case .drizzle: "Nieselregen"
        case .rain: "Regen"
        case .heavyRain: "Starkregen"
        case .snow: "Schnee"
        case .sleet: "Schneeregen"
        case .hail: "Hagel"
        case .thunderstorm: "Gewitter"
        case .wind: "Windig"
        case .unknown: "Unbekannt"
        }
    }

    func symbol(isDay: Bool = true) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: isDay ? "cloud.rain.fill" : "cloud.moon.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow: "cloud.snow.fill"
        case .sleet: "cloud.sleet.fill"
        case .hail: "cloud.hail.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .wind: "wind"
        case .unknown: "questionmark.circle"
        }
    }

    var isWet: Bool { [.drizzle, .rain, .heavyRain, .snow, .sleet, .hail, .thunderstorm].contains(self) }
}

enum SourceNames {
    static func name(_ source: String) -> String {
        switch source {
        case "weatherkit": "Apple Weather"
        case "open_meteo:icon_d2": "ICON-D2 (DWD)"
        case "open_meteo:icon_eu": "ICON-EU (DWD)"
        case "open_meteo:ecmwf_ifs": "ECMWF IFS"
        case "open_meteo:gfs": "GFS (NOAA)"
        case "bright_sky:mosmix": "MOSMIX (DWD)"
        case "bright_sky:radar": "Radar (DWD)"
        case "pirate_weather": "Pirate Weather"
        default: source
        }
    }

    static func error(_ code: String) -> String {
        switch code {
        case "quota": "Kontingent erreicht"
        case "timeout": "Zeitüberschreitung"
        default: code
        }
    }
}

/// Regen in den nächsten 2 Stunden laut Radar-Nowcast.
enum NowcastSummary: Equatable {
    case none                          // kein Nowcast
    case dry(horizon: Int)             // kein Regen bis zum Ende des Nowcasts (Minuten)
    case startsIn(minutes: Int, peak: Double)
    case rainingEndsIn(minutes: Int, peak: Double)
    case rainingContinues(horizon: Int, peak: Double)

    /// Ab dieser Intensität gilt ein 5-min-Schritt als Regen.
    static let threshold = 0.1

    init(_ nowcast: Nowcast?, now: Date) {
        // Der Schritt, in dem `now` liegt, und alle danach.
        let points = (nowcast?.points ?? []).filter { $0.at.addingTimeInterval(300) > now }
        guard let first = points.first else { self = .none; return }
        let wet = { (p: NowcastPoint) in p.precipMmH >= Self.threshold }
        func minutes(_ date: Date) -> Int {
            // Auf 5 min gerundet, mindestens 5: „in 0 Minuten“ ergibt keinen Sinn.
            max(5, Int((date.timeIntervalSince(now) / 300).rounded()) * 5)
        }
        if wet(first) {
            let spell = points.prefix { wet($0) }
            let peak = spell.map(\.precipMmH).max() ?? 0
            if let end = points.first(where: { !wet($0) }) {
                self = .rainingEndsIn(minutes: minutes(end.at), peak: peak)
            } else {
                self = .rainingContinues(horizon: minutes(points.last!.at.addingTimeInterval(300)), peak: peak)
            }
        } else if let start = points.firstIndex(where: wet) {
            let peak = points[start...].prefix { wet($0) }.map(\.precipMmH).max() ?? 0
            self = .startsIn(minutes: minutes(points[start].at), peak: peak)
        } else {
            self = .dry(horizon: minutes(points.last!.at.addingTimeInterval(300)))
        }
    }

    static func intensityWord(_ peak: Double) -> String {
        switch peak {
        case ..<0.5: "Leichter Regen"
        case ..<4: "Regen"
        default: "Starker Regen"
        }
    }

    var sentence: String? {
        switch self {
        case .none: nil
        case let .dry(horizon): "Kein Regen in den nächsten \(Self.span(horizon))"
        case let .startsIn(minutes, peak): "\(Self.intensityWord(peak)) in \(minutes) Minuten"
        case let .rainingEndsIn(minutes, peak): "\(Self.intensityWord(peak)) endet in \(minutes) Minuten"
        case let .rainingContinues(horizon, peak): "\(Self.intensityWord(peak)) hält mindestens \(Self.span(horizon)) an"
        }
    }

    /// „2 Stunden“ bei vollem Nowcast, sonst die tatsächlich abgedeckten Minuten.
    static func span(_ minutes: Int) -> String {
        minutes >= 115 ? "2 Stunden" : "\(minutes) Minuten"
    }

    var expectsRain: Bool {
        switch self {
        case .none, .dry: false
        default: true
        }
    }
}

extension Forecast {
    func hour(at date: Date) -> HourRow? {
        hourly.last { $0.at <= date && date < $0.at.addingTimeInterval(3600) }
    }

    func day(at date: Date) -> DayRow? {
        let key = Fmt.dayString(date)
        return daily.first { $0.date == key }
    }

    /// Konsens der Stunde von jetzt (auch aus einem älteren Cache), sonst `now.forecast`.
    var currentHour: HourPoint? { hour(at: .now)?.consensus ?? now.forecast }

    var hasWeatherKit: Bool { sources.contains { $0.source == "weatherkit" && $0.ok } }

    /// Kurzer Regenhinweis für Widgets: Radar, wenn es `date` abdeckt, sonst Stunden.
    func rainHint(at date: Date) -> String {
        var from = date
        switch NowcastSummary(nowcast, now: date) {
        case .startsIn(let minutes, _):
            return "Regen ab \(Fmt.time(date.addingTimeInterval(Double(minutes) * 60)))"
        case .rainingEndsIn(let minutes, _):
            return "Regen bis \(Fmt.time(date.addingTimeInterval(Double(minutes) * 60)))"
        case .rainingContinues:
            return "Regen hält an"
        case .dry:
            // Das Radar ist genauer als die Stundenwerte: erst nach seinem Ende weitersuchen.
            from = nowcast?.points.last.map { $0.at.addingTimeInterval(300) } ?? date
        case .none:
            break
        }
        // Nächste 12 h, Regen = Median ab 0,1 mm in der Stunde.
        let wet = hourly.first {
            $0.at.addingTimeInterval(3600) > from && $0.at < date.addingTimeInterval(12 * 3600) && $0.consensus.precipMm >= 0.1
        }
        guard let wet else { return "Kein Regen in Sicht" }
        return wet.at <= date ? "Regen jetzt" : "Regen ab \(Fmt.hour(max(wet.at, from)))"
    }
}

/// Ein Zeitpunkt im Widget: alles, was die Ansicht braucht, aus dem Cache berechnet.
struct WeatherSnapshot: Sendable {
    struct Hour: Sendable, Hashable {
        let at: Date
        let temp: Double
        let symbol: String
        let precipProb: Double?
    }

    struct Day: Sendable, Hashable {
        let date: String
        let min: Double
        let max: Double
        let symbol: String
        let precipProb: Double?
    }

    let date: Date
    let placeName: String
    let isCurrentLocation: Bool
    let temp: Double
    let condition: Condition
    let isDay: Bool
    let min: Double?
    let max: Double?
    let rainHint: String
    let hours: [Hour]
    let days: [Day]
    let generatedAt: Date
    /// Apple-Weather-Marke zeigen (WeatherKit-Attribution, auch im Widget).
    let hasWeatherKit: Bool

    /// Einträge ab `now`: erst jetzt, dann zu jeder vollen Stunde, solange es Daten gibt.
    static func timeline(_ forecast: Forecast, now: Date, count: Int = 8, placeName: String? = nil) -> [WeatherSnapshot] {
        let nextHour = Fmt.calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
        let dates = [now] + (0..<(count - 1)).map { nextHour.addingTimeInterval(Double($0) * 3600) }
        return dates.compactMap { make(forecast, at: $0, placeName: placeName) }
    }

    static func make(_ forecast: Forecast, at date: Date, placeName: String? = nil) -> WeatherSnapshot? {
        // Ohne Stundenwert für `date` ist die Vorhersage abgelaufen: lieber „keine Daten“ als alte Werte.
        guard let row = forecast.hour(at: date)?.consensus else { return nil }
        // Beobachtung gilt, solange sie frisch ist; danach die Prognose der Stunde.
        let observed = forecast.now.observed.flatMap { o in date.timeIntervalSince(o.at) < 90 * 60 ? o : nil }
        let day = forecast.day(at: date)?.consensus
        let isDay = row.isDay ?? true
        return WeatherSnapshot(
            date: date,
            placeName: placeName ?? forecast.location.name,
            isCurrentLocation: forecast.location.kind == "current",
            temp: observed?.tempC ?? row.tempC,
            condition: row.condition,
            isDay: isDay,
            min: day?.tempMinC,
            max: day?.tempMaxC,
            rainHint: forecast.rainHint(at: date),
            hours: forecast.hourly.filter { $0.at > date }.prefix(6).map {
                Hour(at: $0.at, temp: $0.consensus.tempC, symbol: $0.consensus.condition.symbol(isDay: $0.consensus.isDay ?? true),
                     precipProb: $0.consensus.precipProbPct)
            },
            days: forecast.daily.filter { $0.date >= Fmt.dayString(date) }.prefix(5).map {
                Day(date: $0.date, min: $0.consensus.tempMinC, max: $0.consensus.tempMaxC,
                    symbol: $0.consensus.condition.symbol(), precipProb: $0.consensus.precipProbPct)
            },
            generatedAt: forecast.generatedAt,
            hasWeatherKit: forecast.hasWeatherKit
        )
    }
}
