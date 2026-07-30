import Foundation
import Observation
import PrivyCore

/// Main-actor projection of the newest pipeline truth for SwiftUI.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: PipelineSnapshot?
    private(set) var bootstrapError: String?
    private(set) var audioDirectory: URL?
    private(set) var supportDirectory: URL?
    private(set) var isShuttingDown = false
    private(set) var launchAtLoginEnabled = LoginItem.isRegistered
    private(set) var loginItemError: String?

    func apply(_ snapshot: PipelineSnapshot) {
        self.snapshot = snapshot
        bootstrapError = nil
    }

    func setStorageLayout(_ layout: StorageLayout) {
        supportDirectory = layout.rootDirectory
        audioDirectory = layout.audioDirectory
    }

    func reportBootstrapError(_ message: String) {
        guard snapshot == nil else { return }
        bootstrapError = message
    }

    func beginShutdown() {
        isShuttingDown = true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLoginEnabled = LoginItem.isRegistered
            loginItemError = nil
        } catch {
            launchAtLoginEnabled = LoginItem.isRegistered
            loginItemError = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    var statusTitle: String {
        guard let snapshot else {
            return bootstrapError == nil ? "Starting" : "Error"
        }
        return switch snapshot.capture {
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Paused"
        case .recovering: "Recovering"
        case .error: "Error"
        case .stopped: "Stopped"
        }
    }

    var statusDetail: String? {
        guard let snapshot else { return bootstrapError }
        switch snapshot.capture {
        case .starting:
            return "Preparing audio capture"
        case .recording:
            return switch snapshot.vad {
            case .notStarted, .preparingModel: "Preparing speech model — recording continues"
            case .ready: nil
            case .failed(let message): "Speech model unavailable — recording continues: \(message)"
            }
        case .paused(let untilUTC):
            guard let untilUTC else { return "Until resumed" }
            return "Resumes \(untilUTC.formatted(date: .omitted, time: .shortened))"
        case .recovering(let message), .error(let message):
            return message
        case .stopped:
            return isShuttingDown ? "Finishing orderly shutdown" : nil
        }
    }

    var accessibilityStatus: String {
        [statusTitle, statusDetail].compactMap { $0 }.joined(separator: " — ")
    }

    var iconName: String {
        guard let snapshot else {
            return bootstrapError == nil ? "arrow.clockwise.circle" : "exclamationmark.triangle.fill"
        }
        return switch snapshot.capture {
        case .starting, .recovering: "arrow.clockwise.circle"
        case .recording: "waveform.circle.fill"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    var canPause: Bool {
        guard !isShuttingDown, let capture = snapshot?.capture else { return false }
        return switch capture {
        case .starting, .recording, .recovering: true
        case .paused, .error, .stopped: false
        }
    }

    var canResume: Bool {
        guard !isShuttingDown, let capture = snapshot?.capture else { return false }
        if case .paused = capture { return true }
        return false
    }

    var currentChunkElapsed: String {
        guard let seconds = snapshot?.currentChunk?.durationSeconds else { return "—" }
        return Self.duration(seconds)
    }

    var bytesRecordedToday: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: snapshot?.bytesRecordedToday ?? 0)
    }

    var recentHealth: [HealthEvent] {
        Array((snapshot?.recentHealth ?? []).sorted { $0.atUTC > $1.atUTC }.prefix(3))
    }

    func healthText(_ event: HealthEvent) -> String {
        let time = event.atUTC.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(event.kind.rawValue) · \(event.detail.message)"
    }

    private static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
