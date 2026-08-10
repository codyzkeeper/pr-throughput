import AppKit
import SwiftUI

@main
struct PRThroughputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(model: model)
        statusItemController = controller
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            controller.showPopover()
        }
        Task { await model.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showPopover()
        return false
    }
}
