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
