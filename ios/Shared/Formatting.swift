import Foundation

/// Anzeige immer deutsch, metrisch, 24 h, Europe/Berlin – unabhängig von den
/// Geräteeinstellungen (die App ist für einen Ort in Deutschland gebaut).
enum Fmt {
    static let locale = Locale(identifier: "de_DE")
    static let timeZone = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    /// „8°“, gerundet, nie „-0°“.
    static func temp(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()) == 0 ? 0 : Int(value.rounded()))°"
    }

    /// Dezimalzahl mit Komma: `number(7.5, digits: 1)` → „7,5“.
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale).grouping(.automatic))
    }

    static func mm(_ value: Double) -> String { "\(number(value)) mm" }
    static func kmh(_ value: Double) -> String { "\(Int(value.rounded())) km/h" }
    static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }
    static func hpa(_ value: Double) -> String { "\(number(value, digits: 0)) hPa" }

    static func distance(meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) m" : "\(number(meters / 1000)) km"
    }

    /// „14:20“
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))
    }

    /// „14 Uhr“
    static func hour(_ date: Date) -> String {
        "\(calendar.component(.hour, from: date)) Uhr"
    }

    /// „Mo“, „Di“ … bzw. „Heute“ für den Tag von `now`.
    static func weekday(_ dateString: String, now: Date = .now) -> String {
        guard let date = day(dateString) else { return dateString }
        if calendar.isDate(date, inSameDayAs: now) { return "Heute" }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).weekday(.abbreviated))
            .replacingOccurrences(of: ".", with: "")
    }

    /// „Dienstag, 10. November“
    static func longDay(_ dateString: String) -> String {
        guard let date = day(dateString) else { return dateString }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).weekday(.wide).day().month(.wide))
    }

    /// `JJJJ-MM-TT` (Europe/Berlin) → Mitternacht dieses Tages.
    static func day(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// „gerade eben“, „vor 12 min“, „vor 3 h“, „vor 2 Tagen“
    static func age(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "gerade eben"
        case ..<60: return "vor \(minutes) min"
        case ..<(48 * 60): return "vor \(minutes / 60) h"
        default: return "vor \(minutes / 1440) Tagen"
        }
    }

    private static let compass = ["N", "NNO", "NO", "ONO", "O", "OSO", "SO", "SSO", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// Windrichtung (woher) als Himmelsrichtung, 16-teilig.
    static func compassPoint(_ degrees: Double) -> String {
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) + 360 + 11.25) / 22.5) % 16
        return compass[index]
    }
}
