import Foundation
import Testing

/// Live-Aktivität: dieselben Regeln wie `live::desired` auf dem Server (server/src/live.rs).
struct LiveActivityTests {
    typealias State = WeatherActivityAttributes.ContentState
    static let start = NowcastTests.start

    static func alert(_ id: String, _ severity: WeatherAlert.Severity, inMinutes: Double, hours: Double = 3) -> WeatherAlert {
        let onset = start.addingTimeInterval(inMinutes * 60)
        return WeatherAlert(id: id, severity: severity, event: "ORKANARTIGE BÖEN", headline: "", description: "", instruction: nil,
                            onset: onset, expires: onset.addingTimeInterval(hours * 3600), source: "dwd")
    }

    @Test func rainSoonThenRainingThenNothing() throws {
        let nowcast = NowcastTests.nowcast([0, 0, 0, 0.3, 1.2, 5, 0, 0])
        let soon = try #require(State.desired(alerts: [], nowcast: nowcast, now: Self.start.addingTimeInterval(120)))
        #expect(soon.kind == .rainSoon)
        #expect(soon.start == Self.start.addingTimeInterval(15 * 60))
        #expect(soon.end == Self.start.addingTimeInterval(30 * 60))
        #expect(soon.peakMmH == 5)
        #expect(soon.countdownTarget == soon.start)
        #expect(soon.countdownLabel == "Regen in")
        #expect(soon.title == "Regen ab 13:15")
        #expect(soon.detail() == "ab 13:15 bis 13:30, stark")
        // Ab dem laufenden Schritt (12:00), eine Stunde lang, so viele wie das Radar hat.
        #expect(soon.bars == [0, 0, 0, 0.3, 1.2, 5, 0, 0])
        #expect(soon.barsStart == Self.start.timeIntervalSince1970)

        let raining = try #require(State.desired(alerts: [], nowcast: nowcast, now: Self.start.addingTimeInterval(22 * 60)))
        #expect(raining.kind == .raining)
        #expect(raining.start == soon.start)
        #expect(raining.countdownTarget == raining.end)
        #expect(raining.countdownLabel == "Trocken in")
        #expect(raining.title == "Trocken ab 13:30")
        #expect(raining.detail() == "trocken ab 13:30, jetzt stark")

        #expect(State.desired(alerts: [], nowcast: nowcast, now: Self.start.addingTimeInterval(31 * 60)) == nil)
    }

    @Test func rainBeyondAnHourIsNotShown() {
        let nowcast = NowcastTests.nowcast(Array(repeating: 0, count: 13) + [2])
        #expect(State.desired(alerts: [], nowcast: nowcast, now: Self.start) == nil)
        #expect(State.desired(alerts: [], nowcast: nil, now: Self.start) == nil)
    }

    @Test func severeWarningBeatsRainModerateDoesNot() throws {
        let rain = NowcastTests.nowcast([1, 1, 0])
        let moderate = Self.alert("m", .moderate, inMinutes: 0)
        #expect(State.desired(alerts: [moderate], nowcast: rain, now: Self.start)?.kind == .raining)

        let alerts = [moderate, Self.alert("s", .severe, inMinutes: 50), Self.alert("x", .extreme, inMinutes: 30, hours: 2)]
        let warning = try #require(State.desired(alerts: alerts, nowcast: rain, now: Self.start))
        #expect(warning.kind == .warning)
        #expect(warning.severity == "extreme")
        #expect(warning.countdownTarget == nil)
        #expect(warning.title == "Orkanartige Böen")
        #expect(warning.bars == nil)
        #expect(warning.detail(now: Self.start) == "Extreme Unwetterwarnung · ab 13:30 · bis 15:30")

        #expect(State.desired(alerts: [Self.alert("f", .severe, inMinutes: 90)], nowcast: nil, now: Self.start) == nil)
        #expect(State.desired(alerts: [Self.alert("o", .severe, inMinutes: -240)], nowcast: nil, now: Self.start) == nil)
    }

    /// Regen bis ans Ende des Radars: Ende aus den Stunden, nicht doppelt „hält an“.
    @Test func dryHourAfterTheRadar() throws {
        let forecast = InsightTests.forecast(temps: Array(repeating: 5, count: 8), precip: [2, 1, 0.6, 0.3, 0, 0, 0, 0],
                                             nowcast: NowcastTests.nowcast(Array(repeating: 1.5, count: 24)))
        let state = try #require(State.desired(alerts: [], nowcast: forecast.nowcast, hourly: forecast.hourly, now: Self.start))
        #expect(state.kind == .raining)
        #expect(state.countdownTarget == nil)
        #expect(state.bars?.count == State.barCount)
        #expect(state.title == "Regen bis ca. 17 Uhr")
        #expect(state.detail() == "jetzt mäßig, Ende laut Vorhersage")

        let endless = try #require(State.desired(alerts: [], nowcast: forecast.nowcast, now: Self.start))
        #expect(endless.title == "Regen hält an")
        #expect(endless.detail() == "jetzt mäßig, kein Ende in 12 h")
    }

    /// Der Server schickt Unix-Sekunden und camelCase-Schlüssel (`live::payload`).
    @Test func decodesServerContentState() throws {
        let json = #"{"kind":"rain_soon","startsAt":1794226680,"peakMmH":3.0,"updatedAt":1794225600}"#
        let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))
        #expect(state.kind == .rainSoon)
        #expect(state.end == nil)
        #expect(state.start == Self.start.addingTimeInterval(18 * 60))
        let attributes = try JSONDecoder().decode(WeatherActivityAttributes.self,
                                                  from: Data(#"{"placeId":3,"placeName":"Uelzen","current":false}"#.utf8))
        #expect(attributes.placeName == "Uelzen")
    }

    @Test func smallShiftsAreNoChange() throws {
        let nowcast = NowcastTests.nowcast([0, 0, 0, 1, 1, 0])
        let a = try #require(State.desired(alerts: [], nowcast: nowcast, now: Self.start))
        var b = a
        b.startsAt += 120
        #expect(!b.differs(from: a))
        b.startsAt += 300
        #expect(b.differs(from: a))
    }
}
