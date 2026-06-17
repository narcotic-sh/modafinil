import Foundation
import ModafinilShared

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: ModafinilConstants.helperMachServiceName)
    private let stateQueue = DispatchQueue(label: "com.narcotic.modafinil.helper.state")
    private let idleExitDelay: TimeInterval = 15
    private var connectedSessionIDs = Set<UUID>()
    private var activeLeaseIDs = Set<UUID>()
    private var idleExitWorkItem: DispatchWorkItem?
    private let ownershipMarkerURL = URL(
        fileURLWithPath: "/Library/Application Support/Modafinil/sleep-prevention.enabled"
    )

    override init() {
        super.init()
        // Bind authorization to the XPC peer instead of re-checking a reusable PID.
        listener.setConnectionCodeSigningRequirement(ModafinilConstants.appSigningRequirement)
        listener.delegate = self
        performStartupCleanup()
    }

    func run() {
        listener.resume()
        RunLoop.current.run()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let session = HelperSession(service: self)
        clientConnectionStarted(sessionID: session.id)

        newConnection.exportedInterface = NSXPCInterface(with: ModafinilHelperProtocol.self)
        newConnection.exportedObject = session
        newConnection.invalidationHandler = { [weak self] in
            self?.clientConnectionEnded(sessionID: session.id)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.clientConnectionEnded(sessionID: session.id)
        }
        newConnection.resume()
        return true
    }

    fileprivate func setSleepPreventionEnabled(
        _ enabled: Bool,
        sessionID: UUID,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                if enabled {
                    do {
                        try self.writeOwnershipMarker()
                        try self.setSystemSleepPreventionEnabled(true)
                        self.activeLeaseIDs.insert(sessionID)
                        reply(true, nil)
                    } catch {
                        self.removeOwnershipMarker()
                        reply(false, error.localizedDescription)
                    }
                } else {
                    try self.setSystemSleepPreventionEnabled(false)
                    self.activeLeaseIDs.removeAll()
                    self.removeOwnershipMarker()
                    reply(true, nil)
                }
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    fileprivate func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                let enabled = try self.readSleepPreventionStatus()
                reply(true, enabled, nil)
            } catch {
                reply(false, false, error.localizedDescription)
            }
        }
    }

    private func clientConnectionStarted(sessionID: UUID) {
        stateQueue.async {
            self.connectedSessionIDs.insert(sessionID)
            self.cancelIdleExit()
        }
    }

    private func clientConnectionEnded(sessionID: UUID) {
        stateQueue.async {
            self.connectedSessionIDs.remove(sessionID)
            let hadActiveLease = self.activeLeaseIDs.remove(sessionID) != nil

            if hadActiveLease, self.activeLeaseIDs.isEmpty {
                do {
                    try self.setSystemSleepPreventionEnabled(false)
                    self.removeOwnershipMarker()
                    NSLog("ModafinilHelper restored normal sleep behavior after client disconnect")
                } catch {
                    NSLog("ModafinilHelper could not restore sleep after client disconnect: \(error.localizedDescription)")
                }
            }

            self.scheduleIdleExitIfNeeded()
        }
    }

    private func performStartupCleanup() {
        stateQueue.async {
            self.restoreStaleSleepPreventionIfNeeded()
            self.scheduleIdleExitIfNeeded()
        }
    }

    private func restoreStaleSleepPreventionIfNeeded() {
        guard FileManager.default.fileExists(atPath: ownershipMarkerURL.path) else {
            return
        }

        do {
            try setSystemSleepPreventionEnabled(false)
            activeLeaseIDs.removeAll()
            removeOwnershipMarker()
            NSLog("ModafinilHelper restored stale sleep-prevention state on startup")
        } catch {
            NSLog("ModafinilHelper could not restore stale sleep-prevention state: \(error.localizedDescription)")
        }
    }

    private func scheduleIdleExitIfNeeded() {
        guard connectedSessionIDs.isEmpty, activeLeaseIDs.isEmpty else { return }

        cancelIdleExit()
        let workItem = DispatchWorkItem { [weak self] in
            self?.exitIfStillIdle()
        }
        idleExitWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + idleExitDelay, execute: workItem)
    }

    private func cancelIdleExit() {
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil
    }

    private func exitIfStillIdle() {
        idleExitWorkItem = nil

        guard connectedSessionIDs.isEmpty, activeLeaseIDs.isEmpty else { return }
        NSLog("ModafinilHelper exiting after idle timeout")
        exit(EXIT_SUCCESS)
    }

    private func setSystemSleepPreventionEnabled(_ enabled: Bool) throws {
        try Shell.run("/usr/bin/pmset", ["-a", "disablesleep", enabled ? "1" : "0"])
    }

    private func readSleepPreventionStatus() throws -> Bool {
        let output = try Shell.run("/usr/bin/pmset", ["-g"])
        return output
            .split(separator: "\n")
            .first { $0.contains("SleepDisabled") }?
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .last == "1"
    }

    private func writeOwnershipMarker() throws {
        let directoryURL = ownershipMarkerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: ownershipMarkerURL, options: .atomic)
    }

    private func removeOwnershipMarker() {
        do {
            try FileManager.default.removeItem(at: ownershipMarkerURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            NSLog("ModafinilHelper could not remove sleep-prevention ownership marker: \(error.localizedDescription)")
        }
    }
}

private final class HelperSession: NSObject, ModafinilHelperProtocol {
    let id = UUID()
    private weak var service: HelperService?

    init(service: HelperService) {
        self.service = service
    }

    func setSleepPreventionEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard let service else {
            reply(false, "The helper service is unavailable.")
            return
        }

        service.setSleepPreventionEnabled(enabled, sessionID: id, withReply: reply)
    }

    func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        guard let service else {
            reply(false, false, "The helper service is unavailable.")
            return
        }

        service.getSleepPreventionStatus(withReply: reply)
    }
}
