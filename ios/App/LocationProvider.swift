import CoreLocation
import Observation

/// „Mein Standort“: Standort während die App aktiv ist, Wechsel erst ab 1 km.
@MainActor
@Observable
final class LocationProvider {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var denied = CLLocationManager().authorizationStatus == .denied
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?

    init() {
        if let last = SharedStore.lastLocation {
            coordinate = CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon)
        }
    }

    func start(onChange: @escaping @MainActor (CLLocationCoordinate2D) -> Void) {
        guard task == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    let denied = update.authorizationDenied || update.authorizationDeniedGlobally
                    if self.denied != denied { self.denied = denied }
                    guard let location = update.location else { continue }
                    if let old = self.coordinate,
                       CLLocation(latitude: old.latitude, longitude: old.longitude).distance(from: location) < 1000 {
                        continue
                    }
                    self.coordinate = location.coordinate
                    SharedStore.lastLocation = (location.coordinate.latitude, location.coordinate.longitude)
                    onChange(location.coordinate)
                }
            } catch {
                // Abgebrochen (App im Hintergrund): beim nächsten Start weiter.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session = nil
    }
}
