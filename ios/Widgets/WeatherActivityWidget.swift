#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Sperrbildschirm und Dynamic Island für die Live-Aktivität (`WeatherActivityAttributes`).
/// Oben eine Zeile, die die Frage beantwortet („Trocken in 12:34“, „Regen bis ca. 21 Uhr“),
/// darunter die Radarbalken der nächsten Stunde. Bei Warnungen Ereignis und Zeitraum.
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
                    if let bars = state.bars, !bars.isEmpty {
                        RainBars(state: state, height: 34)
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

/// Radar der nächsten Stunde in 5-min-Balken; trockene Schritte als flache Striche.
private struct RainBars: View {
    let state: WeatherActivityAttributes.ContentState
    var height: CGFloat = 44

    private var bars: [Double] {
        let values = state.bars ?? []
        let count = WeatherActivityAttributes.ContentState.barCount
        return values + Array(repeating: -1, count: max(0, count - values.count))
    }

    /// Wurzel-Skala bis 8 mm/h: leichter Regen bleibt sichtbar, Starkregen sprengt nichts.
    private func level(_ v: Double) -> CGFloat {
        guard v >= NowcastSummary.threshold else { return 0.06 }
        return max(0.15, min(1, CGFloat((v / 8).squareRoot())))
    }

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(state.tint.opacity(v < 0 ? 0 : v >= NowcastSummary.threshold ? 1 : 0.3))
                        .frame(height: max(3, height * level(v)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            if let start = state.barsStart.map(Date.init(timeIntervalSince1970:)) {
                HStack(spacing: 0) {
                    ForEach(0..<4) { i in
                        Text(Fmt.time(start.addingTimeInterval(Double(i) * 900)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("DWD").opacity(0.7)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regenradar der nächsten Stunde")
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
            if let bars = state.bars, !bars.isEmpty {
                RainBars(state: state)
            }
        }
        .foregroundStyle(.white)
        .padding(Layout.cardPadding)
    }
}
#endif
