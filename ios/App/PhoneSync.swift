import Foundation
import WatchConnectivity

/// iPhone-Seite der Verbindung zur Watch: schickt Server, Token, Orte und den
/// letzten Standort als `applicationContext` (siehe `WatchLink`). Das System hebt
/// nur den letzten Stand auf und stellt ihn zu, sobald die Watch erreichbar ist.
@MainActor
final class PhoneSync: NSObject, WCSessionDelegate {
    static let shared = PhoneSync()
    private var lastSent: WatchLink?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Nach jeder Änderung an Anmeldung, Server, Orten oder Standort rufen.
    func push() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let link = WatchLink.current
        guard link != lastSent else { return }
        do {
            try session.updateApplicationContext(link.dictionary)
            lastSent = link
        } catch {
            // Nächster Versuch beim nächsten Anlass.
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Watch gewechselt: mit der neuen weitermachen.
        session.activate()
        Task { @MainActor in self.lastSent = nil }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        // Watch-App frisch installiert: Stand erneut schicken.
        Task { @MainActor in
            self.lastSent = nil
            self.push()
        }
    }

    /// Die Watch fragt direkt nach (z. B. gleich nach der Installation).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(WatchLink.current.dictionary)
    }
}
