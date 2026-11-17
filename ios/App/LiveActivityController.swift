import ActivityKit
import Foundation
import os

/// Live-Aktivität für die erste Seite (Standort, sonst der erste Ort): Regen laut Radar oder
/// Unwetterwarnung (`WeatherActivityAttributes`).
///
/// Mit APNs auf dem Server (Antwort der Anmeldung) startet, aktualisiert und beendet der
/// Server sie, auch wenn die App nicht läuft. Die App meldet dafür ihr Push-to-Start-Token,
/// den Ort und für jede laufende Aktivität deren Update-Token. Ohne APNs macht sie es wie
/// bisher selbst, solange sie im Vordergrund lädt; der Countdown zählt danach von allein.
///
/// Bewusst nicht an den Haupt-Actor gebunden: `Activity` ist nicht `Sendable`. Aktivitäten
/// werden darum nur über ihre ID weitergereicht und dort, wo sie gebraucht werden, neu
/// nachgeschlagen; Lesen, Aktualisieren und Beenden laufen im selben Kontext.
enum LiveActivityController {
    typealias WeatherActivity = Activity<WeatherActivityAttributes>

    /// Token aus Debug-Builds gelten nur für die Sandbox von APNs (TestFlight: Produktion).
    #if DEBUG
    static let sandbox = true
    #else
    static let sandbox = false
    #endif

    private static let observing = OSAllocatedUnfairLock(initialState: false)
    private static let followed = OSAllocatedUnfairLock(initialState: Set<String>())

    // MARK: Gespeichert

    private enum Key {
        static let enabled = "liveActivities.enabled"
        static let serverPush = "liveActivities.serverPush"
        static let startToken = "liveActivities.startToken"
        static let placeId = "liveActivities.placeId"
        static let localKey = "liveActivities.localKey"
        static let localStartedAt = "liveActivities.localStartedAt"
    }

    private static var defaults: UserDefaults { .standard }

    /// Schalter in den Einstellungen (Standard: an).
    static var enabled: Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }

    /// Letzte Antwort des Servers: steuert er per APNs?
    private static var serverPush: Bool {
        get { defaults.bool(forKey: Key.serverPush) }
        set { defaults.set(newValue, forKey: Key.serverPush) }
    }

    private static var startToken: String? {
        get { defaults.string(forKey: Key.startToken) }
        set { defaults.set(newValue, forKey: Key.startToken) }
    }

    private static var placeId: Int? {
        get { defaults.object(forKey: Key.placeId) as? Int }
        set { defaults.set(newValue, forKey: Key.placeId) }
    }

    // MARK: Beobachten

    /// Beim Start der App, auch wenn das System sie nach einem Push-Start im Hintergrund
    /// weckt: Push-to-Start-Token und laufende Aktivitäten beobachten und dem Server melden.
    static func observe() {
        let first = observing.withLock { started in
            defer { started = true }
            return !started
        }
        guard first else { return }
        Task.detached { await observeStartTokens() }
        Task.detached { await observeActivities() }
    }

    private static func observeStartTokens() async {
        for await data in WeatherActivity.pushToStartTokenUpdates {
            startToken = data.hex
            if enabled { await register() }
        }
    }

    private static func observeActivities() async {
        for activity in WeatherActivity.activities { follow(activity.id) }
        for await activity in WeatherActivity.activityUpdates { follow(activity.id) }
    }

    private static func follow(_ id: String) {
        guard followed.withLock({ $0.insert(id).inserted }) else { return }
        Task.detached { await reportTokens(id) }
        Task.detached { await watchState(id) }
    }

    private static func activity(_ id: String) -> WeatherActivity? {
        WeatherActivity.activities.first { $0.id == id }
    }

    /// Update-Token an den Server; nur Aktivitäten mit `pushType: .token` liefern welche.
    private static func reportTokens(_ id: String) async {
        guard let activity = activity(id) else { return }
        let place = activity.attributes.placeId
        for await data in activity.pushTokenUpdates {
            try? await API().reportLiveActivity(id: id, token: data.hex, placeId: place, sandbox: sandbox)
        }
    }

    /// Weggewischt oder beendet: Der Server soll sie vergessen.
    private static func watchState(_ id: String) async {
        guard let activity = activity(id) else { return }
        for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
            _ = followed.withLock { $0.remove(id) }
            try? await API().endLiveActivity(id: id)
            return
        }
    }

    // MARK: Anmelden

    /// Meldet Start-Token und Ort; `nil`, wenn der Server nicht erreichbar war.
    @discardableResult
    private static func register() async -> Bool? {
        let push = try? await API().registerLiveActivities(startToken: startToken, placeId: placeId, sandbox: sandbox)
        if let push { serverPush = push }
        return push
    }

    /// Schalter in den Einstellungen.
    static func setEnabled(_ on: Bool) async {
        defaults.set(on, forKey: Key.enabled)
        if on {
            await register()
        } else {
            try? await API().unregisterLiveActivities()
            for activity in WeatherActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: Nach dem Laden

    /// Nach dem Laden der ersten Seite: Ort beim Server anmelden. Steuert der Server per
    /// APNs, räumt die App nur Doppelte weg; sonst startet und aktualisiert sie selbst.
    static func sync(forecast: Forecast, placeName: String, now: Date = .now) async {
        guard enabled else { return }
        if let id = forecast.location.id { placeId = id }
        await register()
        if serverPush {
            await removeDuplicates()
        } else {
            await updateLocally(forecast: forecast, placeName: placeName, now: now)
        }
    }

    /// Start per Push und lokaler Start können sich überschneiden: die neueste bleibt.
    private static func removeDuplicates() async {
        let running = WeatherActivity.activities
        guard running.count > 1 else { return }
        for activity in running.dropLast() { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ohne APNs: wie der Server, nur im Vordergrund.
    private static func updateLocally(forecast: Forecast, placeName: String, now: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = WeatherActivity.activities
        guard let state = WeatherActivityAttributes.ContentState.desired(alerts: forecast.alerts, nowcast: forecast.nowcast, now: now)
        else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let place = forecast.location.id ?? -1
        let content = ActivityContent(state: state, staleDate: state.staleDate(now: now), relevanceScore: state.relevance)
        if let current = running.last(where: { $0.attributes.placeId == place }) {
            await current.update(content)
            for other in running where other.id != current.id { await other.end(nil, dismissalPolicy: .immediate) }
            return
        }
        for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        // Je Ereignis nur ein Start: eine weggewischte Aktivität kommt für denselben Schauer
        // (2 Stunden) oder dieselbe Warnung nicht wieder.
        let key = state.kind == .warning ? "alert:\(state.event ?? "")@\(Int(state.startsAt))" : "rain:\(place)"
        let last = defaults.double(forKey: Key.localStartedAt)
        if defaults.string(forKey: Key.localKey) == key, key.hasPrefix("alert:") || now.timeIntervalSince1970 - last < 2 * 3600 {
            return
        }
        let attributes = WeatherActivityAttributes(placeId: place, placeName: placeName, current: forecast.location.kind == "current")
        guard (try? WeatherActivity.request(attributes: attributes, content: content, pushType: nil)) != nil else { return }
        defaults.set(key, forKey: Key.localKey)
        defaults.set(now.timeIntervalSince1970, forKey: Key.localStartedAt)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
