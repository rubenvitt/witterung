import Charts
import SwiftUI

// MARK: Warnungen

struct AlertCard: View {
    let alert: WeatherAlert
    @State private var showDetail = false

    var body: some View {
        let color = Theme.alertColor(alert.severity)
        Button { showDetail = true } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(alert.eventTitle).font(.headline)
                    Text(alert.timeRange).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    Text(Theme.alertLevel(alert.severity) + " · DWD").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous).strokeBorder(color.opacity(0.8), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Theme.alertLevel(alert.severity)): \(alert.eventTitle), \(alert.timeRange)")
        .accessibilityHint("Zeigt den vollständigen Warntext")
        .sheet(isPresented: $showDetail) { AlertDetail(alert: alert) }
    }
}

extension WeatherAlert {
    /// „STURMBÖEN“ → „Sturmböen“
    var eventTitle: String { event.lowercased(with: Fmt.locale).capitalized(with: Fmt.locale) }

    var timeRange: String {
        let start = onset <= .now ? "seit \(Fmt.dayTime(onset))" : "ab \(Fmt.dayTime(onset))"
        guard let expires else { return start }
        return "\(start) bis \(Fmt.dayTime(expires))"
    }
}

private struct AlertDetail: View {
    let alert: WeatherAlert
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Label(Theme.alertLevel(alert.severity), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.alertColor(alert.severity))
                    Text(alert.headline).font(.title2.bold())
                    Text(alert.timeRange.prefix(1).uppercased() + alert.timeRange.dropFirst()).foregroundStyle(.secondary)
                    Text(alert.description)
                    if let instruction = alert.instruction {
                        Text(instruction)
                            .padding(Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.alertColor(alert.severity).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("Quelle: Deutscher Wetterdienst").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(Layout.screenMargin)
                .textSelection(.enabled)
            }
            .navigationTitle(alert.eventTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Nowcast

struct NowcastCard: View {
    let forecast: Forecast

    var body: some View {
        if let nowcast = forecast.nowcast {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let summary = NowcastSummary(nowcast, now: context.date)
                if summary.expectsRain {
                    Card(title: "Niederschlag · 2 Stunden", icon: "umbrella.fill") {
                        Text(summary.sentence ?? "")
                            .font(.title3.weight(.semibold))
                        NowcastChart(points: nowcast.points.filter { $0.at.addingTimeInterval(300) > context.date })
                            .frame(height: 110)
                        Text("Radar: Deutscher Wetterdienst").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                } else if let sentence = summary.sentence {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "umbrella")
                        Text(sentence)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(Layout.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct NowcastChart: View {
    let points: [NowcastPoint]

    var body: some View {
        let peak = max(1.5, points.map(\.precipMmH).max() ?? 0)
        Chart(points, id: \.at) { point in
            AreaMark(x: .value("Zeit", point.at), y: .value("mm/h", point.precipMmH))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(colors: [.cyan.opacity(0.9), .blue.opacity(0.35)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Zeit", point.at), y: .value("mm/h", point.precipMmH))
                .interpolationMethod(.monotone)
                .foregroundStyle(.cyan)
        }
        .chartYScale(domain: 0...peak)
        .chartYAxis {
            AxisMarks(values: [0.5, 2.5, 7.5].filter { $0 <= peak }) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    switch value.as(Double.self) ?? 0 {
                    case ..<1: Text("leicht")
                    case ..<5: Text("mäßig")
                    default: Text("stark")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 30)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(Fmt.time(date)) }
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Niederschlagsintensität der nächsten zwei Stunden")
    }
}

// MARK: Stunden

struct HourlyCard: View {
    let forecast: Forecast

    var body: some View {
        let rows = forecast.hourly.filter { $0.at.addingTimeInterval(3600) > .now }
        let showsProbability = rows.contains { ($0.consensus.precipProbPct ?? 0) >= 20 }
        Card(title: "48 Stunden", icon: "clock") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(Array(rows.enumerated()), id: \.element.at) { index, row in
                        HourColumn(row: row, isFirst: index == 0, showsProbability: showsProbability)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            .scrollIndicators(.hidden)
            // Bis an den Kartenrand scrollen statt am Innenabstand abgeschnitten zu werden.
            .contentMargins(.horizontal, Layout.cardPadding, for: .scrollContent)
            .padding(.horizontal, -Layout.cardPadding)
            Divider().overlay(.white.opacity(0.3))
            // Platz für die Wochentage über den Mitternachtslinien, die sonst
            // an der Trennlinie und den Temperaturen darüber kleben.
            HourlyChart(rows: rows)
                .frame(height: 170)
                .padding(.top, Spacing.l)
            Text("Linie: Median aller Quellen · Fläche: Spannbreite").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct HourColumn: View {
    let row: HourRow
    let isFirst: Bool
    let showsProbability: Bool

    var body: some View {
        let c = row.consensus
        let isMidnight = Fmt.calendar.component(.hour, from: row.at) == 0
        VStack(spacing: Spacing.s - Spacing.xxs) {
            Text(isFirst ? "Jetzt" : isMidnight ? Fmt.weekday(Fmt.dayString(row.at)) : Fmt.hour(row.at))
                .font(.footnote.weight(isFirst || isMidnight ? .bold : .medium))
                .lineLimit(1)
            Image(systemName: c.condition.symbol(isDay: c.isDay ?? true))
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .frame(height: 26)
            if showsProbability {
                Text(c.precipProbPct.map { $0 >= 20 ? Fmt.percent($0) : " " } ?? " ")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            Text(Fmt.temp(c.tempC)).font(.body.weight(.medium))
        }
        .frame(minWidth: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isFirst ? "Jetzt" : Fmt.hour(row.at)): \(Fmt.temp(c.tempC)), \(c.condition.label(isDay: c.isDay ?? true))"
            + (c.precipProbPct.map { ", Regenwahrscheinlichkeit \(Fmt.percent($0))" } ?? ""))
    }
}

private struct HourlyChart: View {
    let rows: [HourRow]

    var body: some View {
        let temps = rows.flatMap { [$0.spread.tempC?.min ?? $0.consensus.tempC, $0.spread.tempC?.max ?? $0.consensus.tempC] }
        let high = (temps.max() ?? 10).rounded(.up) + 1
        let wettest = rows.map(\.consensus.precipMm).max() ?? 0
        // Niederschlag unten im selben Diagramm, auf das untere Drittel der Temperaturskala
        // abgebildet; ganz ohne Regen bekommt die Temperatur die volle Höhe.
        let rawLow = (temps.min() ?? 0).rounded(.down) - 1
        let low = wettest > 0 ? rawLow - (high - rawLow) / 2 : rawLow
        let scale = (high - low) / 3 / max(2, wettest)

        Chart {
            ForEach(rows.filter { $0.consensus.precipMm > 0 }) { row in
                BarMark(x: .value("Zeit", row.at, unit: .hour),
                        yStart: .value("mm", low),
                        yEnd: .value("mm", low + row.consensus.precipMm * scale))
                    .foregroundStyle(.cyan.opacity(0.7))
            }
            ForEach(rows) { row in
                if let spread = row.spread.tempC {
                    AreaMark(x: .value("Zeit", row.at), yStart: .value("min", spread.min), yEnd: .value("max", spread.max))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.white.opacity(0.18))
                }
            }
            ForEach(rows) { row in
                LineMark(x: .value("Zeit", row.at), y: .value("°C", row.consensus.tempC))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            ForEach(midnights, id: \.self) { date in
                RuleMark(x: .value("Tag", date))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(Fmt.weekday(Fmt.dayString(date))).font(.caption2.bold()).foregroundStyle(.white.opacity(0.8))
                    }
            }
        }
        .chartYScale(domain: low...high)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel { if let v = value.as(Double.self), v >= rawLow { Text(Fmt.temp(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(Fmt.time(date)) }
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Temperaturverlauf und Niederschlag der nächsten 48 Stunden")
    }

    private var midnights: [Date] {
        rows.map(\.at).filter { Fmt.calendar.component(.hour, from: $0) == 0 }
    }
}

// MARK: 10 Tage

struct DailyCard: View {
    let forecast: Forecast
    let ref: PlaceRef

    var body: some View {
        let days = forecast.daily.filter { $0.date >= Fmt.dayString(.now) }
        let low = days.map { $0.spread.tempMinC?.min ?? $0.consensus.tempMinC }.min() ?? 0
        let high = days.map { $0.spread.tempMaxC?.max ?? $0.consensus.tempMaxC }.max() ?? 10
        let current = forecast.now.observed?.tempC ?? forecast.currentHour?.tempC
        Card(title: "10 Tage", icon: "calendar") {
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                    if index > 0 { Divider().overlay(.white.opacity(0.2)) }
                    NavigationLink(value: ComparisonRoute(ref: ref, day: day.date)) {
                        DayRowView(day: day, low: low, high: high, current: index == 0 ? current : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DayRowView: View {
    let day: DayRow
    let low: Double
    let high: Double
    let current: Double?
    @ScaledMetric(relativeTo: .body) private var dayWidth = 52
    @ScaledMetric(relativeTo: .caption) private var mmWidth = 52
    @ScaledMetric(relativeTo: .body) private var tempWidth = 36

    var body: some View {
        let c = day.consensus
        HStack(spacing: Spacing.s) {
            Text(Fmt.weekday(day.date))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: dayWidth, alignment: .leading)
            VStack(spacing: 0) {
                Image(systemName: c.condition.symbol())
                    .symbolRenderingMode(.multicolor)
                    .font(.title3)
                    .frame(height: 24)
                if let prob = c.precipProbPct, prob >= 20 {
                    Text(Fmt.percent(prob)).font(.caption2.weight(.semibold)).foregroundStyle(.cyan)
                }
            }
            .frame(width: 40)
            Text(Fmt.temp(c.tempMinC))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: tempWidth, alignment: .trailing)
            RangeBar(low: low, high: high, min: c.tempMinC, max: c.tempMaxC,
                     spreadMin: day.spread.tempMinC?.min, spreadMax: day.spread.tempMaxC?.max, current: current)
                .frame(height: 6)
            Text(Fmt.temp(c.tempMaxC))
                .frame(width: tempWidth, alignment: .leading)
            Text(c.precipMm >= 0.1 ? Fmt.mm(c.precipMm) : "")
                .font(.caption)
                .foregroundStyle(.cyan)
                .lineLimit(1)
                .frame(width: mmWidth, alignment: .trailing)
        }
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.longDay(day.date)): \(c.condition.label()), \(Fmt.temp(c.tempMinC)) bis \(Fmt.temp(c.tempMaxC))"
            + (c.precipMm >= 0.1 ? ", \(Fmt.mm(c.precipMm)) Niederschlag" : "")
            + (c.precipProbPct.map { ", Wahrscheinlichkeit \(Fmt.percent($0))" } ?? ""))
        .accessibilityHint("Zeigt den Quellenvergleich für diesen Tag")
    }
}

/// Temperaturbalken wie in Apple Wetter, dahinter blass die Spannbreite der Quellen.
private struct RangeBar: View {
    let low: Double, high: Double, min: Double, max: Double
    let spreadMin: Double?, spreadMax: Double?
    let current: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = Swift.max(1, high - low)
            let x = { (v: Double) in (v - low) / span * width }
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.2))
                if let spreadMin, let spreadMax {
                    Capsule().fill(.white.opacity(0.22))
                        .frame(width: Swift.max(6, x(spreadMax) - x(spreadMin)))
                        .offset(x: x(spreadMin))
                }
                Capsule()
                    .fill(LinearGradient(colors: [Self.color(min), Self.color(max)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(6, x(max) - x(min)))
                    .offset(x: x(min))
                if let current {
                    Circle().fill(.white).overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
                        .frame(width: 8, height: 8)
                        .offset(x: x(current) - 4)
                }
            }
        }
    }

    static func color(_ t: Double) -> Color {
        switch t {
        case ..<0: Color(red: 0.45, green: 0.7, blue: 1.0)
        case ..<5: Color(red: 0.4, green: 0.85, blue: 0.85)
        case ..<10: Color(red: 0.55, green: 0.85, blue: 0.4)
        case ..<15: Color(red: 0.95, green: 0.85, blue: 0.3)
        case ..<25: Color(red: 1.0, green: 0.6, blue: 0.2)
        default: Color(red: 1.0, green: 0.35, blue: 0.25)
        }
    }
}

// MARK: Aktuelle Werte

struct CurrentDetailsCard: View {
    let forecast: Forecast

    var body: some View {
        let o = forecast.now.observed
        let f = forecast.currentHour
        Card(title: "Aktuell", icon: "thermometer.medium") {
            if let o {
                Text("Messstation \(o.station) · \(Fmt.distance(meters: o.distanceM)) entfernt · \(Fmt.time(o.at))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("Keine Messstation in der Nähe – Werte aus der Vorhersage")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            // Grid statt LazyVGrid: Kacheln einer Zeile werden gleich hoch und oben bündig.
            let tiles = detailTiles(o, f)
            Grid(horizontalSpacing: Layout.tileSpacing, verticalSpacing: Layout.tileSpacing) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                    GridRow {
                        tiles[i]
                        if i + 1 < tiles.count {
                            tiles[i + 1]
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    private func detailTiles(_ o: ObservedWeather?, _ f: HourPoint?) -> [DetailTile] {
        var tiles: [DetailTile] = []
        if let wind = o?.windKmh ?? f?.windKmh {
            let dir = o?.windDirDeg ?? f?.windDirDeg
            let detail = [dir.map { "aus \(Fmt.compassPoint($0))" }, (o?.gustKmh ?? f?.gustKmh).map { "Böen \(Fmt.kmh($0))" }]
                .compactMap { $0 }.joined(separator: " · ")
            tiles.append(DetailTile(title: "Wind", icon: "wind", value: Fmt.kmh(wind), detail: detail, arrow: dir))
        }
        if let feels = f?.feelsLikeC {
            tiles.append(DetailTile(title: "Gefühlt", icon: "thermometer.variable", value: Fmt.temp(feels), detail: "laut Vorhersage"))
        }
        if let humidity = o?.humidityPct ?? f?.humidityPct {
            tiles.append(DetailTile(title: "Feuchte", icon: "humidity", value: Fmt.percent(humidity), detail: "relativ"))
        }
        if let pressure = o?.pressureHpa ?? f?.pressureHpa {
            tiles.append(DetailTile(title: "Luftdruck", icon: "gauge.with.dots.needle.33percent", value: Fmt.hpa(pressure), detail: "auf Meereshöhe"))
        }
        if let visibility = o?.visibilityM {
            tiles.append(DetailTile(title: "Sicht", icon: "eye", value: Fmt.distance(meters: visibility), detail: ""))
        }
        if let precip = o?.precipMm1h {
            tiles.append(DetailTile(title: "Niederschlag", icon: "drop.fill", value: Fmt.mm(precip), detail: "letzte Stunde"))
        } else if let cloud = o?.cloudPct ?? f?.cloudPct {
            tiles.append(DetailTile(title: "Bewölkung", icon: "cloud", value: Fmt.percent(cloud), detail: ""))
        }
        return tiles
    }
}

private struct DetailTile: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    var arrow: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.title2.weight(.medium)).minimumScaleFactor(0.7).lineLimit(1)
                if let arrow {
                    // Pfeil zeigt, wohin der Wind weht (Richtung + 180°).
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(arrow + 180))
                        .accessibilityHidden(true)
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity, alignment: .topLeading)
        .padding(Layout.tilePadding)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Layout.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Quellen

struct SourcesCard: View {
    let forecast: Forecast
    let ref: PlaceRef

    var body: some View {
        let ok = forecast.sources.filter { $0.ok && !$0.stale }
        let problems = forecast.sources.filter { !$0.ok || $0.stale }
        NavigationLink(value: ComparisonRoute(ref: ref)) {
            Card(title: "Quellen", icon: "square.stack.3d.up") {
                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(ok.count) von \(forecast.sources.count) Quellen aktuell")
                            .font(.body.weight(.medium))
                        ForEach(problems) { source in
                            Label("\(SourceNames.name(source.source)): \(source.error.map(SourceNames.error) ?? "veraltet")",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("Quellenvergleich, Konsens und Spannbreite")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct AttributionFooter: View {
    let forecast: Forecast
    let ref: PlaceRef

    var body: some View {
        VStack(spacing: Spacing.s) {
            if forecast.hasWeatherKit {
                Link(destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
                    Text("\u{F8FF}Weather").font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Apple Weather, rechtliche Hinweise")
            }
            NavigationLink(value: AttributionRoute(ref: ref)) {
                Text("Daten: Open-Meteo (CC BY 4.0), Deutscher Wetterdienst, Pirate Weather · Datenquellen")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .underline()
            }
            Text("Aktualisiert \(Fmt.dayTime(forecast.generatedAt))")
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, Spacing.s)
        .padding(.top, Spacing.s)
    }
}
