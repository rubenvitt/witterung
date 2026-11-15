import CoreLocation
import Foundation
import Observation
import WidgetKit

/// Zustand der Watch-App: wie `AppModel` auf dem iPhone, nur lesend. Orte und
/// Anmeldung kommen vom iPhone, die Vorhersagen lädt die Watch selbst.
@MainActor
@Observable
final class WatchModel {
    private(set) var places: [Place] = SharedStore.places
    private(set) var forecasts: [PlaceRef: Forecast] = [:]
    private(set) var failures: [PlaceRef: String] = [:]
    private(set) var loading: Set<PlaceRef> = []
    private(set) var signedIn = WatchModel.hasAccess
    private(set) var serverURL = SharedStore.serverURL
    /// Ziel aus einem Komplikations-Tipp (`witterung://place/<id|current>`).
    var opened: PlaceRef?

    let location = LocationProvider()

    static var hasAccess: Bool { !API.needsAuth(SharedStore.serverURL) || TokenStore.token != nil }

    init() {
        loadCache()
        WatchSync.shared.onChange = { [weak self] in self?.linkChanged() }
    }

    var api: API { API(baseURL: serverURL) }

    var pages: [PlaceRef] {
        (location.denied ? [] : [.current]) + places.map { .saved($0.id) }
    }

    func place(_ ref: PlaceRef) -> Place? {
        guard case let .saved(id) = ref else { return nil }
        return places.first { $0.id == id }
    }

    func title(_ ref: PlaceRef) -> String {
        if let place = place(ref) { return place.name }
        let name = forecasts[ref]?.location.name ?? ""
        return name.isEmpty ? "Mein Standort" : name
    }

    // MARK: Laden

    func start() async {
        WatchSync.shared.request()
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

    /// Die Orte kommen zwar vom iPhone, der Server weiß es aber genauer
    /// (z. B. ein Ort, der in der Web-App angelegt wurde).
    private func loadPlaces() async {
        let server = serverURL
        do {
            let fresh = try await api.places()
            guard server == serverURL else { return }
            places = fresh
            SharedStore.places = fresh
        } catch {
            handle(error)
        }
    }

    func refresh(_ ref: PlaceRef) async {
        guard signedIn, !loading.contains(ref) else { return }
        var lat: Double?, lon: Double?
        if ref == .current {
            guard let c = location.coordinate else { return }
            (lat, lon) = (c.latitude, c.longitude)
        }
        let server = serverURL
        loading.insert(ref)
        defer { loading.remove(ref) }
        do {
            let (forecast, data) = try await api.forecast(ref, lat: lat, lon: lon)
            guard server == serverURL else { return }
            forecasts[ref] = forecast
            failures[ref] = nil
            ForecastCache.store(data, for: ref)
        } catch {
            guard server == serverURL else { return }
            failures[ref] = error.localizedDescription
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if let error = error as? APIError, error == .unauthorized || error == .notSignedIn {
            signedIn = false
        }
    }

    private func loadCache() {
        forecasts = [:]
        for ref in [PlaceRef.current] + places.map({ .saved($0.id) }) {
            if let cached = ForecastCache.load(ref) { forecasts[ref] = cached }
        }
    }

    /// Das iPhone hat Server, Anmeldung oder Orte geändert.
    private func linkChanged() {
        let serverChanged = serverURL != SharedStore.serverURL
        serverURL = SharedStore.serverURL
        places = SharedStore.places
        signedIn = Self.hasAccess
        if serverChanged { failures = [:] }
        loadCache()
        Task { await start() }
    }
}
