import Foundation
import GRDB

// Typed GRDB records for the tables M1 writes: `chunks`, `vad_events`, `health`. The
// remaining §5 tables (`utterances`, `sessions`, `costs`, `utterances_fts`) are created by
// the migration but have no M1 writer, so they need no record type yet.
//
// Dates are persisted as stable ISO-8601 UTC strings with fractional seconds (see
// `PrivyDateCoding`), never via GRDB's default Date coder, so the on-disk representation
// is exactly what the contract promises and survives process/GRDB-version changes.

// MARK: - Date coding

/// Stable ISO-8601 UTC date coding shared by every SQL TEXT date column and every date
/// inside a `HealthEnvelope`. Uses **microsecond** precision (`yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'`)
/// via a Sendable `Calendar` — not `ISO8601DateFormatter` (not Sendable) nor
/// `Date.ISO8601FormatStyle` (only millisecond precision, which drops sub-ms `Date` info).
/// Microsecond round-trips any `Date` already on the µs grid exactly, so `menuSummary`
/// restores `atUTC`/`gapStartedUTC` unchanged for such values; callers/tests that need
/// exact equality snap with `PrivyDateCoding.date(from: PrivyDateCoding.string(from: x))`.
enum PrivyDateCoding {
    // `Calendar` is a Sendable value type, so this immutable static is concurrency-safe.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func string(from date: Date) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let micros = (c.nanosecond ?? 0) / 1000 // truncate nanoseconds → microseconds
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micros
        )
    }

    /// Returns nil (rather than crashing) for a malformed string; callers surface the
    /// failure rather than silently coercing. Accepts the canonical fractional form and,
    /// defensively, a no-fraction `...Z` form.
    static func date(from string: String) -> Date? {
        let chars = Array(string)
        guard chars.count >= 20,
              chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":", chars.last == "Z" else { return nil }
        func int(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = int(0..<4),
              let month = int(5..<7),
              let day = int(8..<10),
              let hour = int(11..<13),
              let minute = int(14..<16),
              let second = int(17..<19) else { return nil }
        var micros = 0
        var idx = 20
        if chars[19] == "." {
            var digits = ""
            while idx < chars.count - 1 {
                digits.append(chars[idx])
                idx += 1
            }
            guard Int(digits) != nil else { return nil }
            // Pad/truncate to exactly 6 digits so a short fraction like `.1` and a long
            // one like `.123456789` both parse deterministically.
            let padded = (digits + "000000").prefix(6)
            micros = Int(padded) ?? 0
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = micros * 1000
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)
    }
}

// MARK: - Health envelope JSON coder

/// Encodes/decodes `HealthEnvelope` with the same microsecond-precision ISO strategy as
/// the SQL columns, so `HealthDetail` dates round-trip identically to `at_utc`.
enum PrivyHealthCoder {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PrivyDateCoding.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = PrivyDateCoding.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unparseable ISO-8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }()
}

// MARK: - Chunk row

/// Persistable shape of `chunks`. `startedAtUtc`/`durationS` etc. map to snake_case SQL
/// columns via `CodingKeys`; dates are stored as ISO strings, not via Codable Date coding.
struct ChunkRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chunks"

    var id: Int64?
    var kind: String
    var startedAtUtc: String
    var startedMono: Double
    var durationS: Double
    var audioPath: String
    var sizeBytes: Int64
    var checksum: String?
    var state: String
    var sessionId: Int64?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case startedAtUtc = "started_at_utc"
        case startedMono = "started_mono"
        case durationS = "duration_s"
        case audioPath = "audio_path"
        case sizeBytes = "size_bytes"
        case checksum, state
        case sessionId = "session_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ChunkRow {
    /// Builds a row for a freshly opened chunk in the `recording` state.
    init(new: NewChunk) {
        self.init(
            id: nil,
            kind: new.kind.rawValue,
            startedAtUtc: PrivyDateCoding.string(from: new.startedAtUTC),
            startedMono: new.startedMono,
            durationS: 0,
            audioPath: new.relativeAudioPath,
            sizeBytes: 0,
            checksum: nil,
            state: ChunkState.recording.rawValue,
            sessionId: nil
        )
    }

    /// Restores the public `ChunkRecord` value type. Throws if `state`/`kind`/date are not
    /// the exact frozen values, so a corrupt row surfaces rather than silently degrading.
    func toRecord() throws -> ChunkRecord {
        guard let id else {
            throw PrivyStoreError.inconsistentRow("chunk row missing id after fetch")
        }
        guard let kind = ChunkKind(rawValue: kind) else {
            throw PrivyStoreError.inconsistentRow("unknown chunk kind: \(kind)")
        }
        guard let state = ChunkState(rawValue: state) else {
            throw PrivyStoreError.inconsistentRow("unknown chunk state: \(state)")
        }
        guard let startedAtUTC = PrivyDateCoding.date(from: startedAtUtc) else {
            throw PrivyStoreError.inconsistentRow("unparseable started_at_utc: \(startedAtUtc)")
        }
        return ChunkRecord(
            id: id,
            kind: kind,
            startedAtUTC: startedAtUTC,
            startedMono: startedMono,
            durationSeconds: durationS,
            relativeAudioPath: audioPath,
            sizeBytes: sizeBytes,
            checksumSHA256: checksum,
            state: state
        )
    }
}

// MARK: - VAD event row

struct VADEventRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "vad_events"

    var id: Int64?
    var chunkId: Int64
    var tMono: Double
    var kind: String
    var score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case chunkId = "chunk_id"
        case tMono = "t_mono"
        case kind, score
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension VADEventRow {
    init(_ event: VADEventRecord) {
        self.init(
            id: nil,
            chunkId: event.chunkID,
            tMono: event.monotonicSeconds,
            kind: event.kind.rawValue,
            score: event.score.map(Double.init)
        )
    }

    func toRecord() throws -> VADEventRecord {
        guard let kind = VADEventKind(rawValue: kind) else {
            throw PrivyStoreError.inconsistentRow("unknown VAD event kind: \(kind)")
        }
        return VADEventRecord(
            chunkID: chunkId,
            monotonicSeconds: tMono,
            kind: kind,
            score: score.map(Float.init)
        )
    }
}

// MARK: - Health row

/// Persistable shape of `health`. `detail` is one `HealthEnvelope` JSON object; `kind` and
/// `at_utc` are top-level columns. Reading reconstructs the full `HealthEvent` by decoding
/// the envelope and lifting `severity`/`detail` back to the top level.
struct HealthRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "health"

    var id: Int64?
    var atUtc: String
    var kind: String
    var detail: String

    enum CodingKeys: String, CodingKey {
        case id
        case atUtc = "at_utc"
        case kind, detail
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension HealthRow {
    /// Encodes a `HealthEvent` into its persistable columns: `at_utc`, `kind`, and the
    /// `{"severity","detail"}` envelope JSON. Throws on encoding failure (never silently
    /// drops the event).
    init(_ event: HealthEvent) throws {
        let envelope = HealthEnvelope(severity: event.severity, detail: event.detail)
        let data = try PrivyHealthCoder.encoder.encode(envelope)
        let detail = String(data: data, encoding: .utf8) ?? ""
        self.init(id: nil, atUtc: PrivyDateCoding.string(from: event.atUTC), kind: event.kind.rawValue, detail: detail)
    }

    /// Reconstructs the `HealthEvent`. A malformed/unknown envelope fails visibly instead
    /// of defaulting severity, matching the contract's no-silent-degrade rule.
    func toEvent() throws -> HealthEvent {
        guard let kind = HealthKind(rawValue: kind) else {
            throw PrivyStoreError.inconsistentRow("unknown health kind: \(kind)")
        }
        guard let atUTC = PrivyDateCoding.date(from: atUtc) else {
            throw PrivyStoreError.inconsistentRow("unparseable at_utc: \(atUtc)")
        }
        guard let data = detail.data(using: .utf8) else {
            throw PrivyStoreError.inconsistentRow("health.detail is not UTF-8")
        }
        let envelope: HealthEnvelope
        do {
            envelope = try PrivyHealthCoder.decoder.decode(HealthEnvelope.self, from: data)
        } catch {
            throw PrivyStoreError.inconsistentRow("malformed health envelope: \(error)")
        }
        return HealthEvent(atUTC: atUTC, kind: kind, severity: envelope.severity, detail: envelope.detail)
    }
}

// MARK: - Errors

/// Errors surfaced by the store. Every failure path throws one of these or a GRDB error;
/// nothing is silently swallowed.
enum PrivyStoreError: Error, Equatable {
    /// `prepareDatabase` was not called before a mutating method, or the store is closed.
    case notPrepared
    /// A persisted row could not be mapped back to its frozen value type.
    case inconsistentRow(String)
    /// `finalizeChunk`/`failChunk`/`checkpointChunk` referenced an unknown id.
    case unknownChunk(id: Int64)
    /// A relative audio path escapes `StorageLayout.audioDirectory`.
    case unsafeRelativePath(String)
}
