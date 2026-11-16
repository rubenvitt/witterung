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
        case alert, rainNow, rainSoon, event, thunder, storm, ice, frost, snow, heat, rainLater, change, shift, walk, weekend, golden,
             uncertain, calm
    }

    /// Farbe im Widget und auf der Karte (Theme.tone).
    enum Tone: Sendable, Hashable {
        case alert(WeatherAlert.Severity), rain, cold, warm, wind, info, calm
    }

    /// Welche Zusatzansicht das Fokus-Widget neben dem Hinweis zeigt.
    enum Visual: Sendable, Hashable { case radar, hours, days }

    let kind: Kind
    /// 0…1. Bestimmt die Reihenfolge und die Relevanz im Smart Stack.
    var score: Double
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
    /// Für Sperrbildschirm und Watch, höchstens etwa 14 Zeichen: „Regen 13:25“.
    let short: String
    /// Zweite Zeile dort, höchstens etwa 18 Zeichen: „bis 15:00“.
    let shortDetail: String
    /// Herkunft in einem Wort: „DWD“, „Radar“, „Konsens“.
    let source: String
    /// Text für Jev, wenn Titel und Detail Privates enthalten (Kalendertermine): nie der Terminname.
    var jevText: String?
    /// Gesetzt, wenn Jev diesen Hinweis nach vorn geholt hat (Decision.swift).
    var jevProbability: Double?

    var id: Kind { kind }

    var visual: Visual {
        switch kind {
        case .rainNow, .rainSoon: .radar
        case .heat, .change, .weekend: .days
        default: .hours
        }
    }

    /// Warnungen und Regen laut Radar: dafür hat die Ortsseite eigene Karten.
    var isUrgent: Bool { [.alert, .rainNow, .rainSoon].contains(kind) }
}

extension Insight {
    /// Alle Hinweise für `now`, das Wichtigste zuerst. Nie leer: Ohne Auffälliges gibt es „Ruhiges Wetter“.
    /// `baseline`: eine ältere Vorhersage zum Vergleich („Regen jetzt früher“), `window`: das
    /// Gassi-Fenster, das Jev gewählt hat (`WalkWindow.id`).
    /// `events`: Termine aus dem Kalender (nur mit Freigabe), `habits`: was die Person oft antippt.
    static func rank(_ forecast: Forecast, at now: Date, baseline: ForecastDigest? = nil, events: [CalendarEvent] = [],
                     habits: UsageStats? = nil, window: String? = nil) -> [Insight] {
        let context = Context(forecast: forecast, now: now, baseline: baseline, events: events)
        let candidates: [Insight?] = [
            context.alert(),
            context.rain(),
            context.event(),
            context.thunder(),
            context.storm(),
            context.cold(),
            context.heat(),
            context.change(),
            context.shift(),
            context.walk(choice: window),
            context.weekend(),
            context.golden(),
            context.uncertain(),
        ]
        // Was die Person oft antippt, rückt ein wenig nach vorn (UsageStats).
        let favorites = Set(habits?.favoriteKinds ?? [])
        let found = candidates.compactMap { $0 }.map { insight in
            var boosted = insight
            if favorites.contains(insight.kind) { boosted.score = min(1, boosted.score + UsageStats.boost) }
            return boosted
        }.sorted { $0.score > $1.score }
        return found.isEmpty ? [context.calm()] : found
    }

    static func focus(_ forecast: Forecast, at now: Date) -> Insight {
        rank(forecast, at: now)[0]
    }

    /// Trockene Zeitfenster für den Gassigang (Kandidaten für Jev).
    static func walkWindows(_ forecast: Forecast, at now: Date) -> [WalkWindow] {
        Context(forecast: forecast, now: now, baseline: nil, events: []).walkWindows()
    }
}

/// Die Regeln. Schwellen und Gewichte stehen hier beieinander, damit man sie vergleichen kann.
private struct Context {
    let forecast: Forecast
    let now: Date
    let baseline: ForecastDigest?
    let events: [CalendarEvent]

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
        let when = top.onset <= now
            ? top.expires.map { "bis \(Fmt.dayTime($0, now: now))" } ?? "aktiv"
            : "ab \(Fmt.dayTime(top.onset, now: now))"
        return Insight(
            kind: .alert, score: base - (later ? 0.1 : 0),
            title: top.eventTitle,
            detail: top.timeRange(now: now).capitalizedFirst + more,
            reason: "\(top.severity.label) des DWD",
            symbol: "exclamationmark.triangle.fill", tone: .alert(top.severity), badge: "!",
            short: top.eventTitle, shortDetail: when, source: "DWD")
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
                symbol: peak >= 4 ? "cloud.heavyrain.fill" : "cloud.rain.fill", tone: .rain, badge: "\(minutes)′",
                short: "Regen \(Fmt.time(start?.at ?? now))", shortDetail: end.map { "bis \(Fmt.time($0.at))" } ?? "hält an",
                source: "Radar")
        case let .rainingEndsIn(minutes, peak):
            let end = points.first { !wet($0) }
            let dryAt = Fmt.time(end?.at ?? now.addingTimeInterval(Double(minutes) * 60))
            return Insight(
                kind: .rainNow, score: peak >= 4 ? 0.8 : 0.7,
                title: summary.sentence ?? "Regen", detail: "Trocken ab \(dryAt)",
                reason: "Regenradar des DWD: es regnet gerade",
                symbol: "umbrella.fill", tone: .rain, badge: "\(minutes)′",
                short: "Regen bis \(dryAt)", shortDetail: "dann trocken", source: "Radar")
        case let .rainingContinues(_, peak):
            let horizon = points.last.map { $0.at.addingTimeInterval(300) } ?? now
            let dry = forecast.hourly.first { $0.at >= horizon && $0.at < now.addingTimeInterval(12 * 3600) && $0.consensus.precipMm < 0.1 }
            return Insight(
                kind: .rainNow, score: peak >= 4 ? 0.85 : 0.75,
                title: summary.sentence ?? "Regen hält an",
                detail: dry.map { "Trocken voraussichtlich ab \(Fmt.hour($0.at))" } ?? "Kein Ende in den nächsten 12 Stunden",
                reason: "Regenradar des DWD, danach Konsens der Quellen",
                symbol: "umbrella.fill", tone: .rain, badge: "☂︎",
                short: "Regen hält an", shortDetail: dry.map { "trocken ab \(Fmt.hour($0.at))" } ?? "kein Ende in Sicht",
                source: "Radar")
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
            badge: isNow ? "☂︎" : "\(Fmt.calendar.component(.hour, from: first.at))h",
            short: isNow ? "\(word) jetzt" : "\(word == "Schneeregen" ? "Schneereg." : word) \(Fmt.hour(first.at))",
            shortDetail: end.map { $0 < now.addingTimeInterval(12 * 3600) ? "bis \(Fmt.hour($0))" : "länger" } ?? Fmt.mm(total),
            source: "Konsens")
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
            symbol: "cloud.bolt.rain.fill", tone: .alert(.moderate), badge: "⚡︎",
            short: row.at <= now ? "Gewitter" : "Gewitter \(Fmt.hour(row.at))",
            shortDetail: strongest.map { $0 >= 40 ? "Böen \(Fmt.kmh($0))" : "möglich" } ?? "möglich", source: "Konsens")
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
            symbol: "wind", tone: .wind, badge: "\(Int(value.rounded()))",
            short: "Böen \(Fmt.kmh(value))", shortDetail: "gegen \(Fmt.hour(peak.at))", source: "Konsens")
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
                symbol: "snowflake", tone: .cold, badge: Fmt.temp(icy.consensus.tempC),
                short: "Glätte", shortDetail: "gegen \(Fmt.hour(icy.at))", source: "Konsens")
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
            symbol: "thermometer.snowflake", tone: .cold, badge: Fmt.temp(temp),
            short: unsure ? "Frost möglich" : "Frost \(Fmt.temp(temp))", shortDetail: "gegen \(Fmt.hour(coldest.at))",
            source: unsure ? "Quellen uneinig" : "Konsens")
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
            symbol: "sun.max.fill", tone: .warm, badge: Fmt.temp(max),
            short: max >= 30 ? "Heiß \(Fmt.temp(max))" : "Warm \(Fmt.temp(max))", shortDetail: label, source: "Konsens")
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
            badge: "\(delta < 0 ? "−" : "+")\(degrees)°",
            short: "Morgen \(delta < 0 ? "−" : "+")\(degrees)°", shortDetail: "H \(Fmt.temp(tomorrow.tempMaxC)) statt \(Fmt.temp(today.tempMaxC))",
            source: "Konsens")
    }

    // MARK: Draußen

    /// Trockene Lücken (mind. 1 h) zwischen 6 und 22 Uhr in den nächsten 12 Stunden, höchstens vier.
    func walkWindows() -> [WalkWindow] {
        let rows = upcoming(12)
        let isDry = { (r: HourRow) in r.consensus.precipMm < 0.1 && (r.consensus.precipProbPct ?? 0) < 50 && !r.consensus.condition.isWet }
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
        return runs.prefix(4).enumerated().map { index, run in
            let points = run.map(\.consensus)
            return WalkWindow(
                id: "w\(index)", start: max(run[0].at, now), end: run[run.count - 1].at.addingTimeInterval(3600),
                hours: run.count,
                tempC: points.map(\.tempC).reduce(0, +) / Double(points.count),
                windKmh: points.map(\.windKmh).max() ?? 0,
                daylight: points.allSatisfy { $0.isDay ?? true },
                isNow: run[0].at <= now)
        }
    }

    /// Gassi-Fenster: Regnet es in den nächsten 12 h, die erste trockene Lücke von mindestens
    /// zwei Stunden (sonst die längste) – oder die, die Jev gewählt hat.
    func walk(choice: String?) -> Insight? {
        guard upcoming(12).contains(where: { $0.consensus.precipMm >= 0.1 || $0.consensus.condition.isWet }) else { return nil }
        let windows = walkWindows()
        let chosen = choice.flatMap { id in windows.first { $0.id == id } }
        guard let window = chosen ?? windows.first(where: { $0.hours >= 2 }) ?? windows.max(by: { $0.hours < $1.hours }) else {
            return nil
        }
        let title = window.isNow ? "Gassi-Fenster bis \(Fmt.hour(window.end))" : "Gassi-Fenster \(Fmt.hourRange(window.start, window.end))"
        let startHour = Fmt.calendar.component(.hour, from: window.start)
        let endHour = Fmt.calendar.component(.hour, from: window.end)
        return Insight(
            kind: .walk, score: window.hours >= 2 ? 0.42 : 0.32, title: title,
            detail: "trocken, um \(Fmt.temp(window.tempC))" + (window.windKmh >= 25 ? ", windig" : "") + (window.daylight ? "" : ", im Dunkeln"),
            reason: chosen != nil ? "Bestes trockenes Fenster laut Jev" : "Längste trockene Lücke zwischen den Schauern",
            symbol: "dog.fill", tone: .info, badge: "\(startHour)h",
            short: window.isNow ? "Gassi bis \(endHour)h" : "Gassi \(startHour)–\(endHour)",
            shortDetail: "trocken, \(Fmt.temp(window.tempC))", source: chosen != nil ? "Jev" : "Konsens")
    }

    // MARK: Vorhersage geändert

    /// Vergleich mit einer 3–18 h älteren Vorhersage: Regen früher, später, neu oder abgesagt,
    /// sonst ein deutlich anderer Höchstwert für morgen.
    func shift() -> Insight? {
        guard let baseline else { return nil }
        let reason = "Vergleich mit der Vorhersage von \(Fmt.dayTime(baseline.generatedAt, now: now))"
        let horizon = baseline.generatedAt.addingTimeInterval(24 * 3600)
        let current = forecast.hourly.first {
            $0.at.addingTimeInterval(3600) > now && $0.at < horizon && $0.consensus.precipMm >= ForecastDigest.rainMm
        }?.at
        let old = baseline.firstRain.flatMap { $0 > now ? $0 : nil }
        func rainShift(_ score: Double, _ title: String, _ detail: String, _ short: String, _ shortDetail: String) -> Insight {
            Insight(kind: .shift, score: score, title: title, detail: detail, reason: reason,
                    symbol: "arrow.triangle.2.circlepath", tone: .rain, badge: "Neu",
                    short: short, shortDetail: shortDetail, source: "Vergleich")
        }
        switch (old, current) {
        case let (old?, new?) where abs(old.timeIntervalSince(new)) >= 2 * 3600:
            let earlier = new < old
            return rainShift(earlier ? 0.4 : 0.3, "Regen \(earlier ? "früher" : "später"): ab \(Fmt.hour(new))",
                             "vorher ab \(Fmt.hour(old)) angesagt", "Regen \(earlier ? "früher" : "später")", "ab \(Fmt.hour(new))")
        case let (nil, new?) where baseline.firstRain == nil:
            return rainShift(0.38, "Regen neu: ab \(Fmt.hour(new))", "vorher war es trocken angesagt", "Regen neu", "ab \(Fmt.hour(new))")
        case let (old?, nil):
            return rainShift(0.3, "Regen fällt aus", "vorher ab \(Fmt.hour(old)) angesagt", "Kein Regen", "statt \(Fmt.hour(old))")
        default:
            break
        }
        let key = Fmt.dayString(now.addingTimeInterval(86_400))
        guard let was = baseline.dailyMax[key], let isNow = forecast.daily.first(where: { $0.date == key })?.consensus.tempMaxC,
              abs(isNow - was) >= 3 else { return nil }
        let degrees = Int(abs(isNow - was).rounded())
        let colder = isNow < was
        return Insight(
            kind: .shift, score: 0.3, title: "Morgen \(degrees)° \(colder ? "kälter" : "wärmer") als angesagt",
            detail: "Höchstwert jetzt \(Fmt.temp(isNow)) statt \(Fmt.temp(was))", reason: reason,
            symbol: "arrow.triangle.2.circlepath", tone: colder ? .cold : .warm, badge: "\(colder ? "−" : "+")\(degrees)°",
            short: "Morgen \(colder ? "kälter" : "wärmer")", shortDetail: "\(Fmt.temp(isNow)) statt \(Fmt.temp(was))", source: "Vergleich")
    }

    // MARK: Termine, Wochenende, goldene Stunde

    /// Der nächste Termin draußen (mit Ort oder passendem Titel) in 24 h, bei dem das Wetter stört:
    /// Warnung, Regen, Böen ab 50 km/h oder Frost.
    func event() -> Insight? {
        let upcoming = events.filter { $0.outdoor && $0.end > now && $0.start < now.addingTimeInterval(24 * 3600) }
            .sorted { $0.start < $1.start }
        for e in upcoming {
            let rows = forecast.hourly.filter { $0.at.addingTimeInterval(3600) > max(e.start, now) && $0.at < e.end }
            guard !rows.isEmpty else { continue }
            let precip = rows.map(\.consensus.precipMm).max() ?? 0
            let strongest = rows.map { gust($0.consensus) }.max() ?? 0
            let coldest = rows.map(\.consensus.tempC).min() ?? 10
            let alert = activeAlerts.first { $0.onset < e.end && ($0.expires ?? .distantFuture) > e.start }
            let (word, tone): (String, Insight.Tone)
            if let alert {
                (word, tone) = (alert.eventTitle, .alert(alert.severity))
            } else if precip >= 0.2 {
                (word, tone) = ("Regen", .rain)
            } else if strongest >= 50 {
                (word, tone) = ("Böen", .wind)
            } else if coldest <= 0 {
                (word, tone) = ("Frost", .cold)
            } else {
                continue
            }
            let name = e.title.count > 22 ? String(e.title.prefix(21)) + "…" : e.title
            let mean = rows.map(\.consensus.tempC).reduce(0, +) / Double(rows.count)
            let facts = [precip >= 0.2 ? Fmt.mm(precip) : nil, strongest >= 50 ? "Böen \(Fmt.kmh(strongest))" : nil, Fmt.temp(mean)]
                .compactMap { $0 }.joined(separator: " · ")
            let when = Fmt.dayTime(e.start, now: now)
            return Insight(
                kind: .event, score: e.start < now.addingTimeInterval(3 * 3600) ? 0.62 : 0.48,
                title: "\(word) zu „\(name)“", detail: "\(when) · \(facts)",
                reason: "Termin draußen in deinem Kalender",
                symbol: "calendar.badge.exclamationmark", tone: tone, badge: "\(Fmt.calendar.component(.hour, from: e.start))h",
                short: alert != nil ? "Termin: Warnung" : "Termin: \(word)", shortDetail: when, source: "Kalender",
                jevText: "Termin draußen \(when): \(word), \(facts)")
        }
        return nil
    }

    /// Donnerstag ab Mittag und Freitag: wie wird das Wochenende, und welcher Tag ist besser für draußen?
    func weekend() -> Insight? {
        let calendar = Fmt.calendar
        let weekday = calendar.component(.weekday, from: now) // 1 = So … 5 = Do, 6 = Fr
        guard (weekday == 5 && calendar.component(.hour, from: now) >= 12) || weekday == 6 else { return nil }
        let saturday = calendar.date(byAdding: .day, value: 7 - weekday, to: calendar.startOfDay(for: now)) ?? now
        guard let sat = forecast.day(at: saturday.addingTimeInterval(12 * 3600))?.consensus,
              let sun = forecast.day(at: saturday.addingTimeInterval(36 * 3600))?.consensus else { return nil }
        func word(_ d: DayPoint) -> String { d.precipMm >= 1 ? "Regen" : d.condition.label() }
        let better: String? = switch (sat.precipMm >= 1, sun.precipMm >= 1) {
        case (true, false): "Sonntag"
        case (false, true): "Samstag"
        default: nil
        }
        return Insight(
            kind: .weekend, score: weekday == 6 ? 0.34 : 0.28,
            title: "Wochenende: Sa \(word(sat)), So \(word(sun))",
            detail: "Sa \(Fmt.temp(sat.tempMinC)) bis \(Fmt.temp(sat.tempMaxC)) · So \(Fmt.temp(sun.tempMinC)) bis \(Fmt.temp(sun.tempMaxC))"
                + (better.map { " · draußen eher am \($0)" } ?? ""),
            reason: "Tagesvorhersage für Samstag und Sonntag",
            symbol: "calendar", tone: .info, badge: "WE",
            short: better.map { "WE: eher \($0.prefix(2))" } ?? "Wochenende",
            shortDetail: "Sa \(Fmt.temp(sat.tempMaxC)) · So \(Fmt.temp(sun.tempMaxC))", source: "Konsens")
    }

    /// Die Stunde vor Sonnenuntergang, wenn sie trocken und kaum bewölkt ist: schönes Licht für die Runde.
    func golden() -> Insight? {
        guard let sunset = forecast.day(at: now)?.consensus.sunset, sunset > now, sunset < now.addingTimeInterval(8 * 3600) else {
            return nil
        }
        let start = sunset.addingTimeInterval(-3600)
        guard let row = forecast.hour(at: max(start, now)) else { return nil }
        let c = row.consensus
        guard c.precipMm < 0.1, (c.cloudPct ?? 100) < 50, !c.condition.isWet else { return nil }
        let from = max(start, now)
        return Insight(
            kind: .golden, score: start < now.addingTimeInterval(3 * 3600) ? 0.3 : 0.24,
            title: "Goldene Stunde ab \(Fmt.time(from))",
            detail: "bis \(Fmt.time(sunset)) · \(c.cloudPct.map { "\(Int($0.rounded())) % Wolken" } ?? "klar") · \(Fmt.temp(c.tempC))",
            reason: "Letzte Stunde vor Sonnenuntergang, trocken und kaum Wolken",
            symbol: "sun.horizon.fill", tone: .warm, badge: Fmt.time(from),
            short: "Goldene Stunde", shortDetail: "\(Fmt.time(from))–\(Fmt.time(sunset))", source: "Konsens")
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
                symbol: "arrow.left.and.right", tone: .info, badge: "±\(Int((width(widest.spread.tempC) / 2).rounded()))°",
                short: "Quellen uneinig", shortDetail: "±\(Int((width(widest.spread.tempC) / 2).rounded()))° gegen \(Fmt.hour(widest.at))",
                source: "Quellen")
        }
        if let split, let agreement = split.spread.precipAgreementPct {
            return Insight(
                kind: .uncertain, score: 0.25, title: "Regen unsicher",
                detail: "gegen \(Fmt.hour(split.at)) erwarten \(Int(agreement.rounded())) % der Quellen Regen",
                reason: "Spannbreite aus \(split.nSources) Quellen",
                symbol: "questionmark.circle", tone: .info, badge: "\(Int(agreement.rounded()))%",
                short: "Regen unsicher", shortDetail: "\(Int(agreement.rounded())) % gegen \(Fmt.hour(split.at))", source: "Quellen")
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
            symbol: condition.symbol(isDay: isDay), tone: .calm, badge: Fmt.temp(hour?.tempC),
            short: "Ruhig", shortDetail: day.map { "\(Fmt.temp($0.tempMinC)) bis \(Fmt.temp($0.tempMaxC))" } ?? condition.label(isDay: isDay),
            source: "Konsens")
    }
}

/// Karten der Ortsseite. Die Reihenfolge richtet sich nach dem wichtigsten Hinweis.
enum PlaceSection: String, CaseIterable, Sendable {
    case alerts, focus, nowcast, tonight, hourly, daily, details, sources

    /// Warnungen stehen immer oben. Danach, was der wichtigste Hinweis braucht:
    /// Regen → Radar vor allem anderen, Umschwung oder Hitze → 10 Tage vor den Stunden,
    /// Wind → Messwerte nach oben, uneinige Quellen → Quellenvergleich nach oben.
    /// Abends (ab 17 Uhr) und nachts rückt „Heute Nacht“ nach oben, tagsüber steht es nach den 10 Tagen.
    static func order(for insights: [Insight], at now: Date = .now, habits: UsageStats? = nil) -> [PlaceSection] {
        let hour = Fmt.calendar.component(.hour, from: now)
        let evening = hour >= 17 || hour < 5
        var order: [PlaceSection] = [.alerts, .focus, .nowcast, .hourly, .daily, .details, .sources]
        if let top = insights.first(where: { $0.kind != .alert }) ?? insights.first {
            switch top.kind {
            case .rainNow, .rainSoon: order = [.alerts, .nowcast, .focus, .hourly, .daily, .details, .sources]
            case .heat, .change: order = [.alerts, .focus, .daily, .nowcast, .hourly, .details, .sources]
            case .storm: order = [.alerts, .focus, .details, .nowcast, .hourly, .daily, .sources]
            case .uncertain, .shift: order = [.alerts, .focus, .nowcast, .hourly, .sources, .daily, .details]
            default: break
            }
        }
        let tonightAfter: PlaceSection = evening ? .focus : .daily
        order.insert(.tonight, at: (order.firstIndex(of: tonightAfter) ?? order.count - 1) + 1)
        // Die Karte, die die Person am häufigsten antippt, rückt hinter „Im Blick“ (nicht vor Radar-Regen).
        if let favorite = habits?.favoriteSections.first(where: { ![.alerts, .focus].contains($0) }),
           let from = order.firstIndex(of: favorite), let focus = order.firstIndex(of: .focus), from > focus + 1 {
            order.remove(at: from)
            order.insert(favorite, at: focus + 1)
        }
        return order
    }
}

/// Ein trockenes Zeitfenster für den Gassigang.
struct WalkWindow: Sendable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let hours: Int
    let tempC: Double
    let windKmh: Double
    let daylight: Bool
    let isNow: Bool

    /// Beschreibung für Jev: „17–19 Uhr (2 h): trocken, 7°, Wind bis 15 km/h, dunkel“.
    var summary: String {
        "\(isNow ? "jetzt bis \(Fmt.hour(end))" : Fmt.hourRange(start, end)) (\(hours) h): trocken, \(Fmt.temp(tempC)), "
            + "Wind bis \(Fmt.kmh(windKmh)), \(daylight ? "hell" : "dunkel")"
    }
}

/// Kurzfassung einer Vorhersage, um spätere Vorhersagen damit zu vergleichen.
struct ForecastDigest: Codable, Sendable, Equatable {
    static let rainMm = 0.2

    let generatedAt: Date
    /// Erste Stunde mit Regen (Median ≥ 0,2 mm) in den 24 h nach `generatedAt`.
    let firstRain: Date?
    /// Höchstwert je Tag (`JJJJ-MM-TT`).
    let dailyMax: [String: Double]

    init(generatedAt: Date, firstRain: Date?, dailyMax: [String: Double]) {
        self.generatedAt = generatedAt
        self.firstRain = firstRain
        self.dailyMax = dailyMax
    }

    init(_ forecast: Forecast) {
        let start = forecast.generatedAt
        generatedAt = start
        firstRain = forecast.hourly.first {
            $0.at.addingTimeInterval(3600) > start && $0.at < start.addingTimeInterval(24 * 3600) && $0.consensus.precipMm >= Self.rainMm
        }?.at
        dailyMax = Dictionary(forecast.daily.map { ($0.date, $0.consensus.tempMaxC) }, uniquingKeysWith: { a, _ in a })
    }

    /// Vergleichsstand für `now`: der jüngste Eintrag, der 3–18 Stunden alt ist.
    static func baseline(in history: [ForecastDigest], now: Date) -> ForecastDigest? {
        history.filter { (3 * 3600...18 * 3600).contains(now.timeIntervalSince($0.generatedAt)) }
            .max { $0.generatedAt < $1.generatedAt }
    }

    /// Neuer Eintrag höchstens stündlich, nur die letzten 24 bleiben.
    static func appending(_ digest: ForecastDigest, to history: [ForecastDigest]) -> [ForecastDigest] {
        if let last = history.last, digest.generatedAt.timeIntervalSince(last.generatedAt) < 3600 { return history }
        return Array((history + [digest]).suffix(24))
    }
}

extension String {
    /// „seit 13:00“ → „Seit 13:00“
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
