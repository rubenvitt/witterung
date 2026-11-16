#if os(iOS)
import ActivityKit
import Foundation

/// Live-Aktivität „Regen in …“: Countdown bis zum Regenbeginn laut Radar, auf dem
/// Sperrbildschirm und in der Dynamic Island. Startet die App (nur im Vordergrund möglich,
/// ohne Push-Server); der Countdown läuft danach von selbst.
struct RainActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Regenbeginn laut Radar.
        var start: Date
        /// Ende des Schauers, falls das Radar es schon zeigt.
        var end: Date?
        /// „Leichter Regen“, „Regen“, „Starker Regen“
        var intensity: String
        var peakMmH: Double
    }

    var placeName: String
}
#endif
