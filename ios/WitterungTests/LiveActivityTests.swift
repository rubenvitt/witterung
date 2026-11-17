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
        #expect(soon.headline(place: "Uelzen") == "Starker Regen in Uelzen")
        #expect(soon.detail() == "ab 13:15 bis 13:30 · Radar: DWD")

        let raining = try #require(State.desired(alerts: [], nowcast: nowcast, now: Self.start.addingTimeInterval(22 * 60)))
        #expect(raining.kind == .raining)
        #expect(raining.start == soon.start)
        #expect(raining.countdownTarget == raining.end)

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
        #expect(warning.headline(place: "Uelzen") == "Orkanartige Böen in Uelzen")
        #expect(warning.detail(now: Self.start) == "Extreme Unwetterwarnung · ab 13:30 · bis 15:30")

        #expect(State.desired(alerts: [Self.alert("f", .severe, inMinutes: 90)], nowcast: nil, now: Self.start) == nil)
        #expect(State.desired(alerts: [Self.alert("o", .severe, inMinutes: -240)], nowcast: nil, now: Self.start) == nil)
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
