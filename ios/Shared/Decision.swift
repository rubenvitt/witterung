import Foundation

/// Antwort von Jev, dem Entscheidungsmodell von TypeSafe, über den Server
/// (`POST /api/v1/decide`, docs/api.md). Jev schreibt keinen Text: Es wählt
/// einen der Hinweise, die die Regeln gefunden haben, und gibt jedem eine
/// Wahrscheinlichkeit. Die Regeln liefern also die Fakten, Jev die Reihenfolge.
struct JevDecision: Codable, Sendable, Equatable {
    let choice: String
    let probabilities: [String: Double]
    let confidence: Double
    let model: String

    /// Darunter bleibt die Reihenfolge der Regeln. TypeSafe nennt 0,5 als Untergrenze,
    /// unter der man nicht automatisch handeln soll.
    static let minimumConfidence = 0.5

    /// Die Hinweise, über die Jev entschieden hat.
    var kinds: Set<String> { Set(probabilities.keys) }
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
}

extension Array where Element == Insight {
    /// Reihenfolge nach Jev – nur wenn Jev über genau diese Hinweise entschieden hat
    /// und sicher genug ist. Sonst bleibt alles, wie die Regeln es sortiert haben.
    func ordered(by decision: JevDecision?) -> [Insight] {
        guard let decision, count >= 2, decision.confidence >= JevDecision.minimumConfidence,
              decision.kinds == Set(map(\.kind.rawValue)) else { return self }
        let p = { (i: Insight) in decision.probabilities[i.kind.rawValue] ?? 0 }
        var result = enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            if p(a.element) != p(b.element) { return p(a.element) > p(b.element) }
            return a.offset < b.offset
        }.map(\.element)
        if !result[0].isPinned { result[0].jevProbability = p(result[0]) }
        return result
    }
}

/// Was die App an Jev schickt: die Lage in wenigen Werten und die Hinweise als Optionen.
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
        let nextHours: [Hour]
    }

    let state: State
    let options: [String: String]

    /// `nil`, wenn es nichts zu entscheiden gibt (weniger als zwei Hinweise). Hinweise und Lage
    /// gelten für die Viertelstunde von `now`, damit die Texte („Regen in 25 Minuten“) stehen bleiben.
    static func make(_ forecast: Forecast, placeName: String, at now: Date) -> DecisionRequest? {
        let quarter = 15.0 * 60
        let rounded = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
        let insights = Insight.rank(forecast, at: rounded)
        guard insights.count >= 2 else { return nil }
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
            nextHours: forecast.hourly.filter { $0.at > now }.prefix(12).map {
                let c = $0.consensus
                return Hour(time: Fmt.hour($0.at), tempC: Int(c.tempC.rounded()), precipMm: (c.precipMm * 10).rounded() / 10,
                            precipProbPct: c.precipProbPct.map { Int($0.rounded()) }, gustKmh: c.gustKmh.map { Int($0.rounded()) },
                            condition: c.condition.label(isDay: c.isDay ?? true))
            })
        let options = Dictionary(insights.map { insight in
            (insight.kind.rawValue, String("\(insight.title). \(insight.detail). Grund: \(insight.reason)".prefix(300)))
        }, uniquingKeysWith: { first, _ in first })
        return DecisionRequest(state: state, options: options)
    }
}
