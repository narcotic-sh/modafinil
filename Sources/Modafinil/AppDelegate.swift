import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helperClient = PrivilegedHelperClient()
    private let helperInstaller = PrivilegedHelperInstaller()
    private let lidMonitor = LidMonitor()

    private var statusItem: NSStatusItem!
    private var isSleepPreventionEnabled = false
    private var isToggleInFlight = false
    private var helperStatus: SMAppService.Status = .notRegistered
    private var lastError: String?
    private var sleepStatusGeneration = 0
    private var isQuitInProgress = false
    private var isTerminatingAfterCleanup = false
    private var isSleepRestoreInProgress = false
    private var selectedTimerLimit = SleepPreventionTimeLimit.savedValue(
        key: AppDelegate.selectedTimerLimitDefaultsKey
    )
    private var deactivationDeadline = AppDelegate.savedDeactivationDeadline()
    private var deactivationTimer: DispatchSourceTimer?
    private var deactivationTimerGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Modafinil applicationDidFinishLaunching")

        guard ensureRunningFromApplicationsAtLaunch() else {
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        do {
            try lidMonitor.start()
        } catch {
            lastError = error.localizedDescription
        }

        refreshHelperStatus()
        refreshSleepStatus()
        refreshIcon()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingAfterCleanup {
            return .terminateNow
        }

        if isQuitInProgress {
            return .terminateCancel
        }

        quit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        parkDeactivationTimer()
        helperClient.invalidate()
        lidMonitor.stop()
    }

    @objc private func screenParametersDidChange() {
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            showMenu()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showMenu()
            return
        }

        toggleSleepPrevention()
    }

    @objc private func toggleSleepPrevention() {
        guard !isSleepOperationInFlight else { return }

        lastError = nil

        let nextState = !isSleepPreventionEnabled

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            installHelper(stateAfterInstall: nextState)
            return
        }

        setSleepPreventionEnabled(nextState, reason: .userAction)
    }

    private func setSleepPreventionEnabled(
        _ enabled: Bool,
        reason: SleepPreventionChangeReason
    ) {
        let previousState = isSleepPreventionEnabled
        let previousDeactivationDeadline = deactivationDeadline
        isToggleInFlight = true
        sleepStatusGeneration += 1
        isSleepPreventionEnabled = enabled
        lidMonitor.setEnabled(enabled)
        if !enabled {
            switch reason {
            case .timerExpired:
                parkDeactivationTimer()
            case .userAction:
                cancelDeactivationTimer()
            }
        }
        refreshIcon()

        helperClient.setSleepPreventionEnabled(enabled) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                self.lastError = nil
                if enabled {
                    self.lidMonitor.turnDisplayOffIfNeeded()
                    self.scheduleDeactivationTimerIfNeeded()
                } else {
                    self.cancelDeactivationTimer()
                    if reason == .timerExpired {
                        self.sleepNowIfNeededAfterTimerExpiry()
                    }
                }
            case .failure(let error):
                self.isSleepPreventionEnabled = previousState
                self.lidMonitor.setEnabled(previousState)
                if previousState, let previousDeactivationDeadline {
                    switch reason {
                    case .timerExpired:
                        self.scheduleDeactivationTimer(
                            until: previousDeactivationDeadline,
                            minimumDelay: Self.deactivationRetryDelay
                        )
                    case .userAction:
                        self.restoreDeactivationTimer(until: previousDeactivationDeadline)
                    }
                } else if previousState {
                    self.setDeactivationDeadline(nil)
                } else {
                    self.cancelDeactivationTimer()
                }
                self.lastError = error.localizedDescription
            }

            self.isToggleInFlight = false
            self.refreshIcon()
        }
    }

    @objc private func installHelper() {
        installHelper(stateAfterInstall: nil)
    }

    private func installHelper(stateAfterInstall: Bool?) {
        lastError = nil

        do {
            try helperInstaller.register()
        } catch {
            if helperInstaller.status != .enabled {
                lastError = error.localizedDescription
            }
        }

        refreshHelperStatus()

        if let stateAfterInstall, helperStatus == .enabled {
            setSleepPreventionEnabled(stateAfterInstall, reason: .userAction)
            return
        }

        if helperStatus == .requiresApproval {
            helperInstaller.openApprovalSettings()
        }

        refreshIcon()
    }

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Modafinil?"
        alert.informativeText = "Modafinil will be completely uninstalled, and your Mac's regular sleep behavior will be restored."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        lastError = nil
        setControlsEnabled(false)

        disableSleepPreventionForUninstall { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result {
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Uninstall Failed", message: error.localizedDescription)
                return
            }

            do {
                try self.unregisterHelperIfRegistered()
                self.clearPreferences()
                self.deleteAppBundleIfInstalledInApplications()
                self.isTerminatingAfterCleanup = true
                NSApp.terminate(nil)
            } catch {
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Uninstall Failed", message: error.localizedDescription)
            }
        }
    }

    private func unregisterHelperIfRegistered() throws {
        switch helperInstaller.status {
        case .enabled, .requiresApproval:
            try helperInstaller.unregister()
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
    }

    @objc private func openSettings() {
        helperInstaller.openApprovalSettings()
    }

    @objc private func quit() {
        guard !isQuitInProgress else { return }

        lastError = nil
        isQuitInProgress = true
        setControlsEnabled(false)

        restoreNormalSleepBehavior { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result {
                self.isQuitInProgress = false
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Could Not Quit", message: "Modafinil could not restore regular sleep behavior: \(error.localizedDescription)")
                return
            }

            self.isTerminatingAfterCleanup = true
            NSApp.terminate(nil)
        }
    }

    private func disableSleepPreventionForUninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        restoreNormalSleepBehavior(completion: completion)
    }

    private func restoreNormalSleepBehavior(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isToggleInFlight, !isSleepRestoreInProgress else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreNormalSleepBehavior(completion: completion)
            }
            return
        }

        refreshHelperStatus()
        let parkedDeactivationDeadline = deactivationDeadline
        parkDeactivationTimer()
        isSleepRestoreInProgress = true

        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else {
                completion(result)
                return
            }

            switch result {
            case .success:
                self.cancelDeactivationTimer()
            case .failure:
                self.restoreDeactivationTimer(until: parkedDeactivationDeadline)
            }

            self.isSleepRestoreInProgress = false
            completion(result)
        }

        let localSleepPreventionStatus = readLocalSleepPreventionStatus()

        if localSleepPreventionStatus == false {
            isSleepPreventionEnabled = false
            lidMonitor.setEnabled(false)
            finish(.success(()))
            return
        }

        guard helperStatus == .enabled else {
            if localSleepPreventionStatus == true {
                finish(.failure(SleepRestoreError("Sleep prevention is still enabled, but the privileged helper is not enabled.")))
            } else {
                finish(.failure(SleepRestoreError("Modafinil could not confirm or restore regular sleep behavior because the privileged helper is not enabled.")))
            }
            return
        }

        helperClient.setSleepPreventionEnabled(false) { [weak self] result in
            guard let self else {
                completion(result)
                return
            }

            if case .success = result {
                self.isSleepPreventionEnabled = false
                self.lidMonitor.setEnabled(false)
            }

            finish(result)
        }
    }

    private func readLocalSleepPreventionStatus() -> Bool? {
        do {
            let output = try Shell.run("/usr/bin/pmset", ["-g"])
            return output
                .split(separator: "\n")
                .first { $0.contains("SleepDisabled") }?
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .last == "1"
        } catch {
            return nil
        }
    }

    private func sleepNowIfNeededAfterTimerExpiry() {
        guard lidMonitor.shouldSleepOnTimerExpiry() else { return }

        do {
            try Shell.run("/usr/bin/pmset", ["sleepnow"])
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearPreferences() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }

    private func deleteAppBundleIfInstalledInApplications() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let applicationsURL = Self.applicationsDirectoryURL

        guard bundleURL.path.hasPrefix(applicationsURL.path + "/") else {
            return
        }

        let remover = Process()
        remover.executableURL = URL(fileURLWithPath: "/bin/sh")
        remover.arguments = [
            "-c",
            "sleep 1; /bin/rm -rf \"$1\"",
            "modafinil-remover",
            bundleURL.path
        ]

        do {
            try remover.run()
        } catch {
            NSLog("Modafinil could not start app bundle remover: \(error.localizedDescription)")
        }
    }

    private func ensureRunningFromApplicationsAtLaunch() -> Bool {
        if isRunningFromApplications {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Move Modafinil to Applications"
        alert.informativeText = "Modafinil must be run from /Applications. Move Modafinil.app to /Applications, then open it again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit")
        alert.runModal()

        isTerminatingAfterCleanup = true
        NSApp.terminate(nil)
        return false
    }

    private var isRunningFromApplications: Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let applicationsURL = Self.applicationsDirectoryURL.resolvingSymlinksInPath()
        return bundleURL.path.hasPrefix(applicationsURL.path + "/")
    }

    private static let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
    private static let selectedTimerLimitDefaultsKey = "SelectedTimerLimitSeconds"
    private static let activeTimerDeadlineDefaultsKey = "ActiveTimerDeadline"
    private static let deactivationRetryDelay: TimeInterval = 5

    private func setControlsEnabled(_ enabled: Bool) {
        statusItem?.button?.isEnabled = enabled
    }

    private var isSleepOperationInFlight: Bool {
        isToggleInFlight || isSleepRestoreInProgress
    }

    private func refreshHelperStatus() {
        helperStatus = helperInstaller.status
    }

    private func refreshSleepStatus() {
        refreshHelperStatus()
        sleepStatusGeneration += 1
        let generation = sleepStatusGeneration

        if let localSleepPreventionStatus = readLocalSleepPreventionStatus() {
            isSleepPreventionEnabled = localSleepPreventionStatus
            lidMonitor.setEnabled(localSleepPreventionStatus)
            if !localSleepPreventionStatus {
                cancelDeactivationTimer()
            }
            if localSleepPreventionStatus {
                lidMonitor.turnDisplayOffIfNeeded()
                resumeDeactivationTimerIfNeeded()
            }
        } else if helperStatus != .enabled {
            isSleepPreventionEnabled = false
            lidMonitor.setEnabled(false)
            cancelDeactivationTimer()
        }

        guard helperStatus == .enabled else {
            refreshIcon()
            return
        }

        helperClient.getSleepPreventionStatus { [weak self] result in
            guard let self else { return }
            guard generation == self.sleepStatusGeneration else { return }

            switch result {
            case .success(let enabled):
                self.isSleepPreventionEnabled = enabled
                self.lidMonitor.setEnabled(enabled)
                if !enabled {
                    self.cancelDeactivationTimer()
                }
                if enabled {
                    self.lidMonitor.turnDisplayOffIfNeeded()
                    self.resumeDeactivationTimerIfNeeded()
                }
            case .failure(let error):
                self.lastError = error.localizedDescription
            }

            self.refreshIcon()
        }
    }

    private func refreshIcon() {
        let symbolName = isSleepPreventionEnabled ? "eye.fill" : Self.inactiveSymbolName
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isSleepPreventionEnabled ? "Modafinil active" : "Modafinil inactive"
        )?.withSymbolConfiguration(configuration)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true

        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.title = image == nil ? "M" : ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = isSleepPreventionEnabled
            ? "Mac is on Modafinil"
            : "Mac is not on Modafinil"
    }

    @objc private func selectTimerLimit(_ sender: NSMenuItem) {
        guard !isSleepOperationInFlight else { return }
        guard let timerLimit = SleepPreventionTimeLimit(rawValue: sender.tag) else { return }

        selectedTimerLimit = timerLimit
        UserDefaults.standard.set(timerLimit.rawValue, forKey: Self.selectedTimerLimitDefaultsKey)

        if isSleepPreventionEnabled, !isToggleInFlight {
            scheduleDeactivationTimerIfNeeded()
        } else if timerLimit == .none || !isSleepPreventionEnabled {
            cancelDeactivationTimer()
        }

        refreshIcon()
    }

    private func showMenu() {
        refreshHelperStatus()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let statusText = isSleepPreventionEnabled ? "Status: On Modafinil" : "Status: Not on Modafinil"
        let stateItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        if let lastError {
            let errorItem = NSMenuItem(title: "Error: \(lastError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: isSleepPreventionEnabled ? "Turn Off" : "Turn On",
            action: #selector(toggleSleepPrevention),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = !isSleepOperationInFlight
        menu.addItem(toggleItem)

        let timerItem = NSMenuItem(title: timerMenuTitle, action: nil, keyEquivalent: "")
        timerItem.submenu = makeTimerLimitMenu()
        timerItem.isEnabled = !isSleepOperationInFlight
        menu.addItem(timerItem)

        let settingsItem = NSMenuItem(
            title: "Open App Background Activity Settings",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let uninstallAppItem = NSMenuItem(
            title: "Uninstall Modafinil...",
            action: #selector(uninstallApp),
            keyEquivalent: ""
        )
        uninstallAppItem.target = self
        menu.addItem(uninstallAppItem)

        let quitItem = NSMenuItem(title: "Quit Modafinil", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private var timerMenuTitle: String {
        if let remaining = activeTimerRemainingDescription {
            return "Time Limit: \(selectedTimerLimit.shortTitle) (\(remaining) left)"
        }

        return "Time Limit: \(selectedTimerLimit.title)"
    }

    private func makeTimerLimitMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for timerLimit in SleepPreventionTimeLimit.allCases {
            let item = NSMenuItem(
                title: timerLimit.title,
                action: #selector(selectTimerLimit(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = timerLimit.rawValue
            item.state = selectedTimerLimit == timerLimit ? .on : .off
            item.isEnabled = !isSleepOperationInFlight
            menu.addItem(item)

            if timerLimit == .none {
                menu.addItem(.separator())
            }
        }

        return menu
    }

    private var activeTimerRemainingDescription: String? {
        guard isSleepPreventionEnabled, let deactivationDeadline else { return nil }
        let secondsRemaining = max(0, Int(ceil(deactivationDeadline.timeIntervalSinceNow)))
        return Self.formatDuration(seconds: secondsRemaining)
    }

    private func scheduleDeactivationTimerIfNeeded() {
        guard isSleepPreventionEnabled, let duration = selectedTimerLimit.duration else {
            cancelDeactivationTimer()
            return
        }

        scheduleDeactivationTimer(until: Date().addingTimeInterval(duration))
    }

    private func resumeDeactivationTimerIfNeeded() {
        guard isSleepPreventionEnabled else {
            cancelDeactivationTimer()
            return
        }

        guard let deactivationDeadline else { return }
        scheduleDeactivationTimer(until: deactivationDeadline)
    }

    private func restoreDeactivationTimer(until deadline: Date?) {
        guard let deadline, isSleepPreventionEnabled else {
            cancelDeactivationTimer()
            return
        }

        scheduleDeactivationTimer(until: deadline)
    }

    private func scheduleDeactivationTimer(
        until deadline: Date,
        minimumDelay: TimeInterval = 0
    ) {
        parkDeactivationTimer()
        setDeactivationDeadline(deadline)
        deactivationTimerGeneration += 1

        let generation = deactivationTimerGeneration
        let delay = max(deadline.timeIntervalSinceNow, minimumDelay)
        guard delay > 0 else {
            expireDeactivationTimer(generation: generation)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let milliseconds = Int((delay * 1_000).rounded(.up))
        timer.schedule(deadline: .now() + .milliseconds(milliseconds), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.deactivationTimerFired(generation: generation)
        }
        deactivationTimer = timer
        timer.resume()
        refreshIcon()
    }

    private func cancelDeactivationTimer() {
        parkDeactivationTimer()
        setDeactivationDeadline(nil)
    }

    private func parkDeactivationTimer() {
        deactivationTimerGeneration += 1
        deactivationTimer?.cancel()
        deactivationTimer = nil
    }

    private func deactivationTimerFired(generation: Int) {
        guard generation == deactivationTimerGeneration else { return }

        deactivationTimer?.cancel()
        deactivationTimer = nil
        expireDeactivationTimer(generation: generation)
    }

    private func expireDeactivationTimer(generation: Int) {
        guard generation == deactivationTimerGeneration else { return }
        guard isSleepPreventionEnabled else {
            cancelDeactivationTimer()
            refreshIcon()
            return
        }

        guard !isSleepOperationInFlight else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.expireDeactivationTimer(generation: generation)
            }
            return
        }

        setSleepPreventionEnabled(false, reason: .timerExpired)
    }

    private func setDeactivationDeadline(_ deadline: Date?) {
        deactivationDeadline = deadline

        if let deadline {
            UserDefaults.standard.set(
                deadline.timeIntervalSince1970,
                forKey: Self.activeTimerDeadlineDefaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeTimerDeadlineDefaultsKey)
        }
    }

    private static func savedDeactivationDeadline(defaults: UserDefaults = .standard) -> Date? {
        guard defaults.object(forKey: activeTimerDeadlineDefaultsKey) != nil else {
            return nil
        }

        let timestamp = defaults.double(forKey: activeTimerDeadlineDefaultsKey)
        guard timestamp > 0 else { return nil }

        return Date(timeIntervalSince1970: timestamp)
    }

    private static func formatDuration(seconds: Int) -> String {
        guard seconds > 0 else { return "<1 min" }

        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        guard minutes >= 60 else {
            return "\(minutes) \(minutes == 1 ? "min" : "mins")"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if remainingMinutes == 0 {
            return "\(hours) \(hours == 1 ? "hr" : "hrs")"
        }

        let hourText = "\(hours) \(hours == 1 ? "hr" : "hrs")"
        let minuteText = "\(remainingMinutes) \(remainingMinutes == 1 ? "min" : "mins")"
        return "\(hourText) \(minuteText)"
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct SleepRestoreError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private enum SleepPreventionChangeReason {
        case userAction
        case timerExpired
    }

    private static let inactiveSymbolName: String = {
        if NSImage(systemSymbolName: "eye.half.closed.fill", accessibilityDescription: nil) != nil {
            return "eye.half.closed.fill"
        }

        return "eye.slash.fill"
    }()
}
