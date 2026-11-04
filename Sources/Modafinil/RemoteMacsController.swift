import AppKit
import Foundation
import ModafinilRemoteProtocol

/// Wakes, keeps awake and puts to sleep other Macs running Modafinil (for example a
/// Mac mini workstation), with the same signed protocol the iPhone uses. Status is
/// read only when a Modafinil view opens or after an action: polling could keep a
/// sleeping Mac's network busy.
@MainActor
final class RemoteMacsController: ObservableObject {
    enum Phase: Equatable {
        case unknown
        case checking
        /// Answered; Modafinil keeps it awake.
        case awake
        /// Answered; keep-awake is off, so it sleeps normally.
        case reachable
        case sleepRequested
        /// No answer: asleep, off, or off Tailscale.
        case unreachable
        case working(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .working: return true
            default: return false
            }
        }
    }

    struct Mac: Identifiable, Equatable {
        var configuration: PairingConfiguration
        var phase: Phase = .unknown
        var lastChecked: Date?
        var scheduledSleepAt: Date?
        var sleepAttempt: RemoteSleepAttempt?
        var id: String { RemoteMacStore.identifier(configuration) }
        var name: String { configuration.displayName }
    }

    @Published private(set) var macs: [Mac] = []
    @Published private(set) var storeError: String?

    private let store = RemoteMacStore()
    private var generations: [String: Int] = [:]
    private var lastRefreshAll: Date?

    init() { reload() }

    /// Re-reads the keychain, keeping each known Mac's live status.
    func reload() {
        do {
            let saved = try store.load()
            storeError = nil
            macs = saved.map { configuration in
                var mac = macs.first { $0.id == RemoteMacStore.identifier(configuration) } ?? Mac(configuration: configuration)
                mac.configuration = configuration
                return mac
            }
        } catch {
            storeError = error.localizedDescription
        }
    }

    /// Refreshes every idle Mac; at most every 10 seconds unless forced.
    func refreshAll(force: Bool = false) {
        reload()
        if !force, let last = lastRefreshAll, Date().timeIntervalSince(last) < 10 { return }
        lastRefreshAll = Date()
        for mac in macs where !mac.phase.isBusy {
            Task { await refresh(mac.id) }
        }
    }

    // MARK: Pairing

    /// Adds a Mac from the pairing link shown in Companion Setup on that Mac.
    func add(pairingLink text: String) throws -> String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteMacError("Paste the pairing link from Companion Setup on the other Mac.")
        }
        let configuration = try PairingConfiguration(pairingURL: url)
        if let own = CompanionNetworkInformation.discover().tailscaleIPv4, own == configuration.macHost {
            throw RemoteMacError("That is this Mac’s own pairing link. Copy it on the other Mac.")
        }
        try store.upsert(configuration)
        reload()
        Task { await refresh(RemoteMacStore.identifier(configuration)) }
        return configuration.displayName
    }

    func remove(_ id: String) {
        do {
            try store.save(macs.map(\.configuration).filter { RemoteMacStore.identifier($0) != id })
            generations[id, default: 0] &+= 1
            reload()
        } catch {
            storeError = error.localizedDescription
        }
    }

    func pairingLink(_ id: String) -> String? {
        macs.first { $0.id == id }?.configuration.pairingURL.absoluteString
    }

    // MARK: Commands

    func refresh(_ id: String) async {
        guard let mac = mac(id), !mac.phase.isBusy else { return }
        let fallback = mac.phase
        let generation = begin(id, .checking)
        do {
            let response = try await send(mac.configuration, .status, timeout: 4)
            guard isCurrent(id, generation) else { return }
            apply(response, to: id)
        } catch {
            guard isCurrent(id, generation) else { return }
            if error is CancellationError { update(id) { $0.phase = fallback }; return }
            fail(id, error)
        }
    }

    /// Wakes the Mac if needed and turns its keep-awake on, like the iPhone's
    /// Wake & Keep Awake: direct first, then Wake-on-LAN from this Mac and the relay.
    func wakeAndKeepAwake(_ id: String) async {
        guard let mac = mac(id) else { return }
        let configuration = mac.configuration
        let generation = begin(id, .working("Contacting…"))
        do {
            let response = try await send(configuration, .keepAwake, argument: "0", timeout: WakeRecovery.macCheckTimeout)
            guard isCurrent(id, generation) else { return }
            apply(response, to: id)
            return
        } catch {
            guard isCurrent(id, generation), !(error is CancellationError) else { return }
            guard RemoteMacClient.indicatesUnavailableDevice(error) else { fail(id, error); return }
        }
        update(id) { $0.phase = .working("Waking…") }
        do {
            let response = try await WakeRecovery.run(
                contactMac: { timeout in
                    guard self.isCurrent(id, generation) else { throw CancellationError() }
                    return try await self.send(configuration, .keepAwake, argument: "0", timeout: timeout)
                },
                wakeRelay: { timeout in
                    guard self.isCurrent(id, generation) else { throw CancellationError() }
                    let targets = self.mac(id)?.configuration.targetMAC ?? configuration.targetMAC
                    // At home this reaches the sleeping Mac directly.
                    LocalWakeOnLAN.send(targets: targets)
                    guard !configuration.relayHost.isEmpty else { return }
                    _ = try await RemoteMacClient(secret: configuration.relaySecret).send(
                        .wake, argument: targets, host: configuration.relayHost,
                        port: configuration.relayPort, timeout: timeout, label: "relay wake")
                },
                isUnavailable: RemoteMacClient.indicatesUnavailableDevice,
                isRelayRetryable: RemoteMacClient.indicatesRetryableRelayFailure,
                onProgress: {
                    if self.isCurrent(id, generation) { self.update(id) { $0.phase = .working("Reconnecting…") } }
                }
            )
            guard isCurrent(id, generation) else { return }
            apply(response, to: id)
        } catch {
            guard isCurrent(id, generation), !(error is CancellationError) else { return }
            fail(id, error)
        }
    }

    func sleepNow(_ id: String) async {
        await command(id, .sleep, working: "Putting to sleep…")
        guard let attempt = mac(id)?.sleepAttempt, attempt.phase == .pending else { return }
        // No follow-up status check: on Ethernet, a connection attempt can itself wake
        // a sleeping Mac mini. The next check (when a view opens) shows the result.
        try? await Task.sleep(for: .seconds(40))
        if mac(id)?.phase == .sleepRequested { update(id) { $0.phase = .unreachable } }
    }

    func sleep(_ id: String, after seconds: Int) async {
        await command(id, .scheduleSleep, argument: String(seconds), working: "Setting sleep timer…")
    }

    func cancelSleepTimer(_ id: String) async {
        await command(id, .cancelScheduledSleep, working: "Cancelling sleep timer…")
    }

    private func command(_ id: String, _ command: RemoteCommand, argument: String = "", working: String) async {
        guard let mac = mac(id), !mac.phase.isBusy else { return }
        let generation = begin(id, .working(working))
        do {
            let response = try await send(mac.configuration, command, argument: argument)
            guard isCurrent(id, generation) else { return }
            apply(response, to: id)
        } catch {
            guard isCurrent(id, generation), !(error is CancellationError) else { return }
            fail(id, error)
        }
    }

    // MARK: Helpers

    /// Newest protocol first, falling back for a Mac that has not been updated.
    private func send(_ configuration: PairingConfiguration, _ command: RemoteCommand,
                      argument: String = "", timeout: TimeInterval = 6) async throws -> RemoteResponse {
        var lastError: Error?
        for version in [RemoteRequest.t3SleepVersion, RemoteRequest.sleepHistoryVersion, RemoteRequest.wakeRecoveryVersion] {
            do {
                return try await RemoteMacClient(secret: configuration.secret, protocolVersion: version)
                    .send(command, argument: argument, host: configuration.macHost,
                          port: configuration.macPort, timeout: timeout)
            } catch where RemoteMacClient.indicatesServerUpdateRequired(error) {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    private func apply(_ response: RemoteResponse, to id: String) {
        guard let state = response.state else {
            update(id) { $0.phase = .failed("The Mac’s answer did not include its state.") }
            return
        }
        if response.version >= RemoteResponse.wakeRecoveryVersion, let targets = state.wakeTargetMACs,
           let current = mac(id)?.configuration, let updated = try? current.updatingWakeTargets(targets),
           updated != current {
            // Verified answer from that Mac: keep its current wake addresses.
            try? store.upsert(updated)
            update(id) { $0.configuration = updated }
        }
        update(id) { mac in
            mac.lastChecked = Date()
            mac.sleepAttempt = state.sleepAttempt
            mac.scheduledSleepAt = state.scheduledSleepAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            if state.sleepPreventionEffective { mac.phase = .awake }
            else if state.sleepAttempt?.phase == .pending { mac.phase = .sleepRequested }
            else { mac.phase = .reachable }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        update(id) {
            $0.phase = RemoteMacClient.indicatesUnavailableDevice(error) ? .unreachable : .failed(error.localizedDescription)
        }
    }

    private func mac(_ id: String) -> Mac? { macs.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        change(&macs[index])
    }

    private func begin(_ id: String, _ phase: Phase) -> Int {
        generations[id, default: 0] &+= 1
        update(id) { $0.phase = phase }
        return generations[id]!
    }

    private func isCurrent(_ id: String, _ generation: Int) -> Bool {
        generations[id] == generation && mac(id) != nil
    }
}

struct RemoteMacError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
