import SwiftUI

/// „Im Blick“ auf der Ortsseite: die Hinweise aus `Insight.rank` mit ihrem Grund.
/// Warnungen und Regen laut Radar haben eigene Karten und tauchen hier nicht doppelt auf.
struct FocusCard: View {
    let forecast: Forecast
    let insights: [Insight]
    /// Hält Jev (oder die Regeln) die Lage für ruhig, wird die Karte zur kompakten Zeile.
    let mode: WidgetMode
    let outfit: String?
    let now: Date

    var body: some View {
        let radarShowsRain = NowcastSummary(forecast.nowcast, now: now).expectsRain
        let shown = insights.filter { insight in
            insight.kind != .alert && !(radarShowsRain && [.rainNow, .rainSoon].contains(insight.kind))
        }
        let quiet = shown.first?.kind == .calm || (mode == .calm && shown.first?.isUrgent != true)
        if quiet {
            // Nichts Auffälliges: kurz sagen, was trotzdem gilt.
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Ruhiges Wetter").font(.subheadline.weight(.semibold))
                }
                let notes = shown.filter { $0.kind != .calm }.prefix(3).map(\.short)
                if !notes.isEmpty {
                    Text("Am Rand: " + notes.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                if let outfit { OutfitRow(text: outfit) }
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
                    if let outfit {
                        Divider().overlay(.white.opacity(0.2))
                        OutfitRow(text: outfit)
                    }
                }
            }
        }
    }
}

/// „Für draußen: warme Jacke, Schirm, Leuchthalsband für den Hund“
private struct OutfitRow: View {
    let text: String

    var body: some View {
        Label {
            Text("**Für draußen:** \(text)")
        } icon: {
            Image(systemName: "tshirt.fill")
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.9))
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
