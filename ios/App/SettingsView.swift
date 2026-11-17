import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var server = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://witterung.rubeen.dev", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.setServer(server) }
                    if server != model.serverURL.absoluteString {
                        Button("Server übernehmen") { model.setServer(server) }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Bei localhost (Dev-Server) entfällt die Anmeldung. Ein Wechsel meldet ab und leert den Cache.")
                }

                Section("Konto") {
                    if !API.needsAuth(model.serverURL) {
                        Label("Dev-Server ohne Anmeldung", systemImage: "hammer")
                    } else if model.signedIn {
                        Label("Angemeldet", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Abmelden", role: .destructive) { model.signOut() }
                    } else {
                        Button("Anmelden") {
                            let session = webAuth
                            Task {
                                await model.signIn(session: WebAuthenticationSessionProxy { server in
                                    try await DeviceSignIn.run(server: server, session: session)
                                })
                            }
                        }
                    }
                }

                Section {
                    Toggle("Kalender einbeziehen", isOn: Binding(
                        get: { model.calendarEnabled },
                        set: { enabled in Task { await model.setCalendarEnabled(enabled) } }))
                } header: {
                    Text("Termine")
                } footer: {
                    Text("Termine mit Ort oder draußen (z. B. Hundeschule, Training) der nächsten 36 Stunden bekommen Hinweise wie „Regen zu …“. Termine bleiben auf dem Gerät; zum Server geht nur „Termin draußen um 15:00“, nie der Name.")
                }

                Section {
                    Toggle("Live-Aktivitäten", isOn: Binding(
                        get: { model.liveActivitiesEnabled },
                        set: { enabled in Task { await model.setLiveActivitiesEnabled(enabled) } }))
                } header: {
                    Text("Sperrbildschirm")
                } footer: {
                    Text("Regen laut Radar in der nächsten Stunde (Countdown bis Beginn, dann bis zum Ende) und Unwetterwarnungen des DWD erscheinen auf dem Sperrbildschirm und in der Dynamic Island, für die erste Seite. Mit Push auf dem Server auch, wenn die App geschlossen ist.")
                }

                Section {
                    if let summary = model.habits.summary {
                        Text(summary).font(.subheadline)
                    } else {
                        Text("Noch keine Vorlieben – Witterung lernt aus deinen Taps auf Karten und „Im Blick“.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("Vorlieben zurücksetzen", role: .destructive) { model.resetHabits() }
                } header: {
                    Text("Gelernt")
                } footer: {
                    Text("Häufig Angetipptes rückt etwas nach vorn. Verblasst nach einigen Wochen und bleibt auf dem Gerät; zum Server geht nur die Kurzfassung oben.")
                }

                Section("Info") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    LabeledContent("Einheiten", value: "°C, mm, km/h, hPa")
                    LabeledContent("Zeitzone", value: "Europe/Berlin")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .onAppear { server = model.serverURL.absoluteString }
        }
    }
}
