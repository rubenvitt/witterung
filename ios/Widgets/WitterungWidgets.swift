import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

@main
struct WitterungWidgetBundle: WidgetBundle {
    var body: some Widget {
        WeatherWidget()
        FocusWidget()
        HourlyWidget()
        DailyWidget()
    }
}

struct WeatherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStyle.weather.kind, intent: SelectPlaceIntent.self, provider: Provider(style: .weather)) {
            WidgetEntryView(style: .weather, entry: $0)
        }
        .configurationDisplayName(WidgetStyle.weather.displayName)
        .description(WidgetStyle.weather.summary)
        .supportedFamilies(WidgetStyle.weather.families)
    }
}

/// „Im Blick“: entscheidet selbst, was gerade zählt (`Insight.rank`), und sagt, warum.
struct FocusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStyle.focus.kind, intent: SelectPlaceIntent.self, provider: Provider(style: .focus)) {
            WidgetEntryView(style: .focus, entry: $0)
        }
        .configurationDisplayName(WidgetStyle.focus.displayName)
        .description(WidgetStyle.focus.summary)
        .supportedFamilies(WidgetStyle.focus.families)
    }
}

struct HourlyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStyle.hourly.kind, intent: SelectPlaceIntent.self, provider: Provider(style: .hourly)) {
            WidgetEntryView(style: .hourly, entry: $0)
        }
        .configurationDisplayName(WidgetStyle.hourly.displayName)
        .description(WidgetStyle.hourly.summary)
        .supportedFamilies(WidgetStyle.hourly.families)
    }
}

struct DailyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStyle.daily.kind, intent: SelectPlaceIntent.self, provider: Provider(style: .daily)) {
            WidgetEntryView(style: .daily, entry: $0)
        }
        .configurationDisplayName(WidgetStyle.daily.displayName)
        .description(WidgetStyle.daily.summary)
        .supportedFamilies(WidgetStyle.daily.families)
    }
}

/// Gemeinsamer Rahmen aller Widgets: Ansicht der Art, Hintergrund nach Wetterlage, Tipp öffnet den Ort.
struct WidgetEntryView: View {
    let style: WidgetStyle
    let entry: Entry

    var body: some View {
        StyledWidgetView(style: style, snapshot: entry.snapshot, family: entry.family)
            .environment(\.locale, Fmt.locale)
            .environment(\.timeZone, Fmt.timeZone)
            .containerBackground(for: .widget) {
                Theme.gradient(entry.snapshot?.condition ?? .cloudy, isDay: entry.snapshot?.isDay ?? true)
            }
            .widgetURL(URL(string: "witterung://place/\(entry.placeID)"))
    }
}

// MARK: Konfiguration

struct PlaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ort"
    static let defaultQuery = PlaceQuery()
    static let current = PlaceEntity(id: "current", name: "Mein Standort")

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    var ref: PlaceRef { id == "current" ? .current : .saved(Int(id) ?? -1) }
}

struct PlaceQuery: EntityQuery {
    /// Aus dem Spiegel der App; das Widget braucht dafür kein Netz.
    static func all() -> [PlaceEntity] {
        [.current] + SharedStore.places.map { PlaceEntity(id: String($0.id), name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [PlaceEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PlaceEntity] { Self.all() }

    func defaultResult() async -> PlaceEntity? {
        SharedStore.lastLocation != nil ? .current : Self.all().dropFirst().first ?? .current
    }
}

struct SelectPlaceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Ort wählen"
    static let description = IntentDescription("Gespeicherter Ort oder aktueller Standort.")

    @Parameter(title: "Ort")
    var place: PlaceEntity?
}

// MARK: Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WeatherSnapshot?
    let family: WidgetFamily
    let placeID: String
    /// Nur „Im Blick“: Gewicht des wichtigsten Hinweises, damit der Smart Stack es nach oben holt.
    var relevanceScore: Double?

    var relevance: TimelineEntryRelevance? {
        relevanceScore.map { TimelineEntryRelevance(score: Float($0)) }
    }
}

struct Provider: AppIntentTimelineProvider {
    let style: WidgetStyle

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil, family: context.family, placeID: "current")
    }

    private func entry(_ snapshot: WeatherSnapshot?, at date: Date, place: PlaceEntity, context: Context) -> Entry {
        Entry(date: date, snapshot: snapshot, family: context.family, placeID: place.id,
              relevanceScore: style == .focus ? snapshot?.focus.score : nil)
    }

    #if os(watchOS)
    /// Auf der Watch gibt es keinen Konfigurationsdialog: Jeder Ort wird als eigene
    /// Komplikation angeboten (Orte kommen vom iPhone).
    func recommendations() -> [AppIntentRecommendation<SelectPlaceIntent>] {
        PlaceQuery.all().map { place in
            let intent = SelectPlaceIntent()
            intent.place = place
            let name = style == .weather ? place.name : "\(style.displayName) · \(place.name)"
            return AppIntentRecommendation(intent: intent, description: Text(name))
        }
    }
    #endif

    func snapshot(for configuration: SelectPlaceIntent, in context: Context) async -> Entry {
        let place = configuration.place ?? .current
        // Galerie: schnell aus dem Cache, nur ohne Cache übers Netz.
        var forecast = ForecastCache.load(place.ref)
        if forecast == nil { forecast = try? await fetch(place.ref) }
        let decision = style == .focus ? DecisionCache.load(place.ref) : nil
        return entry(forecast.flatMap { WeatherSnapshot.make($0, at: .now, placeName: name(place, $0), decision: decision) },
                     at: .now, place: place, context: context)
    }

    func timeline(for configuration: SelectPlaceIntent, in context: Context) async -> Timeline<Entry> {
        let place = configuration.place ?? .current
        let now = Date.now
        // Erst frisch laden; ohne Netz trägt der Cache (stündliche Einträge bleiben richtig).
        var forecast = try? await fetch(place.ref)
        if forecast == nil { forecast = ForecastCache.load(place.ref) }
        // „Im Blick“: Jev ordnet die Hinweise; ohne Antwort entscheiden die Regeln.
        var decision: JevDecision?
        if style == .focus, let forecast {
            decision = await JevClient.decide(forecast, ref: place.ref, placeName: name(place, forecast), at: now)
        }
        var entries = forecast.map { f in
            WeatherSnapshot.timeline(f, now: now, dense: style.isDense, placeName: name(place, f), decision: decision).map {
                entry($0, at: $0.date, place: place, context: context)
            }
        } ?? []
        if entries.isEmpty { entries = [entry(nil, at: now, place: place, context: context)] }
        // Steht Warnung oder Regen laut Radar vorn, lohnt ein früherer neuer Abruf.
        let urgent = style == .focus && entries.first?.snapshot?.focus.isUrgent == true
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval((urgent ? 15 : 30) * 60)))
    }

    private func name(_ place: PlaceEntity, _ forecast: Forecast) -> String {
        if place.ref != .current { return place.name }
        return forecast.location.name.isEmpty ? "Mein Standort" : forecast.location.name
    }

    private func fetch(_ ref: PlaceRef) async throws -> Forecast {
        var lat: Double?, lon: Double?
        if ref == .current {
            // Eigener Standort, falls das Widget darf; sonst der letzte aus der App.
            if let c = CLLocationManager().location?.coordinate {
                (lat, lon) = (c.latitude, c.longitude)
            } else if let last = SharedStore.lastLocation {
                (lat, lon) = (last.lat, last.lon)
            } else {
                throw URLError(.cannotFindHost)
            }
        }
        let (forecast, data) = try await API().forecast(ref, lat: lat, lon: lon)
        ForecastCache.store(data, for: ref)
        return forecast
    }
}
