import Foundation
import Testing
@testable import PrivyCore

actor DeterministicVADModel: VADModelProcessing {
    typealias StreamState = Int

    struct Call: Sendable, Equatable {
        let samples: [Float]
        let inputState: Int
    }

    private var calls: [Call] = []
    private var makeStateCount = 0
    private var probabilities: [Float]
    private var boundaries: [VADEventKind?]
    private var shouldFail = false
    private let delay: Duration?

    init(
        probabilities: [Float] = [0.1, 0.9, 0.2],
        boundaries: [VADEventKind?] = [nil, .speechStart, .speechEnd],
        delay: Duration? = nil
    ) {
        self.probabilities = probabilities
        self.boundaries = boundaries
        self.delay = delay
    }

    func setFailure(_ value: Bool) { shouldFail = value }

    func makeStreamState() async -> Int {
        makeStateCount += 1
        return 0
    }

    func processStreamingChunk(
        _ samples: [Float],
        state: Int,
        config: VADModelConfig
    ) async throws -> VADModelResult<Int> {
        if let delay { try await Task.sleep(for: delay) }
        if shouldFail { throw FakeVADError.failed }
        calls.append(Call(samples: samples, inputState: state))
        let index = calls.count - 1
        return VADModelResult(
            state: state + 1,
            probability: probabilities[index % probabilities.count],
            boundary: boundaries[index % boundaries.count]
        )
    }

    func recordedCalls() -> [Call] { calls }
    func stateResetCount() -> Int { makeStateCount }
}

private enum FakeVADError: Error { case failed }

private func vadBlock(
    count: Int,
    start: Int64,
    sequence: UInt64,
    mono: Double,
    epoch: UUID = UUID(uuidString: "AAAA0000-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
) -> AudioBlock16k {
    AudioBlock16k(
        captureEpoch: UUID(uuidString: "FFFF0000-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        sequence: sequence,
        streamSampleStart: start,
        firstSampleTime: ClockReading(
            wallUTC: Date(timeIntervalSince1970: 1_700_000_000 + mono),
            monotonicSeconds: mono,
            clockEpoch: epoch
        ),
        samples: (0 ..< count).map(Float.init)
    )
}

@Suite struct VADServiceTests {
    @Test func arbitraryBlocksBecomeExactWindowsWithLeftoverCarryAndStatePassThrough() async throws {
        let model = DeterministicVADModel()
        let service = VADService(model: model)
        await service.prepare()

        let first = try await service.process(vadBlock(count: 1_000, start: 10_000, sequence: 0, mono: 50))
        #expect(first.isEmpty)
        let second = try await service.process(vadBlock(count: 5_500, start: 11_000, sequence: 1, mono: 50.0625))
        #expect(second.count == 1)
        let third = try await service.process(vadBlock(count: 1_692, start: 16_500, sequence: 2, mono: 50.40625))
        #expect(third.count == 1)

        let calls = await model.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.samples.count == 4_096 })
        #expect(calls.map(\.inputState) == [0, 1])
        #expect(calls[0].samples.first == 0)
        #expect(calls[0].samples[999] == 999)
        #expect(calls[0].samples[1_000] == 0)
        #expect(calls[1].samples.first == 3_096)
    }

    @Test func observationsUseSourceWindowEndAndMonotonicTimeNotCompletionTime() async throws {
        let model = DeterministicVADModel(
            probabilities: [0.75],
            boundaries: [.speechStart],
            delay: .milliseconds(20)
        )
        let service = VADService(model: model)
        await service.prepare()
        let observations = try await service.process(vadBlock(
            count: 4_096,
            start: 57_599_000,
            sequence: 5,
            mono: 3_599.5
        ))
        let observation = try #require(observations.first)
        #expect(observation.streamSampleIndex == 57_603_096)
        #expect(observation.monotonicSeconds == 3_599.756)
        #expect(observation.probability == 0.75)
        #expect(observation.boundary == .speechStart)
    }

    @Test func gapResetDiscardsLeftoverAndRestartsReturnedStateChain() async throws {
        let model = DeterministicVADModel()
        let service = VADService(model: model)
        await service.prepare()
        _ = try await service.process(vadBlock(count: 2_000, start: 0, sequence: 0, mono: 0))
        await service.reset(afterGapAt: vadBlock(count: 1, start: 2_000, sequence: 1, mono: 1).firstSampleTime)
        let observations = try await service.process(vadBlock(count: 4_096, start: 20_000, sequence: 9, mono: 10))

        #expect(observations.count == 1)
        #expect(observations[0].streamSampleIndex == 24_096)
        #expect((await model.recordedCalls()).map(\.inputState) == [0])
        #expect(await model.stateResetCount() == 2)
    }

    @Test func sourceDiscontinuityDefensivelyResetsWithoutJoiningAudio() async throws {
        let model = DeterministicVADModel()
        let service = VADService(model: model)
        await service.prepare()
        _ = try await service.process(vadBlock(count: 3_000, start: 0, sequence: 0, mono: 0))
        let observations = try await service.process(vadBlock(count: 4_096, start: 9_000, sequence: 3, mono: 1))
        #expect(observations.count == 1)
        #expect(observations[0].streamSampleIndex == 13_096)
        #expect(await model.stateResetCount() == 2)
    }

    @Test func preparationAndRuntimeFailureAreVisibleButSubsequentBlocksDoNotThrow() async throws {
        let model = DeterministicVADModel()
        let service = VADService(model: model)
        #expect(await service.status() == .notStarted)
        await service.prepare()
        #expect(await service.status() == .ready)

        await model.setFailure(true)
        await #expect(throws: FakeVADError.self) {
            try await service.process(vadBlock(count: 4_096, start: 0, sequence: 0, mono: 0))
        }
        guard case .failed = await service.status() else {
            Issue.record("runtime model failure must become visible")
            return
        }
        let ignored = try await service.process(vadBlock(count: 4_096, start: 4_096, sequence: 1, mono: 0.256))
        #expect(ignored.isEmpty)
    }
}
