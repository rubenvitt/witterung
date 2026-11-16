import EventKit
import Foundation

/// Liest die Termine der nächsten 36 Stunden aus dem Gerätekalender (alle Kalender, ohne
/// ganztägige) und legt sie für App und Widgets ab. Nur mit Freigabe in den Einstellungen.
@MainActor
enum CalendarSync {
    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Fragt nach Zugriff; `false`, wenn die Person ablehnt.
    static func requestAccess() async -> Bool {
        // Eigene Instanz: lässt sich ohne Datenrennen an die asynchrone Abfrage übergeben.
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func refresh(now: Date = .now) {
        guard SharedStore.calendarEnabled, isAuthorized else {
            CalendarStore.clear()
            return
        }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { CalendarEvent(start: $0.startDate, end: $0.endDate, title: $0.title ?? "Termin", location: $0.location) }
        CalendarStore.save(events)
    }
}
