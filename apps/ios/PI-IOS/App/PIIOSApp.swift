import SwiftUI

@main
struct PIIOSApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var appearanceStore = AppearanceStore()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(model)
                .environmentObject(model.connection)
                .environmentObject(appearanceStore)
                .tint(PIColor.accent)
                .preferredColorScheme(appearanceStore.mode.colorScheme)
        }
    }
}
