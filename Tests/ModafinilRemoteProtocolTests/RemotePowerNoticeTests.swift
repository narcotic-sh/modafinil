import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class RemotePowerNoticeTests: XCTestCase {
    let secret = Data(repeating: 42, count: 32)
    func testSignedNoticeRoundTripsAndRejectsOtherKeys() throws {
        let notice = RemotePowerNotice.signed(sleeping: true, secret: secret, revision: 100, timestamp: 1000)
        let decoded = try RemoteWireCodec.decodeLine(RemoteResponse.self, from: RemoteWireCodec.encodeLine(notice))
        XCTAssertEqual(RemotePowerNotice.verify(decoded, secret: secret, now: 1000)?.sleeping, true)
        XCTAssertNil(RemotePowerNotice.verify(decoded, secret: Data(repeating: 1, count: 32), now: 1000))
    }
    func testReplaysStalePacketsAndReorderedSleepAreRejected() {
        let sleep = RemotePowerNotice.signed(sleeping: true, secret: secret, revision: 100, timestamp: 1000)
        let wake = RemotePowerNotice.signed(sleeping: false, secret: secret, revision: 101, timestamp: 1000)
        XCTAssertEqual(RemotePowerNotice.verify(wake, secret: secret, lastRevision: 100, now: 1000)?.sleeping, false)
        XCTAssertNil(RemotePowerNotice.verify(sleep, secret: secret, lastRevision: 101, now: 1000))
        XCTAssertNil(RemotePowerNotice.verify(wake, secret: secret, lastRevision: 101, now: 1000))
        XCTAssertNil(RemotePowerNotice.verify(wake, secret: secret, now: 1061))
        XCTAssertNil(RemotePowerNotice.verify(wake, secret: secret, now: 939))
    }
    func testTamperingCannotChangeSleepIntent() {
        let notice = RemotePowerNotice.signed(sleeping: true, secret: secret, revision: 100, timestamp: 1000)
        let modified = RemoteResponse(version: 6, requestID: notice.requestID, timestamp: 1000, ok: true,
            state: nil, message: "power-intent/v1/100/0", signature: notice.signature)
        XCTAssertNil(RemotePowerNotice.verify(modified, secret: secret, now: 1000))
    }
}
