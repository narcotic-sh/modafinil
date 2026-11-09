import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class ShutdownProtocolTests: XCTestCase {
    let secret = Data(repeating: 9, count: 32)

    private func state(t3Action: RemotePowerAction? = .shutdown,
                       scheduledAction: RemotePowerAction? = .shutdown,
                       shutdown: RemoteShutdown? = RemoteShutdown(requestedAt: 1_800_000_000, phase: .pending,
                                                                  trigger: "iPhone", detail: "Quitting apps")) -> RemoteState {
        RemoteState(awakeRequested: true, sleepPreventionEffective: true, serverName: "Mini",
                    scheduledSleepAt: 1_800_000_600,
                    t3Sleep: RemoteT3Sleep(enabled: true, summary: "T3 idle", action: t3Action),
                    sleepIntentActive: false, scheduledAction: scheduledAction, shutdown: shutdown)
    }

    func testShutdownFieldsAreSignedAndCannotBeChanged() throws {
        let response = RemoteResponse.signed(version: 8, requestID: "r", ok: true, state: state(),
                                             message: "Status", secret: secret)
        XCTAssertTrue(response.isAuthentic(secret: secret))
        XCTAssertEqual(response.state?.shutdown?.phase, .pending)
        XCTAssertEqual(response.state?.t3Sleep?.action, .shutdown)
        let tampered = [
            state(t3Action: nil),
            state(scheduledAction: nil),
            state(shutdown: nil),
            state(shutdown: RemoteShutdown(requestedAt: 1_800_000_000, phase: .failed, trigger: "iPhone", detail: "Quitting apps")),
        ]
        for changed in tampered {
            let forged = RemoteResponse(version: 8, requestID: response.requestID, timestamp: response.timestamp,
                                        ok: true, state: changed, message: response.message, signature: response.signature)
            XCTAssertFalse(forged.isAuthentic(secret: secret))
        }
    }

    func testOlderPeersNeverReceiveShutdownFields() throws {
        for version in 1...7 {
            let response = RemoteResponse.signed(version: version, requestID: "r", ok: true, state: state(),
                                                 message: "Status", secret: secret)
            XCTAssertNil(response.state?.shutdown)
            XCTAssertNil(response.state?.scheduledAction)
            XCTAssertNil(response.state?.t3Sleep?.action)
            XCTAssertTrue(response.isAuthentic(secret: secret), "v\(version)")
            // A v6/v7 peer re-encodes the T3 state it knows; the signature must still match.
            if version >= 6 { XCTAssertEqual(response.state?.t3Sleep?.summary, "T3 idle") }
        }
    }

    func testOlderResponseCarryingShutdownFieldsIsRejected() throws {
        let response = RemoteResponse(version: 7, requestID: "r", timestamp: 1, ok: true, state: state(),
                                      message: "", signature: "")
        XCTAssertFalse(response.isAuthentic(secret: secret))
    }

    func testShutdownCommandsNeedVersionEight() {
        XCTAssertEqual(RemoteCommand.shutdown.requiredVersion, 8)
        XCTAssertEqual(RemoteCommand.scheduleShutdown.requiredVersion, 8)
        XCTAssertEqual(RemoteCommand.setT3Action.requiredVersion, 8)
        XCTAssertEqual(RemoteCommand.sleep.requiredVersion, 1)
        XCTAssertNoThrow(try RemoteRequestVerifier(secret: secret).verify(
            RemoteRequest.signed(version: 8, command: .shutdown, secret: secret)))
    }

    func testDecodesStateWithoutShutdownFields() throws {
        let json = #"{"awakeRequested":true,"sleepPreventionEffective":true,"serverName":"Mini"}"#
        let decoded = try JSONDecoder().decode(RemoteState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.shutdown)
        XCTAssertNil(decoded.scheduledAction)
    }
}
