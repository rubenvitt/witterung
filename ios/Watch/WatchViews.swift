import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var path: [PlaceRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.signedIn {
                    NotLinkedView()
                } else if model.pages.isEmpty {
                    ContentUnavailableView("Keine Orte", systemImage: "mappin.slash",
                                           description: Text("Lege Orte in Witterung auf dem iPhone an."))
                } else {
                    List {
                        ForEach(model.pages, id: \.self) { ref in
                            NavigationLink(value: ref) { PlaceRow(ref: ref) }
                                .listRowBackground(rowBackground(ref))
                        }
                    }
                    .refreshable { await model.refreshAll() }
                }
            }
            .navigationTitle("Witterung")
            .navigationDestination(for: PlaceRef.self) { PlaceDetail(ref: $0) }
        }
        .onChange(of: model.opened) { _, ref in
            guard let ref else { return }
            path = model.pages.contains(ref) ? [ref] : []
            model.opened = nil
        }
    }

    private func rowBackground(_ ref: PlaceRef) -> some View {
        let s = model.forecasts[ref].flatMap { WeatherSnapshot.make($0, at: .now) }
        return RoundedRectangle(cornerRadius: Layout.tileRadius)
            .fill(Theme.gradient(s?.condition ?? .cloudy, isDay: s?.isDay ?? true))
    }
}

/// Ohne Token: Die Watch wartet auf das iPhone.
private struct NotLinkedView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                Image(systemName: "iphone.and.arrow.forward").font(.title)
                Text("Öffne Witterung auf dem iPhone und melde dich dort an. Die Watch übernimmt die Anmeldung und deine Orte.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Erneut versuchen") {
                    Task { await model.start() }
                }
            }
        }
    }
}

private struct PlaceRow: View {
    @Environment(WatchModel.self) private var model
    let ref: PlaceRef

    var body: some View {
        let s = model.forecasts[ref].flatMap { WeatherSnapshot.make($0, at: .now) }
        HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(model.title(ref)).font(.headline).lineLimit(1)
                    if ref == .current { Image(systemName: "location.fill").font(.caption2) }
                }
                Text(s?.rainHint ?? (model.loading.contains(ref) ? "Lädt …" : "Keine Daten"))
                    .font(.caption2).lineLimit(2).opacity(0.85)
            }
            Spacer(minLength: 0)
            if let s {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Image(systemName: s.condition.symbol(isDay: s.isDay)).symbolRenderingMode(.multicolor)
                    Text(Fmt.temp(s.temp)).font(.title3.weight(.medium))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: Ortsseite

struct PlaceDetail: View {
    @Environment(WatchModel.self) private var model
    let ref: PlaceRef

    var body: some View {
        let forecast = model.forecasts[ref]
        let s = forecast.flatMap { WeatherSnapshot.make($0, at: .now) }
        ScrollView {
            if let forecast, let s {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    Header(s: s)
                    if !forecast.alerts.isEmpty { Alerts(alerts: forecast.alerts) }
                    RainLine(forecast: forecast, s: s)
                    HoursStrip(forecast: forecast)
                    DaysList(forecast: forecast)
                    Footer(forecast: forecast, failure: model.failures[ref])
                }
                .foregroundStyle(.white)
            } else if model.loading.contains(ref) {
                ProgressView()
            } else {
                Text(model.failures[ref] ?? "Keine Daten").font(.footnote)
            }
        }
        .navigationTitle(model.title(ref))
        .containerBackground(Theme.gradient(s?.condition ?? .cloudy, isDay: s?.isDay ?? true), for: .navigation)
        .task {
            // Beim Öffnen nachladen, wenn die Daten älter als 10 min sind.
            if (forecast?.generatedAt).map({ Date.now.timeIntervalSince($0) > 600 }) ?? true {
                await model.refresh(ref)
            }
        }
    }
}

private struct Header: View {
    let s: WeatherSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(Fmt.temp(s.temp)).font(.system(size: 44, weight: .light)).minimumScaleFactor(0.7)
            Label(s.condition.label(isDay: s.isDay), systemImage: s.condition.symbol(isDay: s.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.footnote.weight(.semibold))
            if let min = s.min, let max = s.max {
                Text("H: \(Fmt.temp(max)) T: \(Fmt.temp(min))").font(.footnote).opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Alerts: View {
    let alerts: [WeatherAlert]
    var body: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(alerts.sorted { $0.severity > $1.severity }) { alert in
                NavigationLink {
                    AlertDetail(alert: alert)
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(alert.event).font(.footnote.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(alert.severity == .minor ? Color.black : Color.white)
                    .padding(Spacing.s)
                    .background(Theme.alertColor(alert.severity), in: RoundedRectangle(cornerRadius: Layout.tileRadius))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AlertDetail: View {
    let alert: WeatherAlert
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(Theme.alertLevel(alert.severity)).font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.alertColor(alert.severity))
                Text(alert.headline).font(.headline)
                if let expires = alert.expires {
                    Text("Bis \(Fmt.time(expires)) Uhr").font(.caption).opacity(0.8)
                }
                Text(alert.description).font(.footnote)
                if let instruction = alert.instruction, !instruction.isEmpty {
                    Text(instruction).font(.footnote).opacity(0.85)
                }
                Text("Quelle: Deutscher Wetterdienst").font(.caption2).opacity(0.7)
            }
        }
        .navigationTitle(alert.event)
    }
}

/// Radar-Nowcast, wenn es einen gibt, sonst der Regenhinweis aus den Stunden.
private struct RainLine: View {
    let forecast: Forecast
    let s: WeatherSnapshot
    var body: some View {
        let summary = NowcastSummary(forecast.nowcast, now: .now)
        Label(summary.sentence ?? s.rainHint, systemImage: summary.expectsRain ? "umbrella.fill" : "umbrella")
            .font(.footnote)
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: Layout.tileRadius))
    }
}

private struct HoursStrip: View {
    let forecast: Forecast
    var body: some View {
        let now = Date.now
        let hours = forecast.hourly.filter { $0.at.addingTimeInterval(3600) > now }.prefix(12)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Stunden").font(.caption.weight(.semibold)).opacity(0.8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                    ForEach(Array(hours)) { hour in
                        let c = hour.consensus
                        VStack(spacing: Spacing.xxs) {
                            Text(hour.at <= now ? "Jetzt" : Fmt.hour(hour.at).replacingOccurrences(of: " Uhr", with: ""))
                                .font(.caption2.weight(.medium))
                            Image(systemName: c.condition.symbol(isDay: c.isDay ?? true))
                                .symbolRenderingMode(.multicolor).frame(height: 20)
                            Text(Fmt.temp(c.tempC)).font(.footnote.weight(.semibold))
                            Text(c.precipProbPct.map { $0 >= 20 ? Fmt.percent($0) : " " } ?? " ")
                                .font(.system(size: 10)).foregroundStyle(.cyan)
                        }
                    }
                }
            }
        }
    }
}

private struct DaysList: View {
    let forecast: Forecast
    var body: some View {
        let days = forecast.daily.filter { $0.date >= Fmt.dayString(.now) }.prefix(10)
        let low = days.map(\.consensus.tempMinC).min() ?? 0
        let high = days.map(\.consensus.tempMaxC).max() ?? 10
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(days.count) Tage").font(.caption.weight(.semibold)).opacity(0.8)
            ForEach(Array(days)) { day in
                let c = day.consensus
                HStack(spacing: Spacing.xs) {
                    Text(Fmt.weekday(day.date)).font(.footnote.weight(.medium)).frame(width: 40, alignment: .leading)
                    Image(systemName: c.condition.symbol()).symbolRenderingMode(.multicolor).frame(width: 22)
                    Text(Fmt.temp(c.tempMinC)).font(.footnote).opacity(0.75).frame(width: 30, alignment: .trailing)
                    TempBar(min: c.tempMinC, max: c.tempMaxC, low: low, high: high)
                    Text(Fmt.temp(c.tempMaxC)).font(.footnote).frame(width: 30, alignment: .leading)
                }
            }
        }
    }
}

private struct TempBar: View {
    let min: Double, max: Double, low: Double, high: Double
    var body: some View {
        GeometryReader { geo in
            let span = Swift.max(1, high - low)
            Capsule().fill(.white.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.cyan, .yellow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: Swift.max(4, (max - min) / span * geo.size.width))
                        .offset(x: (min - low) / span * geo.size.width)
                }
        }
        .frame(height: 4)
    }
}

/// Stand der Daten und Quellen (Pflichtangaben wie in der App).
private struct Footer: View {
    let forecast: Forecast
    let failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            let age = Date.now.timeIntervalSince(forecast.generatedAt)
            if failure != nil || age > 30 * 60 {
                Text((failure != nil ? "Offline · " : "") + "Stand: \(Fmt.age(forecast.generatedAt))")
                    .foregroundStyle(age > 3 * 3600 ? Color.orange : Color.white)
            }
            if forecast.hasWeatherKit {
                // Wie in den Widgets: Die Watch zeigt nur den Konsens, also veränderte Daten.
                Text("\u{F8FF}Weather · Daten verändert").font(.caption.weight(.semibold))
            }
            ForEach(forecast.attribution, id: \.self) { Text($0.text) }
        }
        .font(.caption2)
        .opacity(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
