import Foundation
import Testing

struct PKCETests {
    @Test func rfc7636AppendixB() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuxlBB2-jkM")
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
        #expect(NowcastSummary(Self.nowcast([0, 0.05, 0.09]), now: Self.start) == .dry)
    }

    @Test func rainingNow() {
        #expect(NowcastSummary(Self.nowcast([0.3, 0.3, 0.2, 0, 0]), now: Self.start).sentence == "Leichter Regen endet in 15 Minuten")
        #expect(NowcastSummary(Self.nowcast([5, 6, 8]), now: Self.start).sentence == "Starker Regen hält mindestens 2 Stunden an")
    }

    @Test func noNowcastOrOutdated() {
        #expect(NowcastSummary(nil, now: Self.start).sentence == nil)
        #expect(NowcastSummary(Self.nowcast([1, 1]), now: Self.start.addingTimeInterval(3600)) == .none)
    }

    @Test func widgetRainHint() throws {
        let forecast = try JSONDecoder.api.decode(Forecast.self, from: DecodingTests.fixture())
        #expect(forecast.rainHint(at: Self.start) == "Regen ab 13:25")
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
        #expect(entries[0].hours.count == 6)
    }
}

struct WMSTileTests {
    @Test func bboxMath() {
        let e = WMSTile.earthHalf
        let z0 = WMSTile.bbox(x: 0, y: 0, z: 0)
        #expect(z0.minX == -e && z0.minY == -e && z0.maxX == e && z0.maxY == e)
        let z1 = WMSTile.bbox(x: 1, y: 0, z: 1)
        #expect(z1.minX == 0 && z1.minY == 0 && z1.maxX == e && z1.maxY == e)
        // Uelzen bei z8: Kachel 135/83
        let t = WMSTile.bbox(x: 135, y: 83, z: 8)
        #expect(abs(t.maxX - t.minX - 2 * e / 256) < 0.001)
        #expect(t.minX < 1_175_490 && 1_175_490 < t.maxX) // 10,5594° O
        #expect(t.minY < 6_976_637 && 6_976_637 < t.maxY) // 52,9656° N
    }

    @Test func getMapURL() throws {
        let url = WMSTile.url(base: URL(string: "https://maps.dwd.de/geoserver/dwd/wms")!, layer: "dwd:Radar_rv_product_1x1km_ger",
                              time: NowcastTests.start, x: 1, y: 0, z: 1, pixels: 512)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(q["BBOX"] == "0.00,0.00,20037508.34,20037508.34")
        #expect(q["CRS"] == "EPSG:3857" && q["VERSION"] == "1.3.0" && q["WIDTH"] == "512")
        #expect(q["TIME"] == "2026-11-09T12:00:00Z")
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
