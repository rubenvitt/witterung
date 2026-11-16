import SwiftUI
import WidgetKit

/// Die Widget-Arten. Alle teilen Ortswahl, Provider und Snapshot; sie unterscheiden
/// sich in der Ansicht und darin, wie dicht die Timeline ist.
enum WidgetStyle: String, CaseIterable, Sendable {
    /// Das ursprüngliche Widget. Kind bleibt „weather“, sonst verschwänden schon abgelegte Widgets.
    case weather
    /// Entscheidet selbst, was gerade wichtig ist (`Insight.rank`), und sagt, warum.
    case focus
    case hourly
    case daily

    var kind: String { rawValue }

    var displayName: String {
        switch self {
        case .weather: "Wetter"
        case .focus: "Im Blick"
        case .hourly: "Stunden"
        case .daily: "Tage"
        }
    }

    var summary: String {
        switch self {
        case .weather: "Temperatur, Wetterlage und Regenhinweis für einen Ort."
        case .focus: "Zeigt von selbst, was gerade zählt – Warnung, Regen laut Radar, Glätte, Sturm, Gassi-Fenster – und warum."
        case .hourly: "Temperaturverlauf und Regen der nächsten Stunden."
        case .daily: "Die nächsten Tage mit Höchst- und Tiefstwerten."
        }
    }

    var families: [WidgetFamily] {
        #if os(watchOS)
        return switch self {
        case .weather, .focus: [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
        case .hourly, .daily: [.accessoryRectangular]
        }
        #else
        return switch self {
        case .weather, .focus: [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        case .hourly, .daily: [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular]
        }
        #endif
    }

    /// Fokus: in den ersten zwei Stunden alle 15 Minuten (Radar), sonst stündlich.
    var isDense: Bool { self == .focus }
}

/// Einstieg für alle Widget-Arten (auch für die Debug-Galerie der App).
struct StyledWidgetView: View {
    let style: WidgetStyle
    let snapshot: WeatherSnapshot?
    let family: WidgetFamily

    var body: some View {
        if let s = snapshot {
            switch style {
            case .weather: WeatherWidgetView(snapshot: s, family: family)
            case .focus: FocusWidgetView(s: s, family: family)
            case .hourly: HourlyWidgetView(s: s, family: family)
            case .daily: DailyWidgetView(s: s, family: family)
            }
        } else {
            WeatherWidgetView(snapshot: nil, family: family)
        }
    }
}

// MARK: Im Blick

struct FocusWidgetView: View {
    let s: WeatherSnapshot
    let family: WidgetFamily

    var body: some View {
        let focus = s.focus
        switch family {
        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: focus.symbol)
                .font(.title3)
                .widgetLabel(focus.title)
        #else
        case .systemSmall: FocusSmall(s: s)
        case .systemMedium: FocusMedium(s: s)
        case .systemLarge, .systemExtraLarge: FocusLarge(s: s)
        #endif
        case .accessoryRectangular: FocusRectangular(s: s)
        case .accessoryInline: Label(focus.title, systemImage: focus.symbol)
        default: FocusCircular(s: s)
        }
    }
}

/// Symbol des Hinweises in seiner Farbe; ruhiges Wetter in den Farben der Wetterlage.
struct InsightSymbol: View {
    let insight: Insight

    var body: some View {
        Image(systemName: insight.symbol)
            .symbolRenderingMode(insight.tone == .calm ? SymbolRenderingMode.multicolor : .monochrome)
            .foregroundStyle(Theme.tone(insight.tone))
    }
}

/// Der Entscheidungsgrund, klein unter dem Hinweis.
struct ReasonLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .opacity(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grund: \(text)")
    }
}

#if !os(watchOS)
private struct FocusSmall: View {
    let s: WeatherSnapshot

    var body: some View {
        let f = s.focus
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(s.placeName).lineLimit(1)
                Spacer(minLength: Spacing.xs)
                Text(Fmt.temp(s.temp))
            }
            .font(.caption.weight(.semibold))
            .opacity(0.9)
            Spacer(minLength: 0)
            InsightSymbol(insight: f).font(.title2)
            Text(f.title).font(.headline).lineLimit(3).minimumScaleFactor(0.7)
            Text(f.detail).font(.caption).opacity(0.85).lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            ReasonLine(text: f.reasonLine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

/// Hinweis oben, darunter die passende Ansicht (Radar, Stunden oder Tage), unten der Grund.
private struct FocusMedium: View {
    let s: WeatherSnapshot

    var body: some View {
        let f = s.focus
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.s) {
                InsightSymbol(insight: f).font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(f.title).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                    Text(f.detail).font(.caption).opacity(0.85).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: Spacing.s)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.temp(s.temp)).font(.title3.weight(.medium))
                    Text(s.placeName).font(.caption2.weight(.semibold)).lineLimit(1).opacity(0.85)
                }
            }
            Spacer(minLength: Spacing.xs)
            FocusVisual(s: s, insight: f).frame(height: 54)
            Spacer(minLength: Spacing.xs)
            ReasonLine(text: f.reasonLine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

private struct FocusLarge: View {
    let s: WeatherSnapshot

    var body: some View {
        let f = s.focus
        let others = Array(s.insights.dropFirst().prefix(3))
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                PlaceTitle(s: s)
                Spacer(minLength: Spacing.s)
                Text(Fmt.temp(s.temp)).font(.title3.weight(.medium))
            }
            HStack(alignment: .top, spacing: Spacing.m) {
                InsightSymbol(insight: f).font(.title).frame(width: 34)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(f.title).font(.title3.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text(f.detail).font(.subheadline).opacity(0.85).lineLimit(2)
                }
            }
            FocusVisual(s: s, insight: f).frame(height: 78)
            ReasonLine(text: f.reasonLine)
            Divider().overlay(.white.opacity(0.4))
            if others.isEmpty {
                DayColumns(days: Array(s.days.prefix(5)), now: s.date)
            } else {
                Text("Außerdem").font(.caption.weight(.semibold)).textCase(.uppercase).opacity(0.7)
                ForEach(others) { InsightRow(insight: $0) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}
#endif

/// Kleine Zeile für weitere Hinweise (großes Widget, Karte „Im Blick“).
struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(spacing: Spacing.s) {
            InsightSymbol(insight: insight).font(.body).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(insight.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(insight.detail).font(.caption).opacity(0.8).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Was den Hinweis am besten erklärt: Radar bei Regen, Tage bei Umschwung und Hitze, sonst Stunden.
struct FocusVisual: View {
    let s: WeatherSnapshot
    let insight: Insight

    var body: some View {
        switch insight.visual {
        case .radar where !s.radar.isEmpty:
            RadarBars(values: s.radar, start: s.date)
        case .days:
            DayColumns(days: Array(s.days.prefix(5)), now: s.date, compact: true)
        default:
            HourGraph(hours: Array(s.hours.prefix(12)), labelEvery: 2)
        }
    }
}

private struct FocusRectangular: View {
    let s: WeatherSnapshot

    var body: some View {
        let f = s.focus
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: f.symbol)
                Text(f.title).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            }
            .widgetAccentable()
            Text(f.detail).lineLimit(1).minimumScaleFactor(0.8)
            Text("\(Fmt.temp(s.temp)) · \(f.reasonLine)").lineLimit(1).minimumScaleFactor(0.8).opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FocusCircular: View {
    let s: WeatherSnapshot

    var body: some View {
        let f = s.focus
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: f.symbol).font(.title3).widgetAccentable()
                Text(f.badge).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .accessibilityLabel(f.title)
    }
}

// MARK: Stunden

struct HourlyWidgetView: View {
    let s: WeatherSnapshot
    let family: WidgetFamily

    var body: some View {
        switch family {
        #if !os(watchOS)
        case .systemSmall: HourlySmall(s: s)
        case .systemMedium: HourlyMedium(s: s)
        case .systemLarge, .systemExtraLarge: HourlyLarge(s: s)
        #endif
        default: HourlyRectangular(s: s)
        }
    }
}

#if !os(watchOS)
private struct HourlyHeader: View {
    let s: WeatherSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            PlaceTitle(s: s)
            Text(Fmt.temp(s.temp)).font(.subheadline.weight(.semibold))
            Spacer(minLength: Spacing.s)
            Text(s.rainHint).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8).opacity(0.9)
        }
    }
}

private struct HourlySmall: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                PlaceTitle(s: s)
                Spacer(minLength: Spacing.xxs)
                Text(Fmt.temp(s.temp)).font(.subheadline.weight(.semibold))
            }
            ForEach(s.hours.prefix(5), id: \.self) { hour in
                HStack(spacing: Spacing.xs) {
                    Text(Fmt.hour(hour.at)).font(.caption.weight(.medium)).frame(width: 42, alignment: .leading)
                    Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.caption).frame(width: 20)
                    Spacer(minLength: 0)
                    if let prob = hour.precipProb, prob >= 20 {
                        Text(Fmt.percent(prob)).font(.caption2.weight(.semibold)).foregroundStyle(.cyan)
                    }
                    Text(Fmt.temp(hour.temp)).font(.caption.weight(.semibold)).frame(width: 28, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

private struct HourlyMedium: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HourlyHeader(s: s)
            HourGraph(hours: Array(s.hours.prefix(12)), labelEvery: 2, showsSymbols: true)
        }
        .foregroundStyle(.white)
    }
}

/// 24 Stunden in zwei Diagrammen untereinander.
private struct HourlyLarge: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HourlyHeader(s: s)
            HourGraph(hours: Array(s.hours.prefix(12)), labelEvery: 2, showsSymbols: true)
            if s.hours.count > 12 {
                Divider().overlay(.white.opacity(0.4))
                HourGraph(hours: Array(s.hours.dropFirst(12).prefix(12)), labelEvery: 2, showsSymbols: true)
            }
        }
        .foregroundStyle(.white)
    }
}
#endif

private struct HourlyRectangular: View {
    let s: WeatherSnapshot

    var body: some View {
        HStack(spacing: 0) {
            ForEach(s.hours.prefix(4), id: \.self) { hour in
                VStack(spacing: 1) {
                    Text(Fmt.hour(hour.at).replacingOccurrences(of: " Uhr", with: "")).font(.caption2)
                    Image(systemName: hour.symbol).font(.caption)
                    Text(Fmt.temp(hour.temp)).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Temperaturkurve mit Werten, darunter Regen als Balken und die Stunden. Spalten
/// statt Swift Charts, damit Kurve, Beschriftung und Stunden genau übereinander stehen.
struct HourGraph: View {
    let hours: [WeatherSnapshot.Hour]
    var labelEvery = 1
    var showsSymbols = false

    var body: some View {
        let indexed = Array(hours.enumerated())
        VStack(spacing: Spacing.xxs) {
            if showsSymbols {
                HStack(spacing: 0) {
                    ForEach(indexed, id: \.offset) { i, hour in
                        Image(systemName: hour.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.caption)
                            .opacity(i % labelEvery == 0 ? 1 : 0)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 16)
            }
            GeometryReader { geo in
                curve(in: geo.size)
            }
            HStack(spacing: 0) {
                ForEach(indexed, id: \.offset) { i, hour in
                    Text(i % labelEvery == 0 ? Fmt.hour(hour.at).replacingOccurrences(of: " Uhr", with: "") : " ")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.75)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hours.prefix(6).map { "\(Fmt.hour($0.at)) \(Fmt.temp($0.temp))" }.joined(separator: ", "))
    }

    private func curve(in size: CGSize) -> some View {
        let count = CGFloat(max(1, hours.count))
        let column = size.width / count
        let temps = hours.map(\.temp)
        let low = temps.min() ?? 0
        let span = max(1, (temps.max() ?? 1) - low)
        let barZone = size.height * 0.3
        let top: CGFloat = 13
        let bottom = max(top + 1, size.height - barZone - 2)
        let points = hours.indices.map { i in
            CGPoint(x: (CGFloat(i) + 0.5) * column, y: top + (1 - CGFloat((hours[i].temp - low) / span)) * (bottom - top))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(hours.enumerated()), id: \.offset) { i, hour in
                if hour.precipMm >= 0.1 {
                    let height = max(2, barZone * min(1, CGFloat(hour.precipMm / 3)))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.cyan.opacity(0.75))
                        .frame(width: column * 0.55, height: height)
                        .position(x: points[i].x, y: size.height - height / 2)
                }
            }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ForEach(Array(hours.enumerated()), id: \.offset) { i, hour in
                if i % labelEvery == 0 {
                    Text(Fmt.temp(hour.temp))
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()
                        .position(x: points[i].x, y: points[i].y - 8)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Radar-Nowcast als Balken, 5-min-Schritte; Regen ab 0,1 mm/h farbig.
struct RadarBars: View {
    let values: [Double]
    let start: Date

    var body: some View {
        let peak = max(1.5, values.max() ?? 0)
        let end = start.addingTimeInterval(Double(values.count) * 300)
        VStack(spacing: Spacing.xxs) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(value >= NowcastSummary.threshold ? Color.cyan : Color.white.opacity(0.25))
                            .frame(height: max(2, geo.size.height * min(1, value / peak)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
            HStack {
                Text("Jetzt")
                Spacer()
                Text(Fmt.time(start.addingTimeInterval(end.timeIntervalSince(start) / 2)))
                Spacer()
                Text(Fmt.time(end))
            }
            .font(.system(size: 10, weight: .medium))
            .opacity(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regenradar bis \(Fmt.time(end))")
    }
}

// MARK: Tage

struct DailyWidgetView: View {
    let s: WeatherSnapshot
    let family: WidgetFamily

    var body: some View {
        switch family {
        #if !os(watchOS)
        case .systemSmall: DailySmall(s: s)
        case .systemMedium: DailyMedium(s: s)
        case .systemLarge, .systemExtraLarge: DailyLarge(s: s)
        #endif
        default: DailyRectangular(s: s)
        }
    }
}

#if !os(watchOS)
private struct DailySmall: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            PlaceTitle(s: s)
            ForEach(s.days.prefix(4), id: \.self) { day in
                HStack(spacing: Spacing.xs) {
                    Text(Fmt.weekday(day.date, now: s.date)).font(.subheadline.weight(.medium)).lineLimit(1)
                        .minimumScaleFactor(0.8).frame(width: 40, alignment: .leading)
                    Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.subheadline).frame(width: 22)
                    Spacer(minLength: 0)
                    Text(Fmt.temp(day.max)).font(.subheadline.weight(.semibold))
                    Text(Fmt.temp(day.min)).font(.subheadline).opacity(0.7).frame(width: 28, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

private struct DailyMedium: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                PlaceTitle(s: s)
                Text(Fmt.temp(s.temp)).font(.subheadline.weight(.semibold))
                Spacer(minLength: Spacing.s)
                MinMax(s: s).font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
            DayColumns(days: Array(s.days.prefix(5)), now: s.date)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

/// Zehn Tage mit Temperaturbalken und Niederschlagsmenge.
private struct DailyLarge: View {
    let s: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                PlaceTitle(s: s)
                Text(Fmt.temp(s.temp)).font(.subheadline.weight(.semibold))
                Spacer(minLength: Spacing.s)
                if s.hasWeatherKit { WeatherMark() }
            }
            DayRangeRows(days: Array(s.days.prefix(10)), now: s.date, showsPrecip: true)
                .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }
}
#endif

private struct DailyRectangular: View {
    let s: WeatherSnapshot

    var body: some View {
        HStack(spacing: 0) {
            ForEach(s.days.prefix(3), id: \.self) { day in
                VStack(spacing: 1) {
                    Text(Fmt.weekday(day.date, now: s.date)).font(.caption2)
                    Image(systemName: day.symbol).font(.caption)
                    Text("\(Fmt.temp(day.max)) \(Fmt.temp(day.min))").font(.caption.weight(.semibold)).lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Tage nebeneinander: Wochentag, Symbol, Regenwahrscheinlichkeit, Höchst- und Tiefstwert.
struct DayColumns: View {
    let days: [WeatherSnapshot.Day]
    let now: Date
    /// Ohne Wahrscheinlichkeit, Höchst- und Tiefstwert in einer Zeile.
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                VStack(spacing: Spacing.xxs) {
                    Text(Fmt.weekday(day.date, now: now)).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.callout).frame(height: 20)
                    if compact {
                        Text("\(Fmt.temp(day.max)) \(Fmt.temp(day.min))").font(.caption.weight(.semibold)).lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text(day.precipProb.map { $0 >= 20 ? Fmt.percent($0) : " " } ?? " ")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.cyan)
                        Text(Fmt.temp(day.max)).font(.caption.weight(.semibold))
                        Text(Fmt.temp(day.min)).font(.caption).opacity(0.7)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Tageszeilen mit Temperaturbalken; sie teilen sich die verfügbare Höhe.
struct DayRangeRows: View {
    let days: [WeatherSnapshot.Day]
    let now: Date
    var showsPrecip = false

    var body: some View {
        let low = days.map(\.min).min() ?? 0
        let high = days.map(\.max).max() ?? 10
        VStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                HStack(spacing: Spacing.s) {
                    Text(Fmt.weekday(day.date, now: now)).font(.subheadline.weight(.medium)).frame(width: 46, alignment: .leading)
                    Image(systemName: day.symbol).symbolRenderingMode(.multicolor).frame(width: 26)
                    Text(Fmt.temp(day.min)).font(.subheadline).opacity(0.75).frame(width: 30, alignment: .trailing)
                    GeometryReader { geo in
                        let span = max(1, high - low)
                        Capsule().fill(.white.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [.cyan, .yellow], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, (day.max - day.min) / span * geo.size.width))
                                    .offset(x: (day.min - low) / span * geo.size.width)
                            }
                    }
                    .frame(height: 5)
                    Text(Fmt.temp(day.max)).font(.subheadline).frame(width: 30, alignment: .leading)
                    if showsPrecip {
                        Text(day.precipMm >= 0.1 ? Fmt.mm(day.precipMm) : "")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
