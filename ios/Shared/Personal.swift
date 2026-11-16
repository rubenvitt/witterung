import Foundation

/// Ein Termin aus dem Kalender des Geräts (nur mit Freigabe in den Einstellungen).
/// Bleibt auf dem Gerät: Jev sieht nur „Termin draußen Di 15:00“, nie den Namen.
struct CalendarEvent: Codable, Sendable, Hashable {
    let start: Date
    let end: Date
    let title: String
    /// Mit Ort (kein Videocall) oder einem Titel, der nach draußen klingt.
    let outdoor: Bool

    init(start: Date, end: Date, title: String, outdoor: Bool) {
        self.start = start
        self.end = end
        self.title = title
        self.outdoor = outdoor
    }

    init(start: Date, end: Date, title: String, location: String?) {
        self.init(start: start, end: end, title: title, outdoor: Self.isOutdoor(title: title, location: location))
    }

    static let outdoorWords = [
        "gassi", "hund", "spazier", "wander", "lauf", "jogg", "fahrrad", "radtour", "rad fahren", "training", "garten",
        "markt", "grill", "draußen", "outdoor", "picknick", "strand", "zoo", "fußball", "sport", "einsatz",
        "sanitätsdienst", "übung", "fest", "umzug", "hochzeit", "camping", "angeln", "reiten", "golf",
    ]
    static let onlineWords = ["zoom", "teams", "meet.google", "webex", "http", "online", "telefon", "anruf"]

    static func isOutdoor(title: String, location: String?) -> Bool {
        let t = title.lowercased(with: Fmt.locale)
        if onlineWords.contains(where: { t.contains($0) }) { return false }
        if outdoorWords.contains(where: { t.contains($0) }) { return true }
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Fmt.locale),
              !location.isEmpty else { return false }
        return !onlineWords.contains { location.contains($0) }
    }
}

/// Was die Person antippt: Widget-Ansichten, Hinweise, Karten der Ortsseite. Zählt mit
/// Halbwertszeit von drei Wochen, damit alte Vorlieben verblassen. Bleibt auf dem Gerät;
/// Jev bekommt nur die Kurzfassung (`summary`).
struct UsageStats: Codable, Sendable, Equatable {
    var modes: [String: Double] = [:]
    var kinds: [String: Double] = [:]
    var sections: [String: Double] = [:]
    var updated: Date = .distantPast

    static let halfLifeDays = 21.0
    /// Ab so vielen (gewichteten) Taps gilt etwas als Vorliebe.
    static let threshold = 3.0
    /// So viel Gewicht bekommt ein Lieblingshinweis dazu.
    static let boost = 0.05

    mutating func record(mode: String? = nil, kind: String? = nil, section: String? = nil, at now: Date) {
        if updated != .distantPast, now > updated {
            let factor = pow(0.5, now.timeIntervalSince(updated) / 86_400 / Self.halfLifeDays)
            modes = modes.mapValues { $0 * factor }
            kinds = kinds.mapValues { $0 * factor }
            sections = sections.mapValues { $0 * factor }
        }
        updated = now
        if let mode { modes[mode, default: 0] += 1 }
        if let kind { kinds[kind, default: 0] += 1 }
        if let section { sections[section, default: 0] += 1 }
    }

    private static func top(_ counts: [String: Double], _ n: Int) -> [String] {
        counts.filter { $0.value >= threshold }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map(\.key)
    }

    var favoriteKinds: [Insight.Kind] { Self.top(kinds, 2).compactMap(Insight.Kind.init(rawValue:)) }
    var favoriteMode: WidgetMode? { Self.top(modes, 1).first.flatMap(WidgetMode.init(rawValue:)) }
    var favoriteSections: [PlaceSection] { Self.top(sections, 2).compactMap(PlaceSection.init(rawValue:)) }

    /// „Öffnet oft: Stundenverlauf; achtet oft auf: Gassi-Fenster; Karten: 10 Tage“ – für Jev.
    var summary: String? {
        let modeNames: [WidgetMode: String] = [.hint: "einzelne Hinweise", .hours: "Stundenverlauf", .days: "Tage",
                                               .tonight: "Nacht und Morgen", .calm: "Übersicht"]
        let sectionNames: [PlaceSection: String] = [.focus: "Im Blick", .nowcast: "Regenradar", .tonight: "Heute Nacht",
                                                    .hourly: "48 Stunden", .daily: "10 Tage", .details: "Messwerte",
                                                    .sources: "Quellenvergleich"]
        var parts: [String] = []
        if let mode = favoriteMode, let name = modeNames[mode] { parts.append("öffnet oft: \(name)") }
        let kinds = favoriteKinds.map(\.label)
        if !kinds.isEmpty { parts.append("achtet oft auf: \(kinds.joined(separator: ", "))") }
        let sections = favoriteSections.compactMap { sectionNames[$0] }
        if !sections.isEmpty { parts.append("schaut oft: \(sections.joined(separator: ", "))") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ").capitalizedFirst
    }
}

extension Insight.Kind {
    /// Deutscher Name für Vorlieben.
    var label: String {
        switch self {
        case .alert: "Warnungen"
        case .rainNow, .rainSoon, .rainLater: "Regen"
        case .event: "Termine"
        case .thunder: "Gewitter"
        case .storm: "Wind"
        case .ice: "Glätte"
        case .frost: "Frost"
        case .snow: "Schnee"
        case .heat: "Hitze"
        case .change, .shift: "Änderungen"
        case .walk: "Gassi-Fenster"
        case .weekend: "Wochenende"
        case .golden: "goldene Stunde"
        case .uncertain: "Unsicherheit"
        case .calm: "Ruhe"
        }
    }
}
