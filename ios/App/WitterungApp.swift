import SwiftUI

@main
struct WitterungApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Simulator/Screenshots: `-server http://127.0.0.1:8081` setzt den Server ohne Tippen.
        if let url = DebugArgs.value("-server").flatMap(URL.init(string:)) { SharedStore.serverURL = url }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-widgetGallery") {
                    WidgetGallery()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(model)
            .environment(\.locale, Fmt.locale)
            .environment(\.timeZone, Fmt.timeZone)
            .environment(\.calendar, Fmt.calendar)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.start() }
            case .background: model.location.stop()
            default: break
            }
        }
    }
}
