import SwiftUI

@main
struct WaveCardApp: App {
    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
        }
    }
}
