import Foundation
import Testing

struct DecodingTests {
    static func fixture() throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "forecast", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func decodesFullForecast() throws {
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: Self.fixture())
        #expect(forecast.location.name == "Uelzen")
        #expect(forecast.location.id == 1)
        #expect(forecast.hourly.count == 48)
        #expect(forecast.daily.count == 10)
        #expect(forecast.sources.count == 7)
        // Quellen-IDs bleiben wörtlich erhalten (keine Snake-Case-Umschreibung).
        let first = try #require(forecast.hourly.first)
        #expect(first.bySource["open_meteo:icon_d2"] != nil)
        #expect(first.bySource["bright_sky:mosmix"] != nil)
        #expect(first.bySource.count == first.nSources)
        #expect(forecast.daily[0].bySource["open_meteo:ecmwf_ifs"] != nil)
        // Ausgefallene Quelle
        let pirate = try #require(forecast.sources.first { $0.source == "pirate_weather" })
        #expect(!pirate.ok && pirate.stale && pirate.error == "quota")
        #expect(forecast.sources.first?.error == nil)
        // Beobachtung, Nowcast, Warnungen
        let observed = try #require(forecast.now.observed)
        #expect(observed.station == "Uelzen" && observed.tempC == 7.5 && observed.distanceM == 3383)
        #expect(forecast.nowcast?.points.count == 25)
        #expect(forecast.alerts.map(\.severity) == [.moderate, .minor])
        #expect(forecast.alerts[1].instruction == nil && forecast.alerts[1].expires == nil)
        // Optionale Felder dürfen null sein
        #expect(first.bySource["bright_sky:mosmix"]?.isDay == nil)
        #expect(forecast.daily[0].bySource["weatherkit"]?.windMaxKmh == nil)
        #expect(forecast.generatedAt == Date(timeIntervalSince1970: 1_794_225_603))
        #expect(forecast.hasWeatherKit)
    }

    @Test func decodesCurrentLocationAndFractionalSeconds() throws {
        var text = String(decoding: try Self.fixture(), as: UTF8.self)
        text = text.replacingOccurrences(of: #""id": 1,"#, with: #""id": null,"#)
            .replacingOccurrences(of: #""kind": "saved""#, with: #""kind": "current""#)
            .replacingOccurrences(of: "2026-11-09T12:00:03Z", with: "2026-11-09T12:00:03.250Z")
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: Data(text.utf8))
        #expect(forecast.location.id == nil)
        #expect(forecast.location.kind == "current")
        #expect(abs(forecast.generatedAt.timeIntervalSince1970 - 1_794_225_603.25) < 0.001)
    }

    @Test func unknownConditionDoesNotFail() throws {
        let json = #"{"at":"2026-11-09T12:00:00Z","temp_c":1,"precip_mm":0,"wind_kmh":3,"condition":"volcanic_ash"}"#
        let point = try JSONDecoder.api.decode(HourPoint.self, from: Data(json.utf8))
        #expect(point.condition == .unknown)
    }
}

final class BundleToken {}
