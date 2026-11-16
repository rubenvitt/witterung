import Foundation

/// Antworten von Jev, dem Entscheidungsmodell von TypeSafe, über den Server
/// (`POST /api/v1/decide`, docs/api.md). Jev schreibt keinen Text: Es wählt aus
/// Optionen, die die App vorgibt, und nennt Wahrscheinlichkeiten. Die Regeln
/// liefern die Fakten, Jev trifft die Abwägungen:
///
/// - `focus`: welcher Hinweis vorn steht,
/// - `mode`: was das Smart-Widget zeigt (Hinweis, Stunden, Tage, Heute Nacht, Ruhe),
/// - `urgency`: wie dringend die Lage ist (Neuladen, Smart Stack),
/// - `sections`: welche Karte auf der Ortsseite oben steht,
/// - `window`: das beste Gassi-Fenster.
///
/// Jede Antwort gilt nur bei Konfidenz ≥ 0,5 (TypeSafe: darunter nicht automatisch
/// handeln); sonst und ohne Jev entscheiden die Regeln.
struct JevDecision: Codable, Sendable, Equatable {
    struct Choice: Codable, Sendable, Equatable {
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double

        var isConfident: Bool { confidence >= JevDecision.minimumConfidence }
    }

    struct Score: Codable, Sendable, Equatable {
        /// 0 (reine Information) … 3 (jetzt handeln).
        let score: Double
        let confidence: Double
    }

    let model: String
    let focus: Choice?
    let mode: Choice?
    let urgency: Score?
    let sections: Choice?
    let window: Choice?

    static let minimumConfidence = 0.5

    /// Gassi-Fenster, das Jev gewählt hat, wenn es sicher genug ist.
    var windowChoice: String? { window.flatMap { $0.isConfident ? $0.choice : nil } }
}

extension Insight {
    /// Rote und violette Warnungen stehen vorn, egal was Jev meint.
    var isPinned: Bool {
        if kind == .alert, case let .alert(severity) = tone { return severity >= .severe }
        return false
    }

    /// Grund samt Jev-Anteil, wenn Jev diesen Hinweis nach vorn geholt hat.
    var reasonLine: String {
        guard let p = jevProbability else { return reason }
        return "\(reason) · Jev \(Int((p * 100).rounded())) %"
    }

    /// Herkunft für Sperrbildschirm und Watch: „Jev 84 %“ oder „Radar“.
    var shortReason: String {
        jevProbability.map { "Jev \(Int(($0 * 100).rounded())) %" } ?? source
    }

    /// Hinweise mit allem, was Jev entschieden hat: Gassi-Fenster und Reihenfolge.
    static func ranked(_ forecast: Forecast, at now: Date, baseline: ForecastDigest? = nil, events: [CalendarEvent] = [],
                       habits: UsageStats? = nil, decision: JevDecision? = nil) -> [Insight] {
        rank(forecast, at: now, baseline: baseline, events: events, habits: habits, window: decision?.windowChoice)
            .ordered(by: decision?.focus)
    }
}

extension Array where Element == Insight {
    /// Reihenfolge nach Jev – nur wenn Jev über genau diese Hinweise entschieden hat
    /// und sicher genug ist. Sonst bleibt alles, wie die Regeln es sortiert haben.
    func ordered(by focus: JevDecision.Choice?) -> [Insight] {
        guard let focus, count >= 2, focus.isConfident,
              Set(focus.probabilities.keys) == Set(map(\.kind.rawValue)) else { return self }
        let p = { (i: Insight) in focus.probabilities[i.kind.rawValue] ?? 0 }
        var result = enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            if p(a.element) != p(b.element) { return p(a.element) > p(b.element) }
            return a.offset < b.offset
        }.map(\.element)
        if !result[0].isPinned { result[0].jevProbability = p(result[0]) }
        return result
    }
}

// MARK: Ansicht des Smart-Widgets

/// Was „Im Blick“ zeigt. Der wichtigste Hinweis steht in jeder Ansicht mindestens als Zeile.
enum WidgetMode: String, Codable, Sendable, CaseIterable {
    /// Der Hinweis groß, daneben Radar, Stunden oder Tage.
    case hint
    /// Der Stundenverlauf.
    case hours
    /// Die nächsten Tage.
    case days
    /// Heute Nacht und morgen früh.
    case tonight
    /// Ruhige Übersicht.
    case calm

    /// Jev, wenn sicher genug; sonst die Regeln. Rote und violette Warnungen erzwingen den Hinweis.
    static func decide(_ insights: [Insight], at now: Date, decision: JevDecision?, habits: UsageStats? = nil) -> WidgetMode {
        jevChoice(insights, decision: decision) ?? rules(insights, at: now, habits: habits)
    }

    /// Die Ansicht, die Jev gewählt hat, falls sie gilt.
    static func jevChoice(_ insights: [Insight], decision: JevDecision?) -> WidgetMode? {
        guard insights.first?.isPinned != true, let mode = decision?.mode, mode.isConfident else { return nil }
        return WidgetMode(rawValue: mode.choice)
    }

    /// Warum diese Ansicht – klein im Widget.
    var reason: String {
        switch self {
        case .hint: "Ein Hinweis zählt gerade am meisten"
        case .hours: "Die nächsten Stunden ändern sich"
        case .days: "Die nächsten Tage sind spannender"
        case .tonight: "Abends zählen Nacht und Morgen"
        case .calm: "Nichts Auffälliges in Sicht"
        }
    }

    /// Ohne Jev: Wichtiges groß; ist nichts los, abends die Nacht, tagsüber die Übersicht –
    /// oder Stunden bzw. Tage, wenn die Person diese Ansicht am häufigsten öffnet.
    static func rules(_ insights: [Insight], at now: Date, habits: UsageStats? = nil) -> WidgetMode {
        let hour = Fmt.calendar.component(.hour, from: now)
        let evening = hour >= 18 || hour < 5
        guard let top = insights.first else { return .calm }
        if top.kind == .calm {
            if evening { return .tonight }
            return habits?.favoriteMode.flatMap { [.hours, .days].contains($0) ? $0 : nil } ?? .calm
        }
        if top.isUrgent || top.score >= 0.5 { return .hint }
        if evening, [.frost, .ice, .snow, .walk].contains(top.kind) { return .tonight }
        if top.visual == .days { return .days }
        if top.score < 0.3 { return evening ? .tonight : .hours }
        return .hint
    }
}

/// Dringlichkeit 0…1: Jevs Stufe (0–3) oder das Gewicht des wichtigsten Hinweises.
enum Urgency {
    static func value(_ insights: [Insight], decision: JevDecision?) -> Double {
        if insights.first?.isPinned == true { return 1 }
        if let u = decision?.urgency, u.confidence >= JevDecision.minimumConfidence {
            return min(1, max(0, u.score / 3))
        }
        return insights.first?.score ?? 0
    }

    /// Wie bald das Widget neu lädt.
    static func refreshMinutes(_ urgency: Double) -> Double {
        switch urgency {
        case 0.66...: 15
        case ..<0.2: 60
        default: 30
        }
    }
}

extension PlaceSection {
    /// Warnungen immer zuerst, danach Jevs Reihenfolge, wenn sicher genug, sonst die Regeln.
    static func order(for insights: [Insight], decision: JevDecision?, at now: Date = .now, habits: UsageStats? = nil) -> [PlaceSection] {
        let rules = order(for: insights, at: now, habits: habits)
        guard let sections = decision?.sections, sections.isConfident else { return rules }
        let rest = rules.filter { $0 != .alerts }.enumerated().sorted { a, b in
            let pa = sections.probabilities[a.element.rawValue] ?? 0
            let pb = sections.probabilities[b.element.rawValue] ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
        return [.alerts] + rest
    }
}

// MARK: Anfrage

/// Was die App an Jev schickt: die Lage in wenigen Werten, die Hinweise und die Gassi-Fenster.
/// Zeiten auf 15 Minuten gerundet, damit der Server gleiche Lagen aus seinem Cache beantwortet.
struct DecisionRequest: Encodable, Sendable, Equatable {
    struct Hour: Encodable, Sendable, Equatable {
        let time: String
        let tempC: Int
        let precipMm: Double
        let precipProbPct: Int?
        let gustKmh: Int?
        let condition: String
    }

    struct Alert: Encodable, Sendable, Equatable {
        let event: String
        let level: String
        let period: String
    }

    struct State: Encodable, Sendable, Equatable {
        let place: String
        let localTime: String
        let daylight: Bool
        let tempC: Int?
        let condition: String
        let radar: String?
        let alerts: [Alert]
        let today: String?
        let tomorrow: String?
        let tonight: String?
        let nextHours: [Hour]
        /// Vorlieben aus der Nutzung („Öffnet oft: Stundenverlauf“), ohne Einzelheiten.
        let habits: String?
    }

    let state: State
    let options: [String: String]
    let windows: [String: String]

    static func rounded(_ now: Date) -> Date {
        let quarter = 15.0 * 60
        return Date(timeIntervalSince1970: (now.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
    }

    /// Hinweise und Lage gelten für die Viertelstunde von `now`, damit die Texte („Regen in
    /// 25 Minuten“) stehen bleiben.
    static func make(_ forecast: Forecast, placeName: String, at now: Date, baseline: ForecastDigest? = nil,
                     events: [CalendarEvent] = [], habits: UsageStats? = nil) -> DecisionRequest {
        let rounded = rounded(now)
        let insights = Insight.rank(forecast, at: rounded, baseline: baseline, events: events, habits: habits)
        let current = forecast.hour(at: now)?.consensus ?? forecast.now.forecast
        let observed = forecast.now.observed.flatMap { now.timeIntervalSince($0.at) < 90 * 60 ? $0 : nil }
        let isDay = current?.isDay ?? true
        func dayText(_ date: Date) -> String? {
            forecast.day(at: date).map {
                "\($0.consensus.condition.label()), \(Fmt.temp($0.consensus.tempMinC)) bis \(Fmt.temp($0.consensus.tempMaxC)), "
                    + "\(Fmt.mm($0.consensus.precipMm)) Niederschlag"
            }
        }
        let state = State(
            place: placeName,
            localTime: "\(Fmt.weekday(Fmt.dayString(rounded), now: .distantPast)) \(Fmt.time(rounded))",
            daylight: isDay,
            tempC: (observed?.tempC ?? current?.tempC).map { Int($0.rounded()) },
            condition: (current?.condition ?? .unknown).label(isDay: isDay),
            radar: NowcastSummary(forecast.nowcast, now: rounded).sentence,
            alerts: forecast.alerts.filter { ($0.expires ?? .distantFuture) > now }.map {
                Alert(event: $0.eventTitle, level: $0.severity.label, period: $0.timeRange(now: rounded))
            },
            today: dayText(now),
            tomorrow: dayText(now.addingTimeInterval(86_400)),
            tonight: NightOutlook.make(forecast, at: rounded)?.summary,
            nextHours: forecast.hourly.filter { $0.at > now }.prefix(12).map {
                let c = $0.consensus
                return Hour(time: Fmt.hour($0.at), tempC: Int(c.tempC.rounded()), precipMm: (c.precipMm * 10).rounded() / 10,
                            precipProbPct: c.precipProbPct.map { Int($0.rounded()) }, gustKmh: c.gustKmh.map { Int($0.rounded()) },
                            condition: c.condition.label(isDay: c.isDay ?? true))
            },
            habits: habits?.summary)
        let options = Dictionary(insights.map { insight in
            (insight.kind.rawValue, String((insight.jevText ?? "\(insight.title). \(insight.detail). Grund: \(insight.reason)").prefix(300)))
        }, uniquingKeysWith: { first, _ in first })
        let windows = Dictionary(Insight.walkWindows(forecast, at: rounded).map { ($0.id, $0.summary) },
                                 uniquingKeysWith: { first, _ in first })
        return DecisionRequest(state: state, options: options, windows: windows)
    }
}
