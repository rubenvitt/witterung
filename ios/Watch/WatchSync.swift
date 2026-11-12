import Foundation
import WatchConnectivity
import WidgetKit

/// Watch-Seite der Verbindung zum iPhone: übernimmt Server, Token, Orte und den
/// letzten Standort aus dem `applicationContext` (siehe `WatchLink`).
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// Wird nach jeder übernommenen Änderung gerufen (Modell lädt neu).
    var onChange: (@MainActor () -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Fragt das iPhone direkt nach dem Stand, falls es erreichbar ist
    /// (z. B. Watch-App frisch installiert, Kontext noch nicht da).
    func request() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        // @Sendable: WatchConnectivity ruft die Antwort auf einer eigenen Queue auf.
        session.sendMessage(["request": true], replyHandler: { @Sendable reply in
            let link = WatchLink(reply)
            Task { @MainActor in if let link { WatchSync.shared.apply(link) } }
        }, errorHandler: nil)
    }

    func apply(_ link: WatchLink) {
        guard link != WatchLink.current else { return }
        if link.server != SharedStore.serverURL {
            // Anderer Server, andere Orte: nichts vom alten stehen lassen.
            for ref in [PlaceRef.current] + SharedStore.places.map({ .saved($0.id) }) { ForecastCache.remove(ref) }
            SharedStore.serverURL = link.server
        }
        if let token = link.token {
            if token != TokenStore.token { try? TokenStore.save(token) }
        } else {
            TokenStore.delete()
        }
        let removed = Set(SharedStore.places.map(\.id)).subtracting(link.places.map(\.id))
        for id in removed { ForecastCache.remove(.saved(id)) }
        SharedStore.places = link.places
        // Der eigene Standort der Watch geht vor; der vom iPhone ist nur der Notnagel.
        if SharedStore.lastLocation == nil, let last = link.lastLocation {
            SharedStore.lastLocation = (last.lat, last.lon)
        }
        WidgetCenter.shared.reloadAllTimelines()
        onChange?()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let link = WatchLink(session.receivedApplicationContext)
        Task { @MainActor in
            if let link { self.apply(link) } else { self.request() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let link = WatchLink(context)
        Task { @MainActor in if let link { self.apply(link) } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if !WatchModel.hasAccess { self.request() }
        }
    }
}
