import SwiftUI
import UIKit

@main
struct PhoenixApp: App {
    @StateObject private var model = AppModel()

    init() { SecurityBoot.boot() }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        model.markForeground()
                    case .background:
                        model.markBackground()
                    default:
                        break
                    }
                }
        }
    }
}
