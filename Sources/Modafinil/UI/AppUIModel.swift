import Foundation
import ModafinilShared
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, timers, history, iPhone, otherMacs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .timers: return "Timers"
        case .history: return "Sleep History"
        case .iPhone: return "iPhone"
        case .otherMacs: return "Other Macs"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .timers: return "timer"
        case .history: return "chart.bar.xaxis"
        case .iPhone: return "iphone"
        case .otherMacs: return "desktopcomputer"
        case .settings: return "gearshape"
        }
    }
}

/// Everything the windows show. Built by AppDelegate only while a view is visible.
struct AppSnapshot {
    enum Tone { case active, off, waiting, warning, busy }

    var tone: Tone = .off
    var title = "Keep-awake is off"
    var explanation = ""
    var isKeepAwakeRequested = false
    var isSleepPreventionActive = false
    var isBusy = false
    var isCodexLimitEnabled = false
    var isCodexRunning = false
    var isT3SleepEnabled = false
    /// False on a Mac mini or other desktop: the closed-lid T3 rule is hidden.
    var hasBuiltInLid = true
    /// One line about T3 Code, e.g. "T3 threads: 2 working". Nil when the feature is off.
    var t3Status: String?
    var t3Threads: [T3ThreadRow] = []
    var t3SleepAt: Date?
    var isT3RestorePending = false
    var isQuitBlockersEnabled = false
    /// Apps that would be asked to quit right now.
    var quitCandidates: [String] = []
    var quitExclusions: [AppChoice] = []
    /// Running apps that can be added to the exclusions.
    var excludableApps: [AppChoice] = []
    var helperStatus = ""
    var isHelperEnabled = false
    var scheduledSleepDate: Date?
    var scheduledWakeDate: Date?
    var canScheduleSleep = false
    var canScheduleWake = false
    var sleepAttempt: SleepAttempt?
    var lastError: String?
    var loginItemStatus = ""
    var isLoginItemEnabled = false
    var companionStatus = ""
    var isRemoteWakeArmed = false
    var isWakeRecoveryActive = false
    var tailscaleAddress: String?
    var relayHost: String?
    var blockers: [SleepBlocker] = []
    var version = ""
}

struct AppChoice: Hashable {
    var bundleID: String
    var name: String
}

struct T3ThreadRow: Hashable {
    var title: String
    var isWaiting: Bool
    /// The turn has ended but background work it started is still running.
    var isInBackground = false
}

@MainActor
protocol AppUIActions: AnyObject {
    func uiToggleKeepAwake()
    func uiToggleCodexLimit()
    func uiToggleT3Sleep()
    func uiToggleQuitBlockers()
    func uiSetQuitExclusion(bundleID: String, name: String, excluded: Bool)
    func uiToggleLoginItem()
    func uiScheduleSleep(after seconds: Int)
    func uiCancelSleepTimer()
    func uiScheduleWake(at date: Date)
    func uiCancelWake()
    func uiOpenCompanionSetup()
    func uiOpenBackgroundSettings()
    func uiOpenMainWindow(_ section: AppSection)
    func uiQuit()
    func uiUninstall()
    func uiTimeline(from: Date, to: Date) -> (segments: [PowerSegment], markers: [PowerMarker])
}

@MainActor
final class AppUIModel: ObservableObject {
    @Published var snapshot = AppSnapshot()
    @Published var section: AppSection = .overview
    /// Bumped after wakes so the history page reloads while visible.
    @Published var historyRevision = 0
    weak var actions: AppUIActions?

    func timeline(from: Date, to: Date) -> (segments: [PowerSegment], markers: [PowerMarker]) {
        actions?.uiTimeline(from: from, to: to) ?? ([], [])
    }
}

// MARK: Shared formatting

/// "Sleep when T3 Code finishes" wording: a closed lid on a MacBook, nobody using the
/// keyboard or mouse on a desktop (a headless Mac mini).
enum T3SleepWording {
    static var isDesktop: Bool { !LidMonitor.hasBuiltInLid }
    static var condition: String { isDesktop ? "nobody has used it for 5 minutes" : "the lid is closed" }
    static var shortTitle: String { isDesktop ? "Sleep when T3 Code threads finish (unused)" : "Sleep when T3 Code threads finish (lid closed)" }
    static var toggleTitle: String {
        isDesktop ? "Sleep once all T3 threads finish and nobody is using the Mac"
                  : "Sleep with the lid closed once all T3 threads finish"
    }
    static var rule: String {
        isDesktop
            ? "When no keyboard or mouse has been used for 5 minutes (displays do not matter), the Mac sleeps 1 minute after the last T3 thread on this Mac stops working or waiting. Using the Mac again, or Wake & Keep Awake, turns keep-awake back on. After a remote wake it waits up to 30 minutes for a T3 thread to start."
            : "With the lid closed and no external display, the Mac sleeps 1 minute after the last T3 thread on this Mac stops working or waiting. Keep-awake turns back on when you open the lid."
    }
    static var restore: String {
        isDesktop ? "The Mac slept after T3 Code finished. Keep-awake turns back on when someone uses it or wakes it remotely."
                  : "The Mac slept after T3 Code finished. Keep-awake turns back on when you open the lid."
    }
    static var off: String {
        isDesktop ? "Off. The Mac stays awake for as long as keep-awake is on."
                  : "Off. The Mac stays awake with the lid closed for as long as keep-awake is on."
    }
}

enum UIFormat {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayAndTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today, \(time(date))" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow, \(time(date))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time(date))" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func stateTitle(_ state: PowerSegment.State) -> String {
        switch state {
        case .awake: return "Awake"
        case .background: return "Background wake"
        case .asleep: return "Asleep"
        case .unknown: return "No data"
        }
    }

    static func stateColor(_ state: PowerSegment.State) -> Color {
        switch state {
        case .awake: return .green
        case .background: return .orange
        case .asleep: return .indigo
        case .unknown: return Color.gray.opacity(0.45)
        }
    }

    static func sleepResultTitle(_ attempt: SleepAttempt) -> String {
        switch attempt.phase {
        case .pending: return "Verifying sleep…"
        case .confirmed: return "Sleep confirmed"
        case .failed: return "Sleep not confirmed"
        case .cancelled: return "Sleep request cancelled"
        }
    }
}

extension AppSnapshot.Tone {
    var color: Color {
        switch self {
        case .active: return .green
        case .off: return .secondary
        case .waiting: return .orange
        case .warning: return .orange
        case .busy: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .active: return "eye.fill"
        case .off: return "eye.slash.fill"
        case .waiting: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .busy: return "arrow.triangle.2.circlepath"
        }
    }
}
