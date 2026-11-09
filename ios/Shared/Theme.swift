import SwiftUI

/// Hintergrund nach Wetterlage und Tageszeit. Alle Verläufe sind dunkel genug
/// für weiße Schrift (Kontrast ≥ 4,5:1 am hellsten Punkt).
enum Theme {
    static func gradient(_ condition: Condition, isDay: Bool) -> LinearGradient {
        LinearGradient(colors: colors(condition, isDay: isDay), startPoint: .top, endPoint: .bottom)
    }

    static func colors(_ condition: Condition, isDay: Bool) -> [Color] {
        func c(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch (condition, isDay) {
        case (.clear, true): return [c(0x1F6FC5), c(0x3E8FD8)]
        case (.partlyCloudy, true): return [c(0x2F6AA8), c(0x5683AE)]
        case (.cloudy, true), (.wind, true), (.unknown, true): return [c(0x4B5D72), c(0x6A7B8E)]
        case (.fog, true): return [c(0x5E6670), c(0x7A828B)]
        case (.drizzle, true), (.rain, true): return [c(0x3A4B5E), c(0x56677A)]
        case (.heavyRain, true), (.hail, true): return [c(0x29384A), c(0x44536A)]
        case (.snow, true), (.sleet, true): return [c(0x5A6E86), c(0x7C8FA6)]
        case (.thunderstorm, _): return [c(0x2B2540), c(0x4A4060)]
        case (.clear, false), (.partlyCloudy, false): return [c(0x0B1530), c(0x1E2C52)]
        case (.snow, false), (.sleet, false): return [c(0x1B2436), c(0x34405A)]
        default: return [c(0x141C28), c(0x2A3443)]
        }
    }

    /// DWD-Warnstufen: gelb, orange, rot, violett.
    static func alertColor(_ severity: WeatherAlert.Severity) -> Color {
        switch severity {
        case .minor: Color(red: 1.0, green: 0.84, blue: 0.0)
        case .moderate: Color(red: 1.0, green: 0.55, blue: 0.0)
        case .severe: Color(red: 0.89, green: 0.11, blue: 0.11)
        case .extreme: Color(red: 0.55, green: 0.1, blue: 0.6)
        }
    }

    static func alertLevel(_ severity: WeatherAlert.Severity) -> String {
        switch severity {
        case .minor: "Wetterwarnung"
        case .moderate: "Markante Wetterwarnung"
        case .severe: "Unwetterwarnung"
        case .extreme: "Extreme Unwetterwarnung"
        }
    }
}
