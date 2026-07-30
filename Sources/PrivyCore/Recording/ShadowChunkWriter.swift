import CryptoKit
import Foundation
import OpusIO

protocol OggOpusWriting: AnyObject {
    var sampleRate: Int32 { get }
    func append(_ samples: [Float]) throws
    func finish() throws
    func durablyCloseWithoutEndOfStream() throws
    func synchronize() throws
}

extension OggOpusWriter: OggOpusWriting {}

actor ShadowChunkWriter: ShadowChunkWriting {
    enum ChunkWriterError: Error, CustomStringConvertible {
        case terminalRecoveryRequired(String)
        case terminalRecoveryBlocked(String)
        case invalidAudio(String)

        var description: String {
            switch self {
            case .terminalRecoveryRequired(let message): message
            case .terminalRecoveryBlocked(let message): message
            case .invalidAudio(let message): message
            }
        }
    }

    static let rotationSamples = 57_600_000
    private static let checkpointSamples = privySampleRate * 5

    private struct ActiveChunk {
        var record: ChunkRecord
        let partialURL: URL
        let finalURL: URL
        var writer: any OggOpusWriting
        var inputSamples: Int
        var samplesAtCheckpoint: Int
    }

    private let store: any PrivyStoring
    private let storage: StorageLayout
    private let fileManager: FileManager
    private let rotationSamples: Int
    private let makeWriter: (URL) throws -> any OggOpusWriting
    private var active: ActiveChunk?
    private var terminalBlock: String?

    init(
        store: any PrivyStoring,
        storage: StorageLayout,
        fileManager: FileManager = .default,
        rotationSamples: Int = ShadowChunkWriter.rotationSamples,
        makeWriter: ((URL) throws -> any OggOpusWriting)? = nil
    ) {
        precondition(rotationSamples > 0 && rotationSamples.isMultiple(of: privySampleRate / 50))
        self.store = store
        self.storage = storage
        self.fileManager = fileManager
        self.rotationSamples = rotationSamples
        self.makeWriter = makeWriter ?? { url in
            try OggOpusWriter(url: url, sampleRate: Int32(privySampleRate))
        }
    }

    func activeChunk() -> ChunkRecord? {
        active?.record
    }

    func append(_ block: AudioBlock16k) async throws -> [WriterTransition] {
        if let terminalBlock {
            throw ChunkWriterError.terminalRecoveryBlocked(terminalBlock)
        }
        guard block.samples.allSatisfy(\.isFinite) else {
            throw ChunkWriterError.invalidAudio("audio block contains a non-finite sample")
        }
        guard !block.samples.isEmpty else { return [] }

        var transitions: [WriterTransition] = []
        var consumed = 0

        do {
            while consumed < block.samples.count {
                if active == nil {
                    let start = reading(forSampleOffset: consumed, in: block)
                    transitions.append(.opened(try await openChunk(at: start)))
                }

                guard var current = active else {
                    throw ChunkWriterError.terminalRecoveryRequired("chunk failed to open")
                }
                let remainingInChunk = rotationSamples - current.inputSamples
                let take = min(remainingInChunk, block.samples.count - consumed)
                let end = consumed + take
                try current.writer.append(Array(block.samples[consumed ..< end]))
                current.inputSamples += take
                consumed = end
                active = current

                if current.inputSamples - current.samplesAtCheckpoint >= Self.checkpointSamples {
                    try current.writer.synchronize()
                    let duration = durationSeconds(for: current.inputSamples)
                    let size = try fileSize(at: current.partialURL)
                    try await store.checkpointChunk(
                        id: current.record.id,
                        durationSeconds: duration,
                        sizeBytes: size
                    )
                    current.samplesAtCheckpoint = current.inputSamples
                    current.record = replacing(
                        current.record,
                        durationSeconds: duration,
                        sizeBytes: size,
                        state: .recording,
                        checksum: nil
                    )
                    active = current
                    transitions.append(.checkpointed(
                        chunkID: current.record.id,
                        durationSeconds: duration
                    ))
                }

                if current.inputSamples == rotationSamples {
                    transitions.append(.finalized(try await finalizeCurrent(eosLess: true)))
                }
            }
        } catch {
            let recoveryError = await recoverCurrent(after: error)
            if let recoveryError { throw recoveryError }
            throw error
        }

        assert(consumed == block.samples.count, "hourly split must conserve every input sample")
        return transitions
    }

    func close(reason: StopReason, at: ClockReading) async throws -> [WriterTransition] {
        if active == nil { return [] }
        if let terminalBlock {
            throw ChunkWriterError.terminalRecoveryBlocked(terminalBlock)
        }

        if reason == .fatalError {
            if let recoveryError = await recoverCurrent(
                after: ChunkWriterError.terminalRecoveryRequired("fatal writer close")
            ) {
                throw recoveryError
            }
            return []
        }

        do {
            return [.finalized(try await finalizeCurrent(eosLess: false))]
        } catch {
            if let recoveryError = await recoverCurrent(after: error) {
                throw recoveryError
            }
            throw error
        }
    }

    // MARK: - Chunk lifecycle

    private func openChunk(at start: ClockReading) async throws -> ChunkRecord {
        try fileManager.createDirectory(
            at: storage.audioDirectory,
            withIntermediateDirectories: true
        )

        let filename = makeFilename(startedAt: start.wallUTC)
        let finalURL = storage.audioDirectory.appendingPathComponent(filename)
        let partialURL = finalURL.appendingPathExtension("partial")
        let newChunk = NewChunk(
            kind: .shadow,
            startedAtUTC: start.wallUTC,
            startedMono: start.monotonicSeconds,
            relativeAudioPath: filename
        )
        let record = try await store.createChunk(newChunk)

        do {
            let writer = try makeWriter(partialURL)
            active = ActiveChunk(
                record: record,
                partialURL: partialURL,
                finalURL: finalURL,
                writer: writer,
                inputSamples: 0,
                samplesAtCheckpoint: 0
            )
            return record
        } catch {
            do {
                try await store.failChunk(id: record.id, reason: "writer open failed: \(error)")
            } catch let storeError {
                terminalBlock = "writer open failed and row could not be failed: \(storeError)"
                throw ChunkWriterError.terminalRecoveryBlocked(terminalBlock!)
            }
            throw error
        }
    }

    private func finalizeCurrent(eosLess: Bool) async throws -> ChunkRecord {
        guard var current = active else {
            throw ChunkWriterError.terminalRecoveryRequired("no active chunk to finalize")
        }

        if eosLess {
            precondition(
                current.inputSamples == rotationSamples,
                "EOS-less close is reserved for the exact hourly boundary"
            )
            try current.writer.durablyCloseWithoutEndOfStream()
        } else {
            try current.writer.finish()
        }

        try movePartialToFinal(current)
        let size = try fileSize(at: current.finalURL)
        let checksum = try checksumSHA256(at: current.finalURL)
        let duration = durationSeconds(for: current.inputSamples)
        let finalized = try await store.finalizeChunk(
            id: current.record.id,
            durationSeconds: duration,
            sizeBytes: size,
            checksumSHA256: checksum
        )
        current.record = finalized
        active = nil
        return finalized
    }

    /// Terminally resolves the active row after any same-process writer failure. A
    /// replacement chunk is forbidden until this method has persisted `ready` or
    /// `failed`; inability to persist either leaves the writer terminally blocked.
    private func recoverCurrent(after originalError: Error) async -> Error? {
        guard let current = active else { return nil }
        var recoveryFailure: Error?

        do {
            if fileManager.fileExists(atPath: current.partialURL.path) {
                // Both close operations are idempotent. If the original failure happened
                // after close (rename/checksum/Store), this intentionally becomes a no-op
                // before recovery retries the remaining filesystem/row transitions.
                if current.inputSamples.isMultiple(of: Int(current.writer.sampleRate) / 50) {
                    try current.writer.durablyCloseWithoutEndOfStream()
                } else {
                    try current.writer.finish()
                }
            }

            if !fileManager.fileExists(atPath: current.finalURL.path) {
                try movePartialToFinal(current)
            }
            let measuredDuration = try probeDuration(at: current.finalURL)
            let size = try fileSize(at: current.finalURL)
            let checksum = try checksumSHA256(at: current.finalURL)
            _ = try await store.finalizeChunk(
                id: current.record.id,
                durationSeconds: measuredDuration,
                sizeBytes: size,
                checksumSHA256: checksum
            )
            active = nil
            terminalBlock = nil
            return nil
        } catch {
            recoveryFailure = error
        }

        do {
            try await store.failChunk(
                id: current.record.id,
                reason: "writer failure: \(originalError); recovery failure: \(String(describing: recoveryFailure))"
            )
            active = nil
            terminalBlock = nil
            return nil
        } catch {
            let message = "writer row \(current.record.id) could not reach ready or failed: \(error)"
            terminalBlock = message
            return ChunkWriterError.terminalRecoveryBlocked(message)
        }
    }

    private func movePartialToFinal(_ current: ActiveChunk) throws {
        guard fileManager.fileExists(atPath: current.partialURL.path) else {
            throw ChunkWriterError.terminalRecoveryRequired(
                "missing partial file \(current.partialURL.path)"
            )
        }
        guard !fileManager.fileExists(atPath: current.finalURL.path) else {
            throw ChunkWriterError.terminalRecoveryRequired(
                "refusing to overwrite existing final file \(current.finalURL.path)"
            )
        }
        try fileManager.moveItem(at: current.partialURL, to: current.finalURL)
    }

    // MARK: - File measurements

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ChunkWriterError.terminalRecoveryRequired("cannot measure \(url.path)")
        }
        return size.int64Value
    }

    private func checksumSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func probeDuration(at url: URL) throws -> Double {
        guard let executable = executable(named: "ffprobe") else {
            throw ChunkWriterError.terminalRecoveryRequired("ffprobe is unavailable")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let duration = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration.isFinite,
              duration > 0 else {
            let detail = String(data: errorData, encoding: .utf8) ?? "unknown ffprobe error"
            throw ChunkWriterError.terminalRecoveryRequired("ffprobe failed: \(detail)")
        }
        return duration
    }

    private func executable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        return environmentPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Values

    private func durationSeconds(for samples: Int) -> Double {
        Double(samples) / Double(privySampleRate)
    }

    private func reading(forSampleOffset offset: Int, in block: AudioBlock16k) -> ClockReading {
        let seconds = Double(offset) / Double(privySampleRate)
        return ClockReading(
            wallUTC: block.firstSampleTime.wallUTC.addingTimeInterval(seconds),
            monotonicSeconds: block.firstSampleTime.monotonicSeconds + seconds,
            clockEpoch: block.firstSampleTime.clockEpoch
        )
    }

    private func makeFilename(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return "\(formatter.string(from: startedAt))-\(UUID().uuidString.lowercased()).ogg"
    }

    private func replacing(
        _ record: ChunkRecord,
        durationSeconds: Double,
        sizeBytes: Int64,
        state: ChunkState,
        checksum: String?
    ) -> ChunkRecord {
        ChunkRecord(
            id: record.id,
            kind: record.kind,
            startedAtUTC: record.startedAtUTC,
            startedMono: record.startedMono,
            durationSeconds: durationSeconds,
            relativeAudioPath: record.relativeAudioPath,
            sizeBytes: sizeBytes,
            checksumSHA256: checksum,
            state: state
        )
    }
}
