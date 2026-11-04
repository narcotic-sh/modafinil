import Foundation

/// A foreground-only recovery attempt. All deadlines use continuous time.
@MainActor
public enum WakeRecovery {
    public static let timeout: TimeInterval = 60
    /// A locked, idle relay can need several seconds to reconnect to Tailscale
    /// and start its socket-activated process, so allow more than a Mac request.
    public static let relayTimeout: TimeInterval = 15
    /// Minimum time between the starts of two unanswered relay attempts. A fast
    /// transport failure (a Tailscale reconnect, a reset) is retried after this,
    /// which also clears launchd's 2-second relaunch throttle on the relay.
    public static let relayRetrySpacing: TimeInterval = 3
    /// After the relay confirmed a packet burst, send another this often: the
    /// sleeping Mac's Wi-Fi can miss a single broadcast burst.
    public static let acknowledgedResendInterval: TimeInterval = 10
    public static let maximumAcknowledgedSends = 4
    /// Hard cap on relay requests per attempt, answered or not.
    public static let maximumRelayAttempts = 16
    public static let macCheckTimeout: TimeInterval = 3

    public static func run<Response>(
        now: (() -> TimeInterval)? = nil,
        pause: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        contactMac: (TimeInterval) async throws -> Response,
        wakeRelay: (TimeInterval) async throws -> Void,
        isUnavailable: (Error) -> Bool,
        /// Relay errors worth retrying. Defaults to `isUnavailable`; pass a wider
        /// rule for relay rejections that a moment later may succeed.
        isRelayRetryable: ((Error) -> Bool)? = nil,
        onProgress: () -> Void = {}
    ) async throws -> Response {
        let clock = ContinuousClock()
        let start = clock.now
        let readTime = now ?? {
            let duration = start.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        let deadline = readTime() + timeout
        var nextRelayAttempt = readTime()
        var relayAttempts = 0
        var acknowledgedSends = 0
        var lastRelayError: Error?
        var lastMacCheck = readTime()

        while readTime() < deadline {
            try Task.checkCancellation()
            if readTime() >= nextRelayAttempt,
               acknowledgedSends < maximumAcknowledgedSends,
               relayAttempts < maximumRelayAttempts {
                relayAttempts += 1
                let attemptStart = readTime()
                do {
                    try await wakeRelay(min(relayTimeout, deadline - attemptStart))
                    acknowledgedSends += 1
                    nextRelayAttempt = readTime() + acknowledgedResendInterval
                } catch {
                    if error is CancellationError { throw error }
                    // Authentication and other definite rejections stop at once.
                    guard isRelayRetryable?(error) ?? isUnavailable(error) else {
                        if acknowledgedSends > 0 { throw error }
                        throw WakeRecoveryError.relay(error.localizedDescription, attempts: relayAttempts)
                    }
                    // A relay that timed out may still have sent the packet, so keep
                    // checking the Mac and ask the relay again soon.
                    lastRelayError = error
                    if acknowledgedSends == 0 {
                        nextRelayAttempt = attemptStart + relayRetrySpacing
                    }
                }
            }
            try Task.checkCancellation()
            guard readTime() < deadline else { break }
            lastMacCheck = readTime()
            do {
                return try await contactMac(min(macCheckTimeout, deadline - readTime()))
            } catch {
                if error is CancellationError || !isUnavailable(error) { throw error }
            }
            onProgress()
            let delay = min(2, deadline - readTime())
            if delay > 0 { try await pause(delay) }
        }
        // The phone may have been suspended (locked) long enough for the deadline
        // to pass unseen; the Mac may be awake by now, so look once more.
        if readTime() - lastMacCheck > macCheckTimeout + 5 {
            try Task.checkCancellation()
            do {
                return try await contactMac(macCheckTimeout)
            } catch {
                if error is CancellationError || !isUnavailable(error) { throw error }
            }
        }
        if acknowledgedSends == 0, let lastRelayError {
            throw WakeRecoveryError.relay(lastRelayError.localizedDescription, attempts: relayAttempts)
        }
        throw WakeRecoveryError.timedOut
    }
}

public enum WakeRecoveryError: LocalizedError, Equatable {
    case relay(String, attempts: Int)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .relay(let detail, let attempts):
            let tries = attempts == 1 ? "1 try" : "\(attempts) tries"
            return "The iPad wake relay could not be reached (\(tries) in 60 s). Last error: \(detail) Check that the iPad is on, on home Wi-Fi, and that Tailscale on the iPad is connected."
        case .timedOut:
            return "The iPad relay sent the wake packets, but the Mac did not reconnect within 60 seconds. Check that the Mac is on power, on the same home network as the iPad, and that Wake for network access is on."
        }
    }
}
