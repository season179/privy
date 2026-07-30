import Foundation

// Injectable audio-probing seam used by `PrivyStore` during reconciliation. Production
// runs the real `ffprobe`; tests inject fakes to cover every failure mode (executable
// unavailable, launch failure, nonzero exit, timeout, malformed duration) deterministically
// and without depending on the host's ffmpeg.
//
// `probe(durationOf:)` is `async` so the Store actor yields while ffprobe runs and is never
// blocked by a slow/hung probe (findings 6 + 8). `AudioProbeResult` is declared in
// `ReconciliationPlanner.swift` and reused here.

// MARK: - Seam

/// Probes an audio file for its decoded duration. Implementations must be deterministic
/// about failure: a missing executable, launch error, nonzero exit, timeout, or unparseable
/// output all surface as `.failed`; only a real decoded duration becomes `.decodable`.
protocol AudioProbing: Sendable {
    func probe(durationOf url: URL) async -> AudioProbeResult
}

// MARK: - ffprobe locator

/// Resolves the `ffprobe` executable path from an environment dictionary.
///
/// `PRIVY_FFPROBE_PATH` is honored *strictly*: when set, it is the only candidate and an
/// invalid/non-executable value yields `nil` (unavailable) with **no** fallthrough to
/// common paths. This makes "ffprobe unavailable" deterministic and testable, and avoids
/// surprising operators who pointed the env at a specific binary. When unset, common
/// Homebrew/system locations are checked. Pure for unit testing.
func locateFFProbe(env: [String: String]) -> String? {
    if let configured = env["PRIVY_FFPROBE_PATH"], !configured.isEmpty {
        return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
    }
    for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"] {
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

// MARK: - Real ffprobe probe

/// Production `AudioProbing` backed by `ffprobe`. The executable path and timeout are
/// constructor-injected so tests can exercise every classification branch without the real
/// binary or a real 10-second wait.
struct FFprobeAudioProbe: AudioProbing {
    let ffprobePath: String?
    let timeout: Duration

    /// Production default: locate `ffprobe` from the environment with a 10 s bound.
    init(ffprobePath: String? = locateFFProbe(env: ProcessInfo.processInfo.environment), timeout: Duration = .seconds(10)) {
        self.ffprobePath = ffprobePath
        self.timeout = timeout
    }

    func probe(durationOf url: URL) async -> AudioProbeResult {
        guard let executablePath = ffprobePath else {
            return .failed(reason: "ffprobe unavailable")
        }
        let arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            "-i", url.path,
        ]
        let result = await BoundedProcess.run(
            executable: executablePath,
            arguments: arguments,
            timeout: timeout
        )
        switch result {
        case .success(let output):
            let raw = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let duration = Double(raw), duration.isFinite, duration >= 0 else {
                return .failed(reason: "ffprobe returned no parseable duration (got \"\(raw)\")")
            }
            return .decodable(durationSeconds: duration)
        case .failure(let error):
            return .failed(reason: error.reason)
        }
    }
}

// MARK: - Bounded process execution (async, non-actor-blocking)

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed(String)
    case nonzeroExit(Int32)
    case timedOut
}

extension BoundedProcessError {
    var reason: String {
        switch self {
        case .launchFailed(let message): return "ffprobe launch failed: \(message)"
        case .nonzeroExit(let code): return "ffprobe exited with status \(code) (file undecodable or unreadable)"
        case .timedOut: return "ffprobe timed out"
        }
    }
}

/// Runs an external process, capturing stdout, and guarantees it terminates within
/// `timeout`. Waiting is done off the calling actor via `terminationHandler` + a detached
/// timeout task; the caller `await`s and is never busily polled (finding 8). A timed-out
/// child is sent `terminate` and then `interrupt` if still running, then reaped.
enum BoundedProcess {
    enum Outcome: Sendable {
        case success(Data)
        case failure(BoundedProcessError)
    }

    static func run(executable: String, arguments: [String], timeout: Duration) async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let state = ProbeState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            // Natural exit: classify by status, UNLESS the timeout task already flagged a
            // timeout (in which case it owns the resume with `.timedOut`).
            process.terminationHandler = { proc in
                if state.isTimedOut { return }  // timeout task resumes
                guard state.tryResume() else { return }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: .success(data))
                } else {
                    continuation.resume(returning: .failure(.nonzeroExit(proc.terminationStatus)))
                }
            }
            // Detached timeout: mark timed-out BEFORE terminating so the natural-exit
            // handler defers; then terminate, reap, and resume `.timedOut` if not already.
            Task.detached(priority: .userInitiated) {
                let nanos = UInt64(max(0, timeout.components.seconds)) * 1_000_000_000
                    + UInt64(max(0, timeout.components.attoseconds / 1_000_000_000))
                try? await Task.sleep(nanoseconds: nanos)
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)  // give SIGTERM a moment
                if process.isRunning { process.interrupt() }
                process.waitUntilExit()  // reap deterministically; no zombie/linger
                if state.tryResume() {
                    continuation.resume(returning: .failure(.timedOut))
                }
            }
        }
    }
}

/// State for one bounded-process run: a one-shot resume guard plus a timed-out flag. Both
/// are lock-protected; `@unchecked Sendable` is justified because every access goes through
/// `lock`.
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var timedOut = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }
    var isTimedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}
