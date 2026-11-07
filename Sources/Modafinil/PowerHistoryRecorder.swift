import Foundation
import ModafinilRemoteProtocol
import ModafinilShared

/// Records sleep/wake transitions and Modafinil actions. It runs only when macOS
/// reports a transition or Modafinil changes something: there is no timer, and
/// nothing runs while the Mac sleeps.
final class PowerHistoryRecorder {
    private let store: PowerHistoryStore
    private var state: PowerRecorderState
    private(set) var events: [PowerEvent]
    private var lastCompaction = Date().timeIntervalSince1970
    private(set) var lastSnapshot: PowerSnapshot?
    var modafinilPIDs: Set<Int32> = []

    init(store: PowerHistoryStore = PowerHistoryStore()) {
        self.store = store
        events = (try? store.compact(now: Date().timeIntervalSince1970)) ?? store.load()
        state = PowerRecorderState(events: events)
    }

    func recordAppStart() {
        if let snapshot = PowerSnapshot.read() {
            lastSnapshot = snapshot
            append(state.events(for: snapshot, onStart: true))
        }
        append([PowerEvent(kind: .appStart, at: Date().timeIntervalSince1970)])
    }

    /// Called for every system wake. Returns the snapshot used, for wake-cause decisions.
    @discardableResult
    func recordWake() -> PowerSnapshot? {
        guard let snapshot = PowerSnapshot.read() else { return nil }
        lastSnapshot = snapshot
        append(state.events(for: snapshot))
        compactIfDue()
        return snapshot
    }

    /// Called when the display side of macOS wakes (a full, user-visible wake).
    func recordFullWake() {
        let snapshot = recordWake()
        guard snapshot?.hasGraphics != false else { return }
        append([PowerEvent(kind: .fullWake, at: Date().timeIntervalSince1970)])
    }

    func recordAppStop() {
        append([PowerEvent(kind: .appStop, at: Date().timeIntervalSince1970)])
    }

    func note(_ text: String, at date: Date = Date()) {
        append([PowerEvent(kind: .note, at: date.timeIntervalSince1970, note: text)])
    }

    func timeline(from: Date, to: Date) -> (segments: [PowerSegment], markers: [PowerMarker]) {
        PowerTimeline.build(events: events, from: from.timeIntervalSince1970,
                            to: to.timeIntervalSince1970, modafinilPIDs: modafinilPIDs)
    }

    /// Newest-first page that fits comfortably inside one signed response.
    func remoteHistory(from: Int64, to: Int64) -> RemoteHistory {
        let timeline = PowerTimeline.build(events: events, from: Double(from), to: Double(to),
                                           modafinilPIDs: modafinilPIDs)
        let segments = timeline.segments.map { segment in
            RemoteHistorySegment(
                start: Int64(segment.start.rounded(.down)), end: Int64(segment.end.rounded(.up)),
                kind: RemoteHistorySegment.Kind(rawValue: segment.state.rawValue) ?? .unknown,
                reason: String(segment.reason.prefix(80)), cause: segment.wakeCause?.rawValue)
        }
        let markers = timeline.markers.map {
            RemoteHistoryMarker(at: Int64($0.at.rounded(.down)), text: String($0.text.prefix(100)))
        }
        return RemoteHistory.page(from: from, to: to, segments: segments, markers: markers)
    }

    /// The privileged helper runs during dark wakes that may suspend the app.
    /// Import its bounded kernel observations once, without duplicating UI records.
    func importHelperEvents(_ observed: [PowerEvent]) {
        let known = Set(events.map { "\($0.kind.rawValue)|\($0.at)" })
        let fresh = observed.filter { !known.contains("\($0.kind.rawValue)|\($0.at)") }.sorted { $0.at < $1.at }
        guard !fresh.isEmpty else { return }
        append(fresh)
        state = PowerRecorderState(events: events)
    }

    private func append(_ newEvents: [PowerEvent]) {
        guard !newEvents.isEmpty else { return }
        events += newEvents
        do { try store.append(newEvents) }
        catch { NSLog("Modafinil could not save sleep history: \(error.localizedDescription)") }
    }

    private func compactIfDue() {
        let now = Date().timeIntervalSince1970
        guard now - lastCompaction > 24 * 3600 else { return }
        lastCompaction = now
        if let kept = try? store.compact(now: now) { events = kept }
    }
}
