import Foundation

struct GapWatchdog: Sendable {
    enum Action: Sendable, Equatable {
        case restart(heartbeat: ClockReading, detectedAt: ClockReading)
        case heartbeatFault(heartbeat: ClockReading, detectedAt: ClockReading)
        case wakeGraceExpired(wake: ClockReading, detectedAt: ClockReading)
    }

    private enum Mode: Sendable {
        case disarmed
        case armed(heartbeat: ClockReading)
        case restartRecovery(heartbeat: ClockReading)
        case wakeGrace(wake: ClockReading)
    }

    private let clock: any PrivyClock
    private var mode: Mode = .disarmed

    init(clock: any PrivyClock) {
        self.clock = clock
    }

    var isArmed: Bool {
        if case .armed = mode { return true }
        return false
    }

    var isInWakeGrace: Bool {
        if case .wakeGrace = mode { return true }
        return false
    }

    /// Arms only from a real audio heartbeat. Lifecycle events cannot call this.
    mutating func arm(withFreshHeartbeat heartbeat: ClockReading) {
        mode = .armed(heartbeat: heartbeat)
    }

    mutating func heartbeat(_ heartbeat: ClockReading) {
        mode = .armed(heartbeat: heartbeat)
    }

    /// Synchronous value-state cancellation. The pipeline calls this before every
    /// intentional stop/restart, so no stale deadline can fire afterward.
    mutating func disarm() {
        mode = .disarmed
    }

    mutating func beginRestartRecovery(since heartbeat: ClockReading) {
        mode = .restartRecovery(heartbeat: heartbeat)
    }

    mutating func beginWakeGrace(at wake: ClockReading) {
        mode = .wakeGrace(wake: wake)
    }

    mutating func tick(at now: ClockReading) -> [Action] {
        switch mode {
        case .disarmed:
            return []

        case .armed(let heartbeat):
            let elapsed = clock.elapsedSeconds(from: heartbeat, to: now)
            guard elapsed >= 2 else { return [] }
            mode = .restartRecovery(heartbeat: heartbeat)
            return [.restart(heartbeat: heartbeat, detectedAt: now)]

        case .restartRecovery(let heartbeat):
            guard clock.elapsedSeconds(from: heartbeat, to: now) >= 5 else { return [] }
            mode = .disarmed
            return [.heartbeatFault(heartbeat: heartbeat, detectedAt: now)]

        case .wakeGrace(let wake):
            guard clock.elapsedSeconds(from: wake, to: now) >= 10 else { return [] }
            mode = .disarmed
            return [.wakeGraceExpired(wake: wake, detectedAt: now)]
        }
    }
}
