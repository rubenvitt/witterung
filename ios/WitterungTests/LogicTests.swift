import Foundation
import Testing

struct PKCETests {
    @Test func rfc7636AppendixB() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierFormat() {
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) })
        #expect(verifier != PKCE.makeVerifier())
    }
}

struct NowcastTests {
    static let start = Date(timeIntervalSince1970: 1_794_225_600) // 2026-11-09T12:00:00Z

    static func nowcast(_ values: [Double]) -> Nowcast {
        Nowcast(source: "bright_sky:radar", at: start,
                points: values.enumerated().map { NowcastPoint(at: start.addingTimeInterval(Double($0.offset) * 300), precipMmH: $0.element) })
    }

    @Test func rainStartsIn25Minutes() throws {
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: DecodingTests.fixture())
        let summary = NowcastSummary(forecast.nowcast, now: Self.start)
        #expect(summary == .startsIn(minutes: 25, peak: 3.1))
        #expect(summary.sentence == "Regen in 25 Minuten")
    }

    @Test func minutesCountFromNowNotFromNowcastTime() {
        // 7 min nach Nowcast-Beginn: Regen ab 12:25 ist 18 min entfernt → auf 5 gerundet 20.
        let summary = NowcastSummary(Self.nowcast([0, 0, 0, 0, 0, 1, 1]), now: Self.start.addingTimeInterval(7 * 60))
        #expect(summary.sentence == "Regen in 20 Minuten")
    }

    @Test func dry() {
        #expect(NowcastSummary(Self.nowcast(Array(repeating: 0, count: 25)), now: Self.start).sentence == "Kein Regen in den nächsten 2 Stunden")
        #expect(NowcastSummary(Self.nowcast([0, 0.05, 0.09]), now: Self.start) == .dry(horizon: 15))
        // Nur noch 15 min Radar übrig: nicht „2 Stunden“ versprechen.
        #expect(NowcastSummary(Self.nowcast([0, 0.05, 0.09]), now: Self.start).sentence == "Kein Regen in den nächsten 15 Minuten")
    }

    @Test func rainingNow() {
        #expect(NowcastSummary(Self.nowcast([0.3, 0.3, 0.2, 0, 0]), now: Self.start).sentence == "Leichter Regen endet in 15 Minuten")
        #expect(NowcastSummary(Self.nowcast(Array(repeating: 5, count: 25)), now: Self.start).sentence == "Starker Regen hält mindestens 2 Stunden an")
        #expect(NowcastSummary(Self.nowcast([5, 6, 8]), now: Self.start).sentence == "Starker Regen hält mindestens 15 Minuten an")
        #expect(NowcastSummary(Self.nowcast(Array(repeating: 0, count: 21)), now: Self.start).sentence == "Kein Regen in den nächsten 1½ Stunden")
        #expect(NowcastSummary(Self.nowcast(Array(repeating: 0, count: 13)), now: Self.start).sentence == "Kein Regen in der nächsten Stunde")
    }

    @Test func noNowcastOrOutdated() {
        #expect(NowcastSummary(nil, now: Self.start).sentence == nil)
        #expect(NowcastSummary(Self.nowcast([1, 1]), now: Self.start.addingTimeInterval(3600)) == .none)
    }

    @Test func widgetRainHint() throws {
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: DecodingTests.fixture())
        #expect(forecast.rainHint(at: Self.start) == "Regen ab 13:25")
        // 3 min später: weiter die Uhrzeit des Radarschritts, nicht 13:28
        #expect(forecast.rainHint(at: Self.start.addingTimeInterval(180)) == "Regen ab 13:25")
        // Nach dem Radar-Horizont: Stundenwerte (Fixture: trocken ab 16 Uhr UTC bis zum nächsten Mittag).
        #expect(forecast.rainHint(at: Self.start.addingTimeInterval(5 * 3600)) == "Kein Regen in Sicht")
        #expect(forecast.rainHint(at: Self.start.addingTimeInterval(20 * 3600)) == "Regen ab 15 Uhr")
    }

    @Test func widgetTimelineIsHourly() throws {
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: DecodingTests.fixture())
        let now = Self.start.addingTimeInterval(10 * 60)
        let entries = WeatherSnapshot.timeline(forecast, now: now)
        #expect(entries.count == 8)
        #expect(entries[0].date == now)
        #expect(entries[1].date == Self.start.addingTimeInterval(3600))
        #expect(entries[0].temp == 7.5) // Beobachtung, 20 min alt
        #expect(entries[3].temp == forecast.hourly[3].consensus.tempC)
        #expect(entries[0].min == forecast.daily[0].consensus.tempMinC)
        #expect(entries[0].hours.count == 24)
        #expect(entries[0].days.count == 10)
        // Nach dem letzten Stundenwert gibt es keine Einträge mit alten Werten.
        #expect(WeatherSnapshot.timeline(forecast, now: Self.start.addingTimeInterval(49 * 3600)).isEmpty)
    }
}

struct RadarGeometryTests {
    /// Ausschnitt des Servers: 2–18° O, 46–56° N.
    static let bbox = [222_638.98, 5_780_349.22, 2_003_750.83, 7_558_415.66]

    @Test func mercatorCorners() throws {
        let c = try #require(RadarGeometry.corners(Self.bbox))
        #expect(abs(c.northWest.lat - 56) < 1e-6 && abs(c.northWest.lon - 2) < 1e-6)
        #expect(abs(c.southEast.lat - 46) < 1e-6 && abs(c.southEast.lon - 18) < 1e-6)
        #expect(RadarGeometry.corners([1, 2, 3]) == nil)
        #expect(RadarGeometry.corners([5, 0, 1, 1]) == nil)
    }

    @Test func loadOrderStartsAtTheShownFrame() {
        #expect(RadarGeometry.loadOrder(count: 5, from: 2) == [2, 3, 1, 4, 0])
        #expect(RadarGeometry.loadOrder(count: 4, from: 3) == [3, 2, 1, 0])
        #expect(RadarGeometry.loadOrder(count: 3, from: 9) == [2, 1, 0])
        #expect(RadarGeometry.loadOrder(count: 0, from: 0).isEmpty)
        #expect(Set(RadarGeometry.loadOrder(count: 49, from: 24)).count == 49)
    }

    @Test func playbackSkipsMissingFrames() {
        let loaded: Set<Int> = [0, 3]
        #expect(RadarGeometry.nextLoaded(after: 0, count: 5) { loaded.contains($0) } == 3)
        #expect(RadarGeometry.nextLoaded(after: 3, count: 5) { loaded.contains($0) } == 0)
        #expect(RadarGeometry.nextLoaded(after: 1, count: 5) { _ in false } == nil)
    }

    @Test func framePath() throws {
        let json = #"{"bbox":[0,0,1,1],"width":1024,"height":1022,"frame":"/api/v1/radar/frames/{unix}","warnings":"/api/v1/radar/warnings"}"#
        let image = try JSONDecoder.api.decode(RadarImage.self, from: Data(json.utf8))
        #expect(image.framePath(NowcastTests.start) == "/api/v1/radar/frames/\(Int(NowcastTests.start.timeIntervalSince1970))")
    }
}

struct FormattingTests {
    @Test func numbers() {
        #expect(Fmt.number(7.5) == "7,5")
        #expect(Fmt.number(1020.7, digits: 0) == "1.021")
        #expect(Fmt.mm(0.4) == "0,4 mm")
        #expect(Fmt.distance(meters: 3383) == "3,4 km")
        #expect(Fmt.temp(-0.4) == "0°")
        #expect(Fmt.temp(-2.6) == "-3°")
        #expect(Fmt.temp(7.5) == "8°")
        #expect(Fmt.percent(33.3) == "33 %")
    }

    @Test func timesInBerlin() {
        let date = NowcastTests.start.addingTimeInterval(20 * 60) // 12:20Z = 13:20 MEZ
        #expect(Fmt.time(date) == "13:20")
        #expect(Fmt.hour(date) == "13 Uhr")
        #expect(Fmt.time(NowcastTests.start.addingTimeInterval(-7 * 3600)) == "06:00")
        #expect(Fmt.dayString(Date(timeIntervalSince1970: 1_794_265_200)) == "2026-11-10") // 23:00Z = 00:00 MEZ
        #expect(Fmt.weekday("2026-11-10", now: NowcastTests.start) == "Di")
        #expect(Fmt.weekday("2026-11-09", now: NowcastTests.start) == "Heute")
        #expect(Fmt.longDay("2026-11-10") == "Dienstag, 10. November")
    }

    @Test func ages() {
        let now = NowcastTests.start
        #expect(Fmt.age(now.addingTimeInterval(-20), now: now) == "gerade eben")
        #expect(Fmt.age(now.addingTimeInterval(-12 * 60), now: now) == "vor 12 min")
        #expect(Fmt.age(now.addingTimeInterval(-3 * 3600), now: now) == "vor 3 h")
    }

    @Test func compass() {
        #expect(Fmt.compassPoint(0) == "N")
        #expect(Fmt.compassPoint(160) == "SSO")
        #expect(Fmt.compassPoint(210) == "SSW")
        #expect(Fmt.compassPoint(359) == "N")
        #expect(Fmt.compassPoint(90) == "O")
    }

    @Test func localhostSkipsAuth() {
        #expect(!API.needsAuth(URL(string: "http://localhost:8080")!))
        #expect(!API.needsAuth(URL(string: "http://127.0.0.1:8081")!))
        #expect(API.needsAuth(URL(string: "https://witterung.rubeen.dev")!))
    }
}
