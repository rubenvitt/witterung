import MapKit
import SwiftUI

/// Radarbilder aller Zeitpunkte. Der Server holt je Zeitpunkt ein Bild für ganz Deutschland
/// beim DWD und hält es vor; hier laden vier gleichzeitig, zuerst um das angezeigte Bild herum.
@MainActor @Observable
final class RadarFrames {
    private(set) var images: [Int: UIImage] = [:]
    private(set) var warnings: UIImage?
    private(set) var message: String?

    var loaded: Int { images.count }

    func load(api: API, radar: RadarInfo, layout: RadarImage, start: Int) async {
        let order = RadarGeometry.loadOrder(count: radar.frames.count, from: start)
        var pending = order.map { ($0, layout.framePath(radar.frames[$0])) }[...]
        await withTaskGroup(of: (Int, Result<UIImage, any Error>).self) { group in
            for _ in 0..<4 {
                guard let next = pending.popFirst() else { break }
                group.addTask { await (next.0, Self.fetch(api, next.1)) }
            }
            for await (i, result) in group {
                switch result {
                case let .success(image):
                    images[i] = image
                    message = nil
                case let .failure(error):
                    if images.isEmpty, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                        message = "Radarbilder laden nicht: \(error.localizedDescription)"
                    }
                }
                if let next = pending.popFirst() {
                    group.addTask { await (next.0, Self.fetch(api, next.1)) }
                }
            }
        }
    }

    func loadWarnings(api: API, layout: RadarImage) async {
        if case let .success(image) = await Self.fetch(api, layout.warnings) { warnings = image }
    }

    /// Lädt und dekodiert abseits des Hauptthreads, damit das Abspielen nicht ruckelt.
    nonisolated private static func fetch(_ api: API, _ path: String) async -> Result<UIImage, any Error> {
        do {
            let data = try await api.image(path)
            guard let image = await UIImage(data: data)?.byPreparingForDisplay() else {
                throw URLError(.cannotDecodeContentData)
            }
            return .success(image)
        } catch {
            return .failure(error)
        }
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
    @State private var frames = RadarFrames()
    @AppStorage("radarShowsWarnings") private var showWarnings = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                RadarMap(center: model.coordinate(ref), bbox: radar?.image?.bbox,
                         radar: frames.images[index], warnings: showWarnings ? frames.warnings : nil)
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
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let radar, !radar.frames.isEmpty {
                let frame = radar.frames[min(index, radar.frames.count - 1)]
                let isForecast = index > radar.lastMeasured
                HStack(spacing: Spacing.s) {
                    Button {
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(playing ? "Anhalten" : "Abspielen")
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(Fmt.time(frame)).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(isForecast ? "Vorhersage" : "Messung")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isForecast ? .orange : .secondary)
                    }
                    Spacer()
                    Toggle(isOn: $showWarnings) {
                        Label("Warnungen", systemImage: "exclamationmark.triangle")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .accessibilityLabel("Wetterwarnungen zeigen")
                }
                FrameSlider(frames: radar.frames, nowIndex: radar.lastMeasured, index: $index)
                RadarLegend()
                if showWarnings { WarningLegend() }
                status(radar)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(Layout.cardPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.cardRadius + 2, style: .continuous))
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 30) // Platz für den Rechtshinweis von Apple Karten
    }

    /// Ladestand, damit eine leere Karte nicht wie „kein Regen“ aussieht.
    @ViewBuilder private func status(_ radar: RadarInfo) -> some View {
        if let message = frames.message {
            Label(message, systemImage: "exclamationmark.triangle").font(.footnote)
        } else if frames.loaded < radar.frames.count {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.mini)
                Text(frames.images[index] == nil
                     ? "Bild lädt … (\(frames.loaded) von \(radar.frames.count))"
                     : "Lade Radarbilder: \(frames.loaded) von \(radar.frames.count)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        let api = model.api
        do {
            let info = try await api.radar()
            radar = info
            // Start beim jüngsten gemessenen Bild.
            index = info.lastMeasured
            guard let layout = info.image else {
                error = "Der Server ist zu alt für die Radarkarte. Bitte den Witterung-Server aktualisieren."
                radar = nil
                return
            }
            async let warnings: Void = frames.loadWarnings(api: api, layout: layout)
            await frames.load(api: api, radar: info, layout: layout, start: info.lastMeasured)
            await warnings
        } catch {
            self.error = error.localizedDescription
            model.handle(error)
        }
    }

    private func play() async {
        guard playing, let count = radar?.frames.count, count > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // Noch fehlende Bilder überspringen statt eine leere Karte zu zeigen.
            if let next = RadarGeometry.nextLoaded(after: index, count: count, isLoaded: { frames.images[$0] != nil }) {
                index = next
            }
        }
    }
}

/// Zeitleiste: Messung links, Vorhersage rechts (orange markiert).
private struct FrameSlider: View {
    let frames: [Date]
    let nowIndex: Int
    @Binding var index: Int

    var body: some View {
        VStack(spacing: Spacing.xs) {
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
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

/// Warnstufen des DWD (Farben der Warnkarte).
private struct WarningLegend: View {
    private static let levels: [(String, Color)] = [
        ("Warnung", Color(red: 1, green: 1, blue: 0)),
        ("markant", Color(red: 0.98, green: 0.66, blue: 0)),
        ("Unwetter", Color(red: 1, green: 0.17, blue: 0)),
        ("extrem", Color(red: 0.69, green: 0, blue: 0.39)),
    ]

    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(Self.levels, id: \.0) { level in
                HStack(spacing: Spacing.xxs) {
                    RoundedRectangle(cornerRadius: 2).fill(level.1).frame(width: 10, height: 10)
                    Text(level.0)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warnstufen: gelb Warnung, orange markant, rot Unwetter, violett extrem")
    }
}

/// Ein Bild über einem festen Kartenausschnitt (Web Mercator, wie MapKit).
final class GeoImageOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    init?(bbox: [Double]) {
        guard let c = RadarGeometry.corners(bbox) else { return nil }
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: c.northWest.lat, longitude: c.northWest.lon))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: c.southEast.lat, longitude: c.southEast.lon))
        boundingMapRect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }
}

/// Zeichnet das jeweils gesetzte Bild; MapKit ruft `draw` auf Hintergrund-Threads auf.
final class GeoImageRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CGImage?

    var image: CGImage? {
        get { lock.withLock { current } }
        set {
            lock.withLock { current = newValue }
            setNeedsDisplay()
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image else { return }
        let rect = self.rect(for: overlay.boundingMapRect)
        context.interpolationQuality = .medium
        // Core Graphics zeichnet Bilder von unten nach oben, die Karte zählt y nach unten.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    }
}

/// MKMapView, weil SwiftUI-`Map` keine Bild-Overlays kann. Ein Overlay je Ebene; beim
/// Bildwechsel tauscht nur das Bild, die Karte lädt nichts neu.
private struct RadarMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D?
    let bbox: [Double]?
    let radar: UIImage?
    let warnings: UIImage?

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
        let c = context.coordinator
        if c.radar == nil, let bbox, let warningsOverlay = GeoImageOverlay(bbox: bbox), let radarOverlay = GeoImageOverlay(bbox: bbox) {
            let warningsRenderer = GeoImageRenderer(overlay: warningsOverlay)
            warningsRenderer.alpha = 0.5
            let radarRenderer = GeoImageRenderer(overlay: radarOverlay)
            radarRenderer.alpha = 0.8
            c.renderers = [ObjectIdentifier(warningsOverlay): warningsRenderer, ObjectIdentifier(radarOverlay): radarRenderer]
            c.warnings = warningsRenderer
            c.radar = radarRenderer
            // Warnungen unter dem Regen, damit der Niederschlag lesbar bleibt.
            map.addOverlay(warningsOverlay, level: .aboveRoads)
            map.addOverlay(radarOverlay, level: .aboveRoads)
        }
        if c.radar?.image !== radar?.cgImage { c.radar?.image = radar?.cgImage }
        if c.warnings?.image !== warnings?.cgImage { c.warnings?.image = warnings?.cgImage }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderers: [ObjectIdentifier: GeoImageRenderer] = [:]
        var radar: GeoImageRenderer?
        var warnings: GeoImageRenderer?

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            renderers[ObjectIdentifier(overlay)] ?? MKOverlayRenderer(overlay: overlay)
        }
    }
}
