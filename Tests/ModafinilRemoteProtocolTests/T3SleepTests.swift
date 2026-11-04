import Foundation
import SQLite3
import XCTest
@testable import ModafinilT3

final class T3ActivityReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoRuntimeFileMeansNotRunning() {
        XCTAssertEqual(reader(alive: true).read(), .notRunning)
    }

    func testDeadServerMeansNotRunningEvenWithStaleRuns() throws {
        try writeRuntime(pid: 4242)
        _ = try makeDatabase(runs: [("a", "Stale", "running", nil)])
        XCTAssertEqual(reader(alive: false).read(), .notRunning)
    }

    func testFinishedRunsAreIdle() throws {
        try writeRuntime(pid: 4242)
        _ = try makeDatabase(runs: [("a", "Done", "completed", nil), ("b", "Broke", "failed", nil),
                                ("c", "Stopped", "interrupted", nil), ("d", "Rolled", "rolled_back", nil)])
        XCTAssertEqual(reader(alive: true).read(), .idle)
    }

    func testWorkingAndWaitingThreadsAreBusy() throws {
        try writeRuntime(pid: 4242)
        _ = try makeDatabase(runs: [("a", "Build", "running", nil), ("b", "Ask", "waiting", nil),
                                ("c", "Old", "completed", nil), ("d", "Next", "queued", nil),
                                ("e", "Gone", "running", "2026-10-01T00:00:00Z")])
        guard case .busy(let threads) = reader(alive: true).read() else { return XCTFail("expected busy") }
        XCTAssertEqual(Set(threads.map(\.title)), ["Build", "Ask", "Next"])
        XCTAssertEqual(threads.filter(\.isWaiting).map(\.title), ["Ask"])
        XCTAssertEqual(T3Activity.busy(threads).summary, "T3 threads: 2 working, 1 waiting")
    }

    func testBackgroundWorkAfterTheTurnEndedKeepsTheThreadBusy() throws {
        try writeRuntime(pid: 4242)
        let db = try makeDatabase(runs: [("a", "Movie", "completed", nil), ("b", "Done", "completed", nil),
                                         ("c", "Gone", "completed", "2026-10-01T00:00:00Z")],
                                  activeProviderThread: ["a": "pt-a2"])
        try addProviderThread(db, id: "pt-a2", thread: "a", tasks: #"[{"taskId":"bub","kind":"command"}]"#)
        try addProviderThread(db, id: "pt-b", thread: "b", tasks: "[]")
        try addProviderThread(db, id: "pt-c", thread: "c", tasks: #"[{"taskId":"x","kind":"monitor"}]"#)
        guard case .busy(let threads) = reader(alive: true).read() else { return XCTFail("expected busy") }
        XCTAssertEqual(threads, [T3ActiveThread(title: "Movie", status: "background")])
        XCTAssertTrue(threads[0].isInBackground)
        XCTAssertFalse(threads[0].isWaiting)
        XCTAssertEqual(T3Activity.busy(threads).summary, "T3 threads: 1 working")
    }

    func testOnlyTheActiveProviderThreadsTasksCount() throws {
        try writeRuntime(pid: 4242)
        let db = try makeDatabase(runs: [("a", "Handed off", "completed", nil)],
                                  activeProviderThread: ["a": "pt-new"])
        try addProviderThread(db, id: "pt-old", thread: "a", tasks: #"[{"taskId":"stale","kind":"command"}]"#)
        try addProviderThread(db, id: "pt-new", thread: "a", tasks: "[]")
        XCTAssertEqual(reader(alive: true).read(), .idle)
    }

    func testRunningToolItemsCountButPersistentToolsAndRolledBackRunsDoNot() throws {
        try writeRuntime(pid: 4242)
        let db = try makeDatabase(runs: [("a", "Shell", "completed", nil), ("b", "Server", "completed", nil),
                                         ("c", "Undone", "rolled_back", nil), ("d", "Agent", "interrupted", nil),
                                         ("e", "Edit", "completed", nil)])
        try addItem(db, thread: "a", type: "command_execution", status: "running")
        try addItem(db, thread: "b", type: "dynamic_tool", status: "running", input: #"{"persistent":true}"#)
        try addItem(db, thread: "c", type: "command_execution", status: "running")
        try addItem(db, thread: "d", type: "subagent", status: "pending")
        try addItem(db, thread: "e", type: "file_change", status: "running")
        guard case .busy(let threads) = reader(alive: true).read() else { return XCTFail("expected busy") }
        XCTAssertEqual(Set(threads.map(\.title)), ["Shell", "Agent"])
    }

    /// A task delegated to a linked environment (the Mac mini) runs on that Mac; the
    /// local thread waiting on it must not keep this Mac awake.
    func testWorkDelegatedToAnotherMacDoesNotCount() throws {
        try writeRuntime(pid: 4242)
        let db = try makeDatabase(runs: [("a", "Waits on mini", "completed", nil), ("b", "Reads mini", "completed", nil),
                                         ("c", "Remote task", "completed", nil), ("d", "Local tool", "completed", nil),
                                         ("e", "Local task", "completed", nil)])
        try exec(db, """
            CREATE TABLE peer_environment_links (environment_id TEXT PRIMARY KEY, label TEXT NOT NULL);
            INSERT INTO peer_environment_links VALUES ('env-mini', 'Mac mini');
            """)
        try addItem(db, thread: "a", type: "dynamic_tool", status: "running",
                    input: #"{"title":"Render","target":{"environmentId":"env-mini"}}"#)
        try addItem(db, thread: "b", type: "dynamic_tool", status: "running",
                    input: #"{"threadId":"t1","environmentId":"env-mini"}"#)
        try addProviderThread(db, id: "pt-c", thread: "c",
                              tasks: #"[{"taskId":"node:delegated-task:x%3Aremote-delegate%3Ay","kind":"subagent"}]"#)
        try addItem(db, thread: "d", type: "dynamic_tool", status: "running", input: #"{"title":"Local"}"#)
        try addProviderThread(db, id: "pt-e", thread: "e", tasks: #"[{"taskId":"bub","kind":"command"}]"#)
        guard case .busy(let threads) = reader(alive: true).read() else { return XCTFail("expected busy") }
        XCTAssertEqual(Set(threads.map(\.title)), ["Local tool", "Local task"])
    }

    func testAThreadIsListedOnceWhenItsRunIsActive() throws {
        try writeRuntime(pid: 4242)
        let db = try makeDatabase(runs: [("a", "Build", "running", nil)])
        try addProviderThread(db, id: "pt-a", thread: "a", tasks: #"[{"taskId":"bub","kind":"command"}]"#)
        try addItem(db, thread: "a", type: "command_execution", status: "running")
        XCTAssertEqual(reader(alive: true).read(), .busy([T3ActiveThread(title: "Build", status: "running")]))
    }

    func testUnexpectedSchemaIsUnavailableAndNeverFinished() throws {
        try writeRuntime(pid: 4242)
        try exec(open(), "CREATE TABLE something_else (id TEXT)")
        let activity = reader(alive: true).read()
        guard case .unavailable = activity else { return XCTFail("expected unavailable, got \(activity)") }
        XCTAssertFalse(activity.isFinished)
    }

    func testMissingDatabaseIsUnavailable() throws {
        try writeRuntime(pid: 4242)
        guard case .unavailable = reader(alive: true).read() else { return XCTFail("expected unavailable") }
    }

    func testCurrentProcessIsNotMistakenForT3() {
        // The test runner is xctest, not a T3 server: a reused PID must not count.
        XCTAssertFalse(T3ActivityReader.isT3ServerProcess(getpid()))
        XCTAssertFalse(T3ActivityReader.isT3ServerProcess(999_999))
    }

    // MARK: Fixture

    private func reader(alive: Bool) -> T3ActivityReader {
        T3ActivityReader(userDataDirectory: directory, isServerProcessAlive: { _ in alive })
    }

    private func writeRuntime(pid: Int32) throws {
        let json = #"{"version":1,"pid":\#(pid),"port":3773}"#
        try json.write(to: directory.appendingPathComponent("server-runtime.json"), atomically: true, encoding: .utf8)
    }

    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("statev2.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw XCTSkip("sqlite unavailable") }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            XCTFail(message)
        }
    }

    /// Mirrors the columns of T3's tables that the reader depends on, in WAL mode like T3.
    /// The returned connection stays open for the test's lifetime.
    @discardableResult
    private func makeDatabase(
        runs: [(thread: String, title: String, status: String, deletedAt: String?)],
        activeProviderThread: [String: String] = [:]
    ) throws -> OpaquePointer {
        let db = try open()
        addTeardownBlock { sqlite3_close(db) }
        try exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE orchestration_v2_projection_threads (
              thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
              payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_runs (
              run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
              provider TEXT NOT NULL, status TEXT NOT NULL, requested_at TEXT NOT NULL,
              completed_at TEXT, payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_provider_threads (
              provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT,
              provider TEXT NOT NULL, provider_session_id TEXT, status TEXT NOT NULL,
              first_run_ordinal INTEGER, last_run_ordinal INTEGER, updated_at TEXT NOT NULL,
              payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_turn_items (
              turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT, node_id TEXT,
              provider_thread_id TEXT, provider_turn_id TEXT, parent_item_id TEXT,
              ordinal INTEGER NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL,
              updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
            """)
        for (index, run) in runs.enumerated() {
            let deleted = run.deletedAt.map { "'\($0)'" } ?? "NULL"
            let payload = activeProviderThread[run.thread].map { #"{"activeProviderThreadId":"\#($0)"}"# }
                ?? #"{"activeProviderThreadId":null}"#
            try exec(db, """
                INSERT INTO orchestration_v2_projection_threads VALUES
                  ('\(run.thread)', 'p', '\(run.title)', 'x', 'x', NULL, \(deleted), '\(payload)');
                INSERT INTO orchestration_v2_projection_runs VALUES
                  ('run-\(run.thread)', '\(run.thread)', 1, 'codex', '\(run.status)', '2026-10-24T10:0\(index):00Z', NULL, '{}');
                """)
        }
        return db
    }

    private func addProviderThread(_ db: OpaquePointer, id: String, thread: String, tasks: String) throws {
        try exec(db, """
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
              ('\(id)', '\(thread)', NULL, 'claudeAgent', NULL, 'idle', 1, 1, 'x',
               '{"id":"\(id)","appThreadId":"\(thread)","pendingBackgroundTasks":\(tasks)}');
            """)
    }

    private var itemCount = 0

    private func addItem(_ db: OpaquePointer, thread: String, type: String, status: String,
                         input: String = #""ls""#) throws {
        itemCount += 1
        try exec(db, """
            INSERT INTO orchestration_v2_projection_turn_items VALUES
              ('item-\(itemCount)', '\(thread)', 'run-\(thread)', NULL, NULL, NULL, NULL, \(itemCount),
               '\(type)', '\(status)', 'x', '{"type":"\(type)","input":\(input)}');
            """)
    }
}

final class T3SleepWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let closed = T3SleepWatch.Conditions(isEnabled: true, isKeepAwakeOn: true,
                                                 isLidClosed: true, hasExternalDisplay: false)

    func testSleepsOnlyAfterGracePeriodOfFinishedThreads() {
        var watch = T3SleepWatch(gracePeriod: 60)
        XCTAssertEqual(watch.evaluate(closed, now: start) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(60)))
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(45)) { .notRunning },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(60)))
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(60)) { .idle }, .sleepNow)
    }

    /// 2026-11-02: an iPhone Wake & Keep Awake at 12:25 was undone at 12:26 because
    /// T3 was already finished with the lid closed.
    func testRemoteWakeWaitsForNewT3ActivityBeforeSleepingAgain() {
        var watch = T3SleepWatch(gracePeriod: 60)
        watch.waitForNewActivity()
        XCTAssertEqual(watch.evaluate(closed, now: start) { .idle }, .waitingForActivity)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(600)) { .notRunning },
                       .waitingForActivity)
        // A later maintenance wake resets the grace period but keeps the wait.
        watch.reset()
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(700)) { .idle },
                       .waitingForActivity)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(710)) {
            .busy([T3ActiveThread(title: "New run", status: "running")])
        }, .busy)
        XCTAssertFalse(watch.waitsForNewActivity)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(720)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(780)))
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(780)) { .idle }, .sleepNow)
    }

    func testClearingTheWaitRestoresTheNormalRule() {
        var watch = T3SleepWatch(gracePeriod: 0)
        watch.waitForNewActivity()
        XCTAssertEqual(watch.evaluate(closed, now: start) { .idle }, .waitingForActivity)
        watch.clearWaitForNewActivity()
        XCTAssertEqual(watch.evaluate(closed, now: start) { .idle }, .sleepNow)
    }

    func testNewWorkRestartsTheGracePeriod() {
        var watch = T3SleepWatch(gracePeriod: 60)
        _ = watch.evaluate(closed, now: start) { .idle }
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(30)) {
            .busy([T3ActiveThread(title: "Resume", status: "running")])
        }, .busy)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(70)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(130)))
    }

    func testWaitingThreadAndUnreadableStateKeepTheMacAwake() {
        var watch = T3SleepWatch(gracePeriod: 0)
        XCTAssertEqual(watch.evaluate(closed, now: start) {
            .busy([T3ActiveThread(title: "Approve?", status: "waiting")])
        }, .busy)
        XCTAssertEqual(watch.evaluate(closed, now: start) { .unavailable("schema changed") }, .busy)
    }

    func testDoesNotWatchUnlessLidClosedWithoutExternalDisplayAndKeepAwakeOn() {
        var readCount = 0
        let read: () -> T3Activity = { readCount += 1; return .idle }
        var watch = T3SleepWatch(gracePeriod: 0)
        var conditions = closed
        conditions.isLidClosed = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isLidClosed = nil
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.hasExternalDisplay = true
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isKeepAwakeOn = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isEnabled = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        XCTAssertEqual(readCount, 0, "T3 is read only while the lid is closed")
    }

    func testDesktopWatchesWhenNobodyUsesItWhateverTheDisplays() {
        var watch = T3SleepWatch(gracePeriod: 60)
        var desktop = T3SleepWatch.Conditions(isEnabled: true, isKeepAwakeOn: true, isLidClosed: nil,
                                              hasExternalDisplay: true, isDesktop: true, userIdleSeconds: 299)
        XCTAssertEqual(watch.evaluate(desktop, now: start) { .idle }, .notWatching, "someone used it recently")
        desktop.userIdleSeconds = 300
        XCTAssertEqual(watch.evaluate(desktop, now: start) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(60)))
        XCTAssertEqual(watch.evaluate(desktop, now: start.addingTimeInterval(60)) { .idle }, .sleepNow)
        desktop.isKeepAwakeOn = false
        XCTAssertEqual(watch.evaluate(desktop, now: start) { .idle }, .notWatching)
    }

    func testDesktopRemoteWakeWaitsAtMostThirtyMinutesForNewWork() {
        var watch = T3SleepWatch(gracePeriod: 60)
        let desktop = T3SleepWatch.Conditions(isEnabled: true, isKeepAwakeOn: true, isLidClosed: nil,
                                              hasExternalDisplay: false, isDesktop: true, userIdleSeconds: 3600)
        watch.waitForNewActivity(now: start)
        XCTAssertEqual(watch.evaluate(desktop, now: start.addingTimeInterval(29 * 60)) { .idle }, .waitingForActivity)
        XCTAssertEqual(watch.evaluate(desktop, now: start.addingTimeInterval(30 * 60)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(31 * 60)))
        XCTAssertFalse(watch.waitsForNewActivity)
        // A laptop keeps waiting: someone may open the lid.
        var laptop = T3SleepWatch(gracePeriod: 60)
        laptop.waitForNewActivity(now: start)
        XCTAssertEqual(laptop.evaluate(closed, now: start.addingTimeInterval(3 * 3600)) { .idle }, .waitingForActivity)
    }

    /// 2026-11-04: an 8-second T3 run on the Mac mini fell between two 15 s checks.
    func testARunThatStartedAfterTheWakeEndsTheWaitEvenIfAlreadyFinished() {
        var watch = T3SleepWatch(gracePeriod: 60)
        watch.waitForNewActivity(now: start)
        watch.noteRunStarted(at: start.addingTimeInterval(-5))
        XCTAssertTrue(watch.waitsForNewActivity, "a run from before the wake does not count")
        watch.noteRunStarted(at: start.addingTimeInterval(10))
        XCTAssertFalse(watch.waitsForNewActivity)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(20)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(80)))
        XCTAssertEqual(T3ActivityReader.parseTimestamp("2026-11-04T17:23:29.890Z"),
                       Date(timeIntervalSince1970: 1_793_813_009.89))
    }

    func testOpeningTheLidResetsTheGracePeriod() {
        var watch = T3SleepWatch(gracePeriod: 60)
        _ = watch.evaluate(closed, now: start) { .idle }
        var open = closed
        open.isLidClosed = false
        _ = watch.evaluate(open, now: start.addingTimeInterval(50)) { .idle }
        XCTAssertFalse(watch.isWatching)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(55)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(115)))
    }
}
