import Charts
import SwiftUI

/// Je Stunde bzw. Tag: Werte jeder Quelle, Konsens, Spannbreite, Quellenstatus.
struct ComparisonView: View {
    @Environment(AppModel.self) private var model
    let route: ComparisonRoute

    @State private var mode = Mode.hours
    @State private var hour: Date?
    @State private var day: String?

    enum Mode: String, CaseIterable { case hours = "Stunden", days = "Tage" }

    var body: some View {
        if let forecast = model.forecasts[route.ref] {
            List {
                Picker("Ansicht", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch mode {
                case .hours: hours(forecast)
                case .days: days(forecast)
                }
                statusSection(forecast)
            }
            .navigationTitle("Quellenvergleich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .onAppear {
                if let d = route.day { mode = .days; day = d }
                hour = hour ?? forecast.hourly.first?.at
                day = day ?? forecast.daily.first?.date
            }
        }
    }

    // MARK: Stunden

    @ViewBuilder private func hours(_ forecast: Forecast) -> some View {
        let sources = Array(Set(forecast.hourly.flatMap(\.bySource.keys))).sorted()
        Section("Temperatur je Quelle") {
            Chart {
                ForEach(sources, id: \.self) { source in
                    ForEach(forecast.hourly.compactMap { row in row.bySource[source].map { (row.at, $0.tempC) } }, id: \.0) { at, temp in
                        LineMark(x: .value("Zeit", at), y: .value("°C", temp), series: .value("Quelle", SourceNames.name(source)))
                            .foregroundStyle(by: .value("Quelle", SourceNames.name(source)))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                ForEach(forecast.hourly) { row in
                    LineMark(x: .value("Zeit", row.at), y: .value("°C", row.consensus.tempC), series: .value("Quelle", "Konsens"))
                        .foregroundStyle(.white)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                }
                if let hour {
                    RuleMark(x: .value("Gewählt", hour)).foregroundStyle(.yellow.opacity(0.7))
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let d = value.as(Date.self) { Text(Fmt.dayTime(d)) } }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.temp(v)) } }
                }
            }
            .frame(height: 220)
            .padding(.vertical, 6)
            .accessibilityLabel("Temperaturverlauf je Quelle, weiße Linie ist der Konsens")
        }

        Section {
            Picker("Stunde", selection: $hour) {
                ForEach(forecast.hourly) { row in
                    Text(Fmt.dayTime(row.at)).tag(Optional(row.at))
                }
            }
            if let row = forecast.hourly.first(where: { $0.at == hour }) {
                SourceGrid(
                    header: ["", "Temp.", "Regen", "Wind"],
                    consensus: hourCells(row.consensus),
                    rows: row.bySource.sorted { $0.key < $1.key }.map { (SourceNames.name($0.key), hourCells($0.value)) }
                )
                spreadLine(n: row.nSources,
                           parts: [row.spread.tempC.map { "Temp. \(Fmt.temp($0.min))–\(Fmt.temp($0.max))" },
                                   row.spread.precipMm.map { "Regen \(Fmt.number($0.min))–\(Fmt.mm($0.max))" },
                                   row.spread.windKmh.map { "Wind \(Int($0.min.rounded()))–\(Fmt.kmh($0.max))" }],
                           agreement: row.spread.precipAgreementPct)
            }
        } header: {
            Text("Werte je Quelle")
        }
    }

    private func hourCells(_ p: HourPoint) -> Cells {
        Cells(symbol: p.condition.symbol(isDay: p.isDay ?? true), values: [Fmt.temp(p.tempC), Fmt.mm(p.precipMm), Fmt.kmh(p.windKmh)])
    }

    // MARK: Tage

    @ViewBuilder private func days(_ forecast: Forecast) -> some View {
        Section {
            Picker("Tag", selection: $day) {
                ForEach(forecast.daily) { row in
                    Text(Fmt.longDay(row.date)).tag(Optional(row.date))
                }
            }
            if let row = forecast.daily.first(where: { $0.date == day }) {
                SourceGrid(
                    header: ["", "Tief", "Hoch", "Regen"],
                    consensus: dayCells(row.consensus),
                    rows: row.bySource.sorted { $0.key < $1.key }.map { (SourceNames.name($0.key), dayCells($0.value)) }
                )
                spreadLine(n: row.nSources,
                           parts: [row.spread.tempMinC.map { "Tief \(Fmt.temp($0.min))–\(Fmt.temp($0.max))" },
                                   row.spread.tempMaxC.map { "Hoch \(Fmt.temp($0.min))–\(Fmt.temp($0.max))" },
                                   row.spread.precipMm.map { "Regen \(Fmt.number($0.min))–\(Fmt.mm($0.max))" }],
                           agreement: row.spread.precipAgreementPct)
                if let sunrise = row.consensus.sunrise, let sunset = row.consensus.sunset {
                    Label("Sonne \(Fmt.time(sunrise))–\(Fmt.time(sunset))", systemImage: "sunrise")
                        .font(.footnote)
                }
            }
        } header: {
            Text("Werte je Quelle")
        }
    }

    private func dayCells(_ p: DayPoint) -> Cells {
        Cells(symbol: p.condition.symbol(), values: [Fmt.temp(p.tempMinC), Fmt.temp(p.tempMaxC), Fmt.mm(p.precipMm)])
    }

    private func spreadLine(n: Int, parts: [String?], agreement: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spannbreite aus \(n) Quellen").font(.footnote.weight(.semibold))
            Text(parts.compactMap { $0 }.joined(separator: " · ")).font(.footnote)
            if let agreement {
                Text("\(Fmt.percent(agreement)) der Quellen erwarten Niederschlag").font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Status

    private func statusSection(_ forecast: Forecast) -> some View {
        Section("Quellenstatus") {
            ForEach(forecast.sources) { source in
                HStack {
                    Image(systemName: !source.ok ? "xmark.octagon.fill" : source.stale ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill")
                        .foregroundStyle(!source.ok ? .red : source.stale ? .orange : .green)
                    VStack(alignment: .leading) {
                        Text(SourceNames.name(source.source))
                        Text(statusText(source)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let nowcast = forecast.nowcast {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(SourceNames.name(nowcast.source))
                        Text("Nowcast von \(Fmt.dayTime(nowcast.at))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusText(_ source: SourceStatus) -> String {
        var parts: [String] = []
        if let error = source.error { parts.append(SourceNames.error(error)) }
        if source.stale { parts.append("veraltet") }
        if let fetched = source.fetchedAt { parts.append("abgerufen \(Fmt.age(fetched))") }
        return parts.joined(separator: " · ")
    }
}

struct Cells {
    let symbol: String
    let values: [String]
}

/// Tabelle: Konsens oben, darunter jede Quelle.
private struct SourceGrid: View {
    let header: [String]
    let consensus: Cells
    let rows: [(String, Cells)]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { index, title in
                    Text(title).gridColumnAlignment(index == 0 ? .leading : .trailing)
                }
                Text("")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            row("Konsens (Median)", consensus).fontWeight(.semibold)
            Divider()
            ForEach(rows, id: \.0) { name, cells in row(name, cells) }
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    private func row(_ name: String, _ cells: Cells) -> some View {
        GridRow {
            Text(name).lineLimit(1).minimumScaleFactor(0.8)
            ForEach(Array(cells.values.enumerated()), id: \.offset) { Text($0.element) }
            Image(systemName: cells.symbol).symbolRenderingMode(.multicolor)
        }
        .accessibilityElement(children: .combine)
    }
}
