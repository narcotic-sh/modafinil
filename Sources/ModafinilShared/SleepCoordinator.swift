import Foundation
import Darwin
import notify
import IOKit
import IOKit.pwr_mgt

public struct SleepAttempt: Codable, Equatable {
    public enum Phase: String, Codable { case pending, confirmed, failed, cancelled }
    public var id: String
    public var requestedAt: Date
    public var baselineSleep: TimeInterval
    public var deadline: TimeInterval
    public var nextAttempt: TimeInterval
    public var attempts: Int
    public var phase: Phase
    public var sleptAt: Date?
    public var wokeAt: Date?
    public var detail: String
    /// "timer" or "request"; nil in journals written before 0.5.0.
    public var trigger: String? = nil
    /// True once the first wake after `sleptAt` was recorded or became unknowable.
    public var wakeResolved: Bool? = nil
}

public struct SleepSchedule: Codable, Equatable {
    public var date: Date
    public var continuousDeadline: TimeInterval
    public var bootTime: TimeInterval
}

public struct SleepJournal: Codable, Equatable {
    public var schedule: SleepSchedule?
    public var attempt: SleepAttempt?
    public var intent: SleepIntent?
    public var observedPowerEvents: [PowerEvent]?
    public init() {}
}

/// A user's explicit sleep choice, scoped to this boot. Deadlines and the wake
/// storm budget use continuous time, which includes time spent asleep.
public struct SleepIntent: Codable, Equatable {
    public var boot: TimeInterval
    public var lastSleep: TimeInterval
    public var lastWake: TimeInterval
    public var returnAfter: TimeInterval?
    public var returns: [TimeInterval] = []
}

public struct SystemSleepTimes {
    public var slept: TimeInterval
    public var woke: TimeInterval
    public var boot: TimeInterval
    public init(slept: TimeInterval, woke: TimeInterval, boot: TimeInterval) {
        self.slept = slept; self.woke = woke; self.boot = boot
    }
    public static func read() throws -> Self {
        func readTime(_ key: String) throws -> TimeInterval {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
                throw SleepError("Cannot read macOS sleep history (\(key)).")
            }
            return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return try Self(slept: readTime("kern.sleeptime"), woke: readTime("kern.waketime"), boot: readTime("kern.boottime"))
    }
    public static var continuousTime: TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

public struct SleepError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Requests sleep through the documented API; acceptance is not proof of sleep.
public enum NativeSleep {
    public static func request() throws {
        let connection = IOPMFindPowerManagement(0)
        guard connection != 0 else { throw SleepError("Cannot connect to macOS power management.") }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else {
            throw SleepError(String(format: "macOS rejected sleep (IOKit 0x%08x).", result))
        }
    }
}

public enum SleepJournalStore {
    public static let url = URL(fileURLWithPath: "/Library/Application Support/Modafinil/sleep-journal.json")
    /// Darwin notification posted after every save, so the app never polls the file.
    public static let changeNotification = "com.narcotic.modafinil.sleep-journal-changed"
    public static func read() throws -> SleepJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return SleepJournal() }
        return try JSONDecoder().decode(SleepJournal.self, from: Data(contentsOf: url))
    }
    public static func write(_ journal: SleepJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        notify_post(changeNotification)
    }
}

/// Called only on the helper's serial queue. No power requests occur in init.
/// Injected dependencies allow verification without putting the test host to sleep.
public final class SleepCoordinator {
    public private(set) var journal: SleepJournal
    private let now: () -> Date
    private let continuous: () -> TimeInterval
    private let powerTimes: () throws -> SystemSleepTimes
    private let disablePrevention: () throws -> Void
    private let requestSleep: () throws -> Void
    private let save: (SleepJournal) throws -> Void
    private let failureHint: () -> String?
    private let snapshot: () -> PowerSnapshot?
    private let userIdle: () -> TimeInterval?
    private var lastUserIdle: TimeInterval?
    public var hasWork: Bool { journal.intent != nil || journal.schedule != nil || journal.attempt?.phase == .pending }

    /// How the helper should wake itself: never, once at the timer date, or every
    /// second during verification or a bounded background-wake grace period.
    public enum TimerMode: Equatable { case idle, deadline(Date), verifying, monitoring }
    public var timerMode: TimerMode {
        if journal.attempt?.phase == .pending || isAwaitingFirstWake || journal.intent?.returnAfter != nil { return .verifying }
        if journal.intent != nil { return .monitoring }
        if let schedule = journal.schedule { return .deadline(schedule.date) }
        return .idle
    }

    /// Sleep confirmed before macOS actually stopped the CPU: the next tick runs at
    /// the first wake. Journals from before 0.5.0 (no trigger) never tick for this.
    private var isAwaitingFirstWake: Bool {
        guard let attempt = journal.attempt else { return false }
        return attempt.phase == .confirmed && attempt.wokeAt == nil && attempt.sleptAt != nil
            && attempt.wakeResolved != true && attempt.trigger != nil
    }

    /// Wall-clock deadline for the timer: the earlier of its date and its
    /// continuous-time deadline, so a clock set backwards cannot delay it.
    public func timerDeadline(now: Date, continuousNow: TimeInterval) -> Date? {
        guard let schedule = journal.schedule else { return nil }
        return min(schedule.date, now.addingTimeInterval(max(0, schedule.continuousDeadline - continuousNow)))
    }

    public init(journal: SleepJournal = .init(), now: @escaping () -> Date = Date.init,
                continuous: @escaping () -> TimeInterval = { SystemSleepTimes.continuousTime },
                powerTimes: @escaping () throws -> SystemSleepTimes = SystemSleepTimes.read,
                disablePrevention: @escaping () throws -> Void,
                requestSleep: @escaping () throws -> Void = NativeSleep.request,
                save: @escaping (SleepJournal) throws -> Void = SleepJournalStore.write,
                failureHint: @escaping () -> String? = { nil },
                snapshot: @escaping () -> PowerSnapshot? = PowerSnapshot.read,
                userIdle: @escaping () -> TimeInterval? = SystemUserActivity.idleSeconds) {
        self.journal = journal; self.now = now; self.continuous = continuous
        self.powerTimes = powerTimes; self.disablePrevention = disablePrevention
        self.requestSleep = requestSleep; self.save = save; self.failureHint = failureHint
        self.snapshot = snapshot; self.userIdle = userIdle
    }

    public func restore() throws {
        if let intent = journal.intent, intent.boot != (try powerTimes()).boot {
            journal.intent = nil
        }
        // Legacy one-shot requests stop after a crash. A durable sleep intent
        // resumes its existing deadline and attempt budget on the same boot.
        if let attempt = journal.attempt, attempt.phase == .pending, journal.intent == nil {
            let times = try powerTimes()
            if times.slept > attempt.baselineSleep {
                journal.attempt?.phase = .confirmed
                journal.attempt?.sleptAt = Date(timeIntervalSince1970: times.slept)
                journal.attempt?.detail = "macOS recorded a system sleep before the helper restarted."
            } else {
                journal.attempt?.phase = .failed
                journal.attempt?.detail = "The helper restarted before sleep was verified. Request sleep again."
            }
        }
        if let schedule = journal.schedule, schedule.bootTime != (try powerTimes()).boot {
            journal.schedule = nil
        }
        try persist()
        tick()
    }

    public func stopAfterFailure(_ detail: String) {
        journal.intent = nil
        journal.schedule = nil
        journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: now(), baselineSleep: 0,
            deadline: continuous(), nextAttempt: continuous(), attempts: 0, phase: .failed, detail: detail)
        try? persist()
    }

    public func schedule(after seconds: TimeInterval) throws {
        guard seconds.isFinite, (60...86400).contains(seconds) else {
            throw SleepError("The sleep timer must be between 1 minute and 24 hours.")
        }
        let prior = journal
        journal.schedule = SleepSchedule(date: now().addingTimeInterval(seconds),
            continuousDeadline: continuous() + seconds, bootTime: try powerTimes().boot)
        do { try persist() } catch { journal = prior; throw error }
    }

    public func cancelSchedule() throws {
        let prior = journal
        journal.schedule = nil
        do { try persist() } catch { journal = prior; throw error }
    }

    public func cancelPending() throws {
        journal.intent = nil
        lastUserIdle = nil
        guard journal.attempt?.phase == .pending else { try persist(); return }
        if let attempt = journal.attempt, let times = try? powerTimes(), times.slept > attempt.baselineSleep {
            journal.attempt?.phase = .confirmed
            journal.attempt?.sleptAt = Date(timeIntervalSince1970: times.slept)
            journal.attempt?.wokeAt = times.woke >= times.slept ? Date(timeIntervalSince1970: times.woke) : nil
            journal.attempt?.detail = "Sleep was recorded before the newer power command."
        } else {
            journal.attempt?.phase = .cancelled
            journal.attempt?.detail = "Sleep request cancelled by a newer power command."
        }
        try persist()
    }

    public func begin(trigger: String = "request", maintainSleepIntent: Bool = false) throws {
        let times = try powerTimes()
        try disablePrevention()
        let time = continuous()
        if maintainSleepIntent {
            journal.intent = SleepIntent(boot: times.boot, lastSleep: times.slept, lastWake: times.woke)
            lastUserIdle = userIdle()
        }
        journal.schedule = nil
        journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: now(), baselineSleep: times.slept,
            deadline: time + 120, nextAttempt: time + 2, attempts: 0, phase: .pending,
            detail: "Sleep requested. Waiting for macOS to enter sleep.", trigger: trigger)
        do { try persist() } // Durable receipt before acknowledging or issuing a power request.
        catch {
            journal.intent = nil
            journal.attempt?.phase = .failed
            journal.attempt?.detail = "The sleep receipt could not be saved. No power request was sent."
            throw error
        }
    }

    public func tick() {
        do {
            let time = continuous()
            let times = try powerTimes()
            if let intent = journal.intent, times.woke <= intent.lastWake, let idle = userIdle() {
                if let previous = lastUserIdle, idle + 0.5 < previous {
                    try cancelPending()
                    return
                }
                lastUserIdle = idle
            }
            if let schedule = journal.schedule, now() >= schedule.date || time >= schedule.continuousDeadline {
                // Never put a just-awakened Mac back to sleep for an elapsed timer.
                if times.slept > 0, times.slept <= schedule.date.timeIntervalSince1970,
                   times.woke >= schedule.date.timeIntervalSince1970 {
                    journal.schedule = nil
                    journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                        baselineSleep: times.slept, deadline: time, nextAttempt: time, attempts: 0,
                        phase: .confirmed, sleptAt: Date(timeIntervalSince1970: times.slept),
                        wokeAt: Date(timeIntervalSince1970: times.woke),
                        detail: "The Mac was already asleep when the timer elapsed; it has since woken.",
                        trigger: "timer", wakeResolved: true)
                    try persist()
                } else if time - schedule.continuousDeadline > 60 || now().timeIntervalSince(schedule.date) > 60 {
                    journal.schedule = nil
                    journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                        baselineSleep: times.slept, deadline: time, nextAttempt: time, attempts: 0,
                        phase: .failed, detail: "The sleep timer was missed by more than a minute. Request sleep again.")
                    try persist()
                } else { try begin(trigger: "timer", maintainSleepIntent: true) }
            }
            guard var attempt = journal.attempt else { return }
            if attempt.phase == .pending {
                if times.slept > attempt.baselineSleep {
                    attempt.phase = .confirmed
                    attempt.sleptAt = Date(timeIntervalSince1970: times.slept)
                    attempt.detail = "macOS recorded a system sleep."
                } else if abs(now().timeIntervalSince(attempt.requestedAt) - (time - (attempt.deadline - 120))) > 5 {
                    attempt.phase = .failed
                    attempt.detail = "The system clock changed during sleep verification. No further retries will run."
                } else if time >= attempt.deadline {
                    attempt.phase = .failed
                    attempt.detail = "macOS did not enter sleep within two minutes. No further retries will run. Background activity or macOS may be delaying sleep."
                    if let hint = failureHint() { attempt.detail += " " + hint }
                } else if time >= attempt.nextAttempt, attempt.attempts < 3 {
                    attempt.attempts += 1
                    attempt.nextAttempt = time + 10
                    journal.attempt = attempt
                    try persist()
                    try requestSleep()
                    return
                }
            }
            // kern.waketime is the first wake after a sleep only while kern.sleeptime
            // still names that sleep. Record it once; never overwrite it later.
            if attempt.phase == .confirmed, attempt.wokeAt == nil, attempt.wakeResolved != true,
               let sleptAt = attempt.sleptAt {
                if abs(times.slept - sleptAt.timeIntervalSince1970) < 0.5 {
                    if times.woke >= times.slept {
                        attempt.wokeAt = Date(timeIntervalSince1970: times.woke)
                        attempt.wakeResolved = true
                        attempt.detail = "Sleep was confirmed; macOS subsequently woke (background or full wake)."
                    }
                } else {
                    attempt.wakeResolved = true // A later sleep replaced the evidence.
                }
            }
            if journal.attempt != attempt { journal.attempt = attempt; try persist() }
            if attempt.phase == .failed { journal.intent = nil; try persist() }
            try maintainIntent(times: times, time: time)
        } catch {
            journal.intent = nil
            if let schedule = journal.schedule {
                journal.schedule = nil
                journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                    baselineSleep: 0, deadline: continuous(), nextAttempt: continuous(), attempts: 0,
                    phase: .failed, detail: error.localizedDescription)
                try? persist()
            }
            if journal.attempt?.phase == .pending {
                journal.attempt?.phase = .failed
                journal.attempt?.detail = error.localizedDescription
                try? persist()
            }
            try? persist()
            NSLog("Modafinil sleep coordinator: %@", error.localizedDescription)
        }
    }

    /// Called on real power notifications as well as verification ticks. Network
    /// reachability and display wake alone never count as the user's wake command.
    private func maintainIntent(times: SystemSleepTimes, time: TimeInterval) throws {
        guard var intent = journal.intent else { return }
        guard intent.boot == times.boot else { journal.intent = nil; try persist(); return }
        let power = snapshot()
        if times.slept > intent.lastSleep {
            recordPowerEvent(PowerEvent(kind: .sleep, at: times.slept,
                reason: power?.lastSleepReason, pid: power?.sleepRequestedByPID))
            intent.lastSleep = times.slept
            intent.returnAfter = nil
            lastUserIdle = nil
        }
        if times.woke > intent.lastWake, times.woke >= times.slept {
            intent.lastWake = times.woke
            recordPowerEvent(PowerEvent(kind: .wake, at: times.woke,
                reason: power?.combinedWakeReason, dark: power?.hasGraphics.map { !$0 }))
            let cause = PowerReason.wakeCause(power?.combinedWakeReason)
            if cause == .userInput || cause == .lid {
                journal.intent = nil
                try persist()
                return
            }
            // Apple silicon can take ~50 s to finish a natural maintenance sleep.
            // Let that transition settle before asking for another sleep.
            // Permit the travelling phone to reconnect and authenticate, without
            // turning on a sleep-prevention lease for incidental Ethernet traffic.
            intent.returnAfter = time + 90
            lastUserIdle = userIdle()
        }
        if intent.returnAfter != nil, let idle = userIdle() {
            if let previous = lastUserIdle, idle + 0.5 < previous {
                journal.intent = nil
                lastUserIdle = nil
                try persist()
                return
            }
            lastUserIdle = idle
        }
        journal.intent = intent
        if let deadline = intent.returnAfter, time >= deadline {
            intent.returns = intent.returns.filter { time - $0 < 600 }
            guard intent.returns.count < 3 else {
                journal.intent = nil
                journal.attempt?.phase = .failed
                journal.attempt?.detail = "Sleep was recorded, but repeated background wakes prevented staying asleep (three returns in ten minutes). Automatic retries stopped. Check Sleep History and network clients."
                try persist()
                return
            }
            intent.returns.append(time)
            intent.returnAfter = nil
            journal.intent = intent
            try begin(trigger: "sleep intent")
        } else {
            // No disk writes on unchanged verification ticks.
            if intent != lastSavedIntent { try persist() }
        }
    }

    private func recordPowerEvent(_ event: PowerEvent) {
        var events = journal.observedPowerEvents ?? []
        if !events.contains(where: { $0.kind == event.kind && $0.at == event.at }) { events.append(event) }
        journal.observedPowerEvents = Array(events.suffix(512))
    }

    private var lastSavedIntent: SleepIntent?

    private func persist() throws {
        try save(journal)
        lastSavedIntent = journal.intent
    }
}
