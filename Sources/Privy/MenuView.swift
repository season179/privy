import AppKit
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel
    let coordinator: AppCoordinator

    var body: some View {
        Text(model.statusTitle)
            .font(.headline)
            .accessibilityLabel(model.accessibilityStatus)
        if let detail = model.statusDetail {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()
        Text("Current chunk: \(model.currentChunkElapsed)")
            .accessibilityLabel("Current chunk elapsed, \(model.currentChunkElapsed)")
        Text("Recorded today: \(model.bytesRecordedToday)")
            .accessibilityLabel("Bytes recorded today, \(model.bytesRecordedToday)")

        Divider()
        Text("Recent health")
            .font(.caption)
        if model.recentHealth.isEmpty {
            Text("No health events yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(model.recentHealth.enumerated()), id: \.offset) { _, event in
                Text(model.healthText(event))
                    .lineLimit(2)
            }
        }

        Divider()
        Menu("Pause Recording") {
            Button("Pause 15 min") {
                Task { await coordinator.pause(for: .seconds(15 * 60)) }
            }
            Button("Pause 1 h") {
                Task { await coordinator.pause(for: .seconds(60 * 60)) }
            }
            Button("Pause until resumed") {
                Task { await coordinator.pause(for: nil) }
            }
        }
        .disabled(!model.canPause)
        .accessibilityLabel("Pause recording")

        Button("Resume") {
            Task { await coordinator.resume() }
        }
        .disabled(!model.canResume)
        .accessibilityLabel("Resume recording")

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            )
        )
        .accessibilityLabel("Launch Privy at login")

        if let loginError = model.loginItemError {
            Text(loginError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Divider()
        Button("Reveal Audio") {
            reveal(model.audioDirectory)
        }
        .disabled(model.audioDirectory == nil)
        .accessibilityLabel("Reveal Privy audio folder in Finder")

        Button("Reveal App Support and Logs") {
            reveal(model.supportDirectory)
        }
        .disabled(model.supportDirectory == nil)
        .accessibilityLabel("Reveal Privy application support and health log location in Finder")

        Divider()
        Button(model.isShuttingDown ? "Quitting…" : "Quit Privy") {
            NSApp.terminate(nil)
        }
        .disabled(model.isShuttingDown)
        .keyboardShortcut("q")
        .accessibilityLabel("Quit Privy after closing the current recording")
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
