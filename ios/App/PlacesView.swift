import MapKit
import SwiftUI

struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Place?
    @State private var newName = ""
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if !model.location.denied {
                    Section {
                        row(.current, name: "Mein Standort", icon: "location.fill")
                    }
                }
                Section {
                    ForEach(model.places) { place in
                        row(.saved(place.id), name: place.name, icon: nil)
                            .swipeActions(edge: .leading) {
                                Button("Umbenennen", systemImage: "pencil") {
                                    newName = place.name
                                    renaming = place
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button("Umbenennen", systemImage: "pencil") {
                                    newName = place.name
                                    renaming = place
                                }
                                Button(place.notify ? "Mitteilungen aus" : "Mitteilungen an",
                                       systemImage: place.notify ? "bell.slash" : "bell") {
                                    Task { await model.toggleNotify(place) }
                                }
                                Button("Löschen", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(place) }
                                }
                            }
                    }
                    .onDelete { offsets in
                        for place in offsets.map({ model.places[$0] }) { Task { await model.delete(place) } }
                    }
                    .onMove { from, to in Task { await model.move(from: from, to: to) } }
                } header: {
                    Text("Gespeicherte Orte")
                } footer: {
                    Text("Glocke: Mitteilungen bei Warnungen und Regenbeginn für diesen Ort.")
                }
            }
            .navigationTitle("Orte")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ort hinzufügen", systemImage: "plus") { adding = true }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            // Gepusht statt als Sheet im Sheet.
            .navigationDestination(isPresented: $adding) { AddPlaceView { adding = false } }
            .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") {
                    if let place = renaming { Task { await model.rename(place, to: newName) } }
                }
            }
        }
    }

    private func row(_ ref: PlaceRef, name: String, icon: String?) -> some View {
        let forecast = model.forecasts[ref]
        let now = forecast?.currentHour
        return HStack(spacing: 12) {
            Button {
                model.selection = ref
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let icon { Image(systemName: icon).font(.caption) }
                            Text(name).font(.headline)
                        }
                        if let now {
                            Text(now.condition.label(isDay: now.isDay ?? true)).font(.subheadline).opacity(0.8)
                        }
                    }
                    Spacer()
                    if let now {
                        Image(systemName: now.condition.symbol(isDay: now.isDay ?? true)).symbolRenderingMode(.multicolor)
                        Text(Fmt.temp(forecast?.now.observed?.tempC ?? now.tempC)).font(.title2).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if case let .saved(id) = ref, let place = model.places.first(where: { $0.id == id }) {
                Button {
                    Task { await model.toggleNotify(place) }
                } label: {
                    Image(systemName: place.notify ? "bell.fill" : "bell.slash")
                        .foregroundStyle(forecast == nil ? AnyShapeStyle(place.notify ? Color.accentColor : .secondary) : AnyShapeStyle(.white.opacity(place.notify ? 1 : 0.6)))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(place.notify ? "Mitteilungen für \(place.name) ausschalten" : "Mitteilungen für \(place.name) einschalten")
                .sensoryFeedback(.selection, trigger: place.notify)
            }
        }
        .padding(.vertical, 6)
        .foregroundStyle(forecast == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
        .listRowBackground(now.map { Theme.gradient($0.condition, isDay: $0.isDay ?? true) })
    }
}

/// Ortssuche mit Vorschlägen beim Tippen (MapKit-Autovervollständigung). Der gewählte
/// Vorschlag wird zu Koordinaten aufgelöst und per POST an den Server geschickt.
private struct AddPlaceView: View {
    @Environment(AppModel.self) private var model
    let onAdded: () -> Void

    @State private var query = ""
    @State private var search = PlaceSearch()
    @State private var adding: MKLocalSearchCompletion?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(search.results, id: \.self) { completion in
                Button {
                    Task { await add(completion) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title).font(.headline)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if adding == completion { ProgressView() }
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .disabled(adding != nil)
            }
        }
        .overlay {
            if search.results.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Ort suchen", systemImage: "magnifyingglass",
                                           description: Text("Stadt, Ortsteil oder Adresse"))
                } else if !search.searching {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stadt oder Adresse")
        .searchFocused($focused)
        .autocorrectionDisabled()
        .onChange(of: query) { _, text in
            error = nil
            search.update(text)
        }
        .onAppear { focused = true }
        .navigationTitle("Ort hinzufügen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(_ completion: MKLocalSearchCompletion) async {
        adding = completion
        defer { adding = nil }
        error = nil
        do {
            let item = try await PlaceSearch.resolve(completion)
            try await model.addPlace(name: item.name ?? completion.title, coordinate: item.location.coordinate)
            onAdded()
        } catch {
            self.error = "„\(completion.title)“ ließ sich nicht hinzufügen: \(error.localizedDescription)"
        }
    }
}

/// Vorschläge von `MKLocalSearchCompleter`; der Completer entprellt das Tippen selbst.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var searching = false
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        // Nur ein Hinweis, Orte außerhalb Deutschlands bleiben auffindbar.
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
                                              span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10))
    }

    func update(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            completer.cancel()
            results = []
            searching = false
            return
        }
        searching = true
        completer.queryFragment = text
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = self.completer.results
            searching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // „Nichts gefunden“ kommt als Fehler; die Ansicht zeigt dann „Keine Ergebnisse“.
        MainActor.assumeIsolated {
            results = []
            searching = false
        }
    }

    /// Koordinaten zu einem Vorschlag.
    static func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else { throw NotFound() }
        return item
    }

    struct NotFound: LocalizedError {
        var errorDescription: String? { "Zu diesem Vorschlag kennt Apple Karten keine Koordinaten." }
    }
}
