import Foundation
import Darwin
import IOKit

/// One recorded power transition or Modafinil action. Timestamps are Unix seconds.
public struct PowerEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case sleep, wake, fullWake, boot, appStart, appStop, note
    }

    public var kind: Kind
    public var at: Double
    /// Raw macOS reason (sleep reason, or "wake reason/wake type").
    public var reason: String?
    /// Process that requested sleep, when macOS reports it.
    public var pid: Int32?
    /// For wakes: true when macOS woke without the display (background or dark wake).
    public var dark: Bool?
    /// Human-readable Modafinil action for `.note` events.
    public var note: String?

    public init(kind: Kind, at: Double, reason: String? = nil, pid: Int32? = nil,
                dark: Bool? = nil, note: String? = nil) {
        self.kind = kind; self.at = at; self.reason = reason
        self.pid = pid; self.dark = dark; self.note = note
    }
}

/// A point-in-time view of the kernel and IOPMrootDomain sleep/wake bookkeeping.
/// Reading it costs a few sysctl/registry lookups and never wakes the Mac.
public struct PowerSnapshot: Equatable {
    public var slept: Double
    public var woke: Double
    public var boot: Double
    public var lastSleepReason: String?
    public var sleepRequestedByPID: Int32?
    public var wakeReason: String?
    public var wakeType: String?
    public var capabilities: Int?

    public init(slept: Double, woke: Double, boot: Double, lastSleepReason: String? = nil,
                sleepRequestedByPID: Int32? = nil, wakeReason: String? = nil,
                wakeType: String? = nil, capabilities: Int? = nil) {
        self.slept = slept; self.woke = woke; self.boot = boot
        self.lastSleepReason = lastSleepReason; self.sleepRequestedByPID = sleepRequestedByPID
        self.wakeReason = wakeReason; self.wakeType = wakeType; self.capabilities = capabilities
    }

    /// kIOPMSystemCapabilityGraphics: absent during a dark (background) wake.
    public static let graphicsCapability = 0x2

    public var hasGraphics: Bool? {
        capabilities.map { $0 & Self.graphicsCapability != 0 }
    }

    public var combinedWakeReason: String? {
        let parts = [wakeReason, wakeType].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    public static func read() -> PowerSnapshot? {
        guard let times = try? SystemSleepTimes.read() else { return nil }
        var snapshot = PowerSnapshot(slept: times.slept, woke: times.woke, boot: times.boot)
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return snapshot }
        defer { IOObjectRelease(rootDomain) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        snapshot.lastSleepReason = property("Last Sleep Reason") as? String
        snapshot.sleepRequestedByPID = (property("SleepRequestedByPID") as? NSNumber)?.int32Value
        snapshot.wakeReason = property("Wake Reason") as? String
        snapshot.wakeType = property("Wake Type") as? String
        snapshot.capabilities = (property("System Capabilities") as? NSNumber)?.intValue
        if snapshot.wakeReason == nil {
            var size = 0
            if sysctlbyname("kern.wakereason", nil, &size, nil, 0) == 0, size > 1 {
                var buffer = [CChar](repeating: 0, count: size)
                if sysctlbyname("kern.wakereason", &buffer, &size, nil, 0) == 0 {
                    snapshot.wakeReason = String(cString: buffer)
                }
            }
        }
        return snapshot
    }
}

/// Plain-language interpretation of macOS reason strings.
public enum PowerReason {
    public enum WakeCause: String, Codable, CaseIterable {
        case lid, userInput, network, alarm, maintenance, backgroundTask, power, unknown

        public var title: String {
            switch self {
            case .lid: return "Lid opened"
            case .userInput: return "Keyboard, trackpad or power button"
            case .network: return "Network activity"
            case .alarm: return "Scheduled wake alarm"
            case .maintenance: return "macOS maintenance"
            case .backgroundTask: return "macOS background task"
            case .power: return "Power adapter or battery change"
            case .unknown: return "Other"
            }
        }

        /// Maintenance and scheduled background work are macOS housekeeping;
        /// they must not start Modafinil's remote-recovery keep-awake lease.
        public var isHousekeeping: Bool { self == .maintenance || self == .backgroundTask }
    }

    public static func wakeCause(_ reason: String?) -> WakeCause {
        guard let text = reason?.lowercased(), !text.isEmpty else { return .unknown }
        if text.contains("rtc/maintenance") || text.hasSuffix("/maintenance") { return .maintenance }
        if text.contains("sleepservice") { return .backgroundTask }
        if text.contains(" lid") || text.hasPrefix("lid") || text.contains("lidopen") { return .lid }
        if text.contains("hid") || text.contains("keyboard") || text.contains("trackpad")
            || text.contains("pwrbtn") || text.contains("power button") || text.contains("useractivity") { return .userInput }
        if text.contains("e_rx_ip_packet") || text.contains("wifibt") || text.contains("wlan")
            || text.contains("arpt") || text.contains("en0") || text.contains("network")
            // Wired Ethernet wakes (Mac mini): "enet SMC.OutboxNotEmpty lan0/".
            || text.contains("enet") || text.contains("lan0") { return .network }
        if text.contains("rtc") || text.contains("alarm") { return .alarm }
        if text.contains("acattach") || text.contains("ac attach") || text.contains("charger")
            || text.contains("battery") || text.contains("usb-c") || text.contains("adapter") { return .power }
        return .unknown
    }

    public enum SleepCause: String, Codable {
        case modafinil, software, idle, lidClosed, backToSleep, lowBattery, powerButton, thermal, unknown
    }

    public static func sleepCause(_ reason: String?, pid: Int32?, modafinilPIDs: Set<Int32> = []) -> SleepCause {
        guard let text = reason?.lowercased(), !text.isEmpty else { return .unknown }
        if text.contains("software") {
            if let pid, modafinilPIDs.contains(pid) { return .modafinil }
            return .software
        }
        if text.contains("idle") { return .idle }
        if text.contains("clamshell") || text.contains("lid") { return .lidClosed }
        if text.contains("back to sleep") || text.contains("maintenance") { return .backToSleep }
        if text.contains("low power") || text.contains("battery") { return .lowBattery }
        if text.contains("power button") { return .powerButton }
        if text.contains("thermal") { return .thermal }
        return .unknown
    }

    public static func sleepTitle(_ cause: SleepCause, raw: String?, attribution: String? = nil) -> String {
        switch cause {
        case .modafinil: return attribution.map { "Modafinil (\($0))" } ?? "Modafinil"
        case .software: return attribution.map { "Modafinil (\($0))" } ?? "An app requested sleep"
        case .idle: return "Idle sleep"
        case .lidClosed: return "Lid closed"
        case .backToSleep: return "Back to sleep after background wake"
        case .lowBattery: return "Low battery"
        case .powerButton: return "Power button"
        case .thermal: return "Too hot"
        case .unknown: return raw ?? "Unknown"
        }
    }
}

public struct PowerSegment: Equatable {
    public enum State: String, Codable { case awake, background, asleep, unknown }
    public var start: Double
    public var end: Double
    public var state: State
    public var reason: String
    public var wakeCause: PowerReason.WakeCause?
    public var duration: Double { max(0, end - start) }

    public init(start: Double, end: Double, state: State, reason: String,
                wakeCause: PowerReason.WakeCause? = nil) {
        self.start = start; self.end = end; self.state = state
        self.reason = reason; self.wakeCause = wakeCause
    }
}

public struct PowerMarker: Equatable {
    public var at: Double
    public var text: String
    public init(at: Double, text: String) { self.at = at; self.text = text }
}

public struct PowerSummary: Equatable {
    public var asleep: Double = 0
    public var background: Double = 0
    public var awake: Double = 0
    public var unknown: Double = 0
    public var backgroundWakes = 0
    public var longestBackground: Double = 0
    public var wakeCauses: [PowerReason.WakeCause: Int] = [:]
    public init() {}
}

/// Builds a timeline from recorded events. Between a recorded sleep and the next
/// wake the Mac is assumed asleep; periods without data are labelled unknown.
public enum PowerTimeline {
    public static let modafinilSleepWindow: Double = 45

    public static func build(events unsorted: [PowerEvent], from: Double, to: Double,
                             modafinilPIDs: Set<Int32> = []) -> (segments: [PowerSegment], markers: [PowerMarker]) {
        let events = unsorted.enumerated().sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.map(\.element)
        var segments: [PowerSegment] = []
        var markers: [PowerMarker] = []
        var current: PowerSegment?
        var lastSleepRequest: (at: Double, source: String)?

        func close(at time: Double) {
            guard var segment = current else { return }
            segment.end = max(segment.start, time)
            if segment.end > segment.start { segments.append(segment) }
            current = nil
        }
        func open(_ state: PowerSegment.State, at time: Double, reason: String,
                  cause: PowerReason.WakeCause? = nil) {
            close(at: time)
            current = PowerSegment(start: time, end: time, state: state, reason: reason, wakeCause: cause)
        }

        for event in events {
            switch event.kind {
            case .note:
                if let text = event.note {
                    markers.append(PowerMarker(at: event.at, text: text))
                    if let source = sleepRequestSource(text) { lastSleepRequest = (event.at, source) }
                }
            case .boot:
                open(.unknown, at: event.at, reason: "Mac restarted; Modafinil was not running")
            case .appStart:
                if current == nil || current?.state == .unknown {
                    open(.awake, at: event.at, reason: "Modafinil started")
                }
            case .appStop:
                open(.unknown, at: event.at, reason: "Modafinil was not running")
            case .sleep:
                var cause = PowerReason.sleepCause(event.reason, pid: event.pid, modafinilPIDs: modafinilPIDs)
                var attribution: String?
                if cause == .software || cause == .modafinil,
                   let request = lastSleepRequest, event.at - request.at >= -2,
                   event.at - request.at <= modafinilSleepWindow {
                    cause = .modafinil
                    attribution = request.source
                }
                open(.asleep, at: event.at, reason: PowerReason.sleepTitle(cause, raw: event.reason, attribution: attribution))
            case .wake:
                let cause = PowerReason.wakeCause(event.reason)
                let state: PowerSegment.State = event.dark == false ? .awake : .background
                open(state, at: event.at, reason: cause == .unknown ? (event.reason ?? cause.title) : cause.title, cause: cause)
            case .fullWake:
                // A user wake starts dark for a few seconds; count it as awake throughout.
                if var segment = current, segment.state == .background, event.at - segment.start <= 30 {
                    segment.state = .awake
                    current = segment
                } else if current?.state == .background || current?.state == .asleep || current == nil {
                    let cause = current?.wakeCause
                    open(.awake, at: event.at, reason: cause.map { "Woke: \($0.title)" } ?? "Display on", cause: cause)
                }
            }
        }
        // The app records live while it runs, so the last state lasts until `to`.
        close(at: to)
        let clipped = segments.compactMap { segment -> PowerSegment? in
            guard segment.end > from, segment.start < to else { return nil }
            var copy = segment
            copy.start = max(from, segment.start); copy.end = min(to, segment.end)
            return copy.end > copy.start ? copy : nil
        }
        return (clipped, markers.filter { $0.at >= from && $0.at <= to })
    }

    public static func summarize(_ segments: [PowerSegment]) -> PowerSummary {
        var summary = PowerSummary()
        for segment in segments {
            switch segment.state {
            case .asleep: summary.asleep += segment.duration
            case .awake: summary.awake += segment.duration
            case .unknown: summary.unknown += segment.duration
            case .background:
                summary.background += segment.duration
                summary.backgroundWakes += 1
                summary.longestBackground = max(summary.longestBackground, segment.duration)
            }
            if let cause = segment.wakeCause, segment.state != .unknown, segment.state != .asleep,
               !segment.reason.hasPrefix("Woke:") {
                summary.wakeCauses[cause, default: 0] += 1
            }
        }
        return summary
    }

    static func sleepRequestSource(_ note: String) -> String? {
        let prefix = "Sleep requested ("
        guard note.hasPrefix(prefix), note.hasSuffix(")") else { return nil }
        return String(note.dropFirst(prefix.count).dropLast())
    }
}

/// Append-only JSON-lines store with bounded retention.
public final class PowerHistoryStore {
    public static let retention: Double = 60 * 24 * 3600
    public let url: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(url: URL = PowerHistoryStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Modafinil/power-history.jsonl")
    }

    public func load() -> [PowerEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0a).compactMap { try? decoder.decode(PowerEvent.self, from: Data($0)) }
    }

    public func append(_ events: [PowerEvent]) throws {
        guard !events.isEmpty else { return }
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0a)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Drops events older than the retention window. Returns the kept events.
    @discardableResult
    public func compact(now: Double) throws -> [PowerEvent] {
        let events = load()
        let kept = events.filter { $0.at >= now - Self.retention }
        guard kept.count != events.count else { return events }
        var data = Data()
        for event in kept {
            data.append(try encoder.encode(event))
            data.append(0x0a)
        }
        try data.write(to: url, options: .atomic)
        return kept
    }
}

/// Turns snapshots into new events without duplicates.
public struct PowerRecorderState: Equatable {
    public var lastSleep: Double = 0
    public var lastWake: Double = 0
    public var lastBoot: Double = 0
    public init() {}

    public init(events: [PowerEvent]) {
        for event in events {
            switch event.kind {
            case .sleep: lastSleep = max(lastSleep, event.at)
            case .wake: lastWake = max(lastWake, event.at)
            case .boot: lastBoot = max(lastBoot, event.at)
            default: break
            }
        }
    }

    /// Events implied by a snapshot taken at app start or after a wake.
    /// `onStart` also records a restart when the boot time changed.
    public mutating func events(for snapshot: PowerSnapshot, onStart: Bool = false) -> [PowerEvent] {
        var result: [PowerEvent] = []
        if onStart, snapshot.boot > 0, abs(snapshot.boot - lastBoot) > 1 {
            result.append(PowerEvent(kind: .boot, at: snapshot.boot))
            lastBoot = snapshot.boot
        }
        if snapshot.slept > snapshot.boot, snapshot.slept > lastSleep + 0.5 {
            result.append(PowerEvent(kind: .sleep, at: snapshot.slept, reason: snapshot.lastSleepReason,
                                     pid: snapshot.sleepRequestedByPID))
            lastSleep = snapshot.slept
        }
        if snapshot.woke > snapshot.boot, snapshot.woke >= snapshot.slept, snapshot.woke > lastWake + 0.5 {
            result.append(PowerEvent(kind: .wake, at: snapshot.woke, reason: snapshot.combinedWakeReason,
                                     dark: snapshot.hasGraphics.map { !$0 }))
            lastWake = snapshot.woke
        }
        return result
    }
}

/// Decides whether a system wake should start the 90-second recovery keep-awake.
public enum WakeRecoveryPolicy {
    public static let quietPeriodAfterSleepRequest: TimeInterval = 120
    public static let minimumBackgroundInterval: TimeInterval = 600

    /// - Parameters:
    ///   - hasGraphics: the display side woke (full wake). nil is treated as background.
    ///   - sinceSleepRequest: seconds since Modafinil last requested sleep.
    ///   - sinceLastBackgroundLease: seconds since a background wake last started one.
    public static func shouldStartLease(hasGraphics: Bool?, cause: PowerReason.WakeCause,
                                        sinceSleepRequest: TimeInterval?,
                                        sinceLastBackgroundLease: TimeInterval?) -> Bool {
        if hasGraphics == true { return !cause.isHousekeeping }
        // Background wakes happen many times a night. Only a network wake can be the
        // iPhone's wake request, and it must not repeat into a night of keep-awake.
        guard cause == .network else { return false }
        if let since = sinceSleepRequest, since < quietPeriodAfterSleepRequest { return false }
        if let since = sinceLastBackgroundLease, since < minimumBackgroundInterval { return false }
        return true
    }
}
