import SwiftUI

/// „Im Blick“ auf der Ortsseite: die Hinweise aus `Insight.rank` mit ihrem Grund.
/// Warnungen und Regen laut Radar haben eigene Karten und tauchen hier nicht doppelt auf.
struct FocusCard: View {
    let forecast: Forecast
    let insights: [Insight]
    let now: Date

    var body: some View {
        let radarShowsRain = NowcastSummary(forecast.nowcast, now: now).expectsRain
        let shown = insights.filter { insight in
            insight.kind != .alert && !(radarShowsRain && [.rainNow, .rainSoon].contains(insight.kind))
        }
        if let calm = shown.first, calm.kind == .calm {
            // Nichts Auffälliges: eine Zeile, die das ausdrücklich sagt.
            HStack(spacing: Spacing.s) {
                InsightSymbol(insight: calm)
                Text(calm.title).font(.subheadline.weight(.semibold))
                Text(calm.reason).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .accessibilityElement(children: .combine)
        } else if !shown.isEmpty {
            Card(title: "Im Blick", icon: "sparkles") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(Array(shown.prefix(3).enumerated()), id: \.element.id) { index, insight in
                        if index > 0 { Divider().overlay(.white.opacity(0.2)) }
                        InsightDetailRow(insight: insight, isPrimary: index == 0)
                    }
                }
            }
        }
    }
}

private struct InsightDetailRow: View {
    let insight: Insight
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            InsightSymbol(insight: insight)
                .font(isPrimary ? .title2 : .title3)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(insight.title).font(isPrimary ? .title3.weight(.semibold) : .headline)
                Text(insight.detail).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Label(insight.reasonLine, systemImage: insight.jevProbability == nil ? "info.circle" : "sparkles")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
