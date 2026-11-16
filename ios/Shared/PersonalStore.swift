import Foundation

extension SharedStore {
    /// Kalender einbeziehen (Einstellungen). Aus, bis die Person es einschaltet.
    static var calendarEnabled: Bool {
        get { defaults.bool(forKey: "calendarEnabled") }
        set { defaults.set(newValue, forKey: "calendarEnabled") }
    }
}

/// Termine der nächsten 36 Stunden, von der App aus dem Gerätekalender gelesen (CalendarSync),
/// im App-Group-Container für die Widgets. Verlässt das Gerät nicht.
enum CalendarStore {
    private static var url: URL { ForecastCache.directory.appendingPathComponent("events.json") }

    static func save(_ events: [CalendarEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Nur Termine, die noch nicht vorbei sind; ohne Freigabe nichts.
    static func load(now: Date = .now) -> [CalendarEvent] {
        guard SharedStore.calendarEnabled, let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([CalendarEvent].self, from: data) else { return [] }
        return events.filter { $0.end > now }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Was die Person antippt (UsageStats), in den App-Group-Defaults.
enum UsageStore {
    private static let key = "usageStats"

    static func load() -> UsageStats {
        SharedStore.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
    }

    static func record(mode: String? = nil, kind: String? = nil, section: String? = nil) {
        var stats = load()
        stats.record(mode: mode, kind: kind, section: section, at: .now)
        SharedStore.defaults.set(try? JSONEncoder().encode(stats), forKey: key)
    }

    static func reset() {
        SharedStore.defaults.removeObject(forKey: key)
    }
}
