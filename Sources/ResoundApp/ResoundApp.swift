import SwiftUI

@main
struct ResoundApp: App {
    @StateObject private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup("Resound") {
            RootView()
                .environmentObject(recorder)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { recorder.startWatching() }
        }
        .windowStyle(.titleBar)
    }
}
