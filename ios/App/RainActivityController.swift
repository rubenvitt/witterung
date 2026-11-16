import ActivityKit
import Foundation

/// Startet, aktualisiert und beendet die Live-Aktivität „Regen in …“ für die erste Seite
/// (Standort, sonst der erste Ort). Läuft nur, solange die App im Vordergrund lädt; der
/// Countdown zählt danach selbst weiter.
///
/// Bewusst nicht an den Haupt-Actor gebunden: `Activity` ist nicht `Sendable`, und Lesen,
/// Aktualisieren und Beenden müssen im selben (nicht isolierten) Kontext passieren.
enum RainActivityController {
    /// Höchstens so weit voraus (Minuten) wird die Aktivität gestartet.
    static let lead = 60

    static func update(forecast: Forecast, placeName: String, now: Date = .now) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Activity<RainActivityAttributes>.activities
        guard case let .startsIn(minutes, peak) = NowcastSummary(forecast.nowcast, now: now), minutes <= lead,
              let start = forecast.nowcast?.points.first(where: { $0.at > now && $0.precipMmH >= NowcastSummary.threshold })?.at
        else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let end = forecast.nowcast?.points.first { $0.at > start && $0.precipMmH < NowcastSummary.threshold }?.at
        let state = RainActivityAttributes.ContentState(start: start, end: end, intensity: NowcastSummary.intensityWord(peak),
                                                        peakMmH: peak)
        // Ab Regenbeginn zeigt sie „jetzt“; beendet wird sie beim nächsten Laden ohne Regen in Sicht
        // (oder vom System nach spätestens acht Stunden).
        let content = ActivityContent(state: state, staleDate: start, relevanceScore: 1)
        if let current = running.first(where: { $0.attributes.placeName == placeName }) {
            await current.update(content)
            for other in running where other.id != current.id { await other.end(nil, dismissalPolicy: .immediate) }
        } else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            _ = try? Activity.request(attributes: RainActivityAttributes(placeName: placeName), content: content, pushType: nil)
        }
    }
}
