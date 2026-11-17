#if os(iOS)
import ActivityKit
import Charts
import SwiftUI
import WidgetKit

/// Sperrbildschirm und Dynamic Island für die Live-Aktivität (`WeatherActivityAttributes`).
/// Oben eine Zeile, die die Frage beantwortet („Trocken in 12:34“, „Regen bis ca. 21 Uhr“),
/// darunter die Regenkurve der nächsten zwei Stunden. Bei Warnungen Ereignis und Zeitraum.
struct WeatherActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WeatherActivityAttributes.self) { context in
            WeatherActivityLockView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(state.tint)
                        .padding(.leading, Spacing.xs)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.placeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Headline(state: state, stale: context.isStale)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let series = state.series, !series.isEmpty {
                        RainChart(state: state, height: 40, showsAxis: false)
                    } else {
                        Text(state.detail()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                CompactValue(state: state, stale: context.isStale)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.tint)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            .keylineTint(state.tint)
            .widgetURL(context.attributes.url)
        }
    }
}

private extension WeatherActivityAttributes {
    var url: URL? { URL(string: "witterung://place/\(current ? "current" : String(placeId))?style=live") }
}

private extension WeatherActivityAttributes.ContentState {
    var symbol: String {
        switch kind {
        case .rainSoon: "umbrella"
        case .raining: "umbrella.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .rainSoon, .raining: Theme.tone(.rain)
        case .warning: Theme.alertColor(alertSeverity ?? .severe)
        }
    }

    /// Countdown nur, solange das Ziel in der Zukunft liegt und die Daten frisch sind.
    func liveTarget(stale: Bool) -> Date? {
        guard !stale, let target = countdownTarget, target > .now else { return nil }
        return target
    }
}

/// „Trocken in 12:34“ (läuft von selbst), sonst der feste Titel.
private struct Headline: View {
    let state: WeatherActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if let target = state.liveTarget(stale: stale) {
            HStack(spacing: Spacing.xs) {
                Text(state.countdownLabel)
                Text(timerInterval: Date.now...target, countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(state.tint)
                    .fixedSize()
            }
        } else {
            Text(state.title)
        }
    }
}

/// Rechts in der Dynamic Island: Countdown, sonst die wichtigste Uhrzeit.
private struct CompactValue: View {
    let state: WeatherActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if let target = state.liveTarget(stale: stale) {
            Text(timerInterval: Date.now...target, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(label).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var label: String {
        switch state.kind {
        case .rainSoon: return "jetzt"
        case .raining:
            if let dry = state.dry { return Fmt.hour(dry) }
            return "☂︎"
        case .warning:
            if state.start > .now { return Fmt.time(state.start) }
            return state.end.map(Fmt.time) ?? "aktiv"
        }
    }
}

/// Regenmenge der nächsten zwei Stunden (Radar, 5-min-Werte) als Fläche über die Zeit.
/// Wurzelskala bis 8 mm/h: leichter Regen bleibt sichtbar, Starkregen sprengt nichts.
private struct RainChart: View {
    let state: WeatherActivityAttributes.ContentState
    var height: CGFloat = 52
    var showsAxis = true

    private struct Point: Identifiable {
        let at: Date
        let level: Double
        var id: Date { at }
    }

    private var points: [Point] {
        guard let values = state.series, let start = state.seriesStart else { return [] }
        return values.enumerated().map { i, v in
            Point(at: Date(timeIntervalSince1970: start + Double(i) * 300),
                  level: v < NowcastSummary.threshold ? 0 : max(0.08, min(1, (v / 8).squareRoot())))
        }
    }

    var body: some View {
        let points = points
        Chart(points) { p in
            AreaMark(x: .value("Zeit", p.at), y: .value("Regen", p.level))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [state.tint.opacity(0.55), state.tint.opacity(0.1)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Zeit", p.at), y: .value("Regen", p.level))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(state.tint)
        }
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .chartXAxis(showsAxis ? .visible : .hidden)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regen in den nächsten zwei Stunden")
    }
}

private struct WeatherActivityLockView: View {
    let context: ActivityViewContext<WeatherActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Headline(state: state, stale: context.isStale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: Spacing.s)
                Text(context.attributes.placeName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .font(.title3.weight(.semibold))
            Text(context.isStale ? "Stand \(Fmt.time(Date(timeIntervalSince1970: state.updatedAt))) · \(state.detail())" : state.detail())
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            if let series = state.series, !series.isEmpty {
                RainChart(state: state)
            }
        }
        .foregroundStyle(.white)
        .padding(Layout.cardPadding)
    }
}
#endif
