import Foundation
import Testing
@testable import PrivyCore

@Suite struct FluidAudioVADSmokeTests {
    @Test func realModelDownloadsOrLoadsCacheThenReopensFromCache() async throws {
        guard ProcessInfo.processInfo.environment["PRIVY_VAD_SMOKE"] == "1" else {
            print("SKIP: set PRIVY_VAD_SMOKE=1 to run FluidAudio model download/cache smoke test")
            return
        }

        let first = VADService<FluidAudioVADAdapter>(factory: {
            try await FluidAudioVADAdapter.load()
        })
        await first.prepare()
        guard case .ready = await first.status() else {
            Issue.record("FluidAudio VAD did not become ready: \(await first.status())")
            return
        }
        let block = AudioBlock16k(
            captureEpoch: UUID(),
            sequence: 0,
            streamSampleStart: 0,
            firstSampleTime: ClockReading(
                wallUTC: Date(),
                monotonicSeconds: 0,
                clockEpoch: UUID()
            ),
            samples: [Float](repeating: 0, count: 4_096)
        )
        #expect(try await first.process(block).count == 1)

        let modelDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("FluidAudio", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
        let cachedFiles = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        #expect(!cachedFiles.isEmpty, "first load must leave a reusable model cache")

        // A second independent manager exercises FluidAudio's cached/offline-reuse path:
        // it must initialize and infer without requiring a fresh model artifact.
        let second = VADService<FluidAudioVADAdapter>(factory: {
            try await FluidAudioVADAdapter.load()
        })
        await second.prepare()
        guard case .ready = await second.status() else {
            Issue.record("cached FluidAudio VAD did not reopen: \(await second.status())")
            return
        }
        #expect(try await second.process(block).count == 1)
    }
}
