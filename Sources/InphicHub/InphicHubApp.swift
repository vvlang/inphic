import InphicCore
import SwiftUI

@main
struct InphicHubApp: App {
    @State private var controller = DeviceController(store: ProfileStore())
    @State private var menuBar = MenuBarController()

    var body: some Scene {
        Window("Inphic Hub", id: "main") {
            ContentView()
                .environment(controller)
                .environment(menuBar)
                .frame(minWidth: 860, minHeight: 620)
                .preferredColorScheme(.dark)
                .task {
                    controller.start()
                    menuBar.attach(to: controller)
                }
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查固件更新…") { }.disabled(true)
            }
        }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(menuBar)
                .preferredColorScheme(.dark)
        }
    }
}
