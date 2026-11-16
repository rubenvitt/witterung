import SwiftUI

/// „Heute Nacht“: Tiefstwert, Nässe, Wind, der Morgen um 7 Uhr und Sonnenaufgang.
/// Steht abends und nachts weit oben (PlaceSection.order), tagsüber nach den 10 Tagen.
struct TonightCard: View {
    let night: NightOutlook

    var body: some View {
        Card(title: "Heute Nacht", icon: "moon.stars.fill") {
            HStack(alignment: .top, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(Fmt.temp(night.low)).font(.system(size: 44, weight: .light))
                    Text("Tiefstwert gegen \(Fmt.hour(night.lowAt))").font(.subheadline)
                    if night.frost {
                        Label("Frost", systemImage: "thermometer.snowflake").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.tone(.cold))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    Label(night.wetFrom.map { "Nass ab \(Fmt.hour($0)) · \(Fmt.mm(night.precipMm))" } ?? "Trocken",
                          systemImage: night.wetFrom == nil ? "drop" : "drop.fill")
                        .foregroundStyle(night.wetFrom == nil ? Color.white : Color.cyan)
                    if let gust = night.maxGust, gust >= 40 {
                        Label("Böen bis \(Fmt.kmh(gust))", systemImage: "wind")
                    }
                    if let morning = night.morningTemp {
                        HStack(spacing: Spacing.xs) {
                            if let symbol = night.morningSymbol { Image(systemName: symbol).symbolRenderingMode(.multicolor) }
                            Text("7 Uhr \(Fmt.temp(morning))")
                        }
                    }
                    if let sunrise = night.sunrise {
                        Label("Sonnenaufgang \(Fmt.time(sunrise))", systemImage: "sunrise.fill")
                    }
                }
                .font(.subheadline)
            }
            HourGraph(hours: Array(night.hours.prefix(12)), labelEvery: 2, showsSymbols: true)
                .frame(height: 110)
            if let day = night.tomorrow {
                HStack(spacing: Spacing.s) {
                    Text("Morgen").font(.subheadline.weight(.semibold))
                    Image(systemName: day.symbol).symbolRenderingMode(.multicolor)
                    Text("\(Fmt.temp(day.min)) bis \(Fmt.temp(day.max))")
                    if let prob = day.precipProb, prob >= 20 {
                        Text(Fmt.percent(prob)).foregroundStyle(.cyan)
                    }
                }
                .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heute Nacht: \(night.summary)")
    }
}
