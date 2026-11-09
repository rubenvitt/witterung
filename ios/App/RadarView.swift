import MapKit
import SwiftUI

final class RadarTileOverlay: MKTileOverlay {
    let base: URL
    let layer: String
    let time: Date

    init(base: URL, layer: String, time: Date) {
        self.base = base
        self.layer = layer
        self.time = time
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Doppelte Auflösung für Retina-Displays.
        WMSTile.url(base: base, layer: layer, time: time, x: path.x, y: path.y, z: path.z, pixels: 256 * Int(path.contentScaleFactor.rounded()))
    }
}

struct RadarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: PlaceRef

    @State private var radar: RadarInfo?
    @State private var index = 0
    @State private var playing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                RadarMap(center: model.coordinate(ref), radar: radar, frame: radar.map { $0.frames[min(index, $0.frames.count - 1)] })
                    .ignoresSafeArea()
                controls
            }
            .navigationTitle("Regenradar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .task { await load() }
            .task(id: playing) { await play() }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let radar, !radar.frames.isEmpty {
                let frame = radar.frames[min(index, radar.frames.count - 1)]
                let isForecast = index > radar.lastMeasured
                HStack {
                    Button {
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(playing ? "Anhalten" : "Abspielen")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.time(frame)).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(isForecast ? "Vorhersage" : "Messung")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isForecast ? .orange : .secondary)
                    }
                    Spacer()
                }
                FrameSlider(frames: radar.frames, nowIndex: radar.lastMeasured, index: $index)
                RadarLegend()
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Text("Radar: Deutscher Wetterdienst").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 30) // Platz für den Rechtshinweis von Apple Karten
    }

    private func load() async {
        do {
            let info = try await model.api.radar()
            radar = info
            // Start beim jüngsten gemessenen Bild.
            index = info.lastMeasured
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play() async {
        guard playing, let count = radar?.frames.count, count > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            index = (index + 1) % count
        }
    }
}

/// Zeitleiste: Messung links, Vorhersage rechts (orange markiert).
private struct FrameSlider: View {
    let frames: [Date]
    let nowIndex: Int
    @Binding var index: Int

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                   in: 0...Double(max(1, frames.count - 1)), step: 1)
                .sensoryFeedback(.selection, trigger: index == nowIndex)
                .accessibilityValue(frames.isEmpty ? "" : Fmt.time(frames[min(index, frames.count - 1)]))
            GeometryReader { geo in
                let split = geo.size.width * Double(nowIndex) / Double(max(1, frames.count - 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.4)).frame(width: split, height: 3)
                    Capsule().fill(.orange.opacity(0.8)).frame(width: geo.size.width - split, height: 3).offset(x: split)
                }
            }
            .frame(height: 3)
            HStack {
                Text(frames.first.map(Fmt.time) ?? "")
                Spacer()
                Text("Jetzt")
                Spacer()
                Text(frames.last.map(Fmt.time) ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Farbskala des DWD-Layers (GetLegendGraphic), verdichtet.
private struct RadarLegend: View {
    private static let steps: [(Double, Color)] = [
        (0.1, Color(red: 0, green: 1, blue: 1)), (0.4, Color(red: 0, green: 0.6, blue: 0.23)),
        (1, Color(red: 0.24, green: 0.7, blue: 0.24)), (2, Color(red: 0.55, green: 0.78, blue: 0)),
        (5, Color(red: 1, green: 1, blue: 0)), (10, Color(red: 1, green: 0.59, blue: 0)),
        (15, Color(red: 1, green: 0.39, blue: 0)), (30, Color(red: 1, green: 0, blue: 0)),
        (75, Color(red: 0.78, green: 0, blue: 0.78)), (150, Color(red: 0, green: 0, blue: 1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                ForEach(Self.steps, id: \.0) { Rectangle().fill($0.1) }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack {
                Text("0,1"); Spacer(); Text("1"); Spacer(); Text("5"); Spacer(); Text("15"); Spacer(); Text("75 mm/h")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Farbskala von 0,1 bis über 150 Millimeter pro Stunde")
    }
}

/// MKMapView, weil SwiftUI-`Map` keine Kachel-Overlays kann.
private struct RadarMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D?
    let radar: RadarInfo?
    let frame: Date?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        if let center {
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 300_000, longitudinalMeters: 300_000), animated: false)
            let pin = MKPointAnnotation()
            pin.coordinate = center
            map.addAnnotation(pin)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let radar, let frame, context.coordinator.current?.time != frame else { return }
        let overlay = RadarTileOverlay(base: radar.wms, layer: radar.layer, time: frame)
        map.addOverlay(overlay, level: .aboveRoads)
        let old = context.coordinator.current
        context.coordinator.current = overlay
        // Altes Bild kurz stehen lassen, bis das neue geladen ist (kein Flackern).
        if let old {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                map.removeOverlay(old)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var current: RadarTileOverlay?

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
            renderer.alpha = 0.75
            return renderer
        }
    }
}
