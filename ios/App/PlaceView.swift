import SwiftUI

struct ComparisonRoute: Hashable {
    let ref: PlaceRef
    var day: String?
}

struct AttributionRoute: Hashable {
    let ref: PlaceRef
}

/// Eine Seite: alles zu einem Ort, das Dringende oben (Warnung, Regen bald).
struct PlaceView: View {
    @Environment(AppModel.self) private var model
    let ref: PlaceRef

    var body: some View {
        let forecast = model.forecasts[ref]
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 12) {
                if let forecast {
                    HeaderView(title: model.title(ref), isCurrent: ref == .current, forecast: forecast)
                    FreshnessBadge(forecast: forecast, failure: model.failures[ref], loading: model.loading.contains(ref))
                    ForEach(forecast.alerts) { AlertCard(alert: $0) }
                    NowcastCard(forecast: forecast)
                    HourlyCard(forecast: forecast).id("hourly")
                    DailyCard(forecast: forecast, ref: ref).id("daily")
                    CurrentDetailsCard(forecast: forecast).id("details")
                    SourcesCard(forecast: forecast, ref: ref)
                    AttributionFooter(forecast: forecast, ref: ref)
                } else {
                    placeholder
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        .task(id: forecast == nil) {
            // Screenshots: `-scrollTo daily` springt zu einem Abschnitt.
            if forecast != nil, let target = DebugArgs.value("-scrollTo") {
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        #endif
        }
        .refreshable { await model.refresh(ref, manual: true) }
        .sensoryFeedback(.success, trigger: model.refreshTick)
        .background {
            Theme.gradient(forecast?.currentHour?.condition ?? .cloudy, isDay: forecast?.currentHour?.isDay ?? true)
                .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .task(id: ref) {
            if forecast == nil { await model.refresh(ref) }
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 16) {
            Text(model.title(ref)).font(.largeTitle)
            if let failure = model.failures[ref] {
                ContentUnavailableView("Keine Daten", systemImage: "wifi.slash", description: Text(failure))
            } else if ref == .current, model.location.coordinate == nil {
                ProgressView()
                Text("Standort wird ermittelt …").foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Wetter wird geladen …").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: Kopf

private struct HeaderView: View {
    let title: String
    let isCurrent: Bool
    let forecast: Forecast

    var body: some View {
        // Aus dem Cache: die Stunde von jetzt, nicht die vom Abrufzeitpunkt.
        let current = forecast.currentHour
        let observed = forecast.now.observed.flatMap { Date.now.timeIntervalSince($0.at) < 90 * 60 ? $0 : nil }
        let temp = observed?.tempC ?? current?.tempC
        let condition = current?.condition ?? observed?.condition ?? .unknown
        let isDay = current?.isDay ?? true
        let today = forecast.day(at: .now)?.consensus

        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if isCurrent { Image(systemName: "location.fill").font(.footnote) }
                Text(title)
            }
            .font(.title.weight(.medium))
            if isCurrent, forecast.location.name != title, !forecast.location.name.isEmpty {
                Text(forecast.location.name).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(Fmt.temp(temp))
                .font(.system(size: 96, weight: .thin))
                .contentTransition(.numericText())
                .padding(.leading, 24) // optischer Ausgleich für das Gradzeichen
            Label(condition.label(isDay: isDay), systemImage: condition.symbol(isDay: isDay))
                .symbolRenderingMode(.multicolor)
                .font(.title3.weight(.medium))
            if let today {
                Text("H: \(Fmt.temp(today.tempMaxC))  T: \(Fmt.temp(today.tempMinC))")
                    .font(.title3)
                    .accessibilityLabel("Höchstwert \(Fmt.temp(today.tempMaxC)), Tiefstwert \(Fmt.temp(today.tempMinC))")
            }
            if let feels = current?.feelsLikeC {
                Text("Gefühlt \(Fmt.temp(feels))").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// „Stand: vor 12 min“ – nur wenn die Daten alt sind oder der letzte Abruf scheiterte.
private struct FreshnessBadge: View {
    let forecast: Forecast
    let failure: String?
    let loading: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let age = context.date.timeIntervalSince(forecast.generatedAt)
            if failure != nil || age > 30 * 60 {
                HStack(spacing: 6) {
                    Image(systemName: failure != nil ? "wifi.slash" : "clock.arrow.circlepath")
                    Text((failure != nil ? "Offline · " : "") + "Stand: \(Fmt.age(forecast.generatedAt, now: context.date))")
                    if loading { ProgressView().controlSize(.mini) }
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((age > 3 * 3600 ? Color.orange : Color.white).opacity(0.22), in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Bausteine

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension Fmt {
    /// „15:00“ heute, sonst „Di 04:00“.
    static func dayTime(_ date: Date, now: Date = .now) -> String {
        calendar.isDate(date, inSameDayAs: now) ? time(date) : "\(weekday(dayString(date), now: now)) \(time(date))"
    }
}
