import AVFoundation
import Foundation
import Observation

/// Thread-safe frame counter the audio tap can write to.
/// Spike only — M1 proper replaces the tap body with a lock-free ring buffer (req 4).
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ n: Int) {
        lock.lock()
        value += n
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Day-1 spike: prove that a signed, LSUIElement menu bar app gets mic
/// permission once, keeps it across rebuilds, and receives audio frames.
@MainActor
@Observable
final class CaptureSpike {
    static let shared = CaptureSpike()

    private(set) var statusText = "starting…"
    private(set) var frameCount = 0

    private let engine = AVAudioEngine()
    private let counter = FrameCounter()
    private var pollTask: Task<Void, Never>?

    func start() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let before = AVCaptureDevice.authorizationStatus(for: .audio)
        SpikeLog.log("launch build=\(build) authAtLaunch=\(label(before))")
        statusText = "auth: \(label(before))"

        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            SpikeLog.log("requestAccess granted=\(granted)")
            guard granted else {
                statusText = "mic access denied"
                return
            }
            startEngine()
        }
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            statusText = "no input device"
            SpikeLog.log("engine error: no input device (sampleRate=0)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [counter] buffer, _ in
            counter.add(Int(buffer.frameLength))
        }
        do {
            try engine.start()
        } catch {
            statusText = "engine error"
            SpikeLog.log("engine error: \(error)")
            return
        }
        statusText = "capturing (spike)"
        SpikeLog.log("engine started sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

        pollTask = Task { @MainActor [weak self] in
            var loggedProof = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.frameCount = self.counter.current
                if !loggedProof && self.frameCount > 0 {
                    SpikeLog.log("frames=\(self.frameCount) — capture confirmed")
                    loggedProof = true
                }
            }
        }
    }

    private func label(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }
}
