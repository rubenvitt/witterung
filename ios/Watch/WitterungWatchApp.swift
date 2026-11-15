import SwiftUI

@main
struct WitterungWatchApp: App {
    @State private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchSync.shared.activate()
        _model = State(initialValue: WatchModel())
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .environment(\.locale, Fmt.locale)
                .environment(\.timeZone, Fmt.timeZone)
                .environment(\.calendar, Fmt.calendar)
                .onOpenURL { url in
                    // Komplikation: witterung://place/<id|current>
                    guard url.host() == "place", let id = url.pathComponents.last else { return }
                    model.opened = id == "current" ? .current : .saved(Int(id) ?? -1)
                }
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
