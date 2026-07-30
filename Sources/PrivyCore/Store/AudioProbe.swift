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
/// `timeout`. Natural exit, timeout, and caller cancellation contend for one lock-protected
/// outcome. The winning path reaps/cleans the process and closes every pipe handle before
/// resuming the caller; natural exit also cancels and awaits the timeout arm so it cannot
/// retain descriptors until the deadline.
enum BoundedProcess {
    enum Outcome: Sendable {
        case success(Data)
        case failure(BoundedProcessError)
    }

    static func run(executable: String, arguments: [String], timeout: Duration) async -> Outcome {
        let execution = ProcessExecution(executable: executable, arguments: arguments)
        return await withTaskCancellationHandler {
            await execution.start(timeout: timeout)
        } onCancel: {
            // Task-group cancellation at the inventory deadline must become real process
            // termination; cancellation alone would make the group wait for a hung child.
            execution.cancel()
        }
    }
}

/// Owns one `Process` invocation. `@unchecked Sendable` is justified because outcome,
/// continuation, timeout-task, and launch state are accessed only while holding `lock`.
private final class ProcessExecution: @unchecked Sendable {
    private enum Claim {
        case pending
        case naturalExit
        case timeout
    }

    private struct Ownership {
        let continuation: CheckedContinuation<BoundedProcess.Outcome, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let process = Process()
    private let stdout = Pipe()
    private var claim: Claim = .pending
    private var continuation: CheckedContinuation<BoundedProcess.Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var launchFinished = false
    private var cancellationRequested = false

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        // ffprobe diagnostics are intentionally classified by exit status, not captured.
        // Using the null device also prevents an unread stderr pipe from filling and
        // deadlocking a verbose child before timeout can terminate it.
        process.standardError = FileHandle.nullDevice
    }

    func start(timeout: Duration) async -> BoundedProcess.Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<BoundedProcess.Outcome, Never>) in
            install(continuation)
            process.terminationHandler = { [weak self] process in
                self?.naturalExit(process)
            }

            if cancellationWasRequested() {
                finishWithoutLaunchAsTimeout()
                return
            }

            do {
                try process.run()
            } catch {
                finishLaunchFailure(error)
                return
            }

            let cancelledDuringLaunch = markLaunchFinished()
            if cancelledDuringLaunch {
                cancel()
            } else {
                armTimeout(after: timeout)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        guard launchFinished, let ownership = claimLocked(.timeout) else {
            lock.unlock()
            return
        }
        lock.unlock()

        ownership.timeoutTask?.cancel()
        Task.detached(priority: .userInitiated) { [self] in
            if let timeoutTask = ownership.timeoutTask {
                await timeoutTask.value
            }
            await terminateReapAndFinish(continuation: ownership.continuation)
        }
    }

    private func install(_ continuation: CheckedContinuation<BoundedProcess.Outcome, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    private func cancellationWasRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationRequested
    }

    private func markLaunchFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        launchFinished = true
        return cancellationRequested
    }

    private func armTimeout(after timeout: Duration) {
        let task = Task.detached(priority: .userInitiated) { [self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await timeoutReached()
        }

        lock.lock()
        if case .pending = claim {
            timeoutTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func naturalExit(_ terminatedProcess: Process) {
        lock.lock()
        guard let ownership = claimLocked(.naturalExit) else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Claim before draining stdout: once termination is observed, timeout cannot win
        // while the handler is reading the final output bytes.
        ownership.timeoutTask?.cancel()
        Task.detached(priority: .userInitiated) { [self] in
            if let timeoutTask = ownership.timeoutTask {
                await timeoutTask.value
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            cleanupHandles()
            if terminatedProcess.terminationStatus == 0 {
                ownership.continuation.resume(returning: .success(data))
            } else {
                ownership.continuation.resume(
                    returning: .failure(.nonzeroExit(terminatedProcess.terminationStatus))
                )
            }
        }
    }

    private func timeoutReached() async {
        guard let ownership = claimTimeout() else { return }
        // This method is running in the timeout arm itself; release that stored task but do
        // not attempt to await it from itself.
        await terminateReapAndFinish(continuation: ownership.continuation)
    }

    private func claimTimeout() -> Ownership? {
        lock.lock(); defer { lock.unlock() }
        return claimLocked(.timeout)
    }

    /// Must be called with `lock` held. Exactly one contender receives ownership of the
    /// continuation and timeout arm; all later natural-exit/timeout/cancel paths defer.
    private func claimLocked(_ winner: Claim) -> Ownership? {
        guard case .pending = claim, let continuation else { return nil }
        claim = winner
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        return Ownership(continuation: continuation, timeoutTask: timeoutTask)
    }

    private func finishWithoutLaunchAsTimeout() {
        lock.lock()
        launchFinished = true
        guard let ownership = claimLocked(.timeout) else {
            lock.unlock()
            return
        }
        lock.unlock()
        cleanupHandles()
        ownership.continuation.resume(returning: .failure(.timedOut))
    }

    private func finishLaunchFailure(_ error: Error) {
        lock.lock()
        launchFinished = true
        guard let ownership = claimLocked(.naturalExit) else {
            lock.unlock()
            return
        }
        lock.unlock()
        ownership.timeoutTask?.cancel()
        cleanupHandles()
        ownership.continuation.resume(
            returning: .failure(.launchFailed(error.localizedDescription))
        )
    }

    private func terminateReapAndFinish(
        continuation: CheckedContinuation<BoundedProcess.Outcome, Never>
    ) async {
        if process.isRunning { process.terminate() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if process.isRunning { process.interrupt() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        cleanupHandles()
        continuation.resume(returning: .failure(.timedOut))
    }

    private func cleanupHandles() {
        // Foundation forbids changing standardOutput/standardError after launch. Closing both
        // retained pipe handles and clearing the callback breaks the retention chain while
        // the Process object itself is released with this execution.
        process.terminationHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
    }
}
