import ServiceManagement
import SwiftUI

struct MenuView: View {
    private var spike: CaptureSpike { CaptureSpike.shared }

    var body: some View {
        Text(spike.statusText)
        Text("frames: \(spike.frameCount)")
        Divider()
        Button(loginItemTitle) { LoginItem.toggle() }
        Button("Reveal log") {
            NSWorkspace.shared.activateFileViewerSelecting([SpikeLog.url])
        }
        Divider()
        Button("Quit Privy") { NSApp.terminate(nil) }
    }

    private var loginItemTitle: String {
        LoginItem.isRegistered ? "Disable launch at login" : "Enable launch at login"
    }
}
