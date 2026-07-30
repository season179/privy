import AppKit
import SwiftUI

@main
struct PrivyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model, coordinator: appDelegate.coordinator)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let coordinator: AppCoordinator

    private var launchTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    override init() {
        let model = AppModel()
        self.model = model
        self.coordinator = AppCoordinator(model: model)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchTask = Task { [coordinator] in
            await coordinator.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        model.beginShutdown()
        terminationTask = Task { [coordinator] in
            await coordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
