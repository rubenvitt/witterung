import CoreLocation
import Foundation
import MapKit
import Observation
import WidgetKit

@MainActor
@Observable
final class AppModel {
    private(set) var places: [Place] = SharedStore.places
    private(set) var forecasts: [PlaceRef: Forecast] = [:]
    /// Letzter Abruf schlug fehl: Anzeige aus dem Cache, mit Hinweis.
    private(set) var failures: [PlaceRef: String] = [:]
    private(set) var loading: Set<PlaceRef> = []
    /// Zählt erfolgreiche manuelle Aktualisierungen (Haptik).
    private(set) var refreshTick = 0
    private(set) var serverURL = SharedStore.serverURL
    private(set) var signedIn = !API.needsAuth(SharedStore.serverURL) || TokenStore.token != nil
    var message: String?
    var selection: PlaceRef?

    let location = LocationProvider()

    init() {
        for ref in [PlaceRef.current] + places.map({ .saved($0.id) }) {
            if let cached = ForecastCache.load(ref) { forecasts[ref] = cached }
        }
        selection = pages.first
    }

    var api: API { API(baseURL: serverURL) }

    /// Seiten wie in Apple Wetter: zuerst der Standort (falls erlaubt), dann die Orte.
    var pages: [PlaceRef] {
        (location.denied ? [] : [.current]) + places.map { .saved($0.id) }
    }

    func place(_ ref: PlaceRef) -> Place? {
        guard case let .saved(id) = ref else { return nil }
        return places.first { $0.id == id }
    }

    func title(_ ref: PlaceRef) -> String {
        place(ref)?.name ?? "Mein Standort"
    }

    func coordinate(_ ref: PlaceRef) -> CLLocationCoordinate2D? {
        if let place = place(ref) { return CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon) }
        if let f = forecasts[ref] { return CLLocationCoordinate2D(latitude: f.location.lat, longitude: f.location.lon) }
        return location.coordinate
    }

    // MARK: Laden

    func start() async {
        guard signedIn else { return }
        location.start { [weak self] _ in
            Task { await self?.refresh(.current) }
        }
        await refreshAll()
    }

    func refreshAll() async {
        await loadPlaces()
        await withTaskGroup(of: Void.self) { group in
            for ref in pages { group.addTask { await self.refresh(ref) } }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func loadPlaces() async {
        let server = serverURL
        do {
            let fresh = try await api.places()
            guard server == serverURL else { return } // Server inzwischen gewechselt
            places = fresh
            SharedStore.places = fresh
            if selection == nil || !pages.contains(selection!) { selection = pages.first }
        } catch {
            handle(error)
        }
    }

    func refresh(_ ref: PlaceRef, manual: Bool = false) async {
        guard signedIn, !loading.contains(ref) else { return }
        var lat: Double?, lon: Double?
        if ref == .current {
            guard let c = location.coordinate else { return }
            (lat, lon) = (c.latitude, c.longitude)
        }
        let server = serverURL
        loading.insert(ref)
        do {
            let (forecast, data) = try await api.forecast(ref, lat: lat, lon: lon)
            loading.remove(ref)
            guard server == serverURL else { return } // Server inzwischen gewechselt
            forecasts[ref] = forecast
            failures[ref] = nil
            ForecastCache.store(data, for: ref)
            if manual {
                refreshTick += 1
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            loading.remove(ref)
            guard server == serverURL else { return }
            failures[ref] = error.localizedDescription
            handle(error)
        }
        // Standort hat sich während des Abrufs geändert: mit dem neuen nachladen.
        if ref == .current, let c = location.coordinate, c.latitude != lat || c.longitude != lon {
            await refresh(.current)
        }
    }

    func handle(_ error: Error) {
        if let error = error as? APIError, error == .unauthorized || error == .notSignedIn {
            signedIn = false
        }
    }

    // MARK: Anmeldung und Server

    func signIn(session: WebAuthenticationSessionProxy) async {
        do {
            try await session.run(serverURL)
            signedIn = true
            message = nil
            await start()
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() {
        TokenStore.delete()
        signedIn = !API.needsAuth(serverURL)
    }

    func setServer(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = (text.hasPrefix("localhost") || text.hasPrefix("127.") ? "http://" : "https://") + text }
        guard let url = URL(string: text), url.host() != nil, url != serverURL else { return }
        // Anderer Server, andere Orte: nichts vom alten stehen lassen.
        TokenStore.delete()
        for ref in forecasts.keys { ForecastCache.remove(ref) }
        forecasts = [:]
        failures = [:]
        places = []
        SharedStore.places = []
        SharedStore.serverURL = url
        serverURL = url
        signedIn = !API.needsAuth(url)
        selection = pages.first
        WidgetCenter.shared.reloadAllTimelines()
        Task { await start() }
    }

    // MARK: Orte

    func addPlace(name: String, coordinate: CLLocationCoordinate2D) async {
        do {
            let place = try await api.addPlace(name: name, lat: coordinate.latitude, lon: coordinate.longitude)
            places.append(place)
            placesChanged()
            selection = .saved(place.id)
            await refresh(.saved(place.id))
        } catch {
            message = error.localizedDescription
            handle(error)
        }
    }

    func rename(_ place: Place, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != place.name else { return }
        await update(place) { try await self.api.updatePlace(place.id, ["name": name]) }
    }

    func toggleNotify(_ place: Place) async {
        await update(place) { try await self.api.updatePlace(place.id, ["notify": !place.notify]) }
    }

    func delete(_ place: Place) async {
        let backup = places
        places.removeAll { $0.id == place.id }
        placesChanged()
        do {
            try await api.deletePlace(place.id)
            ForecastCache.remove(.saved(place.id))
            forecasts[.saved(place.id)] = nil
        } catch {
            places = backup
            placesChanged()
            message = error.localizedDescription
            handle(error)
        }
    }

    func move(from source: IndexSet, to destination: Int) async {
        let backup = places
        places.move(fromOffsets: source, toOffset: destination)
        placesChanged()
        // Vertrag: `position` 0-basiert, der Server rückt die übrigen nach.
        guard let moved = source.first.map({ backup[$0] }), let index = places.firstIndex(of: moved) else { return }
        do {
            _ = try await api.updatePlace(moved.id, ["position": index])
        } catch {
            places = backup
            placesChanged()
            message = error.localizedDescription
            handle(error)
        }
    }

    private func update(_ place: Place, _ call: () async throws -> Place) async {
        do {
            let updated = try await call()
            if let index = places.firstIndex(where: { $0.id == place.id }) { places[index] = updated }
            placesChanged()
        } catch {
            message = error.localizedDescription
            handle(error)
        }
    }

    private func placesChanged() {
        SharedStore.places = places
        if selection == nil || !pages.contains(selection!) { selection = pages.first }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Kapselt `WebAuthenticationSession` aus der Umgebung, damit das Modell sie nicht hält.
struct WebAuthenticationSessionProxy {
    let run: @MainActor (URL) async throws -> Void
}
