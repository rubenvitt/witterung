import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

@main
struct WitterungWidgetBundle: WidgetBundle {
    var body: some Widget {
        WeatherWidget()
    }
}

struct WeatherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "weather", intent: SelectPlaceIntent.self, provider: Provider()) { entry in
            WeatherWidgetView(snapshot: entry.snapshot, family: entry.family)
                .environment(\.locale, Fmt.locale)
                .environment(\.timeZone, Fmt.timeZone)
                .containerBackground(for: .widget) {
                    Theme.gradient(entry.snapshot?.condition ?? .cloudy, isDay: entry.snapshot?.isDay ?? true)
                }
                .widgetURL(URL(string: "witterung://place/\(entry.placeID)"))
        }
        .configurationDisplayName("Wetter")
        .description("Temperatur, Wetterlage und Regenhinweis für einen Ort.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
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
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil, family: context.family, placeID: "current")
    }

    func snapshot(for configuration: SelectPlaceIntent, in context: Context) async -> Entry {
        let place = configuration.place ?? .current
        // Galerie: schnell aus dem Cache, nur ohne Cache übers Netz.
        var forecast = ForecastCache.load(place.ref)
        if forecast == nil { forecast = try? await fetch(place.ref) }
        return Entry(date: .now, snapshot: forecast.flatMap { WeatherSnapshot.make($0, at: .now, placeName: name(place, $0)) },
                     family: context.family, placeID: place.id)
    }

    func timeline(for configuration: SelectPlaceIntent, in context: Context) async -> Timeline<Entry> {
        let place = configuration.place ?? .current
        let now = Date.now
        // Erst frisch laden; ohne Netz trägt der Cache (stündliche Einträge bleiben richtig).
        var forecast = try? await fetch(place.ref)
        if forecast == nil { forecast = ForecastCache.load(place.ref) }
        var entries = forecast.map { f in
            WeatherSnapshot.timeline(f, now: now, placeName: name(place, f)).map {
                Entry(date: $0.date, snapshot: $0, family: context.family, placeID: place.id)
            }
        } ?? []
        if entries.isEmpty { entries = [Entry(date: now, snapshot: nil, family: context.family, placeID: place.id)] }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
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
