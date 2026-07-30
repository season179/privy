import AppKit
import SwiftUI

@main
struct PrivyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Privy", systemImage: "waveform") {
            MenuView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureSpike.shared.start()
    }
}
