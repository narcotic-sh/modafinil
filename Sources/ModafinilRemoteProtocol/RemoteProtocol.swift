import CryptoKit
import Foundation
import Security

public enum RemoteCommand: String, Codable, Sendable {
    case status
    case keepAwake
    case sleep
    case scheduleSleep
    case cancelScheduledSleep
    case scheduleWake
    case cancelScheduledWake
    case wake
    /// Protocol v5: argument "<from>-<to>" in Unix seconds.
    case history
    /// Protocol v6: argument "1" turns "Sleep when T3 Code threads finish" on, "0" off.
    case setT3Sleep
}

/// The Mac's "Sleep when T3 Code threads finish (lid closed)" setting and what T3 is doing.
public struct RemoteT3Sleep: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// One line, e.g. "T3 threads: 2 working, 1 waiting" or "T3 Code is not running".
    public let summary: String
    public let working: Int
    public let waiting: Int
    /// Set while the lid is closed and T3 has finished: the Mac sleeps at this time.
    public let sleepAt: Int64?
    /// The Mac slept after T3 finished; keep-awake returns when the lid opens.
    public let restorePending: Bool

    public init(enabled: Bool, summary: String, working: Int = 0, waiting: Int = 0,
                sleepAt: Int64? = nil, restorePending: Bool = false) {
        self.enabled = enabled; self.summary = summary; self.working = working
        self.waiting = waiting; self.sleepAt = sleepAt; self.restorePending = restorePending
    }

    public static func parseArgument(_ argument: String) -> Bool? {
        switch argument {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}

/// One stretch of the Mac's power state. Short keys keep pages small.
public struct RemoteHistorySegment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case awake, background, asleep, unknown }
    public let start: Int64
    public let end: Int64
    public let kind: Kind
    public let reason: String
    /// Wake cause identifier for wake segments (e.g. "network", "maintenance").
    public let cause: String?

    public init(start: Int64, end: Int64, kind: Kind, reason: String, cause: String? = nil) {
        self.start = start; self.end = end; self.kind = kind; self.reason = reason; self.cause = cause
    }

    enum CodingKeys: String, CodingKey { case start = "s", end = "e", kind = "k", reason = "r", cause = "c" }
}

/// A Modafinil action, such as turning keep-awake on from the iPhone.
public struct RemoteHistoryMarker: Codable, Equatable, Sendable {
    public let at: Int64
    public let text: String
    public init(at: Int64, text: String) { self.at = at; self.text = text }
    enum CodingKeys: String, CodingKey { case at = "t", text = "m" }
}

public struct RemoteHistory: Codable, Equatable, Sendable {
    public static let maximumRange: Int64 = 8 * 24 * 3600

    public let from: Int64
    public let to: Int64
    /// Newest first. When `complete` is false, request again with `to = oldest`.
    public let segments: [RemoteHistorySegment]
    public let markers: [RemoteHistoryMarker]
    public let complete: Bool
    /// Start of the oldest returned item; the next page ends here.
    public let oldest: Int64

    public init(from: Int64, to: Int64, segments: [RemoteHistorySegment],
                markers: [RemoteHistoryMarker], complete: Bool, oldest: Int64) {
        self.from = from; self.to = to; self.segments = segments
        self.markers = markers; self.complete = complete; self.oldest = oldest
    }

    public static func argument(from: Int64, to: Int64) -> String { "\(from)-\(to)" }

    /// Builds one newest-first page whose JSON stays within `budget` bytes, so a
    /// signed response always fits in `RemoteWireCodec.maximumMessageSize`.
    /// Pages are cut only at segment starts, so consecutive pages never leave gaps.
    public static func page(from: Int64, to: Int64, segments: [RemoteHistorySegment],
                            markers: [RemoteHistoryMarker], budget: Int = 11_000) -> RemoteHistory {
        let sortedSegments = segments.sorted { $0.start > $1.start }
        let sortedMarkers = markers.sorted { $0.at > $1.at }
        func build(_ count: Int) -> RemoteHistory {
            guard count < sortedSegments.count else {
                return RemoteHistory(from: from, to: to, segments: sortedSegments,
                                     markers: sortedMarkers, complete: true, oldest: from)
            }
            var included = Array(sortedSegments.prefix(max(1, count)))
            let oldest = included.last!.start
            // Keep every segment that starts in the same second as the cut.
            included += sortedSegments.dropFirst(included.count).prefix { $0.start == oldest }
            return RemoteHistory(from: from, to: to, segments: included,
                                 markers: sortedMarkers.filter { $0.at >= oldest },
                                 complete: false, oldest: oldest)
        }
        let encoder = JSONEncoder()
        var count = sortedSegments.count
        var result = build(count)
        while count > 1, ((try? encoder.encode(result))?.count ?? .max) > budget {
            count = max(1, count * 3 / 4)
            result = build(count)
        }
        return result
    }

    public static func parseRange(_ argument: String, now: Int64 = Int64(Date().timeIntervalSince1970)) -> (from: Int64, to: Int64)? {
        let parts = argument.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let from = Int64(parts[0]), let to = Int64(parts[1]),
              from >= 0, from < to, to <= now + 300, to - from <= maximumRange else { return nil }
        return (from, to)
    }
}

/// An app or system process holding a power assertion on the Mac.
public struct RemoteSleepBlocker: Codable, Equatable, Sendable {
    /// "systemSleep", "idleSleep", "display", "background" or "userActive".
    public let effect: String
    public let name: String
    public let detail: String?
    public init(effect: String, name: String, detail: String? = nil) {
        self.effect = effect; self.name = name; self.detail = detail
    }
}

public struct RemoteSleepAttempt: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case pending, confirmed, failed, cancelled }
    public let requestedAt: Int64
    public let phase: Phase
    public let sleptAt: Int64?
    public let wokeAt: Int64?
    public let detail: String
    public init(requestedAt: Int64, phase: Phase, sleptAt: Int64? = nil, wokeAt: Int64? = nil, detail: String) {
        self.requestedAt = requestedAt; self.phase = phase
        self.sleptAt = sleptAt; self.wokeAt = wokeAt; self.detail = detail
    }
}

public struct RemoteState: Codable, Equatable, Sendable {
    public let awakeRequested: Bool
    public let sleepPreventionEffective: Bool
    public let serverName: String
    public let scheduledSleepAt: Int64?
    public let scheduledWakeAt: Int64?
    public let sleepAttempt: RemoteSleepAttempt?
    public let wakeTargetMACs: String?
    public let blockers: [RemoteSleepBlocker]?
    public let history: RemoteHistory?
    /// Protocol v6.
    public let t3Sleep: RemoteT3Sleep?
    /// Protocol v7: a sleep choice, not proof that the CPU is asleep now.
    public let sleepIntentActive: Bool?

    public init(
        awakeRequested: Bool,
        sleepPreventionEffective: Bool,
        serverName: String,
        scheduledSleepAt: Int64? = nil,
        scheduledWakeAt: Int64? = nil,
        sleepAttempt: RemoteSleepAttempt? = nil,
        wakeTargetMACs: String? = nil,
        blockers: [RemoteSleepBlocker]? = nil,
        history: RemoteHistory? = nil,
        t3Sleep: RemoteT3Sleep? = nil,
        sleepIntentActive: Bool? = nil
    ) {
        self.awakeRequested = awakeRequested
        self.sleepPreventionEffective = sleepPreventionEffective
        self.serverName = serverName
        self.scheduledSleepAt = scheduledSleepAt
        self.scheduledWakeAt = scheduledWakeAt
        self.sleepAttempt = sleepAttempt
        self.wakeTargetMACs = wakeTargetMACs
        self.blockers = blockers
        self.history = history
        self.t3Sleep = t3Sleep
        self.sleepIntentActive = sleepIntentActive
    }
}

public struct RemoteRequest: Codable, Equatable, Sendable {
    // Version 1 remains the default for existing phones and the wake relay.
    public static let currentVersion = 1
    public static let wakeSchedulingVersion = 2
    public static let sleepTrackingVersion = 3
    public static let wakeRecoveryVersion = 4
    public static let sleepHistoryVersion = 5
    public static let t3SleepVersion = 6
    public static let sleepIntentVersion = 7
    public static let supportedVersions: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    public let version: Int
    public let requestID: String
    public let timestamp: Int64
    public let command: RemoteCommand
    public let argument: String
    public let signature: String

    public init(
        version: Int = Self.currentVersion,
        requestID: String,
        timestamp: Int64,
        command: RemoteCommand,
        argument: String,
        signature: String
    ) {
        self.version = version
        self.requestID = requestID
        self.timestamp = timestamp
        self.command = command
        self.argument = argument
        self.signature = signature
    }

    public static func signed(
        version: Int = Self.currentVersion,
        command: RemoteCommand,
        argument: String = "",
        secret: Data,
        requestID: String = UUID().uuidString.lowercased(),
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Self {
        let unsigned = Self(
            version: version,
            requestID: requestID,
            timestamp: timestamp,
            command: command,
            argument: argument,
            signature: ""
        )
        return Self(
            version: version,
            requestID: requestID,
            timestamp: timestamp,
            command: command,
            argument: argument,
            signature: RemoteAuthentication.signature(
                for: unsigned.canonicalPayload,
                secret: secret
            )
        )
    }

    public var canonicalPayload: Data {
        Data(
            [
                String(version),
                requestID,
                String(timestamp),
                command.rawValue,
                argument
            ]
            .joined(separator: "\n")
            .utf8
        )
    }

    public func isAuthentic(secret: Data) -> Bool {
        Self.supportedVersions.contains(version) &&
            RemoteAuthentication.isValid(
                signature: signature,
                payload: canonicalPayload,
                secret: secret
            )
    }
}

public struct RemoteResponse: Codable, Equatable, Sendable {
    // Version 1 remains the default for existing phones and the wake relay.
    public static let currentVersion = 1
    public static let wakeSchedulingVersion = 2
    public static let sleepTrackingVersion = 3
    public static let wakeRecoveryVersion = 4
    public static let sleepHistoryVersion = 5
    public static let t3SleepVersion = 6
    public static let sleepIntentVersion = 7
    public static let supportedVersions: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    public let version: Int
    public let requestID: String
    public let timestamp: Int64
    public let ok: Bool
    public let state: RemoteState?
    public let message: String
    public let signature: String

    public init(
        version: Int = Self.currentVersion,
        requestID: String,
        timestamp: Int64,
        ok: Bool,
        state: RemoteState?,
        message: String,
        signature: String
    ) {
        self.version = version
        self.requestID = requestID
        self.timestamp = timestamp
        self.ok = ok
        self.state = state
        self.message = message
        self.signature = signature
    }

    public static func signed(
        version: Int = Self.currentVersion,
        requestID: String,
        ok: Bool,
        state: RemoteState? = nil,
        message: String,
        secret: Data,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Self {
        // Older peers must never receive fields absent from their signed payload.
        let responseState = state.map {
            RemoteState(awakeRequested: $0.awakeRequested,
                        sleepPreventionEffective: $0.sleepPreventionEffective,
                        serverName: $0.serverName, scheduledSleepAt: $0.scheduledSleepAt,
                        scheduledWakeAt: version >= 2 ? $0.scheduledWakeAt : nil,
                        sleepAttempt: version >= 3 ? $0.sleepAttempt : nil,
                        wakeTargetMACs: version >= 4 ? $0.wakeTargetMACs : nil,
                        blockers: version >= 5 ? $0.blockers : nil,
                        history: version >= 5 ? $0.history : nil,
                        t3Sleep: version >= 6 ? $0.t3Sleep : nil,
                        sleepIntentActive: version >= 7 ? $0.sleepIntentActive : nil)
        }
        let unsigned = Self(
            version: version,
            requestID: requestID,
            timestamp: timestamp,
            ok: ok,
            state: responseState,
            message: message,
            signature: ""
        )
        return Self(
            version: version,
            requestID: requestID,
            timestamp: timestamp,
            ok: ok,
            state: responseState,
            message: message,
            signature: RemoteAuthentication.signature(
                for: unsigned.canonicalPayload,
                secret: secret
            )
        )
    }

    public var canonicalPayload: Data {
        let statePayload: String
        if let state {
            var fields = [
                state.awakeRequested ? "1" : "0",
                state.sleepPreventionEffective ? "1" : "0",
                state.serverName,
                state.scheduledSleepAt.map(String.init) ?? ""
            ]
            if version >= Self.wakeSchedulingVersion {
                fields.append(state.scheduledWakeAt.map(String.init) ?? "")
            }
            if version >= Self.sleepTrackingVersion {
                // JSON makes boundaries unambiguous even inside error messages.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                statePayload = (try! encoder.encode(state)).base64EncodedString()
            } else {
                statePayload = fields.joined(separator: "\u{1f}")
            }
        } else {
            statePayload = ""
        }

        return Data(
            [
                String(version),
                requestID,
                String(timestamp),
                ok ? "1" : "0",
                statePayload,
                message
            ]
            .joined(separator: "\n")
            .utf8
        )
    }

    public func isAuthentic(secret: Data) -> Bool {
        Self.supportedVersions.contains(version) &&
            (version >= Self.wakeSchedulingVersion || state?.scheduledWakeAt == nil) &&
            (version >= Self.sleepTrackingVersion || state?.sleepAttempt == nil) &&
            (version >= Self.wakeRecoveryVersion || state?.wakeTargetMACs == nil) &&
            (version >= Self.sleepHistoryVersion || (state?.blockers == nil && state?.history == nil)) &&
            (version >= Self.t3SleepVersion || state?.t3Sleep == nil) &&
            (version >= Self.sleepIntentVersion || state?.sleepIntentActive == nil) &&
            RemoteAuthentication.isValid(
                signature: signature,
                payload: canonicalPayload,
                secret: secret
            )
    }
}

public enum RemoteAuthentication {
    public static func generateSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }

    public static func signature(for payload: Data, secret: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: secret)
        )
        return Data(code).hexEncodedString
    }

    public static func isValid(
        signature: String,
        payload: Data,
        secret: Data
    ) -> Bool {
        guard let suppliedCode = Data(hexEncoded: signature) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            suppliedCode,
            authenticating: payload,
            using: SymmetricKey(data: secret)
        )
    }
}

public final class RemoteRequestVerifier: @unchecked Sendable {
    private let secret: Data
    private let allowedClockSkew: Int64
    private let replayRetention: Int64
    private let lock = NSLock()
    private var acceptedRequestIDs: [String: Int64] = [:]

    public init(
        secret: Data,
        allowedClockSkew: Int64 = 90,
        replayRetention: Int64 = 300
    ) {
        precondition(secret.count == 32, "Remote secrets must contain 256 bits")
        self.secret = secret
        self.allowedClockSkew = allowedClockSkew
        self.replayRetention = replayRetention
    }

    public func verify(
        _ request: RemoteRequest,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        guard RemoteRequest.supportedVersions.contains(request.version),
              (request.version >= 2 || ![RemoteCommand.scheduleWake, .cancelScheduledWake].contains(request.command)),
              (request.version >= RemoteRequest.sleepHistoryVersion || request.command != .history),
              (request.version >= RemoteRequest.t3SleepVersion || request.command != .setT3Sleep) else {
            throw VerificationError.unsupportedVersion
        }
        guard UUID(uuidString: request.requestID) != nil else {
            throw VerificationError.invalidRequestID
        }
        guard request.argument.utf8.count <= 256 else {
            throw VerificationError.argumentTooLarge
        }
        guard
            request.timestamp >= now - allowedClockSkew,
            request.timestamp <= now + allowedClockSkew
        else {
            throw VerificationError.timestampOutsideWindow
        }
        guard request.isAuthentic(secret: secret) else {
            throw VerificationError.invalidSignature
        }

        lock.lock()
        defer { lock.unlock() }

        acceptedRequestIDs = acceptedRequestIDs.filter {
            $0.value >= now - replayRetention
        }
        guard acceptedRequestIDs[request.requestID] == nil else {
            throw VerificationError.replayedRequest
        }
        acceptedRequestIDs[request.requestID] = now
    }

    public enum VerificationError: LocalizedError, Equatable {
        case unsupportedVersion
        case invalidRequestID
        case argumentTooLarge
        case timestampOutsideWindow
        case invalidSignature
        case replayedRequest

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return "The request protocol version is unsupported."
            case .invalidRequestID:
                return "The request identifier is invalid."
            case .argumentTooLarge:
                return "The request argument is too large."
            case .timestampOutsideWindow:
                return "The request timestamp is outside the allowed window."
            case .invalidSignature:
                return "The request signature is invalid."
            case .replayedRequest:
                return "The request has already been accepted."
            }
        }
    }
}

public enum RemoteWireCodec {
    public static let maximumMessageSize = 16_384

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public static func decodeLine<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        guard data.count <= maximumMessageSize else {
            throw WireError.messageTooLarge
        }

        let payload: Data
        if data.last == 0x0a {
            payload = data.dropLast()
        } else {
            payload = data
        }
        return try decoder.decode(type, from: payload)
    }

    public enum WireError: LocalizedError {
        case messageTooLarge

        public var errorDescription: String? {
            "The remote message exceeded the size limit."
        }
    }
}

public extension Data {
    init?(hexEncoded string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }

        var data = Data()
        data.reserveCapacity(string.count / 2)
        var index = string.startIndex

        while index < string.endIndex {
            let nextIndex = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
