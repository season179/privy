import FluidAudio
import Foundation

struct VADModelResult<State: Sendable>: Sendable {
    let state: State
    let probability: Float
    let boundary: VADEventKind?
}

typealias VADModelConfig = VadSegmentationConfig

/// Narrow seam around FluidAudio's streaming API. The associated state is deliberately
/// opaque: `VADService` passes the exact value returned by one call into the next.
protocol VADModelProcessing: Sendable {
    associatedtype StreamState: Sendable

    func makeStreamState() async -> StreamState
    func processStreamingChunk(
        _ samples: [Float],
        state: StreamState,
        config: VADModelConfig
    ) async throws -> VADModelResult<StreamState>
}

actor VADService<Model: VADModelProcessing>: VADAnalyzing {
    static var windowSamples: Int { 4096 }

    private let config: VADModelConfig
    private let factory: (@Sendable () async throws -> Model)?
    private var model: Model?
    private var streamState: Model.StreamState?
    private var runtimeStatus: VADRuntimeStatus = .notStarted

    private var pendingSamples: [Float] = []
    private var pendingStreamStart: Int64?
    private var pendingMonotonicStart: Double?
    private var pendingClockEpoch: UUID?
    private var expectedStreamStart: Int64?

    init(model: Model, config: VADModelConfig = .default) {
        self.model = model
        self.factory = nil
        self.config = config
    }

    init(
        config: VADModelConfig = .default,
        factory: @escaping @Sendable () async throws -> Model
    ) {
        self.model = nil
        self.factory = factory
        self.config = config
    }

    func prepare() async {
        guard runtimeStatus != .preparingModel, runtimeStatus != .ready else { return }
        runtimeStatus = .preparingModel

        do {
            if model == nil, let factory {
                // A caller may be main-actor isolated. Detached construction guarantees
                // FluidAudio model discovery/download and Core ML loading never run there.
                model = try await Task.detached(priority: .utility) {
                    try await factory()
                }.value
            }
            guard let model else {
                throw VADServiceError.modelUnavailable
            }
            streamState = await model.makeStreamState()
            runtimeStatus = .ready
        } catch {
            clearContinuity()
            runtimeStatus = .failed(String(describing: error))
        }
    }

    func status() -> VADRuntimeStatus {
        runtimeStatus
    }

    func process(_ block: AudioBlock16k) async throws -> [VADObservation] {
        guard case .ready = runtimeStatus,
              let model,
              var state = streamState else {
            return []
        }
        guard block.samples.allSatisfy(\.isFinite) else {
            clearContinuity()
            runtimeStatus = .failed("audio block contains a non-finite sample")
            throw VADServiceError.nonFiniteAudio
        }
        guard !block.samples.isEmpty else { return [] }

        if expectedStreamStart != nil,
           (expectedStreamStart != block.streamSampleStart || pendingClockEpoch != block.firstSampleTime.clockEpoch) {
            clearContinuity()
            state = await model.makeStreamState()
        }

        if pendingSamples.isEmpty {
            pendingStreamStart = block.streamSampleStart
            pendingMonotonicStart = block.firstSampleTime.monotonicSeconds
            pendingClockEpoch = block.firstSampleTime.clockEpoch
        }
        pendingSamples.append(contentsOf: block.samples)
        expectedStreamStart = block.streamSampleStart + Int64(block.samples.count)

        var observations: [VADObservation] = []
        var consumed = 0

        do {
            while pendingSamples.count - consumed >= Self.windowSamples {
                let end = consumed + Self.windowSamples
                let window = Array(pendingSamples[consumed ..< end])
                assert(window.count == Self.windowSamples)
                let result = try await model.processStreamingChunk(
                    window,
                    state: state,
                    config: config
                )
                state = result.state

                guard let streamStart = pendingStreamStart,
                      let monotonicStart = pendingMonotonicStart else {
                    throw VADServiceError.missingTimeline
                }
                observations.append(VADObservation(
                    streamSampleIndex: streamStart + Int64(end),
                    monotonicSeconds: monotonicStart + Double(end) / Double(privySampleRate),
                    probability: result.probability,
                    boundary: result.boundary
                ))
                consumed = end
            }
        } catch {
            clearContinuity()
            runtimeStatus = .failed(String(describing: error))
            throw error
        }

        if consumed > 0 {
            pendingSamples.removeFirst(consumed)
            pendingStreamStart = pendingStreamStart.map { $0 + Int64(consumed) }
            pendingMonotonicStart = pendingMonotonicStart.map {
                $0 + Double(consumed) / Double(privySampleRate)
            }
        }
        streamState = state
        return observations
    }

    func reset(afterGapAt: ClockReading) async {
        clearContinuity()
        if case .ready = runtimeStatus, let model {
            streamState = await model.makeStreamState()
        }
    }

    private func clearContinuity() {
        pendingSamples.removeAll(keepingCapacity: true)
        pendingStreamStart = nil
        pendingMonotonicStart = nil
        pendingClockEpoch = nil
        expectedStreamStart = nil
        streamState = nil
    }
}

private enum VADServiceError: Error {
    case modelUnavailable
    case nonFiniteAudio
    case missingTimeline
}

/// Concrete Sendable adapter for FluidAudio 0.15.5. `VadManager` and its recurrent
/// `VadStreamState` never escape this actor.
actor FluidAudioVADAdapter: VADModelProcessing {
    typealias StreamState = VadStreamState

    private let manager: VadManager

    private init(manager: VadManager) {
        self.manager = manager
    }

    static func load() async throws -> FluidAudioVADAdapter {
        FluidAudioVADAdapter(manager: try await VadManager())
    }

    func makeStreamState() async -> VadStreamState {
        await manager.makeStreamState()
    }

    func processStreamingChunk(
        _ samples: [Float],
        state: VadStreamState,
        config: VADModelConfig
    ) async throws -> VADModelResult<VadStreamState> {
        precondition(samples.count == VADService<FluidAudioVADAdapter>.windowSamples)
        let result = try await manager.processStreamingChunk(
            samples,
            state: state,
            config: config,
            returnSeconds: false,
            timeResolution: 1
        )
        let boundary: VADEventKind? = switch result.event?.kind {
        case .speechStart: .speechStart
        case .speechEnd: .speechEnd
        case nil: nil
        }
        return VADModelResult(
            state: result.state,
            probability: result.probability,
            boundary: boundary
        )
    }
}
