#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Sperrbildschirm und Dynamic Island für die Live-Aktivität (`WeatherActivityAttributes`):
/// „Regen in …“ mit Countdown bis Beginn, „Regen endet in …“ und Unwetterwarnungen.
struct WeatherActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WeatherActivityAttributes.self) { context in
            WeatherActivityLockView(context: context)
                .activityBackgroundTint(context.state.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.placeName, systemImage: state.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.tint)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityCountdown(state: state, stale: context.isStale)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(state.headline(place: context.attributes.placeName)).font(.headline).lineLimit(1)
                        Text(state.detail()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                ActivityCountdown(state: state, stale: context.isStale, compact: true)
                    .frame(maxWidth: 56)
                    .font(.caption.weight(.semibold))
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
        case .rainSoon, .raining: peakMmH >= 4 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .rainSoon, .raining: Theme.tone(.rain)
        case .warning: Theme.alertColor(alertSeverity ?? .severe)
        }
    }

    var background: Color {
        switch kind {
        case .rainSoon, .raining: Color(red: 0.16, green: 0.22, blue: 0.3)
        case .warning: alertSeverity == .extreme ? Color(red: 0.24, green: 0.08, blue: 0.28) : Color(red: 0.3, green: 0.09, blue: 0.09)
        }
    }
}

/// Rechte Seite: Countdown („4:59“) bei Regen, „ab 18:00“/„bis 04:00“ bei Warnungen.
private struct ActivityCountdown: View {
    let state: WeatherActivityAttributes.ContentState
    let stale: Bool
    var compact = false

    var body: some View {
        if let target = state.countdownTarget, !stale, target > .now {
            Text(timerInterval: Date.now...target, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(label).multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var label: String {
        let time = { (prefix: String, date: Date) in compact ? Fmt.time(date) : "\(prefix) \(Fmt.time(date))" }
        switch state.kind {
        case .rainSoon:
            return "jetzt"
        case .raining:
            guard let end = state.end else { return "hält an" }
            return end <= .now ? "vorbei" : time("bis", end)
        case .warning:
            if state.start > .now { return time("ab", state.start) }
            if let end = state.end { return time("bis", end) }
            return "aktiv"
        }
    }
}

private struct WeatherActivityLockView: View {
    let context: ActivityViewContext<WeatherActivityAttributes>

    var body: some View {
        let state = context.state
        HStack(spacing: Spacing.m) {
            Image(systemName: state.symbol)
                .font(.title)
                .foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(state.headline(place: context.attributes.placeName)).font(.headline).lineLimit(1)
                Text(state.detail()).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                if context.isStale {
                    Text("Stand \(Fmt.time(Date(timeIntervalSince1970: state.updatedAt)))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: Spacing.s)
            ActivityCountdown(state: state, stale: context.isStale)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: 96, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(Layout.cardPadding)
    }
}
#endif
