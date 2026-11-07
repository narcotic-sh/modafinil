import Foundation

/// A stored sleep request suppresses automatic contact even after reopening the
/// app. An explicit refresh remains available, and may wake a networked Mac.
public struct SleepContactPolicy: Codable, Equatable, Sendable {
    public var quietAfter: TimeInterval?
    public init(quietAfter: TimeInterval? = nil) { self.quietAfter = quietAfter }
    public func allowsAutomaticContact(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        quietAfter.map { now < $0 } ?? true
    }
}
