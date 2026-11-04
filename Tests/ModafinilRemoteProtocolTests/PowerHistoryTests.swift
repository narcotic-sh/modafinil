import Foundation
import XCTest
@testable import ModafinilShared
@testable import ModafinilRemoteProtocol

final class PowerHistoryTests: XCTestCase {
    // Reason strings observed on the user's Mac14,10 (pmset log, Oct 2026).
    func testWakeReasonsFromRealMacClassifyCorrectly() {
        XCTAssertEqual(PowerReason.wakeCause("NUB.SPMI0Sw3IRQ nub-spmi0.0x02 rtc/Maintenance"), .maintenance)
        XCTAssertEqual(PowerReason.wakeCause("NUB.SPMI0Sw3IRQ nub-spmi0.0x02 rtc/SleepService"), .backgroundTask)
        XCTAssertEqual(PowerReason.wakeCause("smc.70070000 lid SMC.OutboxNotEmpty/UserActivity Assertion"), .lid)
        XCTAssertEqual(PowerReason.wakeCause("smc.70070000 wifibt SMC.OutboxNotEmpty E_RX_IP_PACKET ARPT"), .network)
        XCTAssertEqual(PowerReason.wakeCause("smc.70070000 wifibt SMC.OutboxNotEmpty"), .network)
        XCTAssertEqual(PowerReason.wakeCause("HID Activity"), .userInput)
        XCTAssertEqual(PowerReason.wakeCause("smc.70070000 enet SMC.OutboxNotEmpty lan0/"), .network)
        XCTAssertEqual(PowerReason.wakeCause(nil), .unknown)
        XCTAssertTrue(PowerReason.WakeCause.maintenance.isHousekeeping)
        XCTAssertTrue(PowerReason.WakeCause.backgroundTask.isHousekeeping)
        XCTAssertFalse(PowerReason.WakeCause.network.isHousekeeping)
        XCTAssertFalse(PowerReason.WakeCause.unknown.isHousekeeping, "Unknown wakes must still allow remote recovery")
    }

    func testRecoveryKeepAwakeIsBoundedOnBackgroundWakes() {
        func lease(_ graphics: Bool?, _ cause: PowerReason.WakeCause, sleep: Double? = 3_600, last: Double? = nil) -> Bool {
            WakeRecoveryPolicy.shouldStartLease(hasGraphics: graphics, cause: cause,
                                                sinceSleepRequest: sleep, sinceLastBackgroundLease: last)
        }
        XCTAssertTrue(lease(false, .network), "A relay wake hours after sleep starts recovery")
        XCTAssertFalse(lease(false, .network, sleep: 20), "Not the network blip right after Modafinil sleeps")
        XCTAssertFalse(lease(false, .network, last: 300), "At most once per 10 minutes in background")
        XCTAssertTrue(lease(false, .network, last: 700))
        XCTAssertFalse(lease(false, .maintenance))
        XCTAssertFalse(lease(false, .backgroundTask))
        XCTAssertFalse(lease(false, .unknown))
        XCTAssertFalse(lease(false, .alarm))
        XCTAssertFalse(lease(nil, .unknown), "Missing capabilities count as a background wake")
        XCTAssertTrue(lease(true, .lid), "Opening the lid behaves as before")
        XCTAssertTrue(lease(true, .network, sleep: 5, last: 10), "Full wakes are not rate-limited")
        XCTAssertFalse(lease(true, .maintenance))
    }

    func testSleepReasonsClassify() {
        XCTAssertEqual(PowerReason.sleepCause("Idle Sleep", pid: 100), .idle)
        XCTAssertEqual(PowerReason.sleepCause("Clamshell Sleep", pid: nil), .lidClosed)
        XCTAssertEqual(PowerReason.sleepCause("Maintenance Sleep", pid: nil), .backToSleep)
        XCTAssertEqual(PowerReason.sleepCause("Sleep Service Back to Sleep", pid: nil), .backToSleep)
        XCTAssertEqual(PowerReason.sleepCause("Software Sleep", pid: 42), .software)
        XCTAssertEqual(PowerReason.sleepCause("Software Sleep", pid: 42, modafinilPIDs: [42]), .modafinil)
    }

    func testRecorderStateRecordsEachTransitionOnceAndMarksRestarts() {
        var state = PowerRecorderState()
        let snapshot = PowerSnapshot(slept: 1_000, woke: 1_050, boot: 10, lastSleepReason: "Idle Sleep",
                                     wakeReason: "rtc/Maintenance", wakeType: "Maintenance", capabilities: 9)
        let first = state.events(for: snapshot, onStart: true)
        XCTAssertEqual(first.map(\.kind), [.boot, .sleep, .wake])
        XCTAssertEqual(first[2].dark, true)
        XCTAssertEqual(first[2].reason, "rtc/Maintenance/Maintenance")
        XCTAssertTrue(state.events(for: snapshot).isEmpty, "Repeated wake notifications must not duplicate")
        XCTAssertTrue(state.events(for: snapshot, onStart: true).isEmpty, "Same boot is not a restart")

        // Restored from disk after an app restart.
        var restored = PowerRecorderState(events: first)
        XCTAssertTrue(restored.events(for: snapshot, onStart: true).isEmpty)

        // A new boot with no sleep yet records only the restart.
        let rebooted = PowerSnapshot(slept: 0, woke: 0, boot: 5_000)
        XCTAssertEqual(restored.events(for: rebooted, onStart: true).map(\.kind), [.boot])
    }

    func testTimelineAssumesSleepBetweenRecordsAndAttributesModafinil() {
        let events = [
            PowerEvent(kind: .appStart, at: 0),
            PowerEvent(kind: .note, at: 100, note: "Sleep requested (sleep timer)"),
            PowerEvent(kind: .sleep, at: 102, reason: "Software Sleep", pid: 77),
            PowerEvent(kind: .wake, at: 1_000, reason: "rtc/Maintenance", dark: true),
            PowerEvent(kind: .sleep, at: 1_045, reason: "Maintenance Sleep"),
            PowerEvent(kind: .wake, at: 2_000, reason: "smc.70070000 lid SMC.OutboxNotEmpty", dark: true),
            PowerEvent(kind: .fullWake, at: 2_003),
        ]
        let timeline = PowerTimeline.build(events: events, from: 0, to: 3_000)
        XCTAssertEqual(timeline.segments.map(\.state), [.awake, .asleep, .background, .asleep, .awake])
        XCTAssertEqual(timeline.segments.last?.start, 2_000, "A user wake counts as awake from the wake itself")
        XCTAssertEqual(timeline.segments.last?.reason, "Lid opened")
        XCTAssertEqual(timeline.segments[1].reason, "Modafinil (sleep timer)")
        XCTAssertEqual(timeline.segments[1].duration, 898)
        XCTAssertEqual(timeline.segments[2].wakeCause, .maintenance)
        XCTAssertEqual(timeline.segments[3].reason, "Back to sleep after background wake")
        XCTAssertEqual(timeline.segments.last?.end, 3_000)
        XCTAssertEqual(timeline.markers.count, 1)

        let summary = PowerTimeline.summarize(timeline.segments)
        XCTAssertEqual(summary.asleep, 898 + 955)
        XCTAssertEqual(summary.backgroundWakes, 1)
        XCTAssertEqual(summary.wakeCauses[.maintenance], 1)
        XCTAssertEqual(summary.wakeCauses[.lid], 1)
    }

    func testSoftwareSleepWithoutModafinilRequestIsNotClaimed() {
        let events = [
            PowerEvent(kind: .appStart, at: 0),
            PowerEvent(kind: .note, at: 100, note: "Sleep requested (iPhone)"),
            PowerEvent(kind: .sleep, at: 400, reason: "Software Sleep", pid: 5),
        ]
        let timeline = PowerTimeline.build(events: events, from: 0, to: 500)
        XCTAssertEqual(timeline.segments.last?.reason, "An app requested sleep")
    }

    func testPeriodsWithoutTheAppAreUnknownNotAsleep() {
        let events = [
            PowerEvent(kind: .appStart, at: 0),
            PowerEvent(kind: .appStop, at: 100),
            PowerEvent(kind: .boot, at: 500),
            PowerEvent(kind: .appStart, at: 900),
        ]
        let timeline = PowerTimeline.build(events: events, from: 50, to: 1_000)
        XCTAssertEqual(timeline.segments.map(\.state), [.awake, .unknown, .unknown, .awake])
        XCTAssertEqual(timeline.segments.first?.start, 50, "Segments are clipped to the requested range")
        XCTAssertEqual(PowerTimeline.summarize(timeline.segments).unknown, 800)
    }

    func testStoreAppendsLoadsAndDropsOldEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PowerHistoryStore(url: directory.appendingPathComponent("history.jsonl"))
        let now = 100 * 24 * 3600.0
        try store.append([PowerEvent(kind: .sleep, at: now - 61 * 24 * 3600, reason: "Idle Sleep")])
        try store.append([PowerEvent(kind: .wake, at: now - 10, reason: "lid", dark: false),
                          PowerEvent(kind: .note, at: now, note: "Keep-awake on (Mac)")])
        XCTAssertEqual(store.load().count, 3)
        let kept = try store.compact(now: now)
        XCTAssertEqual(kept.map(\.kind), [.wake, .note])
        XCTAssertEqual(store.load(), kept)
    }

    func testBlockersAreGroupedAndUserActivityIsSeparated() {
        let blockers = SleepBlockers.summarize([
            .init(pid: 10, processName: "Google Chrome", type: "NoDisplaySleepAssertion", name: "Video Wake Lock"),
            .init(pid: 10, processName: "Google Chrome", type: "NoDisplaySleepAssertion", name: "Video Wake Lock"),
            .init(pid: 11, processName: "caffeinate", type: "PreventSystemSleep", name: "caffeinate command-line tool"),
            .init(pid: 100, processName: "powerd", type: "PreventUserIdleSystemSleep", name: "Powerd - Prevent sleep while display is on"),
            .init(pid: 156, processName: "WindowServer", type: "UserIsActive", name: "com.apple.iohideventsystem.queue.tickle"),
            .init(pid: 138, processName: "dasd", type: "BackgroundTask", name: "DASActivity"),
            .init(pid: 12, processName: "Xcode", type: "PreventUserIdleSystemSleep", name: "Build"),
        ])
        XCTAssertEqual(blockers.map(\.processName), ["caffeinate", "Xcode", "Google Chrome", "dasd", "powerd", "WindowServer"])
        XCTAssertEqual(blockers.map(\.effect), [.systemSleep, .idleSleep, .display, .background, .userActive, .userActive])
        XCTAssertEqual(blockers[2].details, ["Video Wake Lock"])
    }

    // MARK: Sleep coordinator regressions

    func testWakeTimeIsTheFirstWakeAndIsNeverOverwritten() throws {
        let f = SleepCoordinatorTests.Fixture()
        try f.engine.begin(trigger: "request")
        f.advance(2)
        f.times.slept = 1_003; f.times.woke = 1_006
        f.advance(1)
        XCTAssertEqual(f.engine.journal.attempt?.wokeAt, Date(timeIntervalSince1970: 1_006))
        XCTAssertEqual(f.engine.journal.attempt?.trigger, "request")
        // Later wakes, ticks, and a helper restart must keep the first wake.
        f.times.woke = 90_000
        f.advance(100)
        let restarted = f.makeEngine(journal: f.engine.journal)
        try restarted.restore()
        XCTAssertEqual(restarted.journal.attempt?.wokeAt, Date(timeIntervalSince1970: 1_006))
    }

    func testTimerModeWakesHelperOnlyAtDeadlineAndDuringVerification() throws {
        let f = SleepCoordinatorTests.Fixture()
        XCTAssertEqual(f.engine.timerMode, .idle)
        try f.engine.schedule(after: 600)
        XCTAssertEqual(f.engine.timerMode, .deadline(Date(timeIntervalSince1970: 1_600)))
        f.advance(600)
        XCTAssertEqual(f.engine.timerMode, .verifying)
        XCTAssertEqual(f.engine.journal.attempt?.trigger, "timer")
        f.times.slept = 1_605; f.times.woke = 1_700
        f.advance(5)
        XCTAssertEqual(f.engine.timerMode, .idle)
    }

    func testSleepConfirmedBeforeCPUStopsRecordsTheFirstWakeLater() throws {
        let f = SleepCoordinatorTests.Fixture()
        try f.engine.begin(trigger: "timer")
        f.advance(2)
        f.times.slept = 1_003 // kernel recorded sleep, CPU not yet stopped: woke (950) < slept
        f.advance(1)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
        XCTAssertNil(f.engine.journal.attempt?.wokeAt)
        XCTAssertEqual(f.engine.timerMode, .verifying, "Keeps one more check for the first wake")
        f.times.woke = 5_000
        f.advance(1)
        XCTAssertEqual(f.engine.journal.attempt?.wokeAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(f.engine.timerMode, .idle)
    }

    func testLaterSleepMakesFirstWakeUnknownInsteadOfWrong() throws {
        let f = SleepCoordinatorTests.Fixture()
        try f.engine.begin(trigger: "timer")
        f.advance(2)
        f.times.slept = 1_003
        f.advance(1)
        f.times.slept = 9_000; f.times.woke = 9_500 // a second sleep/wake pair happened
        f.advance(1)
        XCTAssertNil(f.engine.journal.attempt?.wokeAt)
        XCTAssertEqual(f.engine.timerMode, .idle)
    }

    func testTimerDeadlineIgnoresClockSetBackwards() throws {
        let f = SleepCoordinatorTests.Fixture()
        try f.engine.schedule(after: 600) // date 1_600, continuous deadline 700
        f.date = Date(timeIntervalSince1970: 400) // clock set back 600 s
        let deadline = f.engine.timerDeadline(now: f.date, continuousNow: f.clock)
        XCTAssertEqual(deadline, Date(timeIntervalSince1970: 1_000), "Fires after 600 s of real time")
    }

    // MARK: Protocol v5

    private let secret = Data(repeating: 7, count: 32)

    func testHistoryCommandRequiresVersionFive() throws {
        let verifier = RemoteRequestVerifier(secret: secret)
        let old = RemoteRequest.signed(version: 4, command: .history, argument: "1-2", secret: secret)
        XCTAssertThrowsError(try verifier.verify(old))
        let current = RemoteRequest.signed(version: 5, command: .history, argument: "1-2", secret: secret)
        XCTAssertNoThrow(try verifier.verify(current))
    }

    func testOlderClientsNeverReceiveHistoryOrBlockers() {
        let history = RemoteHistory(from: 0, to: 10, segments: [.init(start: 0, end: 10, kind: .asleep, reason: "Idle sleep")],
                                    markers: [], complete: true, oldest: 0)
        let state = RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mac",
                                wakeTargetMACs: "aa:bb:cc:dd:ee:ff",
                                blockers: [.init(effect: "display", name: "Chrome")], history: history)
        let v4 = RemoteResponse.signed(version: 4, requestID: "a", ok: true, state: state, message: "ok", secret: secret)
        XCTAssertNil(v4.state?.history)
        XCTAssertNil(v4.state?.blockers)
        XCTAssertEqual(v4.state?.wakeTargetMACs, "aa:bb:cc:dd:ee:ff")
        XCTAssertTrue(v4.isAuthentic(secret: secret))
        let v5 = RemoteResponse.signed(version: 5, requestID: "a", ok: true, state: state, message: "ok", secret: secret)
        XCTAssertEqual(v5.state?.history, history)
        XCTAssertTrue(v5.isAuthentic(secret: secret))

        // A v4 response carrying v5 fields is rejected even with a valid signature.
        let forged = RemoteResponse(version: 4, requestID: "a", timestamp: v5.timestamp, ok: true,
                                    state: state, message: "ok", signature: "")
        let signed = RemoteResponse(version: 4, requestID: "a", timestamp: v5.timestamp, ok: true, state: state,
                                    message: "ok", signature: RemoteAuthentication.signature(for: forged.canonicalPayload, secret: secret))
        XCTAssertFalse(signed.isAuthentic(secret: secret))
    }

    func testHistoryRangeValidation() {
        XCTAssertNotNil(RemoteHistory.parseRange("100-200", now: 1_000))
        XCTAssertNil(RemoteHistory.parseRange("200-100", now: 1_000))
        XCTAssertNil(RemoteHistory.parseRange("0-\(9 * 24 * 3600)", now: 10 * 24 * 3600))
        XCTAssertNil(RemoteHistory.parseRange("abc", now: 1_000))
        XCTAssertNil(RemoteHistory.parseRange("100-5000", now: 1_000), "Future ranges are rejected")
        XCTAssertEqual(RemoteHistory.argument(from: 1, to: 2), "1-2")
    }

    func testHistoryPagesFitInsideOneSignedResponse() throws {
        // A week of quarter-hourly background wakes, far more than one page.
        var segments: [RemoteHistorySegment] = []
        for index in 0..<1_400 {
            let start = Int64(index * 400)
            segments.append(.init(start: start, end: start + 400, kind: index.isMultiple(of: 2) ? .asleep : .background,
                                  reason: "Back to sleep after background wake", cause: "maintenance"))
        }
        let markers = (0..<50).map { RemoteHistoryMarker(at: Int64($0 * 10_000), text: "Keep-awake on (iPhone)") }
        let page = RemoteHistory.page(from: 0, to: 560_000, segments: segments, markers: markers)
        XCTAssertFalse(page.complete)
        XCTAssertEqual(page.segments.first?.start, 559_600, "Pages are newest first")
        XCTAssertGreaterThan(page.oldest, 0)

        let state = RemoteState(awakeRequested: true, sleepPreventionEffective: true, serverName: "Mario’s MacBook Pro",
                                wakeTargetMACs: "aa:bb:cc:dd:ee:ff,11:22:33:44:55:66",
                                blockers: Array(repeating: .init(effect: "display", name: String(repeating: "x", count: 40),
                                                                 detail: String(repeating: "y", count: 60)), count: 12),
                                history: page)
        let response = RemoteResponse.signed(version: 5, requestID: UUID().uuidString, ok: true, state: state,
                                             message: "History loaded.", secret: secret)
        let line = try RemoteWireCodec.encodeLine(response)
        XCTAssertLessThan(line.count, RemoteWireCodec.maximumMessageSize)
        XCTAssertEqual(try RemoteWireCodec.decodeLine(RemoteResponse.self, from: line), response)

        // Consecutive pages tile the range without gaps.
        var covered: [RemoteHistorySegment] = []
        var to: Int64 = 560_000
        var pages = 0
        while pages < 40 {
            let inRange = segments.compactMap { segment -> RemoteHistorySegment? in
                guard segment.start < to else { return nil }
                return .init(start: segment.start, end: min(segment.end, to), kind: segment.kind,
                             reason: segment.reason, cause: segment.cause)
            }
            let next = RemoteHistory.page(from: 0, to: to, segments: inRange, markers: markers.filter { $0.at <= to })
            covered += next.segments
            pages += 1
            if next.complete { break }
            XCTAssertEqual(next.segments.last?.start, next.oldest)
            XCTAssertTrue(next.markers.allSatisfy { $0.at >= next.oldest })
            to = next.oldest
        }
        let ordered = covered.sorted { $0.start < $1.start }
        XCTAssertEqual(ordered.first?.start, 0)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, "No gap or overlap between pages")
        }

        let small = RemoteHistory.page(from: 0, to: 10, segments: [segments[0]], markers: [])
        XCTAssertTrue(small.complete)
        XCTAssertEqual(small.oldest, 0)
    }
}

final class SleepFailureHintTests: XCTestCase {
    func testFailureHintNamesOnlyAppsThatAffectSleep() {
        let hint = SleepBlockers.failureHint([
            SleepBlocker(processName: "caffeinate", pid: 1, effect: .systemSleep, details: []),
            SleepBlocker(processName: "dasd", pid: 2, effect: .background, details: []),
        ])
        XCTAssertEqual(hint, "Apps holding sleep assertions then: caffeinate (prevents system sleep).")
        XCTAssertNil(SleepBlockers.failureHint([SleepBlocker(processName: "dasd", pid: 2, effect: .background, details: [])]))
    }
}
