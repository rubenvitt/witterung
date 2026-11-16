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
            VStack(spacing: Layout.sectionSpacing) {
                if let forecast {
                    // Was gerade zählt, bestimmt Inhalt und Reihenfolge der Karten:
                    // die Regeln finden die Hinweise, Jev wägt ab (Insight.swift, Decision.swift).
                    let now = Date.now
                    let decision = model.decisions[ref]
                    let insights = Insight.ranked(forecast, at: now, baseline: model.baselines[ref], events: model.events,
                                                  habits: model.habits, decision: decision)
                    let mode = WidgetMode.decide(insights, at: now, decision: decision, habits: model.habits)
                    let night = NightOutlook.make(forecast, at: now)
                    HeaderView(title: model.title(ref), isCurrent: ref == .current, forecast: forecast,
                               briefing: Briefing.sentence(insights, mode: mode, night: night))
                    FreshnessBadge(forecast: forecast, failure: model.failures[ref], loading: model.loading.contains(ref))
                    ForEach(PlaceSection.order(for: insights, decision: decision, at: now, habits: model.habits), id: \.self) { section in
                        card(section, forecast: forecast, insights: insights, mode: mode, night: night, now: now)
                            .id(section.rawValue)
                            // Merkt sich, welche Karten angetippt werden (Lernen aus der Nutzung).
                            .simultaneousGesture(TapGesture().onEnded {
                                model.recordUse(kind: section == .focus ? insights.first?.kind.rawValue : nil, section: section.rawValue)
                            })
                    }
                    AttributionFooter(forecast: forecast, ref: ref)
                } else {
                    placeholder
                }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.top, 60)
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .animation(.snappy, value: forecast.map {
            PlaceSection.order(for: Insight.ranked($0, at: .now, baseline: model.baselines[ref], events: model.events,
                                                   habits: model.habits, decision: model.decisions[ref]),
                               decision: model.decisions[ref], habits: model.habits)
        })
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

    @ViewBuilder
    private func card(_ section: PlaceSection, forecast: Forecast, insights: [Insight], mode: WidgetMode,
                      night: NightOutlook?, now: Date) -> some View {
        switch section {
        case .alerts:
            if !forecast.alerts.isEmpty {
                VStack(spacing: Layout.sectionSpacing) { ForEach(forecast.alerts) { AlertCard(alert: $0) } }
            }
        case .focus:
            FocusCard(forecast: forecast, insights: insights, mode: mode,
                      outfit: Outfit.tip(forecast, at: now, insights: insights), now: now)
        case .tonight: if let night { TonightCard(night: night) }
        case .nowcast: NowcastCard(forecast: forecast)
        case .hourly: HourlyCard(forecast: forecast)
        case .daily: DailyCard(forecast: forecast, ref: ref)
        case .details: CurrentDetailsCard(forecast: forecast)
        case .sources: SourcesCard(forecast: forecast, ref: ref)
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: Spacing.l) {
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
    /// Kernsatz aus den Hinweisen („Sturmböen, ab 15:00 … Außerdem: Regen 13:25“).
    let briefing: String

    var body: some View {
        // Aus dem Cache: die Stunde von jetzt, nicht die vom Abrufzeitpunkt.
        let current = forecast.currentHour
        let observed = forecast.now.observed.flatMap { Date.now.timeIntervalSince($0.at) < 90 * 60 ? $0 : nil }
        let temp = observed?.tempC ?? current?.tempC
        let condition = current?.condition ?? observed?.condition ?? .unknown
        let isDay = current?.isDay ?? true
        let today = forecast.day(at: .now)?.consensus

        VStack(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
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
            if !briefing.isEmpty {
                Text(briefing)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.s)
                    .padding(.horizontal, Spacing.l)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.s)
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
                HStack(spacing: Spacing.s) {
                    Image(systemName: failure != nil ? "wifi.slash" : "clock.arrow.circlepath")
                    Text((failure != nil ? "Offline · " : "") + "Stand: \(Fmt.age(forecast.generatedAt, now: context.date))")
                    if loading { ProgressView().controlSize(.mini) }
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s - Spacing.xxs)
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
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
    }
}
