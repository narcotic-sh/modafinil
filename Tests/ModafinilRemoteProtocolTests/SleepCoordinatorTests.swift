import Foundation
import XCTest
@testable import ModafinilShared

final class SleepCoordinatorTests: XCTestCase {
    final class Fixture {
        var date = Date(timeIntervalSince1970: 1000)
        var clock: Double = 100
        var times = SystemSleepTimes(slept: 900, woke: 950, boot: 1)
        var requests = 0
        var disables = 0
        var failRequest = false
        var failSave = false
        var failDisable = false
        var saved = SleepJournal()
        lazy var engine = makeEngine()
        func makeEngine(journal: SleepJournal = .init()) -> SleepCoordinator {
            SleepCoordinator(journal: journal, now: { self.date }, continuous: { self.clock },
                powerTimes: { self.times }, disablePrevention: {
                    if self.failDisable { throw SleepError("disable failed") }
                    self.disables += 1
                }, requestSleep: {
                    self.requests += 1
                    if self.failRequest { throw SleepError("OS rejected sleep") }
                }, save: {
                    if self.failSave { throw SleepError("disk failed") }
                    self.saved = $0
                })
        }
        func advance(_ seconds: Double) { clock += seconds; date.addTimeInterval(seconds); engine.tick() }
    }

    func testAcceptanceDoesNotClaimSleepAndWaitsForReplyWindow() throws {
        let f = Fixture(); try f.engine.begin()
        XCTAssertEqual(f.engine.journal.attempt?.phase, .pending)
        XCTAssertEqual(f.requests, 0)
        f.advance(2)
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .pending)
    }
    func testThreeAttemptsThenStopAndReportFailure() throws {
        let f = Fixture(); try f.engine.begin()
        f.advance(2); f.advance(10); f.advance(10); f.advance(98)
        XCTAssertEqual(f.requests, 3)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertFalse(f.engine.hasWork)
        f.advance(3600); XCTAssertEqual(f.requests, 3)
    }
    func testObservedSleepThenWakeNeverRetries() throws {
        let f = Fixture(); try f.engine.begin(); f.advance(2)
        f.times.slept = 1003; f.times.woke = 1006
        f.advance(6)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
        XCTAssertEqual(f.engine.journal.attempt?.wokeAt, Date(timeIntervalSince1970: 1006))
        f.advance(3600); XCTAssertEqual(f.requests, 1)
    }
    func testOSRejectionIsExposedAndNotRetried() throws {
        let f = Fixture(); f.failRequest = true
        try f.engine.begin(); f.advance(2); f.advance(100)
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.engine.journal.attempt?.detail, "OS rejected sleep")
    }
    func testExplicitNewPowerCommandCancelsRetries() throws {
        let f = Fixture(); try f.engine.begin(); try f.engine.cancelPending(); f.advance(100)
        XCTAssertEqual(f.requests, 0)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .cancelled)
    }
    func testClockRollbackCannotExtendRequestForever() throws {
        let f = Fixture(); try f.engine.begin(); f.date.addTimeInterval(-86400)
        f.advance(33)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.requests, 0)
    }
    func testScheduleFiresUsingContinuousDeadlineAfterClockRollback() throws {
        let f = Fixture(); try f.engine.schedule(after: 120)
        f.date.addTimeInterval(-3600); f.advance(120)
        XCTAssertNil(f.engine.journal.schedule)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .pending)
        f.advance(2); XCTAssertEqual(f.requests, 1)
    }
    func testScheduleSurvivesHelperRestartOnSameBoot() throws {
        let f = Fixture(); try f.engine.schedule(after: 120)
        let restored = f.makeEngine(journal: f.saved); try restored.restore()
        XCTAssertNotNil(restored.journal.schedule)
        f.clock += 120; f.date.addTimeInterval(120); restored.tick()
        XCTAssertEqual(restored.journal.attempt?.phase, .pending)
    }
    func testRebootDiscardsOldSchedule() throws {
        let f = Fixture(); try f.engine.schedule(after: 120)
        f.times.boot = 500
        let restored = f.makeEngine(journal: f.saved); try restored.restore()
        XCTAssertNil(restored.journal.schedule); XCTAssertEqual(f.requests, 0)
    }
    func testTimerElapsedWhileAsleepDoesNotSleepAgainOnWake() throws {
        let f = Fixture(); try f.engine.schedule(after: 120)
        f.times.slept = 1050; f.times.woke = 1300; f.advance(300)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
        XCTAssertEqual(f.requests, 0)
    }
    func testMissedTimerReportsFailureAndNeverSleepsLate() throws {
        let f = Fixture(); try f.engine.schedule(after: 120); f.advance(200)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.requests, 0)
    }
    func testPendingAttemptDoesNotResumeAfterCrash() throws {
        let f = Fixture(); try f.engine.begin()
        let restored = f.makeEngine(journal: f.saved); try restored.restore()
        f.clock += 3; restored.tick()
        XCTAssertEqual(restored.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.requests, 0)
    }
    func testCrashAfterSleepRecoversKernelEvidence() throws {
        let f = Fixture(); try f.engine.begin(); f.times.slept = 1002; f.times.woke = 1100
        let restored = f.makeEngine(journal: f.saved); try restored.restore()
        XCTAssertEqual(restored.journal.attempt?.phase, .confirmed)
        XCTAssertEqual(f.requests, 0)
    }
    func testPersistenceFailureCannotCauseAnUnacknowledgedSleep() throws {
        let f = Fixture(); f.failSave = true
        XCTAssertThrowsError(try f.engine.begin()); f.advance(3)
        XCTAssertEqual(f.requests, 0)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
    }
    func testDueTimerDisableFailureStopsInsteadOfLooping() throws {
        let f = Fixture(); try f.engine.schedule(after: 60); f.failDisable = true; f.advance(60)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertFalse(f.engine.hasWork); XCTAssertEqual(f.requests, 0)
    }
    func testWakeCommandPreservesSleepEvidenceBeforeNextMonitorTick() throws {
        let f = Fixture(); try f.engine.begin(); f.advance(2)
        f.times.slept = 1003; f.times.woke = 1005
        try f.engine.cancelPending()
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
        XCTAssertNotNil(f.engine.journal.attempt?.wokeAt)
        f.advance(20); XCTAssertEqual(f.requests, 1)
    }
    func testClockChangeStopsRetriesBeforeTheNextAttempt() throws {
        let f = Fixture(); try f.engine.begin(); f.advance(2)
        f.date.addTimeInterval(-3600); f.advance(10)
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
    }
    func testStartupFailureClearsAllPendingWork() throws {
        let f = Fixture(); try f.engine.begin(); try f.engine.schedule(after: 60)
        f.engine.stopAfterFailure("Unreadable sleep history")
        f.advance(200)
        XCTAssertFalse(f.engine.hasWork)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.requests, 0)
    }
    func testScheduleValidationReplacementAndCancellation() throws {
        let f = Fixture()
        for seconds in [0.0, -1, 59, 86401, .infinity, .nan] {
            XCTAssertThrowsError(try f.engine.schedule(after: seconds))
        }
        try f.engine.schedule(after: 60); try f.engine.schedule(after: 120)
        XCTAssertEqual(f.engine.journal.schedule?.date, f.date.addingTimeInterval(120))
        try f.engine.cancelSchedule(); f.advance(200)
        XCTAssertNil(f.engine.journal.schedule); XCTAssertEqual(f.requests, 0)
    }
}
