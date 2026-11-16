import Foundation
import Testing

/// Entscheidungslogik des Fokus-Widgets und der Kartenreihenfolge.
struct InsightTests {
    static let start = NowcastTests.start // 2026-11-09T12:00:00Z = 13 Uhr MEZ

    static func fixture() throws -> Forecast {
        try JSONDecoder.api.decode(Forecast.self, from: DecodingTests.fixture())
    }

    /// Erzeugt eine Vorhersage aus Stundenwerten (ab `start`), ohne Radar und Warnungen.
    static func forecast(
        temps: [Double], precip: [Double]? = nil, gusts: [Double]? = nil, conditions: [Condition]? = nil,
        tempSpread: Double = 1, agreement: Double? = nil, days: [(min: Double, max: Double)] = [(2, 8), (2, 8)],
        alerts: [WeatherAlert] = [], nowcast: Nowcast? = nil
    ) -> Forecast {
        let hourly = temps.indices.map { i in
            let at = start.addingTimeInterval(Double(i) * 3600)
            let mm = precip?[i] ?? 0
            let point = HourPoint(
                at: at, tempC: temps[i], feelsLikeC: nil, precipMm: mm, precipProbPct: mm >= 0.1 ? 80 : 5,
                windKmh: 10, gustKmh: gusts?[i], windDirDeg: 225, cloudPct: 50, humidityPct: 80, pressureHpa: 1015,
                condition: conditions?[i] ?? (mm >= 0.1 ? .rain : .cloudy), isDay: true)
            let spread = HourSpread(
                tempC: ValueRange(min: temps[i] - tempSpread / 2, max: temps[i] + tempSpread / 2),
                precipMm: ValueRange(min: 0, max: mm * 2), windKmh: nil,
                precipAgreementPct: agreement ?? (mm >= 0.1 ? 100 : 0))
            return HourRow(at: at, nSources: 6, consensus: point, spread: spread, bySource: [:])
        }
        let daily = days.indices.map { i in
            let date = Fmt.dayString(start.addingTimeInterval(Double(i) * 86_400))
            let point = DayPoint(date: date, tempMinC: days[i].min, tempMaxC: days[i].max, precipMm: 0, precipProbPct: nil,
                                 windMaxKmh: nil, gustMaxKmh: nil, condition: .cloudy, sunrise: nil, sunset: nil)
            return DayRow(date: date, nSources: 6, consensus: point,
                          spread: DaySpread(tempMinC: nil, tempMaxC: nil, precipMm: nil, precipAgreementPct: nil), bySource: [:])
        }
        return Forecast(
            location: ForecastLocation(id: 1, name: "Test", lat: 52.97, lon: 10.56, kind: "place"),
            generatedAt: start, sources: [], now: Now(observed: nil, forecast: hourly.first?.consensus),
            nowcast: nowcast, hourly: hourly, daily: daily, alerts: alerts, attribution: [])
    }

    static func alert(_ event: String, _ severity: WeatherAlert.Severity, onsetIn hours: Double = 0) -> WeatherAlert {
        WeatherAlert(id: event, severity: severity, event: event, headline: event, description: "", instruction: nil,
                     onset: start.addingTimeInterval(hours * 3600), expires: start.addingTimeInterval(12 * 3600), source: "dwd")
    }

    // MARK: Fixture

    @Test func fixtureRanksAlertThenRadarThenWalk() throws {
        let insights = Insight.rank(try Self.fixture(), at: Self.start)
        #expect(insights.map(\.kind) == [.alert, .rainSoon, .walk])
        let alert = insights[0]
        #expect(alert.title == "Sturmböen")
        #expect(alert.detail == "Ab 15:00 bis Di 04:00") // Nebel beginnt erst in 15 h: nicht mitgezählt
        #expect(alert.reason == "Markante Wetterwarnung des DWD")
        let rain = insights[1]
        #expect(rain.title == "Regen in 25 Minuten")
        #expect(rain.detail == "ab 13:25, bis etwa 15:00")
        #expect(rain.badge == "25′")
        // Trocken ab 17 Uhr MEZ (16:00Z), bis 22 Uhr.
        #expect(insights[2].title == "Gassi-Fenster 17–22 Uhr")
    }

    @Test func fixtureOrdersRadarFirst() throws {
        let insights = Insight.rank(try Self.fixture(), at: Self.start)
        // Warnungen bleiben oben, dann das Radar, weil Regen der wichtigste Hinweis nach der Warnung ist.
        #expect(PlaceSection.order(for: insights) == [.alerts, .nowcast, .focus, .hourly, .daily, .details, .sources])
    }

    @Test func snapshotCarriesFocusAndRadar() throws {
        let snapshot = try #require(WeatherSnapshot.make(try Self.fixture(), at: Self.start))
        #expect(snapshot.focus.kind == .alert)
        #expect(snapshot.radar.count == 25)
        #expect(snapshot.radar[5] == 0.3)
    }

    @Test func denseTimeline() {
        let now = Self.start.addingTimeInterval(7 * 60)
        let dates = WeatherSnapshot.dates(now: now, dense: true)
        #expect(dates[0] == now)
        #expect(dates[1] == Self.start.addingTimeInterval(15 * 60))
        // Viertelstunden bis zum Radar-Horizont (14:07Z), danach volle Stunden.
        #expect(dates.contains(Self.start.addingTimeInterval(2 * 3600)))
        #expect(!dates.contains(Self.start.addingTimeInterval(135 * 60)))
        #expect(dates[9] == Self.start.addingTimeInterval(3 * 3600))
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: Regeln

    @Test func calmWhenNothingStandsOut() {
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24)), at: Self.start)
        #expect(insights.map(\.kind) == [.calm])
        #expect(insights[0].title == "Ruhiges Wetter")
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .nowcast, .hourly, .daily, .details, .sources])
    }

    @Test func rainLaterFromHoursWithWalkWindowBefore() {
        var precip = Array(repeating: 0.0, count: 24)
        precip[4] = 1.2; precip[5] = 0.8 // 17 und 18 Uhr MEZ
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), precip: precip), at: Self.start)
        let rain = insights.first { $0.kind == .rainLater }
        #expect(rain?.title == "Regen ab 17 Uhr")
        #expect(rain?.detail == "bis etwa 19 Uhr · 2,0 mm")
        #expect(rain?.reason == "100 % der Quellen erwarten Regen")
        let walk = insights.first { $0.kind == .walk }
        #expect(walk?.title == "Gassi-Fenster bis 17 Uhr")
    }

    @Test func iceBeatsFrost() {
        var precip = Array(repeating: 0.0, count: 24)
        precip[10] = 0.5
        var temps = Array(repeating: 3.0, count: 24)
        temps[10] = 0.5; temps[14] = -3
        let insights = Insight.rank(Self.forecast(temps: temps, precip: precip, conditions: nil), at: Self.start)
        #expect(insights.first?.kind == .ice)
        #expect(insights.first?.detail == "Regen bei 1° gegen 23 Uhr")
        #expect(insights.contains { $0.kind == .frost } == false)
    }

    @Test func frostOnlyPossibleWhenSourcesDisagree() {
        var temps = Array(repeating: 4.0, count: 24)
        temps[15] = -2
        let sure = Insight.rank(Self.forecast(temps: temps, tempSpread: 1), at: Self.start).first { $0.kind == .frost }
        #expect(sure?.title == "Frost bis -2°")
        #expect(sure?.detail == "am kältesten gegen 4 Uhr")
        let unsure = Insight.rank(Self.forecast(temps: temps, tempSpread: 6), at: Self.start).first { $0.kind == .frost }
        #expect(unsure?.title == "Frost möglich")
        #expect(unsure?.reason == "Nicht alle Quellen erwarten Frost")
    }

    @Test func stormAndItsAlert() {
        var gusts = Array(repeating: 30.0, count: 24)
        gusts[3] = 78
        let storm = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), gusts: gusts), at: Self.start)
        #expect(storm.first?.kind == .storm)
        #expect(storm.first?.title == "Sturmböen bis 78 km/h")
        #expect(storm.first?.detail == "am stärksten gegen 16 Uhr aus SW")
        #expect(PlaceSection.order(for: storm) == [.alerts, .focus, .details, .nowcast, .hourly, .daily, .sources])
        // Mit amtlicher Warnung kein doppelter Hinweis.
        let warned = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), gusts: gusts,
                                                alerts: [Self.alert("STURMBÖEN", .moderate)]), at: Self.start)
        #expect(warned.map(\.kind) == [.alert])
    }

    @Test func alertSeverityAgainstRadar() {
        let nowcast = NowcastTests.nowcast([0, 1, 1, 1, 1, 1])
        let temps = Array(repeating: 8.0, count: 24)
        // Gelbe Warnung (Nebel) steht hinter Regen in 5 Minuten, eine rote davor.
        let minor = Insight.rank(Self.forecast(temps: temps, alerts: [Self.alert("NEBEL", .minor)], nowcast: nowcast), at: Self.start)
        #expect(minor.prefix(2).map(\.kind) == [.rainSoon, .alert])
        let severe = Insight.rank(Self.forecast(temps: temps, alerts: [Self.alert("ORKANBÖEN", .severe)], nowcast: nowcast), at: Self.start)
        #expect(severe.prefix(2).map(\.kind) == [.alert, .rainSoon])
    }

    @Test func expiredAlertIsIgnored() {
        let old = WeatherAlert(id: "x", severity: .severe, event: "GEWITTER", headline: "", description: "", instruction: nil,
                               onset: Self.start.addingTimeInterval(-7200), expires: Self.start.addingTimeInterval(-60), source: "dwd")
        #expect(Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), alerts: [old]), at: Self.start).map(\.kind) == [.calm])
    }

    @Test func temperatureChangeMovesDaysUp() {
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), days: [(2, 10), (-2, 2)]), at: Self.start)
        #expect(insights.first?.kind == .change)
        #expect(insights.first?.title == "Morgen 8° kälter")
        #expect(insights.first?.detail == "Höchstwert 2° statt 10°")
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .daily, .nowcast, .hourly, .details, .sources])
    }

    @Test func heat() {
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 25, count: 24), days: [(18, 33), (17, 29)]), at: Self.start)
        #expect(insights.first?.kind == .heat)
        #expect(insights.first?.title == "Heiß: bis 33°")
    }

    @Test func snowFromHours() {
        var precip = Array(repeating: 0.0, count: 24)
        precip[6] = 0.6
        var conditions = Array(repeating: Condition.cloudy, count: 24)
        conditions[6] = .snow
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 2, count: 24), precip: precip, conditions: conditions),
                                    at: Self.start)
        #expect(insights.first?.kind == .snow)
        #expect(insights.first?.title == "Schnee ab 19 Uhr")
    }

    @Test func thunder() {
        var conditions = Array(repeating: Condition.cloudy, count: 24)
        conditions[2] = .thunderstorm
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 20, count: 24), conditions: conditions), at: Self.start)
        #expect(insights.first?.kind == .thunder)
        #expect(insights.first?.title == "Gewitter ab 15 Uhr")
    }

    @Test func uncertainSources() {
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), tempSpread: 6), at: Self.start)
        #expect(insights.first?.kind == .uncertain)
        #expect(insights.first?.title == "Quellen uneinig")
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .nowcast, .hourly, .sources, .daily, .details])
    }

    @Test func rainingNowByRadar() {
        let nowcast = NowcastTests.nowcast([0.6, 0.8, 0.4, 0, 0])
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), nowcast: nowcast), at: Self.start)
        #expect(insights.first?.kind == .rainNow)
        #expect(insights.first?.title == "Regen endet in 15 Minuten")
        #expect(insights.first?.detail == "Trocken ab 13:15")
    }
}
