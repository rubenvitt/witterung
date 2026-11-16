import Foundation

/// Die kommende Nacht und der Morgen danach: am Abend wichtiger als der Nachmittag.
/// Nacht = 20 bis 8 Uhr; nach 20 Uhr ab jetzt, vor 5 Uhr bis 8 Uhr desselben Tages.
struct NightOutlook: Sendable, Hashable {
    let start: Date
    let end: Date
    let low: Double
    let lowAt: Date
    let precipMm: Double
    let wetFrom: Date?
    let maxGust: Double?
    let morningTemp: Double?
    let morningSymbol: String?
    let sunrise: Date?
    let tomorrow: WeatherSnapshot.Day?
    let hours: [WeatherSnapshot.Hour]

    var frost: Bool { low < 0.5 }

    /// „Tiefstwert 1° gegen 5 Uhr, trocken, um 7 Uhr 2°“ – für Jev und den Kernsatz.
    var summary: String {
        var parts = ["Tiefstwert \(Fmt.temp(low)) gegen \(Fmt.hour(lowAt))"]
        parts.append(wetFrom.map { "Niederschlag ab \(Fmt.hour($0)) (\(Fmt.mm(precipMm)))" } ?? "trocken")
        if let gust = maxGust, gust >= 40 { parts.append("Böen bis \(Fmt.kmh(gust))") }
        if let morningTemp { parts.append("um 7 Uhr \(Fmt.temp(morningTemp))") }
        return parts.joined(separator: ", ")
    }

    static func make(_ forecast: Forecast, at now: Date) -> NightOutlook? {
        let calendar = Fmt.calendar
        let hour = calendar.component(.hour, from: now)
        let today = calendar.startOfDay(for: now)
        func at(_ h: Int, dayOffset: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: dayOffset, to: calendar.date(bySettingHour: h, minute: 0, second: 0, of: today) ?? today)
                ?? today
        }
        let (start, end): (Date, Date) = switch hour {
        case ..<5: (now, at(8))
        case ..<20: (at(20), at(8, dayOffset: 1))
        default: (now, at(8, dayOffset: 1))
        }
        let rows = forecast.hourly.filter { $0.at.addingTimeInterval(3600) > start && $0.at < end }
        guard rows.count >= 3, let coldest = rows.min(by: { $0.consensus.tempC < $1.consensus.tempC }) else { return nil }
        let morning = forecast.hour(at: end.addingTimeInterval(-3600))?.consensus
        let morningDay = forecast.day(at: end)
        return NightOutlook(
            start: start, end: end,
            low: coldest.consensus.tempC, lowAt: coldest.at,
            precipMm: rows.map(\.consensus.precipMm).reduce(0, +),
            wetFrom: rows.first { $0.consensus.precipMm >= 0.1 }?.at,
            maxGust: rows.compactMap(\.consensus.gustKmh).max(),
            morningTemp: morning?.tempC,
            morningSymbol: morning.map { $0.condition.symbol(isDay: $0.isDay ?? false) },
            sunrise: morningDay?.consensus.sunrise,
            tomorrow: morningDay.map {
                WeatherSnapshot.Day(date: $0.date, min: $0.consensus.tempMinC, max: $0.consensus.tempMaxC,
                                    symbol: $0.consensus.condition.symbol(), precipProb: $0.consensus.precipProbPct,
                                    precipMm: $0.consensus.precipMm)
            },
            hours: rows.map {
                WeatherSnapshot.Hour(at: $0.at, temp: $0.consensus.tempC,
                                     symbol: $0.consensus.condition.symbol(isDay: $0.consensus.isDay ?? false),
                                     precipProb: $0.consensus.precipProbPct, precipMm: $0.consensus.precipMm)
            })
    }
}

/// Ein Kernsatz für den Kopf der Ortsseite, aus den Hinweisen gebaut (kein freier Text).
enum Briefing {
    static func sentence(_ insights: [Insight], mode: WidgetMode, night: NightOutlook?) -> String {
        guard let top = insights.first else { return "" }
        var text: String
        if top.kind == .calm {
            text = top.detail.capitalizedFirst + "."
        } else {
            text = "\(top.title), \(top.detail.lowercasedFirst)."
            let others = insights.dropFirst().filter { $0.kind != .calm }.prefix(2).map(\.short)
            if !others.isEmpty { text += " Außerdem: \(others.joined(separator: ", "))." }
        }
        if mode == .tonight, let night {
            text += " Heute Nacht bis \(Fmt.temp(night.low))" + (night.frost ? ", Frost" : "")
                + (night.wetFrom != nil ? ", nass" : ", trocken") + "."
        }
        return text
    }
}

/// Was man für den nächsten Gang nach draußen braucht (mit Hund).
enum Outfit {
    static func tip(_ forecast: Forecast, at now: Date, insights: [Insight]) -> String? {
        let rows = forecast.hourly.filter { $0.at.addingTimeInterval(3600) > now && $0.at < now.addingTimeInterval(2 * 3600) }
        guard !rows.isEmpty else { return nil }
        let feels = rows.map { $0.consensus.feelsLikeC ?? $0.consensus.tempC }.min() ?? 10
        let wet = rows.contains { $0.consensus.precipMm >= 0.1 } || NowcastSummary(forecast.nowcast, now: now).expectsRain
        let gust = rows.compactMap(\.consensus.gustKmh).max() ?? 0
        let dark = rows.first.map { !($0.consensus.isDay ?? true) } ?? false
        let hot = rows.map(\.consensus.tempC).max() ?? 0
        let base: String = switch feels {
        case ..<(-5): "dicke Winterjacke, Mütze, Handschuhe"
        case ..<3: "Winterjacke und Mütze"
        case ..<10: "warme Jacke"
        case ..<16: "leichte Jacke"
        case ..<22: "Pulli"
        default: "T-Shirt"
        }
        var items = [base]
        if wet { items.append(gust >= 40 ? "Regenjacke statt Schirm" : "Schirm") }
        if insights.contains(where: { $0.kind == .ice }) { items.append("rutschfeste Schuhe") }
        if dark { items.append("Leuchthalsband für den Hund") }
        if hot >= 27 { items.append("Wasser für den Hund") }
        return items.joined(separator: ", ").capitalizedFirst
    }
}

extension String {
    /// „Ab 13:25“ → „ab 13:25“
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
