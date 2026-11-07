import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class SleepContactPolicyTests: XCTestCase {
    func testNoSleepRequestAllowsForegroundRefresh() {
        XCTAssertTrue(SleepContactPolicy().allowsAutomaticContact(now: 1000))
    }
    func testSleepRequestSuppressesAutomaticContactWithoutExpiring() throws {
        let policy = SleepContactPolicy(quietAfter: 1000)
        XCTAssertFalse(policy.allowsAutomaticContact(now: 1000))
        XCTAssertFalse(policy.allowsAutomaticContact(now: 1000 + 30 * 86400))
        let restored = try JSONDecoder().decode(SleepContactPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.allowsAutomaticContact(now: 2000))
    }
    func testFutureTimerAllowsRefreshUntilDueAndWakeClearsSilence() {
        var policy = SleepContactPolicy(quietAfter: 2000)
        XCTAssertTrue(policy.allowsAutomaticContact(now: 1999))
        XCTAssertFalse(policy.allowsAutomaticContact(now: 2000))
        policy.quietAfter = nil
        XCTAssertTrue(policy.allowsAutomaticContact(now: 2000))
    }
}
