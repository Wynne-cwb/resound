import SwiftUI

@main
struct ResoundApp: App {
    var body: some Scene {
        WindowGroup("Resound") {
            RootView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}
