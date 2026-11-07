import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class SleepIntentProtocolTests: XCTestCase {
    let secret = Data(repeating: 7, count: 32)
    func testIntentIsSignedAndCannotBeRemovedOrChanged() throws {
        let response = RemoteResponse.signed(version: 7, requestID: "test", ok: true,
            state: RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mini", sleepIntentActive: true),
            message: "Status", secret: secret)
        XCTAssertTrue(response.isAuthentic(secret: secret))
        for value in [nil, false] as [Bool?] {
            let changed = RemoteResponse(version: 7, requestID: response.requestID, timestamp: response.timestamp, ok: true,
                state: RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mini", sleepIntentActive: value),
                message: response.message, signature: response.signature)
            XCTAssertFalse(changed.isAuthentic(secret: secret))
        }
    }
    func testOldClientsNeverReceiveAnUnsupportedIntentField() throws {
        for version in 1...6 {
            let response = RemoteResponse.signed(version: version, requestID: "test", ok: true,
                state: RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mini", sleepIntentActive: true),
                message: "Status", secret: secret)
            XCTAssertNil(response.state?.sleepIntentActive)
            XCTAssertTrue(response.isAuthentic(secret: secret))
        }
    }
    func testVersionSevenRequestsAreVerified() throws {
        XCTAssertNoThrow(try RemoteRequestVerifier(secret: secret).verify(RemoteRequest.signed(version: 7, command: .sleep, secret: secret)))
    }
}
