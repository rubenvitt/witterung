import SwiftUI
import WidgetKit

/// Ansichten der Widgets. Liegen in Shared, damit die App sie in der
/// DEBUG-Galerie zeigen kann (Screenshots ohne Home-Bildschirm).
struct WeatherWidgetView: View {
    let snapshot: WeatherSnapshot?
    let family: WidgetFamily

    var body: some View {
        if let s = snapshot {
            switch family {
            case .systemSmall: SmallView(s: s)
            case .systemMedium: MediumView(s: s)
            case .systemLarge, .systemExtraLarge: LargeView(s: s)
            case .accessoryCircular: CircularView(s: s)
            case .accessoryRectangular: RectangularView(s: s)
            case .accessoryInline: InlineView(s: s)
            default: SmallView(s: s)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "icloud.slash")
                Text(family.isAccessory ? "–" : "Keine Daten – App öffnen").font(.caption)
            }
            .foregroundStyle(.white)
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(self) }
}

private struct PlaceTitle: View {
    let s: WeatherSnapshot
    var body: some View {
        HStack(spacing: 3) {
            Text(s.placeName).lineLimit(1)
            if s.isCurrentLocation { Image(systemName: "location.fill").font(.system(size: 9)) }
        }
        .font(.subheadline.weight(.semibold))
    }
}

private struct MinMax: View {
    let s: WeatherSnapshot
    var body: some View {
        if let min = s.min, let max = s.max {
            Text("H: \(Fmt.temp(max)) T: \(Fmt.temp(min))")
        }
    }
}

private struct SmallView: View {
    let s: WeatherSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlaceTitle(s: s)
            Text(Fmt.temp(s.temp)).font(.system(size: 44, weight: .light)).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Image(systemName: s.condition.symbol(isDay: s.isDay)).symbolRenderingMode(.multicolor).font(.body)
            Text(s.rainHint).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            MinMax(s: s).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

private struct HoursRow: View {
    let hours: [WeatherSnapshot.Hour]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                VStack(spacing: 4) {
                    Text(Fmt.hour(hour.at).replacingOccurrences(of: " Uhr", with: "")).font(.caption2.weight(.medium))
                    Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.callout).frame(height: 20)
                    Text(Fmt.temp(hour.temp)).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct MediumView: View {
    let s: WeatherSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    PlaceTitle(s: s)
                    Text(Fmt.temp(s.temp)).font(.system(size: 40, weight: .light))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: s.condition.symbol(isDay: s.isDay)).symbolRenderingMode(.multicolor).font(.title3)
                    Text(s.condition.label(isDay: s.isDay)).font(.caption.weight(.semibold))
                    MinMax(s: s).font(.caption)
                }
            }
            Text(s.rainHint).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            HoursRow(hours: Array(s.hours.prefix(6)))
            if s.hasWeatherKit { WeatherMark() }
        }
        .foregroundStyle(.white)
    }
}

/// WeatherKit verlangt die Marke überall, wo Apple-Daten erscheinen; der Link
/// steht in der App (Tipp aufs Widget öffnet sie).
private struct WeatherMark: View {
    var body: some View {
        Text("\u{F8FF}Weather · Daten verändert").font(.system(size: 9, weight: .medium)).opacity(0.7)
    }
}

private struct LargeView: View {
    let s: WeatherSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediumView(s: s).frame(height: 140)
            Divider().overlay(.white.opacity(0.4))
            let low = s.days.map(\.min).min() ?? 0
            let high = s.days.map(\.max).max() ?? 10
            ForEach(s.days, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(Fmt.weekday(day.date, now: s.date)).font(.subheadline.weight(.medium)).frame(width: 46, alignment: .leading)
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
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

private struct CircularView: View {
    let s: WeatherSnapshot
    var body: some View {
        if let min = s.min, let max = s.max, min < max {
            Gauge(value: Swift.min(Swift.max(s.temp, min), max), in: min...max) {
                Image(systemName: s.condition.symbol(isDay: s.isDay))
            } currentValueLabel: {
                Text(Fmt.temp(s.temp))
            } minimumValueLabel: {
                Text(Fmt.temp(min).dropLast())
            } maximumValueLabel: {
                Text(Fmt.temp(max).dropLast())
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            VStack(spacing: 0) {
                Image(systemName: s.condition.symbol(isDay: s.isDay))
                Text(Fmt.temp(s.temp)).font(.headline)
            }
        }
    }
}

private struct RectangularView: View {
    let s: WeatherSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: s.condition.symbol(isDay: s.isDay))
                Text("\(Fmt.temp(s.temp)) \(s.placeName)").font(.headline).lineLimit(1)
            }
            Text(s.rainHint).lineLimit(1)
            MinMax(s: s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineView: View {
    let s: WeatherSnapshot
    var body: some View {
        Label("\(Fmt.temp(s.temp)) · \(s.rainHint)", systemImage: s.condition.symbol(isDay: s.isDay))
    }
}
