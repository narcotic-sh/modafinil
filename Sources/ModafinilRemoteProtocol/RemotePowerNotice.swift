import Foundation

/// A best-effort, signed push to already authenticated observers. This never
/// authorizes a power command; it only silences observers' automatic probes.
public enum RemotePowerNotice {
    public static let port: UInt16 = 48767
    public static func signed(sleeping: Bool, secret: Data,
                              revision: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000),
                              timestamp: Int64 = Int64(Date().timeIntervalSince1970)) -> RemoteResponse {
        RemoteResponse.signed(version: 6, requestID: UUID().uuidString, ok: true,
            message: "power-intent/v1/\(revision)/\(sleeping ? 1 : 0)", secret: secret, timestamp: timestamp)
    }
    public static func verify(_ response: RemoteResponse, secret: Data, lastRevision: Int64 = 0,
                              now: Int64 = Int64(Date().timeIntervalSince1970)) -> (sleeping: Bool, revision: Int64)? {
        guard response.version == 6, response.ok, response.state == nil,
              response.timestamp >= now - 60, response.timestamp <= now + 60,
              response.isAuthentic(secret: secret) else { return nil }
        let parts = response.message.split(separator: "/")
        guard parts.count == 4, parts[0] == "power-intent", parts[1] == "v1",
              let revision = Int64(parts[2]), revision > lastRevision,
              parts[3] == "0" || parts[3] == "1" else { return nil }
        return (parts[3] == "1", revision)
    }
}
