import SwiftUI

/// Datenquellen und Lizenzen. Pflichtangaben: Open-Meteo CC BY 4.0, DWD als Quelle,
/// Apple-Weather-Marke mit Link (sobald WeatherKit liefert), Pirate Weather.
struct AttributionView: View {
    @Environment(AppModel.self) private var model
    let route: AttributionRoute

    var body: some View {
        let forecast = model.forecasts[route.ref]
        List {
            if forecast?.hasWeatherKit ?? false {
                Section {
                    Link(destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\u{F8FF}Weather").font(.title3.weight(.semibold))
                            Text("Rechtliche Hinweise und Datenquellen von Apple Weather").font(.footnote)
                        }
                    }
                }
            }
            Section("Quellen") {
                source("Open-Meteo", "Wettermodelle ICON-D2, ICON-EU (DWD), ECMWF IFS, GFS (NOAA). Lizenz: CC BY 4.0.",
                       links: [("open-meteo.com", "https://open-meteo.com/"), ("Lizenz CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/")])
                source("Deutscher Wetterdienst", "Messwerte (SYNOP), MOSMIX, Radar und amtliche Warnungen, über Bright Sky. Quelle: Deutscher Wetterdienst.",
                       links: [("dwd.de", "https://www.dwd.de/"), ("brightsky.dev", "https://brightsky.dev/")])
                source("Pirate Weather", "Powered by Pirate Weather.", links: [("pirateweather.net", "https://pirateweather.net/")])
                source("Apple Weather", "Über WeatherKit, sofern auf dem Server eingerichtet.",
                       links: [("Rechtliche Hinweise", "https://weatherkit.apple.com/legal-attribution.html")])
            }
            if let attribution = forecast?.attribution, !attribution.isEmpty {
                Section("Vom Server gemeldet") {
                    ForEach(attribution, id: \.self) { item in
                        if let url = URL(string: item.url) {
                            Link(item.text, destination: url)
                        } else {
                            Text(item.text)
                        }
                    }
                }
            }
            Section {
                Text("Konsens (Median), Spannbreite, Regenhinweise und Tageswerte berechnet Witterung aus den Quelldaten. Diese Werte sind gegenüber den Quellen verändert. Warnungen des DWD werden unverändert angezeigt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Datenquellen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
    }

    private func source(_ name: String, _ text: String, links: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(links, id: \.1) { title, url in
                    // borderless: sonst löst ein Tipp in der Zeile alle Links aus
                    Link(title, destination: URL(string: url)!).font(.subheadline).buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
