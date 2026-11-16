#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Sperrbildschirm und Dynamic Island für „Regen in …“ (RainActivityAttributes).
struct RainActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainActivityAttributes.self) { context in
            RainActivityLockView(context: context)
                .activityBackgroundTint(Color(red: 0.16, green: 0.22, blue: 0.3))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.placeName, systemImage: "cloud.rain.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RainCountdown(state: context.state, stale: context.isStale)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(RainActivityLockView.detail(context.state)).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "cloud.rain.fill").foregroundStyle(.cyan)
            } compactTrailing: {
                RainCountdown(state: context.state, stale: context.isStale)
                    .frame(maxWidth: 52)
                    .font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: "cloud.rain.fill").foregroundStyle(.cyan)
            }
        }
    }
}

/// „4:59“ bis zum Regenbeginn, danach „jetzt“.
private struct RainCountdown: View {
    let state: RainActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if stale || state.start <= .now {
            Text("jetzt")
        } else {
            Text(state.start, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

private struct RainActivityLockView: View {
    let context: ActivityViewContext<RainActivityAttributes>

    static func detail(_ state: RainActivityAttributes.ContentState) -> String {
        "\(state.intensity) ab \(Fmt.time(state.start))" + (state.end.map { " bis \(Fmt.time($0))" } ?? "") + " · Radar: DWD"
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: context.state.peakMmH >= 4 ? "cloud.heavyrain.fill" : "cloud.rain.fill")
                .font(.title)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("\(context.state.intensity) in \(context.attributes.placeName)").font(.headline).lineLimit(1)
                Text(Self.detail(context.state)).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            RainCountdown(state: context.state, stale: context.isStale)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: 80, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(Layout.cardPadding)
    }
}
#endif
