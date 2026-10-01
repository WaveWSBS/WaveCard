import SwiftUI

@main
struct AirCardApp: App {
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
