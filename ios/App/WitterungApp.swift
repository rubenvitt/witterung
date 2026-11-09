import SwiftUI

@main
struct WitterungApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
