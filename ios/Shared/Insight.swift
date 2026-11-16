import Foundation

/// Worauf es gerade ankommt: ein Hinweis mit Entscheidungsgrund.
///
/// `Insight.rank` prüft die Vorhersage auf alles, was einen Blick wert ist (Warnung,
/// Regen laut Radar, Gewitter, Böen, Glätte, Frost, Schnee, Hitze, Umschwung, trockene
/// Lücke, Uneinigkeit der Quellen) und sortiert nach Gewicht. Das Fokus-Widget zeigt den
/// ersten Hinweis, die Ortsseite ordnet danach ihre Karten. Reine Logik ohne SwiftUI,
/// damit sie in Tests und auf jeder Plattform gleich läuft.
struct Insight: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case alert, rainNow, rainSoon, thunder, storm, ice, frost, snow, heat, rainLater, change, walk, uncertain, calm
    }

    /// Farbe im Widget und auf der Karte (Theme.tone).
    enum Tone: Sendable, Hashable {
        case alert(WeatherAlert.Severity), rain, cold, warm, wind, info, calm
    }

    /// Welche Zusatzansicht das Fokus-Widget neben dem Hinweis zeigt.
    enum Visual: Sendable, Hashable { case radar, hours, days }

    let kind: Kind
    /// 0…1. Bestimmt die Reihenfolge und die Relevanz im Smart Stack.
    let score: Double
    /// „Regen in 25 Minuten“
    let title: String
    /// „ab 13:25, bis etwa 15:00“
    let detail: String
    /// Entscheidungsgrund: warum dieser Hinweis, woher die Daten.
    let reason: String
    let symbol: String
    let tone: Tone
    /// Ganz kurz für runde Komplikationen: „25′“, „−3°“, „68“.
    let badge: String

    var id: Kind { kind }

    var visual: Visual {
        switch kind {
        case .rainNow, .rainSoon: .radar
        case .heat, .change: .days
        default: .hours
        }
    }

    /// Warnungen und Regen laut Radar: dafür hat die Ortsseite eigene Karten.
    var isUrgent: Bool { [.alert, .rainNow, .rainSoon].contains(kind) }
}

extension Insight {
    /// Alle Hinweise für `now`, das Wichtigste zuerst. Nie leer: Ohne Auffälliges gibt es „Ruhiges Wetter“.
    static func rank(_ forecast: Forecast, at now: Date) -> [Insight] {
        let context = Context(forecast: forecast, now: now)
        let candidates: [Insight?] = [
            context.alert(),
            context.rain(),
            context.thunder(),
            context.storm(),
            context.cold(),
            context.heat(),
            context.change(),
            context.walk(),
            context.uncertain(),
        ]
        let found = candidates.compactMap { $0 }.sorted { $0.score > $1.score }
        return found.isEmpty ? [context.calm()] : found
    }

    static func focus(_ forecast: Forecast, at now: Date) -> Insight {
        rank(forecast, at: now)[0]
    }
}

/// Die Regeln. Schwellen und Gewichte stehen hier beieinander, damit man sie vergleichen kann.
private struct Context {
    let forecast: Forecast
    let now: Date

    /// Stunden ab der laufenden bis `hours` voraus.
    func upcoming(_ hours: Double) -> [HourRow] {
        forecast.hourly.filter { $0.at.addingTimeInterval(3600) > now && $0.at < now.addingTimeInterval(hours * 3600) }
    }

    var activeAlerts: [WeatherAlert] {
        forecast.alerts.filter { ($0.expires ?? .distantFuture) > now && $0.onset < now.addingTimeInterval(12 * 3600) }
    }

    /// Steht das Thema schon in einer amtlichen Warnung, braucht es keinen eigenen Hinweis.
    func alertCovers(_ words: [String]) -> Bool {
        activeAlerts.contains { alert in
            let event = alert.event.uppercased(with: Fmt.locale)
            return words.contains { event.contains($0) }
        }
    }

    func gust(_ p: HourPoint) -> Double { p.gustKmh ?? p.windKmh }

    // MARK: Warnung

    func alert() -> Insight? {
        let sorted = activeAlerts.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.onset < $1.onset }
        guard let top = sorted.first else { return nil }
        let base: Double = switch top.severity {
        case .minor: 0.55
        case .moderate: 0.8
        case .severe: 0.92
        case .extreme: 1.0
        }
        // Was erst in einigen Stunden beginnt, darf hinter Regen in 10 Minuten stehen.
        let later = top.onset > now.addingTimeInterval(3 * 3600)
        let more = sorted.count > 1 ? " · \(sorted.count - 1) weitere" : ""
        return Insight(
            kind: .alert, score: base - (later ? 0.1 : 0),
            title: top.eventTitle,
            detail: top.timeRange(now: now).capitalizedFirst + more,
            reason: "\(top.severity.label) des DWD",
            symbol: "exclamationmark.triangle.fill", tone: .alert(top.severity), badge: "!")
    }

    // MARK: Niederschlag

    /// Radar zuerst (genauer), sonst die Stunden der nächsten 12 h.
    func rain() -> Insight? {
        let summary = NowcastSummary(forecast.nowcast, now: now)
        let points = (forecast.nowcast?.points ?? []).filter { $0.at.addingTimeInterval(300) > now }
        let wet = { (p: NowcastPoint) in p.precipMmH >= NowcastSummary.threshold }
        switch summary {
        case let .startsIn(minutes, peak):
            let start = points.first(where: wet)
            let end = start.flatMap { s in points.first { $0.at > s.at && !wet($0) } }
            let detail = "ab \(Fmt.time(start?.at ?? now))" + (end.map { ", bis etwa \(Fmt.time($0.at))" } ?? ", hält an")
            return Insight(
                kind: .rainSoon,
                score: 0.8 - 0.2 * min(1, Double(minutes) / 60) + (peak >= 4 ? 0.05 : 0),
                title: summary.sentence ?? "Regen bald", detail: detail,
                reason: "Regenradar des DWD, nächste 2 Stunden",
                symbol: peak >= 4 ? "cloud.heavyrain.fill" : "cloud.rain.fill", tone: .rain, badge: "\(minutes)′")
        case let .rainingEndsIn(minutes, peak):
            let end = points.first { !wet($0) }
            return Insight(
                kind: .rainNow, score: peak >= 4 ? 0.8 : 0.7,
                title: summary.sentence ?? "Regen", detail: "Trocken ab \(Fmt.time(end?.at ?? now.addingTimeInterval(Double(minutes) * 60)))",
                reason: "Regenradar des DWD: es regnet gerade",
                symbol: "umbrella.fill", tone: .rain, badge: "\(minutes)′")
        case let .rainingContinues(_, peak):
            let horizon = points.last.map { $0.at.addingTimeInterval(300) } ?? now
            let dry = forecast.hourly.first { $0.at >= horizon && $0.at < now.addingTimeInterval(12 * 3600) && $0.consensus.precipMm < 0.1 }
            return Insight(
                kind: .rainNow, score: peak >= 4 ? 0.85 : 0.75,
                title: summary.sentence ?? "Regen hält an",
                detail: dry.map { "Trocken voraussichtlich ab \(Fmt.hour($0.at))" } ?? "Kein Ende in den nächsten 12 Stunden",
                reason: "Regenradar des DWD, danach Konsens der Quellen",
                symbol: "umbrella.fill", tone: .rain, badge: "☂︎")
        case .dry, .none:
            return hourlyPrecip(after: summary == .none ? now : points.last.map { $0.at.addingTimeInterval(300) } ?? now,
                                radarDry: summary != .none)
        }
    }

    /// Erste nasse Stunde (Median ≥ 0,1 mm) nach dem Radar-Horizont, höchstens 12 h voraus.
    private func hourlyPrecip(after from: Date, radarDry: Bool) -> Insight? {
        let rows = upcoming(12)
        guard let index = rows.firstIndex(where: { $0.at.addingTimeInterval(3600) > from && $0.consensus.precipMm >= 0.1 }) else { return nil }
        let first = rows[index]
        let spell = rows[index...].prefix { $0.consensus.precipMm >= 0.1 }
        let total = spell.map(\.consensus.precipMm).reduce(0, +)
        let isNow = first.at <= now && !radarDry
        let hoursAway = max(0, first.at.timeIntervalSince(now) / 3600)
        let agreement = first.spread.precipAgreementPct
        let condition = spell.map(\.consensus.condition).first { $0 == .snow || $0 == .sleet } ?? first.consensus.condition
        let frozen = condition == .snow || condition == .sleet

        if frozen, alertCovers(["SCHNEE", "GLÄTTE", "GLATTEIS"]) { return nil }
        if !frozen, alertCovers(["REGEN"]) { return nil }

        let word = condition == .snow ? "Schnee" : condition == .sleet ? "Schneeregen" : "Regen"
        var score = isNow ? 0.6 : max(0.3, 0.52 - 0.02 * hoursAway)
        if frozen { score += 0.1 }
        if let agreement, agreement < 50 { score *= 0.8 }
        let end = spell.last.map { $0.at.addingTimeInterval(3600) }
        let until = end.map { $0 < now.addingTimeInterval(12 * 3600) ? "bis etwa \(Fmt.hour($0))" : "länger anhaltend" } ?? ""
        let reason = agreement.map { "\(Int($0.rounded())) % der Quellen erwarten \(word)" } ?? "Konsens aus \(first.nSources) Quellen"
        return Insight(
            kind: frozen ? .snow : isNow ? .rainNow : .rainLater, score: score,
            title: isNow ? "\(word) jetzt" : "\(word) ab \(Fmt.hour(first.at))",
            detail: [until, total >= 0.1 ? Fmt.mm(total) : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
            reason: reason,
            symbol: condition.isWet ? condition.symbol(isDay: first.consensus.isDay ?? true) : "cloud.rain.fill",
            tone: frozen ? .cold : .rain,
            badge: isNow ? "☂︎" : "\(Fmt.calendar.component(.hour, from: first.at))h")
    }

    // MARK: Gewitter, Wind

    func thunder() -> Insight? {
        guard !alertCovers(["GEWITTER"]),
              let row = upcoming(12).first(where: { $0.consensus.condition == .thunderstorm }) else { return nil }
        let soon = row.at < now.addingTimeInterval(3 * 3600)
        let strongest = upcoming(12).filter { $0.at >= row.at }.prefix(3).map { gust($0.consensus) }.max()
        return Insight(
            kind: .thunder, score: soon ? 0.75 : 0.65,
            title: row.at <= now ? "Gewitter möglich" : "Gewitter ab \(Fmt.hour(row.at))",
            detail: strongest.map { $0 >= 40 ? "Böen bis \(Fmt.kmh($0))" : "Blitz und Starkregen möglich" } ?? "Blitz und Starkregen möglich",
            reason: "Wetterlage im Konsens der Quellen",
            symbol: "cloud.bolt.rain.fill", tone: .alert(.moderate), badge: "⚡︎")
    }

    func storm() -> Insight? {
        guard !alertCovers(["BÖEN", "STURM", "ORKAN", "WIND"]),
              let peak = upcoming(12).max(by: { gust($0.consensus) < gust($1.consensus) }) else { return nil }
        let value = gust(peak.consensus)
        let (score, title): (Double, String) = switch value {
        case 75...: (0.7, "Sturmböen bis \(Fmt.kmh(value))")
        case 60...: (0.55, "Starke Böen bis \(Fmt.kmh(value))")
        case 50...: (0.35, "Windig, Böen bis \(Fmt.kmh(value))")
        default: (0, "")
        }
        guard score > 0 else { return nil }
        let direction = peak.consensus.windDirDeg.map { " aus \(Fmt.compassPoint($0))" } ?? ""
        return Insight(
            kind: .storm, score: score, title: title,
            detail: "am stärksten gegen \(Fmt.hour(peak.at))\(direction)",
            reason: "Höchste Böe der nächsten 12 Stunden",
            symbol: "wind", tone: .wind, badge: "\(Int(value.rounded()))")
    }

    // MARK: Kälte, Wärme

    /// Glätte (Niederschlag um 0°) vor Frost: Glätte ist das, was draußen stört.
    func cold() -> Insight? {
        let rows = upcoming(18)
        if !alertCovers(["GLÄTTE", "GLATTEIS"]),
           let icy = rows.first(where: { $0.consensus.tempC <= 1 && $0.consensus.precipMm >= 0.1 }) {
            return Insight(
                kind: .ice, score: 0.7, title: "Glättegefahr",
                detail: "\(icy.consensus.condition.label()) bei \(Fmt.temp(icy.consensus.tempC)) gegen \(Fmt.hour(icy.at))",
                reason: "Niederschlag bei Temperaturen um 0°",
                symbol: "snowflake", tone: .cold, badge: Fmt.temp(icy.consensus.tempC))
        }
        guard !alertCovers(["FROST"]),
              let coldest = rows.min(by: { $0.consensus.tempC < $1.consensus.tempC }),
              coldest.consensus.tempC < 0.5 else { return nil }
        let temp = coldest.consensus.tempC
        // Nicht alle Quellen unter 0°: „möglich“ statt einer festen Zusage.
        let unsure = (coldest.spread.tempC?.max ?? temp) > 0.5
        return Insight(
            kind: .frost, score: temp <= -5 ? 0.55 : unsure ? 0.35 : 0.45,
            title: unsure ? "Frost möglich" : "Frost bis \(Fmt.temp(temp))",
            detail: "am kältesten gegen \(Fmt.hour(coldest.at))" + (unsure ? " · \(Fmt.temp(temp))" : ""),
            reason: unsure ? "Nicht alle Quellen erwarten Frost" : "Tiefstwert der nächsten 18 Stunden",
            symbol: "thermometer.snowflake", tone: .cold, badge: Fmt.temp(temp))
    }

    /// Heute (bis 16 Uhr) oder morgen.
    func heat() -> Insight? {
        guard !alertCovers(["HITZE"]) else { return nil }
        let today = Fmt.calendar.component(.hour, from: now) < 16 ? forecast.day(at: now) : nil
        let tomorrow = forecast.day(at: now.addingTimeInterval(86_400))
        let candidates: [(day: DayRow, label: String)] = [(today, "heute"), (tomorrow, "morgen")]
            .compactMap { pair in pair.0.map { (day: $0, label: pair.1) } }
        guard let best = candidates.max(by: { $0.day.consensus.tempMaxC < $1.day.consensus.tempMaxC }) else { return nil }
        let (day, label) = best
        let max = day.consensus.tempMaxC
        let score: Double = max >= 30 ? 0.6 : max >= 25 ? 0.3 : 0
        guard score > 0 else { return nil }
        return Insight(
            kind: .heat, score: score,
            title: max >= 30 ? "Heiß: bis \(Fmt.temp(max))" : "Sommerlich: bis \(Fmt.temp(max))",
            detail: label == "heute" ? "Höchstwert heute" : "Höchstwert morgen",
            reason: max >= 30 ? "Ab 30° gilt ein Tag als heiß" : "Ab 25° gilt ein Tag als Sommertag",
            symbol: "sun.max.fill", tone: .warm, badge: Fmt.temp(max))
    }

    /// Morgen deutlich wärmer oder kälter als heute.
    func change() -> Insight? {
        guard let today = forecast.day(at: now)?.consensus,
              let tomorrow = forecast.day(at: now.addingTimeInterval(86_400))?.consensus else { return nil }
        let delta = tomorrow.tempMaxC - today.tempMaxC
        guard abs(delta) >= 5 else { return nil }
        let evening = Fmt.calendar.component(.hour, from: now) >= 15
        let degrees = Int(abs(delta).rounded())
        return Insight(
            kind: .change, score: (abs(delta) >= 8 ? 0.45 : 0.38) + (evening ? 0.05 : 0),
            title: "Morgen \(degrees)° \(delta < 0 ? "kälter" : "wärmer")",
            detail: "Höchstwert \(Fmt.temp(tomorrow.tempMaxC)) statt \(Fmt.temp(today.tempMaxC))",
            reason: "Höchstwert heute und morgen im Vergleich",
            symbol: delta < 0 ? "thermometer.low" : "thermometer.high", tone: delta < 0 ? .cold : .warm,
            badge: "\(delta < 0 ? "−" : "+")\(degrees)°")
    }

    // MARK: Draußen

    /// Gassi-Fenster: Regnet es in den nächsten 12 h, die erste trockene Lücke
    /// von mindestens zwei Stunden zwischen 6 und 22 Uhr, sonst die längste.
    func walk() -> Insight? {
        let rows = upcoming(12)
        let isDry = { (r: HourRow) in r.consensus.precipMm < 0.1 && (r.consensus.precipProbPct ?? 0) < 50 && !r.consensus.condition.isWet }
        guard rows.contains(where: { !isDry($0) }) else { return nil }
        // Läuft gerade Regen laut Radar, zählt die laufende Stunde nicht als trocken.
        let radarWet: Bool = switch NowcastSummary(forecast.nowcast, now: now) {
        case .rainingEndsIn, .rainingContinues: true
        default: false
        }
        var runs: [[HourRow]] = []
        var current: [HourRow] = []
        for row in rows {
            let hour = Fmt.calendar.component(.hour, from: row.at)
            let usable = isDry(row) && (6..<22).contains(hour) && !(radarWet && row.at <= now)
            if usable { current.append(row) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        guard let run = runs.first(where: { $0.count >= 2 }) ?? runs.max(by: { $0.count < $1.count }),
              let first = run.first, let last = run.last else { return nil }
        let end = last.at.addingTimeInterval(3600)
        let title = first.at <= now ? "Gassi-Fenster bis \(Fmt.hour(end))" : "Gassi-Fenster \(Fmt.hourRange(first.at, end))"
        let mid = run[run.count / 2].consensus
        return Insight(
            kind: .walk, score: run.count >= 2 ? 0.42 : 0.32, title: title,
            detail: "trocken, um \(Fmt.temp(mid.tempC))" + (mid.windKmh >= 25 ? ", windig" : ""),
            reason: "Längste trockene Lücke zwischen den Schauern",
            symbol: "dog.fill", tone: .info, badge: "\(Fmt.calendar.component(.hour, from: first.at))h")
    }

    // MARK: Quellen

    /// Uneinige Quellen: große Temperatur-Spannbreite oder Regen, den nur ein Teil erwartet.
    func uncertain() -> Insight? {
        let rows = upcoming(24)
        let widest = rows.max { width($0.spread.tempC) < width($1.spread.tempC) }
        let split = rows.first { row in
            guard let agreement = row.spread.precipAgreementPct else { return false }
            return (30...70).contains(agreement) && (row.spread.precipMm?.max ?? 0) >= 0.5
        }
        if let widest, width(widest.spread.tempC) >= 5 {
            return Insight(
                kind: .uncertain, score: 0.25, title: "Quellen uneinig",
                detail: "Temperatur gegen \(Fmt.hour(widest.at)): \(Fmt.temp(widest.spread.tempC?.min)) bis \(Fmt.temp(widest.spread.tempC?.max))",
                reason: "Spannbreite aus \(widest.nSources) Quellen",
                symbol: "arrow.left.and.right", tone: .info, badge: "±\(Int((width(widest.spread.tempC) / 2).rounded()))°")
        }
        if let split, let agreement = split.spread.precipAgreementPct {
            return Insight(
                kind: .uncertain, score: 0.25, title: "Regen unsicher",
                detail: "gegen \(Fmt.hour(split.at)) erwarten \(Int(agreement.rounded())) % der Quellen Regen",
                reason: "Spannbreite aus \(split.nSources) Quellen",
                symbol: "questionmark.circle", tone: .info, badge: "\(Int(agreement.rounded()))%")
        }
        return nil
    }

    private func width(_ range: ValueRange?) -> Double { range.map { $0.max - $0.min } ?? 0 }

    // MARK: Ruhe

    func calm() -> Insight {
        let hour = forecast.hour(at: now)?.consensus ?? forecast.now.forecast
        let condition = hour?.condition ?? .cloudy
        let isDay = hour?.isDay ?? true
        let day = forecast.day(at: now)?.consensus
        let range = day.map { "\(Fmt.temp($0.tempMinC)) bis \(Fmt.temp($0.tempMaxC))" }
        return Insight(
            kind: .calm, score: 0.1, title: "Ruhiges Wetter",
            detail: ["\(condition.label(isDay: isDay)), kein Regen in Sicht", range].compactMap { $0 }.joined(separator: " · "),
            reason: "Keine Warnung, kein Regen, kein Frost in den nächsten 12 Stunden",
            symbol: condition.symbol(isDay: isDay), tone: .calm, badge: Fmt.temp(hour?.tempC))
    }
}

/// Karten der Ortsseite. Die Reihenfolge richtet sich nach dem wichtigsten Hinweis.
enum PlaceSection: String, CaseIterable, Sendable {
    case alerts, focus, nowcast, hourly, daily, details, sources

    /// Warnungen stehen immer oben. Danach, was der wichtigste Hinweis braucht:
    /// Regen → Radar vor allem anderen, Umschwung oder Hitze → 10 Tage vor den Stunden,
    /// Wind → Messwerte nach oben, uneinige Quellen → Quellenvergleich nach oben.
    static func order(for insights: [Insight]) -> [PlaceSection] {
        let standard: [PlaceSection] = [.alerts, .focus, .nowcast, .hourly, .daily, .details, .sources]
        guard let top = insights.first(where: { $0.kind != .alert }) ?? insights.first else { return standard }
        switch top.kind {
        case .rainNow, .rainSoon: return [.alerts, .nowcast, .focus, .hourly, .daily, .details, .sources]
        case .heat, .change: return [.alerts, .focus, .daily, .nowcast, .hourly, .details, .sources]
        case .storm: return [.alerts, .focus, .details, .nowcast, .hourly, .daily, .sources]
        case .uncertain: return [.alerts, .focus, .nowcast, .hourly, .sources, .daily, .details]
        default: return standard
        }
    }
}

extension String {
    /// „seit 13:00“ → „Seit 13:00“
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
