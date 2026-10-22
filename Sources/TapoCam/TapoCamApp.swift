import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window quits the app, so streams never keep running hidden.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TapoCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Câmeras", id: "main") {
            ContentView()
                .environmentObject(model.store)
                .environmentObject(model.location)
                .environmentObject(model.sync)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultLaunchBehavior(.presented)
    }
}

/// Owns the app-wide objects (sync needs the other two).
@MainActor
final class AppModel: ObservableObject {
    let store = CameraStore()
    let location = NetworkLocation()
    let sync: PCSync

    init() {
        sync = PCSync(store: store, location: location)
    }
}
