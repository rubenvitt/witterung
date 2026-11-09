import AuthenticationServices
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showPlaces = false
    @State private var showSettings = false
    @State private var radarFor: PlaceRef?
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var model = model
        if !model.signedIn {
            SignInView()
        } else {
            NavigationStack(path: $path) {
                ZStack {
                    background.ignoresSafeArea()
                    if model.pages.isEmpty {
                        emptyState
                    } else {
                        TabView(selection: $model.selection) {
                            ForEach(model.pages, id: \.self) { ref in
                                PlaceView(ref: ref).tag(Optional(ref))
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .ignoresSafeArea(edges: .top)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: ComparisonRoute.self) { ComparisonView(route: $0) }
                .navigationDestination(for: AttributionRoute.self) { AttributionView(route: $0) }
            }
            .environment(\.colorScheme, .dark)
            .sheet(isPresented: $showPlaces) { PlacesView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $radarFor) { ref in RadarView(ref: ref) }
            .onOpenURL { url in
                // Widget-Tipp: witterung://place/<id|current>
                guard url.host() == "place", let id = url.pathComponents.last else { return }
                let ref: PlaceRef = id == "current" ? .current : .saved(Int(id) ?? -1)
                if model.pages.contains(ref) { model.selection = ref }
            }
            #if DEBUG
            .task { await openDebugScreen() }
            #endif
            .alert("Fehler", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
        }
    }

    /// Hintergrund der gewählten Seite, damit der Rand beim Blättern nicht schwarz blitzt.
    private var background: some View {
        let f = model.selection.flatMap { model.forecasts[$0] }
        let condition = f?.now.forecast?.condition ?? .cloudy
        return Theme.gradient(condition, isDay: f?.now.forecast?.isDay ?? true)
            .animation(.easeInOut(duration: 0.6), value: model.selection)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch kein Ort", systemImage: "mappin.and.ellipse")
        } description: {
            Text("Lege einen Ort an oder erlaube den Standortzugriff.")
        } actions: {
            Button("Ort hinzufügen") { showPlaces = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                radarFor = model.selection
            } label: {
                Image(systemName: "map")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Regenradar")
            .disabled(model.selection == nil)

            Spacer()
            PageDots(pages: model.pages, selection: model.selection)
            Spacer()

            Menu {
                Button("Orte verwalten", systemImage: "list.bullet") { showPlaces = true }
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Orte und Einstellungen")
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .background(.ultraThinMaterial.opacity(0.8))
    }
}

#if DEBUG
extension RootView {
    /// Screenshots ohne UI-Automation: `-page 1 -screen radar|places|settings|comparison|days|attribution`.
    private func openDebugScreen() async {
        try? await Task.sleep(for: .seconds(2)) // Orte vom Server abwarten
        if let page = DebugArgs.value("-page").flatMap(Int.init), model.pages.indices.contains(page) {
            model.selection = model.pages[page]
        }
        guard let screen = DebugArgs.value("-screen"), let ref = model.selection else { return }
        try? await Task.sleep(for: .seconds(1))
        switch screen {
        case "radar": radarFor = ref
        case "places": showPlaces = true
        case "settings": showSettings = true
        case "comparison": path.append(ComparisonRoute(ref: ref))
        case "days": path.append(ComparisonRoute(ref: ref, day: model.forecasts[ref]?.daily.dropFirst().first?.date))
        case "attribution": path.append(AttributionRoute(ref: ref))
        default: break
        }
    }
}

enum DebugArgs {
    static func value(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
#endif

private struct PageDots: View {
    let pages: [PlaceRef]
    let selection: PlaceRef?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(pages, id: \.self) { ref in
                Group {
                    if ref == .current {
                        Image(systemName: "location.fill").font(.system(size: 9))
                    } else {
                        Circle().frame(width: 7, height: 7)
                    }
                }
                .opacity(ref == selection ? 1 : 0.4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let selection, let index = pages.firstIndex(of: selection) else { return "" }
        return "Seite \(index + 1) von \(pages.count)"
    }
}

extension PlaceRef: Identifiable {
    var id: String { cacheKey }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var busy = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.gradient(.partlyCloudy, isDay: true).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 88))
                Text("Witterung")
                    .font(.largeTitle.bold())
                Text("Wetter aus mehreren Quellen, mit Konsens und Spannbreite.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
                Button {
                    busy = true
                    Task {
                        let session = webAuth
                        await model.signIn(session: WebAuthenticationSessionProxy { server in
                            try await DeviceSignIn.run(server: server, session: session)
                        })
                        busy = false
                    }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Text("Anmelden") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                .disabled(busy)

                Button("Server: \(model.serverURL.host() ?? "")") { showSettings = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}
