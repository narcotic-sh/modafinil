import Darwin
import Foundation
import SQLite3

/// A T3 Code thread whose latest run has not finished.
public struct T3ActiveThread: Equatable {
    public var title: String
    /// T3's run status (preparing, queued, starting, running or waiting), or
    /// `background` when the turn has ended but its background work is still going.
    public var status: String

    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }

    /// "waiting" means T3 needs an answer or approval; everything else is work in progress.
    public var isWaiting: Bool { status == "waiting" }

    /// The agent ended its turn and waits for a background command, monitor or
    /// subagent to report back. Counts as working.
    public var isInBackground: Bool { status == T3ActivityReader.backgroundStatus }
}

public enum T3Activity: Equatable {
    /// The T3 Code server is not running, so no thread can be working.
    case notRunning
    /// The server is running and every thread has finished.
    case idle
    case busy([T3ActiveThread])
    /// T3's state could not be read. Treated as busy so the Mac never sleeps on a guess.
    case unavailable(String)

    public var summary: String {
        switch self {
        case .notRunning: return "T3 Code is not running"
        case .idle: return "No T3 threads working or waiting"
        case .busy(let threads):
            let waiting = threads.filter(\.isWaiting).count
            let working = threads.count - waiting
            var parts: [String] = []
            if working > 0 { parts.append("\(working) working") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            return "T3 threads: " + parts.joined(separator: ", ")
        case .unavailable(let reason): return "Cannot read T3 Code: \(reason)"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .notRunning, .idle: return true
        case .busy, .unavailable: return false
        }
    }
}

/// Reads T3 Code's thread state from its local database, read-only.
///
/// T3 stores each thread's runs in `orchestration_v2_projection_runs`; a thread is
/// active while its run is in one of T3's own active statuses. A thread whose turn
/// has ended is still active while it waits on background work, as T3 shows it:
/// a background command, monitor or subagent the agent started, or a tool call
/// still running. Both queries take a few milliseconds, so they are cheap enough
/// to poll while the lid is closed.
public struct T3ActivityReader {
    /// T3's `activeRunStatuses`: a thread in one of these is working or waiting.
    public static let activeRunStatuses = ["preparing", "queued", "starting", "running", "waiting"]
    /// The status reported for a thread that waits on background work.
    public static let backgroundStatus = "background"

    public var userDataDirectory: URL
    /// Whether the process recorded in `server-runtime.json` is a live T3 server.
    public var isServerProcessAlive: (Int32) -> Bool

    public init(
        userDataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata", isDirectory: true),
        isServerProcessAlive: @escaping (Int32) -> Bool = T3ActivityReader.isT3ServerProcess
    ) {
        self.userDataDirectory = userDataDirectory
        self.isServerProcessAlive = isServerProcessAlive
    }

    public func read() -> T3Activity {
        guard let pid = serverPID(), isServerProcessAlive(pid) else { return .notRunning }
        let databaseURL = userDataDirectory.appendingPathComponent("statev2.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .unavailable("its state database is missing")
        }
        do {
            let threads = try Self.activeThreads(databasePath: databaseURL.path)
            return threads.isEmpty ? .idle : .busy(threads)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func serverPID() -> Int32? {
        let url = userDataDirectory.appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    static func activeThreads(databasePath: String) throws -> [T3ActiveThread] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the database"
            sqlite3_close(db)
            throw ReadError(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var threads: [T3ActiveThread] = []
        var seen = Set<String>()
        for sql in [activeRunsSQL, backgroundWorkSQL] {
            for row in try rows(db, sql) where seen.insert(row.threadID).inserted {
                threads.append(T3ActiveThread(title: row.title, status: row.status))
            }
        }
        return threads
    }

    private static var activeRunsSQL: String {
        let statuses = activeRunStatuses.map { "'\($0)'" }.joined(separator: ",")
        return """
            SELECT r.thread_id, COALESCE(t.title, 'Untitled thread'), r.status
            FROM orchestration_v2_projection_runs r
            LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = r.thread_id
            WHERE r.status IN (\(statuses)) AND t.deleted_at IS NULL
            GROUP BY r.thread_id
            ORDER BY r.requested_at
            """
    }

    /// Threads whose latest run has settled but that still wait on background work.
    /// Mirrors T3's own `derivePendingBackgroundWork`: the background tasks recorded
    /// on the thread's active provider thread, and command, tool and subagent items
    /// still pending (minus persistent tools and rolled-back runs). Pull request
    /// watches are left out: they wait on other people and can last for days.
    private static let backgroundWorkSQL = """
        WITH candidates(thread_id, provider_thread_id) AS MATERIALIZED (
          SELECT COALESCE(NULLIF(p.thread_id, ''), json_extract(p.payload_json, '$.appThreadId')),
                 p.provider_thread_id
          FROM orchestration_v2_projection_provider_threads p
          WHERE json_array_length(p.payload_json, '$.pendingBackgroundTasks') > 0
          UNION ALL
          SELECT i.thread_id, NULL
          FROM orchestration_v2_projection_turn_items i
          WHERE i.type IN ('command_execution', 'dynamic_tool', 'subagent')
            AND i.status NOT IN ('completed', 'interrupted', 'failed', 'cancelled')
            AND i.status IN ('pending', 'running', 'waiting')
            AND NOT (i.type = 'dynamic_tool' AND json_extract(i.payload_json, '$.input.persistent') = 1)
            AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_runs rb
                            WHERE rb.run_id = i.run_id AND rb.status = 'rolled_back')
        )
        SELECT t.thread_id, COALESCE(t.title, 'Untitled thread'), '\(backgroundStatus)'
        FROM orchestration_v2_projection_threads t
        WHERE t.deleted_at IS NULL
          AND t.thread_id IN (SELECT thread_id FROM candidates)
          AND EXISTS (SELECT 1 FROM candidates c WHERE c.thread_id = t.thread_id
                      AND (c.provider_thread_id IS NULL
                           OR json_extract(t.payload_json, '$.activeProviderThreadId') IS NULL
                           OR c.provider_thread_id = json_extract(t.payload_json, '$.activeProviderThreadId')))
          AND (SELECT r.status FROM orchestration_v2_projection_runs r
               WHERE r.thread_id = t.thread_id AND r.status <> 'queued'
               ORDER BY r.ordinal DESC LIMIT 1) IN ('cancelled', 'completed', 'failed', 'interrupted', 'waiting')
        ORDER BY t.updated_at
        """

    private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [(threadID: String, title: String, status: String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [(threadID: String, title: String, status: String)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError(String(cString: sqlite3_errmsg(db))) }
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            result.append((text(0) ?? "", text(1) ?? "Untitled thread", text(2) ?? "running"))
        }
        return result
    }

    /// True for a live process whose executable looks like a T3 Code server
    /// (the desktop app, or the CLI run with node or bun). Guards against a
    /// stale `server-runtime.json` whose PID was reused by another process.
    public static func isT3ServerProcess(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        let name = (path as NSString).lastPathComponent.lowercased()
        return path.contains("T3 Code") || name == "node" || name == "bun" || name.hasPrefix("t3")
    }

    struct ReadError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Decides when a closed-lid Mac may go to sleep because T3 Code has finished.
public struct T3SleepWatch {
    public struct Conditions: Equatable {
        public var isEnabled: Bool
        /// Keep-awake was asked for and is in effect (not just a wake-recovery lease).
        public var isKeepAwakeOn: Bool
        public var isLidClosed: Bool?
        public var hasExternalDisplay: Bool

        public init(isEnabled: Bool, isKeepAwakeOn: Bool, isLidClosed: Bool?, hasExternalDisplay: Bool) {
            self.isEnabled = isEnabled
            self.isKeepAwakeOn = isKeepAwakeOn
            self.isLidClosed = isLidClosed
            self.hasExternalDisplay = hasExternalDisplay
        }

        /// Only a closed lid without an external display: a Mac used in clamshell
        /// mode with a monitor must never be put to sleep.
        public var isWatching: Bool {
            isEnabled && isKeepAwakeOn && isLidClosed == true && !hasExternalDisplay
        }
    }

    public enum Decision: Equatable {
        case notWatching
        /// Keep-awake was just turned on from the iPhone or a wake alarm while T3 was
        /// idle. Sleep only after a T3 thread has worked again.
        case waitingForActivity
        case busy
        case waitingForGrace(sleepAt: Date)
        case sleepNow
    }

    /// How long T3 must stay finished before sleeping. Covers the short gap
    /// between a delegated task finishing and its parent thread resuming, and
    /// a queued message starting the next turn.
    public static let defaultGracePeriod: TimeInterval = 60

    public let gracePeriod: TimeInterval
    public private(set) var finishedSince: Date?
    /// Set by an explicit remote Wake & Keep Awake (or a wake alarm): the person
    /// wants the Mac awake now, so an already-finished T3 must not put it straight
    /// back to sleep. Cleared once T3 is seen working.
    public private(set) var waitsForNewActivity = false

    public init(gracePeriod: TimeInterval = T3SleepWatch.defaultGracePeriod) {
        self.gracePeriod = gracePeriod
    }

    public var isWatching: Bool { finishedSince != nil }

    /// Call once per check. `activity` is read only when the conditions allow sleeping.
    public mutating func evaluate(
        _ conditions: Conditions,
        now: Date,
        activity: () -> T3Activity
    ) -> Decision {
        guard conditions.isWatching else {
            finishedSince = nil
            return .notWatching
        }
        guard activity().isFinished else {
            finishedSince = nil
            waitsForNewActivity = false
            return .busy
        }
        if waitsForNewActivity {
            finishedSince = nil
            return .waitingForActivity
        }
        let since = finishedSince ?? now
        finishedSince = since
        let sleepAt = since.addingTimeInterval(gracePeriod)
        return now >= sleepAt ? .sleepNow : .waitingForGrace(sleepAt: sleepAt)
    }

    /// A wake resets the grace period but keeps `waitsForNewActivity`.
    public mutating func reset() {
        finishedSince = nil
    }

    public mutating func waitForNewActivity() {
        finishedSince = nil
        waitsForNewActivity = true
    }

    /// Turning the feature off or keep-awake off from the Mac ends the wait.
    public mutating func clearWaitForNewActivity() {
        waitsForNewActivity = false
    }
}
