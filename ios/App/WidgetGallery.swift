#if DEBUG
import SwiftUI
import WidgetKit

/// Nur für Screenshots (`-widgetGallery`): die Widget-Ansichten in Originalgröße
/// (iPhone 17 Pro), weil sich Widgets per simctl nicht auf den Home-Bildschirm legen lassen.
struct WidgetGallery: View {
    var body: some View {
        let forecast = ForecastCache.load(.saved(SharedStore.places.first?.id ?? 1)) ?? ForecastCache.load(.current)
        let snapshot = forecast.flatMap { WeatherSnapshot.make($0, at: .now) }
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    tile(snapshot, .systemSmall, CGSize(width: 170, height: 170))
                    VStack(spacing: 12) {
                        lock(snapshot, .accessoryCircular, CGSize(width: 76, height: 76))
                        lock(snapshot, .accessoryInline, CGSize(width: 170, height: 22))
                    }
                }
                tile(snapshot, .systemMedium, CGSize(width: 364, height: 170))
                lock(snapshot, .accessoryRectangular, CGSize(width: 172, height: 76))
                tile(snapshot, .systemLarge, CGSize(width: 364, height: 382))
            }
            .padding()
        }
        .background(Color(white: 0.12).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ s: WeatherSnapshot?, _ family: WidgetFamily, _ size: CGSize) -> some View {
        WeatherWidgetView(snapshot: s, family: family)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Theme.gradient(s?.condition ?? .cloudy, isDay: s?.isDay ?? true))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func lock(_ s: WeatherSnapshot?, _ family: WidgetFamily, _ size: CGSize) -> some View {
        WeatherWidgetView(snapshot: s, family: family)
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
