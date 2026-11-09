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
            .sheet(isPresented: $adding) { AddPlaceView() }
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
        let now = forecast?.now.forecast
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

/// Ortssuche über MapKit, Ergebnis geht per POST an den Server.
private struct AddPlaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    Task {
                        await model.addPlace(name: item.name ?? query, coordinate: item.location.coordinate)
                        dismiss()
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "").font(.headline)
                        if let address = item.address?.shortAddress ?? item.address?.fullAddress {
                            Text(address).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if results.isEmpty, !query.isEmpty, !searching {
                    ContentUnavailableView.search(text: query)
                } else if query.isEmpty {
                    ContentUnavailableView("Ort suchen", systemImage: "magnifyingglass", description: Text("Stadt, Ortsteil oder Adresse"))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stadt oder Adresse")
            .task(id: query) { await search() }
            .navigationTitle("Ort hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(300)) // tippen lassen
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
                                            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10))
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }
}
