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
        alerts: [WeatherAlert] = [], nowcast: Nowcast? = nil, dayPrecip: [Double]? = nil, clouds: Double = 50,
        sunset: Date? = nil
    ) -> Forecast {
        let hourly = temps.indices.map { i in
            let at = start.addingTimeInterval(Double(i) * 3600)
            let mm = precip?[i] ?? 0
            let point = HourPoint(
                at: at, tempC: temps[i], feelsLikeC: nil, precipMm: mm, precipProbPct: mm >= 0.1 ? 80 : 5,
                windKmh: 10, gustKmh: gusts?[i], windDirDeg: 225, cloudPct: clouds, humidityPct: 80, pressureHpa: 1015,
                condition: conditions?[i] ?? (mm >= 0.1 ? .rain : .cloudy), isDay: true)
            let spread = HourSpread(
                tempC: ValueRange(min: temps[i] - tempSpread / 2, max: temps[i] + tempSpread / 2),
                precipMm: ValueRange(min: 0, max: mm * 2), windKmh: nil,
                precipAgreementPct: agreement ?? (mm >= 0.1 ? 100 : 0))
            return HourRow(at: at, nSources: 6, consensus: point, spread: spread, bySource: [:])
        }
        let daily = days.indices.map { i in
            let date = Fmt.dayString(start.addingTimeInterval(Double(i) * 86_400))
            let point = DayPoint(date: date, tempMinC: days[i].min, tempMaxC: days[i].max, precipMm: dayPrecip?[i] ?? 0,
                                 precipProbPct: nil, windMaxKmh: nil, gustMaxKmh: nil, condition: .cloudy, sunrise: nil,
                                 sunset: i == 0 ? sunset : nil)
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
        #expect(PlaceSection.order(for: insights) == [.alerts, .nowcast, .focus, .hourly, .daily, .tonight, .details, .sources])
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
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .nowcast, .hourly, .daily, .tonight, .details, .sources])
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
        #expect(PlaceSection.order(for: storm) == [.alerts, .focus, .details, .nowcast, .hourly, .daily, .tonight, .sources])
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
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .daily, .tonight, .nowcast, .hourly, .details, .sources])
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
        #expect(PlaceSection.order(for: insights) == [.alerts, .focus, .nowcast, .hourly, .sources, .daily, .tonight, .details])
    }

    @Test func rainingNowByRadar() {
        let nowcast = NowcastTests.nowcast([0.6, 0.8, 0.4, 0, 0])
        let insights = Insight.rank(Self.forecast(temps: Array(repeating: 8, count: 24), nowcast: nowcast), at: Self.start)
        #expect(insights.first?.kind == .rainNow)
        #expect(insights.first?.title == "Regen endet in 15 Minuten")
        #expect(insights.first?.detail == "Trocken ab 13:15")
    }
}

/// Jevs Entscheidungen und ihre Leitplanken (Decision.swift).
struct DecisionTests {
    static func choice(_ p: [String: Double], confidence: Double = 0.7) -> JevDecision.Choice {
        JevDecision.Choice(choice: p.max { $0.value < $1.value }!.key, probabilities: p, confidence: confidence)
    }

    static func decision(focus: [String: Double]? = nil, mode: String? = nil, urgency: Double? = nil,
                         sections: [String: Double]? = nil, window: String? = nil, confidence: Double = 0.7) -> JevDecision {
        JevDecision(model: "jev-1.13.0", focus: focus.map { choice($0, confidence: confidence) },
                    mode: mode.map { choice([$0: 0.8], confidence: confidence) },
                    urgency: urgency.map { JevDecision.Score(score: $0, confidence: confidence) },
                    sections: sections.map { choice($0, confidence: confidence) },
                    window: window.map { choice([$0: 0.9], confidence: confidence) })
    }

    @Test func jevReordersWhenConfident() throws {
        let forecast = try InsightTests.fixture()
        let ordered = Insight.ranked(forecast, at: InsightTests.start,
                                     decision: Self.decision(focus: ["alert": 0.1, "rainSoon": 0.2, "walk": 0.7]))
        #expect(ordered.map(\.kind) == [.walk, .rainSoon, .alert])
        #expect(ordered[0].jevProbability == 0.7)
        #expect(ordered[0].reasonLine == "Längste trockene Lücke zwischen den Schauern · Jev 70 %")
        #expect(ordered[0].shortReason == "Jev 70 %")
        #expect(ordered[1].jevProbability == nil)
        #expect(ordered[1].shortReason == "Radar")
    }

    @Test func rulesStayWhenUnsureOrDifferent() throws {
        let insights = Insight.rank(try InsightTests.fixture(), at: InsightTests.start)
        let unsure = Self.decision(focus: ["alert": 0.3, "rainSoon": 0.3, "walk": 0.4], confidence: 0.3)
        #expect(insights.ordered(by: unsure.focus) == insights)
        #expect(insights.ordered(by: Self.decision(focus: ["alert": 0.1, "walk": 0.9]).focus) == insights)
        #expect(insights.ordered(by: nil) == insights)
    }

    @Test func severeAlertIsPinned() {
        let nowcast = NowcastTests.nowcast([0, 1, 1, 1, 1, 1])
        let forecast = InsightTests.forecast(temps: Array(repeating: 8, count: 24),
                                             alerts: [InsightTests.alert("ORKANBÖEN", .severe)], nowcast: nowcast)
        let d = Self.decision(focus: ["alert": 0.05, "rainSoon": 0.95], mode: "days", urgency: 0.2)
        let ordered = Insight.ranked(forecast, at: InsightTests.start, decision: d)
        #expect(ordered.map(\.kind) == [.alert, .rainSoon])
        #expect(ordered[0].jevProbability == nil)
        // Rote Warnung: immer der Hinweis groß und volle Dringlichkeit.
        #expect(WidgetMode.decide(ordered, at: InsightTests.start, decision: d) == .hint)
        #expect(Urgency.value(ordered, decision: d) == 1)
    }

    @Test func jevChoosesModeUrgencyAndWalkWindow() throws {
        let forecast = try InsightTests.fixture()
        let rules = Insight.rank(forecast, at: InsightTests.start)
        #expect(WidgetMode.decide(rules, at: InsightTests.start, decision: nil) == .hint)
        #expect(WidgetMode.decide(rules, at: InsightTests.start, decision: Self.decision(mode: "hours")) == .hours)
        #expect(WidgetMode.decide(rules, at: InsightTests.start, decision: Self.decision(mode: "hours", confidence: 0.2)) == .hint)
        #expect(Urgency.value(rules, decision: Self.decision(urgency: 1.5)) == 0.5)
        #expect(Urgency.value(rules, decision: nil) == rules[0].score)
        #expect(Urgency.refreshMinutes(0.8) == 15)
        #expect(Urgency.refreshMinutes(0.1) == 60)

        // Zwei Fenster an einem Nachmittag mit Schauer dazwischen: Jev wählt das zweite.
        var precip = Array(repeating: 0.0, count: 24)
        precip[3] = 1.0 // 16 Uhr MEZ
        let showers = InsightTests.forecast(temps: Array(repeating: 8, count: 24), precip: precip)
        let windows = Insight.walkWindows(showers, at: InsightTests.start)
        #expect(windows.map(\.id) == ["w0", "w1"])
        #expect(windows[0].summary == "jetzt bis 16 Uhr (3 h): trocken, 8°, Wind bis 10 km/h, hell")
        let byRules = Insight.rank(showers, at: InsightTests.start).first { $0.kind == .walk }
        #expect(byRules?.title == "Gassi-Fenster bis 16 Uhr")
        let byJev = Insight.ranked(showers, at: InsightTests.start, decision: Self.decision(window: "w1")).first { $0.kind == .walk }
        #expect(byJev?.title == "Gassi-Fenster 17–22 Uhr")
        #expect(byJev?.short == "Gassi 17–22")
        #expect(byJev?.reason == "Bestes trockenes Fenster laut Jev")
    }

    @Test func sectionsFollowJevButAlertsStayFirst() throws {
        let insights = Insight.rank(try InsightTests.fixture(), at: InsightTests.start)
        let d = Self.decision(sections: ["details": 0.5, "sources": 0.3, "focus": 0.2])
        let order = PlaceSection.order(for: insights, decision: d, at: InsightTests.start)
        #expect(order.prefix(4) == [.alerts, .details, .sources, .focus])
        #expect(Set(order) == Set(PlaceSection.allCases))
        // Abends steht „Heute Nacht“ gleich nach „Im Blick“.
        let evening = InsightTests.start.addingTimeInterval(6 * 3600) // 19 Uhr MEZ
        let calm = Insight.rank(InsightTests.forecast(temps: Array(repeating: 8, count: 24)), at: evening)
        #expect(PlaceSection.order(for: calm, at: evening).prefix(3) == [.alerts, .focus, .tonight])
    }

    @Test func requestIsCompactAndStableWithinAQuarter() throws {
        let forecast = try InsightTests.fixture()
        let request = DecisionRequest.make(forecast, placeName: "Uelzen", at: InsightTests.start)
        #expect(Set(request.options.keys) == ["alert", "rainSoon", "walk"])
        #expect(request.options["rainSoon"] == "Regen in 25 Minuten. ab 13:25, bis etwa 15:00. Grund: Regenradar des DWD, nächste 2 Stunden")
        #expect(request.windows == ["w0": "17–22 Uhr (5 h): trocken, 6°, Wind bis 20 km/h, dunkel"])
        #expect(request.state.localTime == "Mo 13:00")
        #expect(request.state.radar == "Regen in 25 Minuten")
        #expect(request.state.nextHours.count == 12)
        #expect(request.state.tonight?.hasPrefix("Tiefstwert") == true)
        // 7 Minuten später: dieselbe Anfrage, der Server antwortet aus dem Cache.
        let later = DecisionRequest.make(forecast, placeName: "Uelzen", at: InsightTests.start.addingTimeInterval(7 * 60))
        #expect(later == request)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains("\"nextHours\""))
        // Auch bei nur einem Hinweis wird gefragt (Ansicht, Dringlichkeit, Karten).
        let calm = InsightTests.forecast(temps: Array(repeating: 8, count: 24))
        #expect(DecisionRequest.make(calm, placeName: "X", at: InsightTests.start).options.keys.sorted() == ["calm"])
    }

    @Test func decodesServerAnswer() throws {
        let json = """
        {"model":"jev-1.13.0","focus":null,"mode":{"choice":"tonight","probabilities":{"tonight":0.7},"confidence":0.6},
         "urgency":{"score":1.2,"confidence":0.5},"sections":null,"window":null}
        """
        let d = try JSONDecoder().decode(JevDecision.self, from: Data(json.utf8))
        #expect(d.mode?.choice == "tonight")
        #expect(d.focus == nil)
        #expect(d.windowChoice == nil)
    }
}

/// Kurztexte, Nacht, Kernsatz, Vergleich mit älterer Vorhersage.
struct OutlookTests {
    @Test func shortTextsFitLockScreen() throws {
        var precip = Array(repeating: 0.0, count: 24)
        precip[4] = 1.2
        var gusts = Array(repeating: 30.0, count: 24)
        gusts[3] = 78
        var temps = Array(repeating: 3.0, count: 24)
        temps[14] = -3
        let forecasts = [
            try InsightTests.fixture(),
            InsightTests.forecast(temps: temps, precip: precip, gusts: gusts, days: [(2, 10), (-2, 2)]),
            InsightTests.forecast(temps: Array(repeating: 8, count: 24), tempSpread: 6),
        ]
        let all = forecasts.flatMap { Insight.rank($0, at: InsightTests.start) }
        #expect(all.count >= 6)
        for insight in all {
            #expect(insight.short.count <= 16, "\(insight.kind): \(insight.short)")
            #expect(insight.shortDetail.count <= 18, "\(insight.kind): \(insight.shortDetail)")
            #expect(insight.source.count <= 16)
        }
        let rain = all.first { $0.kind == .rainSoon }
        #expect(rain?.short == "Regen 13:25")
        #expect(rain?.shortDetail == "bis 15:00")
        #expect(all.first { $0.kind == .storm }?.short == "Böen 78 km/h")
    }

    @Test func tonight() {
        var temps = Array(repeating: 6.0, count: 24)
        temps[16] = -1 // 5 Uhr MEZ
        var precip = Array(repeating: 0.0, count: 24)
        precip[9] = 0.4 // 22 Uhr
        let forecast = InsightTests.forecast(temps: temps, precip: precip)
        let night = NightOutlook.make(forecast, at: InsightTests.start)
        #expect(night?.start == InsightTests.start.addingTimeInterval(7 * 3600)) // 20 Uhr
        #expect(night?.low == -1)
        #expect(night?.frost == true)
        #expect(night?.wetFrom == InsightTests.start.addingTimeInterval(9 * 3600))
        #expect(night?.summary == "Tiefstwert -1° gegen 5 Uhr, Niederschlag ab 22 Uhr (0,4 mm), um 7 Uhr 6°")
        #expect(night?.hours.count == 12)
        // Nach 20 Uhr beginnt die Nacht jetzt.
        let late = InsightTests.start.addingTimeInterval(8 * 3600 + 600)
        #expect(NightOutlook.make(forecast, at: late)?.start == late)
    }

    @Test func briefingAndOutfit() throws {
        let forecast = try InsightTests.fixture()
        let insights = Insight.rank(forecast, at: InsightTests.start)
        #expect(Briefing.sentence(insights, mode: .hint, night: nil)
            == "Sturmböen, ab 15:00 bis Di 04:00. Außerdem: Regen 13:25, Gassi 17–22.")
        let calm = Insight.rank(InsightTests.forecast(temps: Array(repeating: 8, count: 24)), at: InsightTests.start)
        #expect(Briefing.sentence(calm, mode: .calm, night: nil) == "Bewölkt, kein Regen in Sicht · 2° bis 8°.")
        #expect(Outfit.tip(forecast, at: InsightTests.start, insights: insights) == "Warme Jacke, Schirm")
    }

    @Test func forecastShift() {
        let base = InsightTests.start.addingTimeInterval(-5 * 3600)
        var precip = Array(repeating: 0.0, count: 24)
        precip[2] = 0.8 // 15 Uhr MEZ
        let forecast = InsightTests.forecast(temps: Array(repeating: 8, count: 24), precip: precip)
        let earlier = ForecastDigest(generatedAt: base, firstRain: InsightTests.start.addingTimeInterval(5 * 3600), dailyMax: [:])
        let shift = Insight.rank(forecast, at: InsightTests.start, baseline: earlier).first { $0.kind == .shift }
        #expect(shift?.title == "Regen früher: ab 15 Uhr")
        #expect(shift?.detail == "vorher ab 18 Uhr angesagt")
        #expect(shift?.reason == "Vergleich mit der Vorhersage von 08:00")
        let dry = ForecastDigest(generatedAt: base, firstRain: nil, dailyMax: [:])
        #expect(Insight.rank(forecast, at: InsightTests.start, baseline: dry).first { $0.kind == .shift }?.title == "Regen neu: ab 15 Uhr")
        let rainy = ForecastDigest(generatedAt: base, firstRain: InsightTests.start.addingTimeInterval(3600), dailyMax: [:])
        let none = InsightTests.forecast(temps: Array(repeating: 8, count: 24))
        #expect(Insight.rank(none, at: InsightTests.start, baseline: rainy).first { $0.kind == .shift }?.title == "Regen fällt aus")
        // Morgen wärmer als angesagt.
        let warmer = ForecastDigest(generatedAt: base, firstRain: nil, dailyMax: ["2026-11-10": 4])
        #expect(Insight.rank(none, at: InsightTests.start, baseline: warmer).first { $0.kind == .shift }?.title
            == "Morgen 4° wärmer als angesagt")
    }

    @Test func digestHistory() {
        let t = InsightTests.start
        let d = { (h: Double) in ForecastDigest(generatedAt: t.addingTimeInterval(h * 3600), firstRain: nil, dailyMax: [:]) }
        var history: [ForecastDigest] = []
        for h in [-20.0, -10, -9.5, -4, -1] { history = ForecastDigest.appending(d(h), to: history) }
        #expect(history.count == 4) // -9,5 h kam zu früh nach -10 h
        #expect(ForecastDigest.baseline(in: history, now: t) == d(-4))
        #expect(ForecastDigest.baseline(in: [d(-20), d(-1)], now: t) == nil)
    }
}

/// Termine, Wochenende, goldene Stunde und was die Person antippt (Personal.swift).
struct PersonalTests {
    static let start = InsightTests.start

    @Test func outdoorHeuristic() {
        #expect(CalendarEvent.isOutdoor(title: "Hundeschule", location: nil))
        #expect(CalendarEvent.isOutdoor(title: "Treffen", location: "Stadtpark Uelzen"))
        #expect(!CalendarEvent.isOutdoor(title: "Treffen", location: "https://zoom.us/j/1"))
        #expect(!CalendarEvent.isOutdoor(title: "Teams-Call Projekt", location: "Büro"))
        #expect(!CalendarEvent.isOutdoor(title: "Zahnarzt", location: nil))
    }

    @Test func rainAtAnOutdoorEvent() {
        var precip = Array(repeating: 0.0, count: 24)
        precip[2] = 0.8 // 15 Uhr MEZ
        let forecast = InsightTests.forecast(temps: Array(repeating: 8, count: 24), precip: precip)
        let events = [
            CalendarEvent(start: Self.start.addingTimeInterval(2 * 3600), end: Self.start.addingTimeInterval(3 * 3600),
                          title: "Hundeschule", location: "Platz am Wald"),
            CalendarEvent(start: Self.start.addingTimeInterval(2 * 3600), end: Self.start.addingTimeInterval(3 * 3600),
                          title: "Zoom mit Team", location: "https://zoom.us/j/1"),
        ]
        let insights = Insight.rank(forecast, at: Self.start, events: events)
        let event = insights.first
        #expect(event?.kind == .event)
        #expect(event?.title == "Regen zu „Hundeschule“")
        #expect(event?.detail == "15:00 · 0,8 mm · 8°")
        #expect(event?.short == "Termin: Regen")
        #expect(event?.shortDetail == "15:00")
        // Jev sieht den Termin, aber nie seinen Namen.
        let request = DecisionRequest.make(forecast, placeName: "Uelzen", at: Self.start, events: events)
        #expect(request.options["event"] == "Termin draußen 15:00: Regen, 0,8 mm · 8°")
        #expect(!String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self).contains("Hundeschule"))
        // Trockener Termin: kein Hinweis.
        #expect(Insight.rank(InsightTests.forecast(temps: Array(repeating: 8, count: 24)), at: Self.start, events: events)
            .contains { $0.kind == .event } == false)
    }

    @Test func weekendOutlook() {
        let thursday = Self.start.addingTimeInterval(3 * 86_400) // Do 13 Uhr
        let forecast = InsightTests.forecast(temps: Array(repeating: 8, count: 24), days: Array(repeating: (2, 8), count: 7),
                                             dayPrecip: [0, 0, 0, 0, 0, 3, 0])
        let weekend = Insight.rank(forecast, at: thursday).first { $0.kind == .weekend }
        #expect(weekend?.title == "Wochenende: Sa Regen, So Bewölkt")
        #expect(weekend?.detail == "Sa 2° bis 8° · So 2° bis 8° · draußen eher am Sonntag")
        #expect(weekend?.short == "WE: eher So")
        #expect(weekend?.score == 0.28)
        // Montag: noch kein Wochenende.
        #expect(Insight.rank(forecast, at: Self.start).contains { $0.kind == .weekend } == false)
    }

    @Test func goldenHour() {
        let sunset = Self.start.addingTimeInterval(3.5 * 3600) // 16:30 MEZ
        let clear = InsightTests.forecast(temps: Array(repeating: 8, count: 24), clouds: 20, sunset: sunset)
        let golden = Insight.rank(clear, at: Self.start).first { $0.kind == .golden }
        #expect(golden?.title == "Goldene Stunde ab 15:30")
        #expect(golden?.shortDetail == "15:30–16:30")
        let cloudy = InsightTests.forecast(temps: Array(repeating: 8, count: 24), clouds: 80, sunset: sunset)
        #expect(Insight.rank(cloudy, at: Self.start).contains { $0.kind == .golden } == false)
    }

    @Test func habitsFadeAndSteer() throws {
        var stats = UsageStats()
        for _ in 0..<3 { stats.record(mode: "hours", kind: "walk", section: "sources", at: Self.start) }
        #expect(stats.favoriteKinds == [.walk])
        #expect(stats.favoriteMode == .hours)
        #expect(stats.favoriteSections == [.sources])
        #expect(stats.summary == "Öffnet oft: Stundenverlauf; achtet oft auf: Gassi-Fenster; schaut oft: Quellenvergleich")

        // Ruhiger Tag: die Lieblingsansicht statt der Übersicht, die Lieblingskarte nach oben.
        let calm = InsightTests.forecast(temps: Array(repeating: 8, count: 24))
        let insights = Insight.rank(calm, at: Self.start, habits: stats)
        #expect(WidgetMode.rules(insights, at: Self.start) == .calm)
        #expect(WidgetMode.rules(insights, at: Self.start, habits: stats) == .hours)
        #expect(PlaceSection.order(for: insights, at: Self.start, habits: stats).prefix(3) == [.alerts, .focus, .sources])

        // Lieblingshinweis bekommt etwas Gewicht dazu.
        let walk = Insight.rank(try InsightTests.fixture(), at: Self.start, habits: stats).first { $0.kind == .walk }
        #expect(walk?.score == 0.42 + UsageStats.boost)

        // Nach neun Wochen (drei Halbwertszeiten) ist die Vorliebe verblasst.
        stats.record(at: Self.start.addingTimeInterval(63 * 86_400))
        #expect(stats.favoriteKinds.isEmpty)
        #expect(stats.summary == nil)
    }
}
