#if os(iOS)
import ActivityKit
import Foundation

/// Live-Aktivität auf Sperrbildschirm und Dynamic Island: Regen laut Radar („Regen in …“,
/// „Regen endet in …“) oder eine Unwetterwarnung des DWD.
///
/// Mit APNs auf dem Server startet, aktualisiert und beendet der Server sie (auch ohne
/// laufende App, `server/src/live.rs`); sonst die App selbst beim Laden im Vordergrund
/// (`App/LiveActivityController.swift`). Beide bauen denselben Zustand
/// (`ContentState.desired`); die Schlüssel und Werte müssen zum Server passen.
struct WeatherActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            /// Regen beginnt binnen einer Stunde: Countdown bis Beginn.
            case rainSoon = "rain_soon"
            /// Es regnet: Countdown bis zum Ende, falls das Radar es zeigt.
            case raining
            /// Unwetterwarnung (ab Stufe 3): ab/bis.
            case warning
        }

        var kind: Kind
        /// Regen- bzw. Warnbeginn, Unix-Sekunden (kein `Date`: ActivityKit dekodiert Push-Inhalte
        /// mit eigenem Datumsformat, Zahlen sind eindeutig).
        var startsAt: Double
        /// Regenende bzw. Ablauf der Warnung.
        var endsAt: Double?
        /// Stärkster Regen im Schauer (mm/h), 0 bei Warnungen.
        var peakMmH: Double
        /// Ereignis der Warnung, wie der DWD es schreibt („STURMBÖEN“).
        var event: String?
        /// `severe` oder `extreme`.
        var severity: String?
        /// Stand der Daten, Unix-Sekunden.
        var updatedAt: Double
        /// Radar ab dem laufenden 5-min-Schritt, eine Stunde (mm/h); fehlt bei Warnungen.
        var bars: [Double]?
        /// Beginn des ersten Balkens, Unix-Sekunden.
        var barsStart: Double?
        /// Regnet es über das Radar hinaus: erste trockene Stunde laut Konsens.
        var dryAt: Double?

        var start: Date { Date(timeIntervalSince1970: startsAt) }
        var end: Date? { endsAt.map(Date.init(timeIntervalSince1970:)) }
    }

    /// Server-ID des Orts (bei „Mein Standort“ die des Rasterpunkts).
    var placeId: Int
    var placeName: String
    /// „Mein Standort“: Tipp öffnet die Standortseite.
    var current: Bool = false
}

extension WeatherActivityAttributes.ContentState {
    /// So weit voraus startet eine Aktivität (Regen und Warnung).
    static let lead: TimeInterval = 3600

    /// Was die Aktivität jetzt zeigen soll; `nil` = keine. Gleiche Regeln wie
    /// `live::desired` auf dem Server: Unwetterwarnung vor Regen, Regen nur binnen einer Stunde.
    /// So viele 5-min-Balken zeigt die Aktivität (eine Stunde).
    static let barCount = 12

    static func desired(alerts: [WeatherAlert], nowcast: Nowcast?, hourly: [HourRow] = [], now: Date) -> Self? {
        let warning = alerts
            .filter { $0.severity >= .severe && $0.onset <= now.addingTimeInterval(lead) && ($0.expires.map { $0 > now } ?? true) }
            .max { a, b in a.severity != b.severity ? a.severity < b.severity : a.onset > b.onset }
        if let a = warning {
            return Self(kind: .warning, startsAt: a.onset.timeIntervalSince1970, endsAt: a.expires?.timeIntervalSince1970,
                        peakMmH: 0, event: a.event, severity: a.severity.rawValue, updatedAt: now.timeIntervalSince1970,
                        bars: nil, barsStart: nil, dryAt: nil)
        }
        let points = nowcast?.points ?? []
        // Der Schritt, in dem `now` liegt, und alle danach.
        guard let current = points.firstIndex(where: { $0.at.addingTimeInterval(300) > now }) else { return nil }
        let wet = { (i: Int) in points[i].precipMmH >= NowcastSummary.threshold }
        let kind: Kind
        var first: Int
        if wet(current) {
            kind = .raining
            first = current
            while first > 0, wet(first - 1) { first -= 1 }
        } else {
            guard let next = (current..<points.count).first(where: wet),
                  points[next].at <= now.addingTimeInterval(lead) else { return nil }
            kind = .rainSoon
            first = next
        }
        let end = (first..<points.count).first { !wet($0) }
        let peak = points[first..<(end ?? points.count)].map(\.precipMmH).max() ?? 0
        let round = { (v: Double) in (v * 10).rounded() / 10 }
        // Kein Ende im Radar: erste trockene Stunde danach laut Konsens (höchstens 12 h).
        var dryAt: Double?
        if kind == .raining, end == nil {
            let horizon = points.last.map { $0.at.addingTimeInterval(300) } ?? now
            dryAt = hourly.first {
                $0.at >= horizon && $0.at < now.addingTimeInterval(12 * 3600) && $0.consensus.precipMm < 0.1
            }?.at.timeIntervalSince1970
        }
        return Self(kind: kind, startsAt: points[first].at.timeIntervalSince1970,
                    endsAt: end.map { points[$0].at.timeIntervalSince1970 },
                    peakMmH: round(peak), event: nil, severity: nil, updatedAt: now.timeIntervalSince1970,
                    bars: points[current...].prefix(barCount).map { round($0.precipMmH) },
                    barsStart: points[current].at.timeIntervalSince1970, dryAt: dryAt)
    }

    var alertSeverity: WeatherAlert.Severity? { severity.flatMap(WeatherAlert.Severity.init(rawValue:)) }

    var eventTitle: String {
        (event ?? "").lowercased(with: Fmt.locale).capitalized(with: Fmt.locale)
    }

    var dry: Date? { dryAt.map(Date.init(timeIntervalSince1970:)) }

    /// Worauf der Countdown zählt (Regenbeginn, Regenende); `nil` = kein Countdown.
    var countdownTarget: Date? {
        switch kind {
        case .rainSoon: start
        case .raining: end
        case .warning: nil
        }
    }

    /// Erste Zeile ohne Countdown: „Regen bis ca. 21 Uhr“, „Orkanartige Böen“.
    /// Mit Countdown setzt die Ansicht „Regen in“ bzw. „Trocken in“ vor den Timer.
    var countdownLabel: String {
        kind == .rainSoon ? "Regen in" : "Trocken in"
    }

    var title: String {
        switch kind {
        case .rainSoon:
            return "Regen ab \(Fmt.time(start))"
        case .raining:
            if let end { return "Trocken ab \(Fmt.time(end))" }
            if let dry { return "Regen bis ca. \(Fmt.hour(dry))" }
            return "Regen hält an"
        case .warning:
            return eventTitle
        }
    }

    /// Zweite Zeile: Uhrzeiten zum Countdown und die Stärke.
    func detail(now: Date = .now) -> String {
        let strength = Self.strength(peakMmH)
        switch kind {
        case .rainSoon:
            return "ab \(Fmt.time(start))" + (end.map { " bis \(Fmt.time($0))" } ?? "") + ", \(strength)"
        case .raining:
            if let end { return "trocken ab \(Fmt.time(end)), jetzt \(strength)" }
            if dry != nil { return "jetzt \(strength), Ende laut Vorhersage" }
            return "jetzt \(strength), kein Ende in 12 h"
        case .warning:
            let level = alertSeverity?.label ?? "Unwetterwarnung"
            let from = start > now ? "ab \(Fmt.dayTime(start, now: now))" : nil
            let until = end.map { "bis \(Fmt.dayTime($0, now: now))" }
            return ([level] + [from, until].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// „leicht“, „mäßig“, „stark“ nach dem stärksten Wert im Schauer.
    static func strength(_ peak: Double) -> String {
        switch peak {
        case ..<0.5: "leicht"
        case ..<4: "mäßig"
        default: "stark"
        }
    }

    /// Gleiche Grenze wie der Server: kleinere Verschiebungen sind kein neuer Stand.
    func differs(from other: Self) -> Bool {
        func shifted(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case let (a?, b?): abs(a - b) >= 300
            default: (a == nil) != (b == nil)
            }
        }
        return kind != other.kind || event != other.event || severity != other.severity
            || shifted(startsAt, other.startsAt) || shifted(endsAt, other.endsAt)
            || shifted(dryAt, other.dryAt)
            || Self.strength(peakMmH) != Self.strength(other.peakMmH)
    }

    /// Ohne neue Daten gilt eine Regen-Aktivität nach 30 min als veraltet, eine Warnung mit Ablauf.
    func staleDate(now: Date) -> Date? {
        kind == .warning ? end : now.addingTimeInterval(30 * 60)
    }

    var relevance: Double {
        switch kind {
        case .warning: 100
        case .rainSoon: 80
        case .raining: 60
        }
    }
}
#endif
