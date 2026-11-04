import AppKit
import IOKit.pwr_mgt
import notify
import ModafinilShared
import ModafinilRemoteProtocol
import ModafinilT3
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject,
    NSApplicationDelegate,
    NSPopoverDelegate,
    CompanionServerDelegate,
    CompanionSetupWindowControllerDelegate,
    AppUIActions
{
    private let helperClient = PrivilegedHelperClient()
    private let helperInstaller = PrivilegedHelperInstaller()
    private let lidMonitor = LidMonitor()
    private let codexRuntimeMonitor = CodexRuntimeMonitor()
    private let companionConfigurationStore = CompanionConfigurationStore()
    private let statusPopover = NSPopover()
    private let powerMonitor = PowerEventMonitor()
    private let historyRecorder = PowerHistoryRecorder()
    private let loginItems = LoginItemController()
    private let uiModel = AppUIModel()
    private let remoteMacs = RemoteMacsController()
    private var mainWindowController: MainWindowController?
    private var journalNotifyToken: Int32?
    private var assertionNotifyToken: Int32?
    private var isAssertionRefreshScheduled = false
    private var keepAwakeChangeSource: String?
    private var companionAccessStatus = "Starting"
    private var launchedAsLoginItem = false
    private var lastBackgroundLeaseAt: Date?
    private var lastNotedAttempt: (id: String, phase: SleepAttempt.Phase)? =
        (try? SleepJournalStore.read())?.attempt.map { ($0.id, $0.phase) }

    private var companionServer: CompanionServer?
    private var companionSetupWindowController: CompanionSetupWindowController?
    private var statusItem: NSStatusItem!
    private var isSleepPreventionEnabled = false
    private var isSleepPreventionRequested = false
    private var hasLoadedInitialSleepRequest = false
    private var isToggleInFlight = false
    private var needsReconcileAfterToggle = false
    private var helperStatus: SMAppService.Status = .notRegistered
    private var lastError: String?
    private var sleepStatusGeneration = 0
    private var isQuitInProgress = false
    private var isTerminatingAfterCleanup = false
    private var isCodexRuntimeLimitEnabled = UserDefaults.standard.bool(
        forKey: AppDelegate.codexRuntimeLimitEnabledDefaultsKey
    )
    private var isCodexRunning = false
    private var codexRuntimeTimer: Timer?
    private var isProvisionalWakeLeaseActive = false
    private var provisionalWakeLeaseTimer: Timer?
    private var sleepAttempt: SleepAttempt?
    private var lastHandledSleepAttemptID = (try? SleepJournalStore.read())?.attempt?.id
    private var sleepHistoryError: String?
    private var scheduledSleepDate: Date?
    private var scheduledWakeTimer: Timer?
    private var scheduledWakeDate: Date?
    private var isWakeScheduleInFlight = false
    private static let scheduledWakeDefaultsKey = "companion.scheduledWakeAt"
    private let t3ActivityReader = T3ActivityReader()
    private var isT3SleepEnabled = UserDefaults.standard.bool(forKey: AppDelegate.t3SleepEnabledDefaultsKey)
    private var t3SleepWatch = T3SleepWatch()
    private var t3WatchTimer: Timer?
    private var t3WatchActivity: NSObjectProtocol?
    private var lastT3Activity: T3Activity?
    private var lastT3ActivityAt: Date?
    private var t3SleepAt: Date?
    /// Last remote Wake & Keep Awake (or wake alarm), for telling it apart from real input.
    private var lastRemoteKeepAwakeAt: Date?
    private var isQuitBlockersEnabled = UserDefaults.standard.bool(forKey: AppDelegate.quitBlockersDefaultsKey)
    private var quitBlockersTimer: Timer?
    private var quitBlockersArmedFor: Date?
    private var quitBlockersActivity: NSObjectProtocol?
    /// Labels the next helper sleep receipt, which the helper records as a generic request.
    private var pendingSleepSource: (source: String, at: Date)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
    }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(companionConfigurationDidChange),
            name: .modafinilCompanionConfigurationDidChange,
            object: companionConfigurationStore
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        lidMonitor.onLidStateChange = { [weak self] _ in self?.handleLidStateChange() }
        do {
            try lidMonitor.start()
        } catch {
            lastError = error.localizedDescription
        }

        refreshCodexRuntimeState(shouldReconcile: false)
        updateCodexRuntimeMonitoring()
        refreshHelperStatus()
        refreshSleepStatus()
        synchronizeSleepJournal()
        registerJournalNotification()
        powerMonitor.onDidWake = { [weak self] in self?.handleSystemWake() }
        do { try powerMonitor.start() } catch { lastError = error.localizedDescription }
        historyRecorder.recordAppStart()
        loginItems.applyDefaultIfNeeded()
        restoreScheduledWake()
        startCompanionServer()
        refreshIcon()
        if !launchedAsLoginItem {
            showStatusWindow()
        }

        if companionConfigurationStore.isWakeArmed {
            activateProvisionalWakeLease()
        }
        restoreKeepAwakeAfterT3SleepIfLidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        updateAssertionObservation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showStatusWindow()
        return true
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        historyRecorder.recordAppStop()
        powerMonitor.stop()
        if let journalNotifyToken { notify_cancel(journalNotifyToken) }
        if let assertionNotifyToken { notify_cancel(assertionNotifyToken) }
        codexRuntimeTimer?.invalidate()
        t3WatchTimer?.invalidate()
        endT3WatchActivity()
        quitBlockersTimer?.invalidate()
        provisionalWakeLeaseTimer?.invalidate()
        scheduledWakeTimer?.invalidate()
        statusPopover.performClose(nil)
        mainWindowController?.close()
        companionSetupWindowController?.close()
        companionServer?.stop()
        helperClient.invalidate()
        lidMonitor.stop()
    }

    @objc private func screenParametersDidChange() {
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshIcon()
        }
    }

    private func startCompanionServer() {
        let server = CompanionServer(secret: companionConfigurationStore.secret)
        server.delegate = self
        server.errorHandler = { [weak self] message in
            self?.lastError = message
            self?.refreshIcon()
        }
        server.statusHandler = { [weak self] status in
            guard let self else { return }
            self.companionAccessStatus = status
            if status == "Listening", self.lastError?.hasPrefix("Companion listener") == true {
                self.lastError = nil
            }
            self.refreshIcon()
        }

        do {
            try server.start()
            companionServer = server
        } catch {
            lastError = "Could not start companion access: \(error.localizedDescription)"
        }
    }

    @objc private func companionConfigurationDidChange() {
        companionServer?.updateSecret(companionConfigurationStore.secret)
        companionSetupWindowController?.refresh()
    }

    /// A full (display) wake. NSWorkspace does not report background wakes.
    @objc private func workspaceDidWake() {
        historyRecorder.recordFullWake()
        companionServer?.ensureRunning()
        if !completeScheduledWakeIfDue() {
            activateProvisionalWakeLease()
        }
        restoreKeepAwakeAfterT3SleepIfLidOpen()
        refreshHistoryWindow()
    }

    /// Every system wake, including lid-closed network wakes and macOS maintenance.
    private func handleSystemWake() {
        let snapshot = historyRecorder.recordWake()
        companionServer?.ensureRunning()
        synchronizeSleepJournal()
        t3SleepWatch.reset()
        defer {
            restoreKeepAwakeAfterT3SleepIfLidOpen()
            refreshIcon()
            refreshHistoryWindow()
        }
        if completeScheduledWakeIfDue() { return }
        guard companionConfigurationStore.isWakeArmed else { return }
        let now = Date()
        guard WakeRecoveryPolicy.shouldStartLease(
            hasGraphics: snapshot?.hasGraphics,
            cause: PowerReason.wakeCause(snapshot?.combinedWakeReason),
            sinceSleepRequest: sleepAttempt.map { now.timeIntervalSince($0.requestedAt) },
            sinceLastBackgroundLease: lastBackgroundLeaseAt.map { now.timeIntervalSince($0) }
        ) else { return }
        if snapshot?.hasGraphics != true { lastBackgroundLeaseAt = now }
        activateProvisionalWakeLease()
    }

    private func registerJournalNotification() {
        var token: Int32 = 0
        let status = notify_register_dispatch(SleepJournalStore.changeNotification, &token, .main) { [weak self] _ in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.restoreKeepAwakeAfterT3SleepIfLidOpen()
            self.refreshIcon()
        }
        if status == UInt32(NOTIFY_STATUS_OK) { journalNotifyToken = token }
    }

    private func activateProvisionalWakeLease() {
        guard companionConfigurationStore.isWakeArmed else { return }
        if !isProvisionalWakeLeaseActive {
            historyRecorder.note("Wake recovery: keeping the Mac awake for 90 s")
        }
        keepAwakeChangeSource = "wake recovery"

        // A maintenance/dark wake is not the travelling phone's confirmation.
        // Retain the authorization until Keep Awake or an explicit local change.
        isProvisionalWakeLeaseActive = true
        scheduleProvisionalWakeLeaseExpiration()
        reconcileSleepPreventionWithCurrentMode()
    }

    private func scheduleProvisionalWakeLeaseExpiration() {
        provisionalWakeLeaseTimer?.invalidate()
        let timer = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
            // Added to the main run loop below.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isProvisionalWakeLeaseActive = false
                self.provisionalWakeLeaseTimer = nil
                self.keepAwakeChangeSource = "wake recovery ended"
                self.reconcileSleepPreventionWithCurrentMode()
            }
        }
        provisionalWakeLeaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelProvisionalWakeLease() {
        provisionalWakeLeaseTimer?.invalidate()
        provisionalWakeLeaseTimer = nil
        isProvisionalWakeLeaseActive = false
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

        showStatusPopover()
    }

    @objc private func toggleSleepPrevention() {
        guard !isToggleInFlight else { return }

        lastError = nil

        let nextState = !isAwakeRequestedForStatus

        cancelProvisionalWakeLease()
        companionConfigurationStore.isWakeArmed = false
        isKeepAwakeSuspendedForT3Sleep = false
        isSleepPreventionRequested = nextState
        keepAwakeChangeSource = "Mac"
        refreshHelperStatus()
        reconcileSleepPreventionWithCurrentMode()
    }

    private func setSleepPreventionEnabled(
        _ enabled: Bool,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        let previousState = isSleepPreventionEnabled
        isToggleInFlight = true
        sleepStatusGeneration += 1
        isSleepPreventionEnabled = enabled
        lidMonitor.setEnabled(enabled)
        refreshIcon()

        helperClient.setSleepPreventionEnabled(enabled) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                if enabled {
                    self.lastHandledSleepAttemptID = (try? SleepJournalStore.read())?.attempt?.id
                    self.lidMonitor.turnDisplayOffIfNeeded()
                }
                if previousState != enabled {
                    self.historyRecorder.note("Keep-awake \(enabled ? "on" : "off") (\(self.keepAwakeChangeSource ?? "Modafinil"))")
                }
                self.keepAwakeChangeSource = nil
            case .failure(let error):
                self.isSleepPreventionEnabled = previousState
                self.lidMonitor.setEnabled(previousState)
                self.lastError = error.localizedDescription
            }

            self.isToggleInFlight = false
            self.refreshIcon()
            completion?(result)

            if self.needsReconcileAfterToggle {
                self.needsReconcileAfterToggle = false
                self.reconcileSleepPreventionWithCurrentMode()
            }
        }
    }

    private func reconcileSleepPreventionWithCurrentMode() {
        if isToggleInFlight {
            needsReconcileAfterToggle = true
            return
        }

        let enabled = shouldEnableSleepPreventionNow

        guard isSleepPreventionEnabled != enabled else {
            keepAwakeChangeSource = nil
            refreshIcon()
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            if enabled || isSleepPreventionEnabled {
                installHelper(stateAfterInstall: enabled)
            } else {
                refreshIcon()
            }
            return
        }

        setSleepPreventionEnabled(enabled)
    }

    private var shouldEnableSleepPreventionNow: Bool {
        isProvisionalWakeLeaseActive ||
            (isSleepPreventionRequested &&
                (!isCodexRuntimeLimitEnabled || isCodexRunning))
    }

    private var isWaitingForCodex: Bool {
        !isProvisionalWakeLeaseActive &&
            isSleepPreventionRequested &&
            isCodexRuntimeLimitEnabled &&
            !isCodexRunning
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
            setSleepPreventionEnabled(stateAfterInstall)
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

    @objc private func showCompanionSetup() {
        statusPopover.performClose(nil)

        let windowController: CompanionSetupWindowController
        if let existing = companionSetupWindowController {
            windowController = existing
            windowController.refresh()
        } else {
            windowController = CompanionSetupWindowController(
                configurationStore: companionConfigurationStore
            )
            windowController.setupDelegate = self
            companionSetupWindowController = windowController
        }

        NSApp.setActivationPolicy(.regular)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func companionSetupWindowControllerDidClose(
        _ windowController: CompanionSetupWindowController
    ) {
        guard companionSetupWindowController === windowController else { return }
        companionSetupWindowController = nil
        updateActivationPolicy()
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
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            finishRestoringNormalSleepBehavior(completion: completion)
            return
        }
        helperClient.setSleepTimer(after: -1) { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: self?.finishRestoringNormalSleepBehavior(completion: completion)
            }
        }
    }

    private func finishRestoringNormalSleepBehavior(completion: @escaping (Result<Void, Error>) -> Void) {
        cancelProvisionalWakeLease()
        companionConfigurationStore.isWakeArmed = false
        isKeepAwakeSuspendedForT3Sleep = false
        refreshHelperStatus()
        let localSleepPreventionStatus = readLocalSleepPreventionStatus()

        if localSleepPreventionStatus == false {
            isSleepPreventionEnabled = false
            isSleepPreventionRequested = false
            lidMonitor.setEnabled(false)
            completion(.success(()))
            return
        }

        guard helperStatus == .enabled else {
            if localSleepPreventionStatus == true {
                completion(.failure(SleepRestoreError("Sleep prevention is still enabled, but the privileged helper is not enabled.")))
            } else {
                completion(.failure(SleepRestoreError("Modafinil could not confirm or restore regular sleep behavior because the privileged helper is not enabled.")))
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
                self.isSleepPreventionRequested = false
                self.lidMonitor.setEnabled(false)
            }

            completion(result)
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

    private func clearPreferences() {
        companionConfigurationStore.deleteSecrets()
        RemoteMacStore().deleteAll()
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

    private func setControlsEnabled(_ enabled: Bool) {
        statusItem?.button?.isEnabled = enabled
        statusPopover.contentViewController?.view.window?.ignoresMouseEvents = !enabled
        mainWindowController?.window?.ignoresMouseEvents = !enabled
    }

    @objc private func showStatusWindow() {
        showMainWindow(section: nil)
    }

    private func showMainWindow(section: AppSection?) {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)
        statusPopover.performClose(nil)
        if let section { uiModel.section = section }
        uiModel.actions = self

        let controller = mainWindowController ?? {
            let controller = MainWindowController(model: uiModel, remoteMacs: remoteMacs)
            controller.onClose = { [weak self] in
                self?.mainWindowController = nil
                self?.updateActivationPolicy()
            }
            mainWindowController = controller
            return controller
        }()
        historyRecorder.recordWake()
        uiModel.snapshot = makeSnapshot()
        uiModel.historyRevision &+= 1
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        updateAssertionObservation()
    }

    @objc private func showStatusPopover() {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)

        guard let button = statusItem.button else { return }

        if statusPopover.isShown {
            statusPopover.performClose(nil)
            return
        }

        uiModel.actions = self
        uiModel.snapshot = makeSnapshot()
        remoteMacs.refreshAll()
        if statusPopover.contentViewController == nil {
            let host = NSHostingController(rootView: MenuBarPopoverView().environmentObject(uiModel).environmentObject(remoteMacs))
            host.sizingOptions = .preferredContentSize
            statusPopover.contentViewController = host
        }
        statusPopover.behavior = .transient
        if statusPopover.delegate == nil { statusPopover.delegate = self }
        statusPopover.animates = true
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        updateAssertionObservation()
    }

    private var isAnyStatusViewVisible: Bool {
        statusPopover.isShown || mainWindowController?.window?.isVisible == true
    }

    private func refreshStatusPopover() { refreshUI() }

    private func refreshStatusWindow() { refreshUI() }

    /// Rebuilds the snapshot only while a Modafinil view is on screen.
    private func refreshUI() {
        guard isAnyStatusViewVisible else { return }
        uiModel.snapshot = makeSnapshot()
    }

    // MARK: AppUIActions

    func uiToggleKeepAwake() { toggleSleepPrevention() }

    func uiToggleCodexLimit() { toggleCodexRuntimeLimit() }

    func uiToggleT3Sleep() { toggleT3Sleep() }

    func uiToggleQuitBlockers() { toggleQuitBlockers() }

    func uiSetQuitExclusion(bundleID: String, name: String, excluded: Bool) {
        setQuitExclusion(bundleID: bundleID, name: name, excluded: excluded)
    }

    func uiToggleLoginItem() { toggleLoginItem() }

    func uiScheduleSleep(after seconds: Int) {
        scheduleSleep(argument: String(seconds), source: "Mac") { [weak self] result in
            switch result {
            case .success: self?.lastError = nil
            case .failure(let error): self?.lastError = error.localizedDescription
            }
            self?.refreshIcon()
        }
    }

    func uiCancelSleepTimer() { cancelScheduledSleep(source: "Mac") }

    func uiScheduleWake(at date: Date) {
        setScheduledWake(date, source: "Mac") { [weak self] result in
            if case .failure(let error) = result { self?.lastError = error.localizedDescription }
            else { self?.lastError = nil }
            self?.refreshIcon()
        }
    }

    func uiCancelWake() {
        setScheduledWake(nil, source: "Mac") { [weak self] result in
            if case .failure(let error) = result { self?.lastError = error.localizedDescription }
            self?.refreshIcon()
        }
    }

    func uiOpenCompanionSetup() { showCompanionSetup() }

    func uiOpenBackgroundSettings() { openSettings() }

    func uiOpenMainWindow(_ section: AppSection) { showMainWindow(section: section) }

    func uiQuit() {
        statusPopover.performClose(nil)
        quit()
    }

    func uiUninstall() { uninstallApp() }

    func uiTimeline(from: Date, to: Date) -> (segments: [PowerSegment], markers: [PowerMarker]) {
        historyRecorder.timeline(from: from, to: to)
    }

    @objc private func toggleLoginItem() {
        do {
            try loginItems.setEnabled(!loginItems.isEnabled)
        } catch {
            lastError = "Could not change Open at Login: \(error.localizedDescription)"
        }
        refreshIcon()
    }

    @objc private func showSleepHistory() {
        showMainWindow(section: .history)
    }

    private func refreshHistoryWindow() {
        guard isAnyStatusViewVisible else { return }
        uiModel.historyRevision &+= 1
    }

    private func updateActivationPolicy() {
        let anyVisible = mainWindowController?.window?.isVisible == true
            || companionSetupWindowController?.window?.isVisible == true
        if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        updateAssertionObservation()
    }

    /// Watches other apps' power assertions only while a Modafinil status view is
    /// visible, refreshing at most once per second.
    private func updateAssertionObservation() {
        let visible = isAnyStatusViewVisible
        if visible, assertionNotifyToken == nil {
            var token: Int32 = 0
            let status = notify_register_dispatch("com.apple.system.powermanagement.assertions.anychange", &token, .main) { [weak self] _ in
                guard let self, !self.isAssertionRefreshScheduled else { return }
                self.isAssertionRefreshScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.isAssertionRefreshScheduled = false
                    self?.refreshUI()
                }
            }
            if status == UInt32(NOTIFY_STATUS_OK) { assertionNotifyToken = token }
        } else if !visible, let token = assertionNotifyToken {
            notify_cancel(token)
            assertionNotifyToken = nil
        }
    }

    func companionServerCurrentState(_ server: CompanionServer) -> RemoteState {
        if !isToggleInFlight,
           let enabled = readLocalSleepPreventionStatus(),
           enabled != isSleepPreventionEnabled
        {
            isSleepPreventionEnabled = enabled
            lidMonitor.setEnabled(enabled)
            refreshIcon()
        }
        return makeRemoteState()
    }

    func companionServer(
        _ server: CompanionServer,
        perform command: RemoteCommand,
        argument: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        switch command {
        case .status:
            completion(.success((makeRemoteState(), "Status updated.")))
        case .history:
            guard let range = RemoteHistory.parseRange(argument) else {
                completion(.failure(CompanionRemoteError("The history range is invalid.")))
                return
            }
            let history = historyRecorder.remoteHistory(from: range.from, to: range.to)
            completion(.success((makeRemoteState(history: history), "History loaded.")))
        case .setT3Sleep:
            guard let enabled = RemoteT3Sleep.parseArgument(argument) else {
                completion(.failure(CompanionRemoteError("The T3 sleep setting is invalid.")))
                return
            }
            setT3SleepEnabled(enabled, source: "iPhone")
            completion(.success((makeRemoteState(), enabled
                ? "The Mac will sleep once T3 Code threads finish and \(T3SleepWording.condition)."
                : "Sleep when T3 Code finishes is off.")))
        case .keepAwake:
            performRemoteKeepAwake(completion: completion)
        case .sleep:
            performRemoteSleep(completion: completion)
        case .scheduleSleep:
            scheduleSleep(argument: argument, source: "iPhone", completion: completion)
        case .cancelScheduledSleep:
            cancelScheduledSleep(source: "iPhone", completion: completion)
        case .scheduleWake:
            guard let timestamp = Int64(argument) else {
                completion(.failure(CompanionRemoteError("The wake time is invalid.")))
                return
            }
            setScheduledWake(Date(timeIntervalSince1970: TimeInterval(timestamp)), source: "iPhone", completion: completion)
        case .cancelScheduledWake:
            setScheduledWake(nil, source: "iPhone", completion: completion)
        case .wake:
            completion(.failure(
                CompanionRemoteError("Wake requests must be sent to the iPhone relay.")
            ))
        }
    }

    private func scheduleSleep(
        argument: String,
        source: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard let seconds = Int64(argument), (60...86_400).contains(seconds) else {
            completion(.failure(
                CompanionRemoteError("The sleep timer must be between 1 minute and 24 hours.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        helperClient.setSleepTimer(after: Double(seconds)) { [weak self] result in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.refreshIcon()
            switch result {
            case .success:
                self.companionConfigurationStore.isWakeArmed = true
                self.isKeepAwakeSuspendedForT3Sleep = false
                self.historyRecorder.note("Sleep timer set for \(Self.durationText(Double(seconds))) (\(source))")
                completion(.success((self.makeRemoteState(), "Sleep timer saved on the Mac.")))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    private func cancelScheduledSleep(source: String, completion: ((Result<(RemoteState, String), Error>) -> Void)? = nil) {
        helperClient.setSleepTimer(after: 0) { [weak self] result in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.refreshIcon()
            switch result {
            case .success:
                self.companionConfigurationStore.isWakeArmed = false
                self.historyRecorder.note("Sleep timer cancelled (\(source))")
                completion?(.success((self.makeRemoteState(), "The sleep timer is off.")))
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.refreshIcon()
                completion?(.failure(error))
            }
        }
    }

    private func synchronizeSleepJournal() {
        do {
            let journal = try SleepJournalStore.read()
            sleepHistoryError = nil
            scheduledSleepDate = journal.schedule?.date
            sleepAttempt = journal.attempt
            if let attempt = sleepAttempt { noteSleepAttemptIfChanged(attempt) }
            armQuitBlockersTimer()
            if let attempt = sleepAttempt {
                if !isToggleInFlight && (attempt.phase == .pending || (attempt.id != lastHandledSleepAttemptID && attempt.phase != .cancelled)) {
                    // The helper's timer is authoritative even while this UI is suspended.
                    // A fast failure may be observed without ever seeing its pending phase.
                    isSleepPreventionRequested = false
                    cancelProvisionalWakeLease()
                    if let enabled = readLocalSleepPreventionStatus() {
                        isSleepPreventionEnabled = enabled
                        lidMonitor.setEnabled(enabled)
                    }
                }
                lastHandledSleepAttemptID = attempt.id
            }
        } catch {
            sleepHistoryError = "Sleep history is unavailable: \(error.localizedDescription)"
        }
    }

    private func noteSleepAttemptIfChanged(_ attempt: SleepAttempt) {
        let previous = lastNotedAttempt
        guard previous?.id != attempt.id || previous?.phase != attempt.phase else { return }
        lastNotedAttempt = (attempt.id, attempt.phase)
        if previous?.id != attempt.id, attempt.attempts > 0 || attempt.phase == .pending {
            var source = attempt.trigger == "timer" ? "sleep timer" : (attempt.trigger == "request" ? "iPhone" : "Modafinil")
            if attempt.trigger == "request", let pending = pendingSleepSource,
               abs(attempt.requestedAt.timeIntervalSince(pending.at)) < 120 {
                source = pending.source
            }
            pendingSleepSource = nil
            historyRecorder.note("Sleep requested (\(source))", at: attempt.requestedAt)
        }
        switch attempt.phase {
        case .pending: break
        case .confirmed: historyRecorder.note("Sleep confirmed by macOS", at: attempt.sleptAt ?? Date())
        case .failed: historyRecorder.note("Sleep not confirmed: \(attempt.detail)")
        case .cancelled: historyRecorder.note("Sleep request cancelled")
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private var sleepAttemptDescription: String {
        if let sleepHistoryError { return sleepHistoryError }
        guard let attempt = sleepAttempt else { return "No sleep request recorded yet." }
        var text = attempt.detail
        if let date = attempt.sleptAt { text += " Last sleep: \(date.formatted(date: .omitted, time: .standard))." }
        if let date = attempt.wokeAt { text += " Wake: \(date.formatted(date: .omitted, time: .standard))." }
        return text
    }

    private func performRemoteKeepAwake(
        source: String = "iPhone",
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard !isToggleInFlight else {
            completion(.failure(
                CompanionRemoteError("Modafinil is already updating the sleep setting.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        let previousRequestedState = isSleepPreventionRequested
        let previousCodexLimit = isCodexRuntimeLimitEnabled
        let previousProvisionalLease = isProvisionalWakeLeaseActive

        companionConfigurationStore.isWakeArmed = false
        cancelProvisionalWakeLease()
        isKeepAwakeSuspendedForT3Sleep = false
        isSleepPreventionRequested = true

        if isCodexRuntimeLimitEnabled {
            isCodexRuntimeLimitEnabled = false
            UserDefaults.standard.set(
                false,
                forKey: Self.codexRuntimeLimitEnabledDefaultsKey
            )
            updateCodexRuntimeMonitoring()
        }

        lastError = nil
        keepAwakeChangeSource = source
        setSleepPreventionEnabled(true) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                // Without this, a closed-lid Mac with T3 already finished would be
                // put back to sleep by "Sleep when T3 finishes" a minute after the
                // iPhone woke it.
                // Only a closed-lid wake with the feature on needs the wait; a wait
                // left over from an open-lid wake would block the rule later.
                self.lastRemoteKeepAwakeAt = Date()
                if self.isT3SleepEnabled, self.lidMonitor.isLidClosed() != false {
                    self.t3SleepWatch.waitForNewActivity()
                    self.t3SleepAt = nil
                    self.historyRecorder.note("Sleep when T3 finishes: waiting for a T3 thread to start (\(source))")
                }
                // A desktop is a workstation: a remote wake should light its display,
                // not leave it in a display-off background wake.
                if !LidMonitor.hasBuiltInLid { Self.declareRemoteUserActivity() }
                completion(.success((
                    self.makeRemoteState(),
                    "Modafinil is keeping the Mac awake."
                )))
            case .failure(let error):
                self.isSleepPreventionRequested = previousRequestedState
                self.isCodexRuntimeLimitEnabled = previousCodexLimit
                UserDefaults.standard.set(
                    previousCodexLimit,
                    forKey: Self.codexRuntimeLimitEnabledDefaultsKey
                )
                self.updateCodexRuntimeMonitoring()
                if previousProvisionalLease {
                    self.isProvisionalWakeLeaseActive = true
                    self.scheduleProvisionalWakeLeaseExpiration()
                }
                self.refreshIcon()
                completion(.failure(error))
            }
        }
    }

    private func performRemoteSleep(
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        // An explicit sleep from the iPhone: keep-awake stays off afterwards.
        isKeepAwakeSuspendedForT3Sleep = false
        requestSystemSleep(source: "iPhone") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                completion(.success((
                    self.makeRemoteState(),
                    "Sleep request accepted. Check sleep history for confirmation or failure."
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Turns keep-awake off and asks the helper to sleep the Mac now. Arms
    /// remote wake recovery, like a sleep timer.
    private func requestSystemSleep(source: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isToggleInFlight else {
            completion(.failure(
                CompanionRemoteError("Modafinil is already updating the sleep setting.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        let previousRequestedState = isSleepPreventionRequested
        let previousProvisionalLease = isProvisionalWakeLeaseActive

        // The wait for new T3 activity belongs to the wake that just ended.
        t3SleepWatch.clearWaitForNewActivity()
        // The helper retries for about 30 s, which gives the apps time to quit.
        quitSleepBlockingApps(before: source)
        lastError = nil
        companionConfigurationStore.isWakeArmed = true
        cancelProvisionalWakeLease()
        isSleepPreventionRequested = false
        isToggleInFlight = true
        sleepStatusGeneration += 1
        refreshIcon()

        helperClient.sleepAfterDisablingSleepPrevention { [weak self] result in
            guard let self else { return }

            self.isToggleInFlight = false
            switch result {
            case .success:
                self.isSleepPreventionEnabled = false
                self.lidMonitor.setEnabled(false)
                self.refreshIcon()
                completion(.success(()))
            case .failure(let error):
                self.companionConfigurationStore.isWakeArmed = false
                self.isSleepPreventionRequested = previousRequestedState
                if previousProvisionalLease {
                    self.isProvisionalWakeLeaseActive = true
                    self.scheduleProvisionalWakeLeaseExpiration()
                }
                self.lastError = error.localizedDescription
                self.refreshIcon()
                completion(.failure(error))
            }
        }
    }

    private func makeRemoteState(history: RemoteHistory? = nil) -> RemoteState {
        let wakeTargets = CompanionNetworkInformation.discover()
            .wakeTargetMACs(configured: companionConfigurationStore.configuredTargetMACs)
        synchronizeSleepJournal()
        synchronizeWakeSchedule()
        return RemoteState(
            awakeRequested: isAwakeRequestedForStatus,
            sleepPreventionEffective: isSleepPreventionEnabled,
            serverName: Host.current().localizedName ?? "Mac",
            scheduledSleepAt: scheduledSleepDate.map { Int64($0.timeIntervalSince1970) },
            scheduledWakeAt: scheduledWakeDate.map { Int64($0.timeIntervalSince1970) },
            sleepAttempt: sleepAttempt.map {
                RemoteSleepAttempt(requestedAt: Int64($0.requestedAt.timeIntervalSince1970),
                    phase: RemoteSleepAttempt.Phase(rawValue: $0.phase.rawValue)!,
                    sleptAt: $0.sleptAt.map { Int64($0.timeIntervalSince1970) },
                    wokeAt: $0.wokeAt.map { Int64($0.timeIntervalSince1970) }, detail: $0.detail)
            },
            wakeTargetMACs: wakeTargets,
            // History pages carry no blockers, keeping them well inside the size limit.
            blockers: history != nil ? nil : SleepBlockers.current().prefix(12).map {
                RemoteSleepBlocker(effect: $0.effect.rawValue, name: String($0.processName.prefix(40)),
                                   detail: $0.details.first.map { String($0.prefix(60)) })
            },
            history: history,
            t3Sleep: history != nil ? nil : makeRemoteT3Sleep()
        )
    }

    private static func declareRemoteUserActivity() {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity("Modafinil remote wake" as CFString,
                                                      kIOPMUserActiveLocal, &assertionID)
        if result != kIOReturnSuccess {
            NSLog("Modafinil could not wake the display: 0x%x", result)
        }
    }

    private func makeRemoteT3Sleep() -> RemoteT3Sleep {
        guard let activity = currentT3ActivityForDisplay() else {
            return RemoteT3Sleep(enabled: false, summary: "Off", restorePending: isKeepAwakeSuspendedForT3Sleep)
        }
        var working = 0, waiting = 0
        if case .busy(let threads) = activity {
            waiting = threads.filter(\.isWaiting).count
            working = threads.count - waiting
        }
        var summary = activity.summary
        if t3SleepWatch.waitsForNewActivity, activity.isFinished {
            summary += LidMonitor.hasBuiltInLid ? " · sleeps after the next T3 run"
                                                : " · sleeps after the next T3 run (or in 30 min)"
        } else if !LidMonitor.hasBuiltInLid {
            // Phones and Macs show this line as is; it carries the desktop condition.
            summary += " · sleeps once unused for 5 min"
        }
        return RemoteT3Sleep(enabled: true, summary: String(summary.prefix(120)),
                             working: working, waiting: waiting,
                             sleepAt: t3SleepAt.map { Int64($0.timeIntervalSince1970) },
                             restorePending: isKeepAwakeSuspendedForT3Sleep)
    }

    private func setScheduledWake(
        _ date: Date?,
        source: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard !isWakeScheduleInFlight else {
            completion(.failure(CompanionRemoteError("The wake schedule is being updated.")))
            return
        }
        do {
            if let date { try WakeScheduler.validate(date) }
        } catch {
            completion(.failure(error))
            return
        }
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(CompanionRemoteError("Enable the privileged helper in Modafinil on the Mac first.")))
            return
        }
        isWakeScheduleInFlight = true
        refreshIcon()
        helperClient.setScheduledWake(date?.timeIntervalSince1970 ?? 0) { [weak self] result in
            guard let self else { return }
            self.isWakeScheduleInFlight = false
            self.synchronizeWakeSchedule(force: true)
            self.refreshIcon()
            switch result {
            case .success:
                self.historyRecorder.note(date.map {
                    "Wake alarm set for \($0.formatted(date: .abbreviated, time: .shortened)) (\(source))"
                } ?? "Wake alarm cancelled (\(source))")
                completion(.success((self.makeRemoteState(), date == nil
                    ? "The wake timer is off."
                    : "Wake scheduled on the Mac. Keep Modafinil open to stay awake afterward.")))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func restoreScheduledWake() {
        let saved = UserDefaults.standard.double(forKey: Self.scheduledWakeDefaultsKey)
        if saved > 0 { scheduledWakeDate = Date(timeIntervalSince1970: saved) }
        synchronizeWakeSchedule()
        if !completeScheduledWakeIfDue() { armScheduledWakeTimer() }
    }

    private func synchronizeWakeSchedule(force: Bool = false) {
        let systemDate = WakeScheduler().scheduledDate()
        // Preserve a just-fired alarm until the wake handler can consume it.
        if !force, let date = scheduledWakeDate, date <= Date(),
           Date().timeIntervalSince(date) <= 300 { return }
        guard force || systemDate != scheduledWakeDate else { return }
        scheduledWakeDate = systemDate
        saveScheduledWake()
        armScheduledWakeTimer()
    }

    private func saveScheduledWake() {
        if let date = scheduledWakeDate {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.scheduledWakeDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.scheduledWakeDefaultsKey)
        }
    }

    private func armScheduledWakeTimer() {
        scheduledWakeTimer?.invalidate()
        scheduledWakeTimer = nil
        guard let date = scheduledWakeDate else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.completeScheduledWakeIfDue() }
        }
        scheduledWakeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func completeScheduledWakeIfDue() -> Bool {
        guard let date = scheduledWakeDate, date <= Date() else { return false }
        let overdue = Date().timeIntervalSince(date)
        scheduledWakeDate = nil
        scheduledWakeTimer?.invalidate()
        scheduledWakeTimer = nil
        saveScheduledWake()
        refreshIcon()
        // A wake alarm missed hours ago must not unexpectedly change the mode.
        guard overdue <= 300 else { return false }
        historyRecorder.note("Wake alarm fired")
        performRemoteKeepAwake(source: "wake alarm") { [weak self] result in
            if case .failure(let error) = result {
                self?.lastError = "Scheduled wake keep-awake failed: \(error.localizedDescription)"
                self?.refreshIcon()
            }
        }
        return true
    }

    private func updateCodexRuntimeMonitoring() {
        codexRuntimeTimer?.invalidate()
        codexRuntimeTimer = nil

        guard isCodexRuntimeLimitEnabled else { return }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCodexRuntimeState() }
        }
        codexRuntimeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshCodexRuntimeState(shouldReconcile: Bool = true) {
        let wasCodexRunning = isCodexRunning
        isCodexRunning = codexRuntimeMonitor.isCodexRunning()

        guard shouldReconcile, isCodexRuntimeLimitEnabled else {
            refreshIcon()
            return
        }

        if wasCodexRunning != isCodexRunning {
            keepAwakeChangeSource = isCodexRunning ? "Codex started" : "Codex stopped"
            reconcileSleepPreventionWithCurrentMode()
        } else {
            refreshIcon()
        }
    }

    @objc private func toggleCodexRuntimeLimit() {
        lastError = nil
        isCodexRuntimeLimitEnabled.toggle()
        UserDefaults.standard.set(
            isCodexRuntimeLimitEnabled,
            forKey: Self.codexRuntimeLimitEnabledDefaultsKey
        )

        updateCodexRuntimeMonitoring()
        refreshCodexRuntimeState(shouldReconcile: false)
        reconcileSleepPreventionWithCurrentMode()
    }

    // MARK: Quit apps that keep the Mac awake

    @objc private func toggleQuitBlockers() {
        isQuitBlockersEnabled.toggle()
        UserDefaults.standard.set(isQuitBlockersEnabled, forKey: Self.quitBlockersDefaultsKey)
        historyRecorder.note("Quit apps keeping the Mac awake before sleep \(isQuitBlockersEnabled ? "on" : "off")")
        armQuitBlockersTimer()
        refreshIcon()
    }

    /// Bundle identifier → name of apps the user never wants quit.
    private var quitBlockersExclusions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.quitBlockersExclusionsDefaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.quitBlockersExclusionsDefaultsKey) }
    }

    private func setQuitExclusion(bundleID: String, name: String, excluded: Bool) {
        var exclusions = quitBlockersExclusions
        exclusions[bundleID] = excluded ? name : nil
        quitBlockersExclusions = exclusions
        refreshUI()
    }

    private static func regularApp(pid: Int32) -> SleepBlockerApps.App? {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
        return SleepBlockerApps.App(pid: pid, bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    private func sleepBlockingApps() -> [SleepBlockerApps.App] {
        SleepBlockerApps.candidates(
            assertions: SleepBlockers.readAssertions(),
            excludedBundleIDs: Set(quitBlockersExclusions.keys),
            regularApp: Self.regularApp
        )
    }

    /// Asks apps that keep the Mac awake to quit, like ⌘Q: they can still ask to save.
    private func quitSleepBlockingApps(before source: String) {
        guard isQuitBlockersEnabled else { return }
        let apps = sleepBlockingApps()
        guard !apps.isEmpty else { return }
        var asked: [String] = []
        for app in apps where NSRunningApplication(processIdentifier: app.pid)?.terminate() == true {
            asked.append(app.name)
        }
        guard !asked.isEmpty else { return }
        historyRecorder.note("Asked \(asked.joined(separator: ", ")) to quit before sleep (\(source))")
    }

    /// For a sleep timer, apps are asked to quit 1 minute before it fires.
    private func armQuitBlockersTimer() {
        let target = isQuitBlockersEnabled ? scheduledSleepDate : nil
        guard target != quitBlockersArmedFor else { return }
        quitBlockersTimer?.invalidate()
        quitBlockersTimer = nil
        quitBlockersArmedFor = target
        guard let deadline = target, deadline > Date() else {
            if let activity = quitBlockersActivity {
                ProcessInfo.processInfo.endActivity(activity)
                quitBlockersActivity = nil
            }
            return
        }
        // Keeps App Nap from delaying the timer while the display is off. Creates no
        // power assertion and does not prevent sleep.
        if quitBlockersActivity == nil {
            quitBlockersActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Quitting apps that keep the Mac awake before the sleep timer"
            )
        }
        let fire = max(Date(), deadline.addingTimeInterval(-60))
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quitBlockersTimer = nil
                if let activity = self.quitBlockersActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self.quitBlockersActivity = nil
                }
                guard self.scheduledSleepDate == deadline else { return }
                self.quitSleepBlockingApps(before: "sleep timer")
            }
        }
        quitBlockersTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Sleep when T3 Code threads finish

    @objc private func toggleT3Sleep() {
        lastError = nil
        setT3SleepEnabled(!isT3SleepEnabled, source: "Mac")
    }

    private func setT3SleepEnabled(_ enabled: Bool, source: String) {
        guard enabled != isT3SleepEnabled else { return }
        isT3SleepEnabled = enabled
        // Changing the setting starts the rule fresh.
        t3SleepWatch.clearWaitForNewActivity()
        UserDefaults.standard.set(enabled, forKey: Self.t3SleepEnabledDefaultsKey)
        if !enabled { isKeepAwakeSuspendedForT3Sleep = false }
        historyRecorder.note("Sleep when T3 Code finishes \(enabled ? "on" : "off") (\(source))")
        lastT3ActivityAt = nil
        refreshIcon()
    }

    /// Keep-awake that the user asked for and that is in effect. A wake-recovery
    /// lease alone does not count: it ends by itself.
    private var isKeepAwakeOnForT3Watch: Bool {
        isSleepPreventionEnabled && isSleepPreventionRequested
    }

    /// Polls T3 every 15 s while the feature could apply. Each check reads the lid
    /// state first; T3's database is read only while the lid is closed.
    private func updateT3SleepMonitoring() {
        let shouldPoll = isT3SleepEnabled && isKeepAwakeOnForT3Watch && !isQuitInProgress
        if shouldPoll, t3WatchTimer == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateT3Sleep() }
            }
            timer.tolerance = 3
            t3WatchTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.async { [weak self] in self?.evaluateT3Sleep() }
        } else if !shouldPoll, let timer = t3WatchTimer {
            timer.invalidate()
            t3WatchTimer = nil
            t3SleepWatch.reset()
            t3SleepAt = nil
            endT3WatchActivity()
        }
        // Catches a lid opened while an update was in flight. Rare: only after a T3 sleep.
        if isKeepAwakeSuspendedForT3Sleep, !isToggleInFlight, isSomeoneAtTheMac {
            DispatchQueue.main.async { [weak self] in self?.restoreKeepAwakeAfterT3SleepIfLidOpen() }
        }
    }

    private func handleLidStateChange() {
        // Someone is at the Mac: closing the lid again restores the normal rule.
        if lidMonitor.isLidClosed() == false { t3SleepWatch.clearWaitForNewActivity() }
        evaluateT3Sleep()
        restoreKeepAwakeAfterT3SleepIfLidOpen()
    }

    private func evaluateT3Sleep() {
        guard !isToggleInFlight, !isQuitInProgress else { return }
        let conditions = T3SleepWatch.Conditions(
            isEnabled: isT3SleepEnabled,
            isKeepAwakeOn: isKeepAwakeOnForT3Watch,
            isLidClosed: lidMonitor.isLidClosed(),
            hasExternalDisplay: LidMonitor.hasExternalDisplay(),
            isDesktop: !LidMonitor.hasBuiltInLid,
            userIdleSeconds: LidMonitor.userIdleSeconds()
        )
        // Desktop: real keyboard or mouse use after a remote wake means someone is here,
        // like opening a MacBook's lid. The wake's own display wake-up does not count.
        if conditions.isDesktop, t3SleepWatch.waitsForNewActivity, let idle = conditions.userIdleSeconds,
           idle < 60, let wokeAt = lastRemoteKeepAwakeAt, Date().timeIntervalSince(wokeAt) > idle + 15 {
            t3SleepWatch.clearWaitForNewActivity()
        }
        if conditions.isWatching, t3SleepWatch.waitsForNewActivity {
            t3SleepWatch.noteRunStarted(at: t3ActivityReader.latestRunRequestedAt())
        }
        let previousSleepAt = t3SleepAt
        switch t3SleepWatch.evaluate(conditions, now: Date(), activity: readT3Activity) {
        case .notWatching, .waitingForActivity:
            t3SleepAt = nil
            endT3WatchActivity()
        case .busy:
            t3SleepAt = nil
            beginT3WatchActivity()
        case .waitingForGrace(let sleepAt):
            t3SleepAt = sleepAt
            beginT3WatchActivity()
        case .sleepNow:
            t3SleepAt = nil
            t3SleepWatch.reset()
            endT3WatchActivity()
            performT3Sleep()
            return
        }
        if previousSleepAt != t3SleepAt { refreshUI() }
    }

    private func readT3Activity() -> T3Activity {
        let activity = t3ActivityReader.read()
        if activity != lastT3Activity, isT3SleepEnabled {
            if case .unavailable(let reason) = activity {
                NSLog("Modafinil cannot read T3 Code state: \(reason)")
            }
        }
        lastT3Activity = activity
        lastT3ActivityAt = Date()
        return activity
    }

    private func performT3Sleep() {
        historyRecorder.note(LidMonitor.hasBuiltInLid ? "T3 Code finished: sleeping with the lid closed"
                                                      : "T3 Code finished: sleeping (nobody used the Mac for 5 min)")
        pendingSleepSource = ("T3 Code finished", Date())
        isKeepAwakeSuspendedForT3Sleep = true
        requestSystemSleep(source: "T3 Code finished") { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.isKeepAwakeSuspendedForT3Sleep = false
            self.pendingSleepSource = nil
            self.lastError = "Could not sleep after T3 Code finished: \(error.localizedDescription)"
            self.historyRecorder.note("Sleep after T3 Code finished failed: \(error.localizedDescription)")
            self.refreshIcon()
        }
    }

    /// After a T3 sleep, opening the lid turns keep-awake back on, so closing it
    /// again keeps the next agent session running. Waits while the sleep request
    /// is still being verified, so the helper's receipt cannot undo it.
    private func restoreKeepAwakeAfterT3SleepIfLidOpen() {
        guard isKeepAwakeSuspendedForT3Sleep, !isToggleInFlight, !isQuitInProgress,
              isSomeoneAtTheMac else { return }
        synchronizeSleepJournal()
        guard sleepAttempt?.phase != .pending else { return }
        isKeepAwakeSuspendedForT3Sleep = false
        cancelProvisionalWakeLease()
        companionConfigurationStore.isWakeArmed = false
        isSleepPreventionRequested = true
        keepAwakeChangeSource = "lid opened after T3 sleep"
        reconcileSleepPreventionWithCurrentMode()
    }

    /// The lid is open, or on a desktop the keyboard or mouse was used in the last minute.
    private var isSomeoneAtTheMac: Bool {
        if LidMonitor.hasBuiltInLid { return lidMonitor.isLidClosed() == false }
        return (LidMonitor.userIdleSeconds() ?? .infinity) < 60
    }

    private var isKeepAwakeSuspendedForT3Sleep: Bool {
        get { UserDefaults.standard.bool(forKey: Self.t3SleepRestoreDefaultsKey) }
        set {
            if newValue { UserDefaults.standard.set(true, forKey: Self.t3SleepRestoreDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.t3SleepRestoreDefaultsKey) }
        }
    }

    /// Stops App Nap from stretching the 15 s checks while the lid is closed.
    /// Does not prevent sleep and creates no power assertion.
    private func beginT3WatchActivity() {
        guard t3WatchActivity == nil else { return }
        t3WatchActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Waiting for T3 Code threads to finish before sleeping"
        )
    }

    private func endT3WatchActivity() {
        guard let activity = t3WatchActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        t3WatchActivity = nil
    }

    /// Fresh T3 state for a visible window, at most every 5 s.
    private func currentT3ActivityForDisplay() -> T3Activity? {
        guard isT3SleepEnabled else { return nil }
        if let at = lastT3ActivityAt, Date().timeIntervalSince(at) < 5, let activity = lastT3Activity {
            return activity
        }
        return readT3Activity()
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
            syncInitialSleepRequestIfNeeded(localSleepPreventionStatus)
            lidMonitor.setEnabled(localSleepPreventionStatus)
            if localSleepPreventionStatus {
                lidMonitor.turnDisplayOffIfNeeded()
            }
        } else if helperStatus != .enabled {
            isSleepPreventionEnabled = false
            syncInitialSleepRequestIfNeeded(false)
            lidMonitor.setEnabled(false)
        }

        guard helperStatus == .enabled else {
            reconcileSleepPreventionWithCurrentMode()
            return
        }

        helperClient.getSleepPreventionStatus { [weak self] result in
            guard let self else { return }
            guard generation == self.sleepStatusGeneration else { return }

            switch result {
            case .success(let enabled):
                self.isSleepPreventionEnabled = enabled
                self.syncInitialSleepRequestIfNeeded(enabled)
                self.lidMonitor.setEnabled(enabled)
                if enabled {
                    self.lidMonitor.turnDisplayOffIfNeeded()
                }
            case .failure(let error):
                self.lastError = error.localizedDescription
            }

            self.reconcileSleepPreventionWithCurrentMode()
        }
    }

    private func syncInitialSleepRequestIfNeeded(_ enabled: Bool) {
        guard !hasLoadedInitialSleepRequest else { return }

        isSleepPreventionRequested = enabled
        hasLoadedInitialSleepRequest = true
    }

    private func refreshIcon() {
        updateT3SleepMonitoring()
        let symbolName = isSleepPreventionEnabled ? "eye.fill" : Self.inactiveSymbolName
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let accessibilityDescription = if isSleepPreventionEnabled {
            "Modafinil active"
        } else if isWaitingForCodex {
            "Modafinil waiting for Codex"
        } else {
            "Modafinil inactive"
        }
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true

        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.title = image == nil ? "M" : ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = if isSleepPreventionEnabled {
            "Mac is on Modafinil"
        } else if isWaitingForCodex {
            "Modafinil will turn on when Codex is running"
        } else {
            "Mac is not on Modafinil"
        }

        refreshStatusPopover()
        refreshStatusWindow()
    }

    private func showMenu() {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)

        let menu = NSMenu()

        let statusText = if isSleepPreventionEnabled {
            "Status: On Modafinil"
        } else if isWaitingForCodex {
            "Status: Waiting for Codex"
        } else {
            "Status: Not on Modafinil"
        }
        let stateItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        if let lastError {
            let errorItem = NSMenuItem(title: "Error: \(lastError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let showStatusItem = NSMenuItem(
            title: "Open Modafinil",
            action: #selector(showStatusWindow),
            keyEquivalent: ""
        )
        showStatusItem.target = self
        menu.addItem(showStatusItem)

        let toggleItem = NSMenuItem(
            title: isAwakeRequestedForStatus ? "Turn Off" : "Turn On",
            action: #selector(toggleSleepPrevention),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let codexLimitItem = NSMenuItem(
            title: "Only While Codex Is Running",
            action: #selector(toggleCodexRuntimeLimit),
            keyEquivalent: ""
        )
        codexLimitItem.target = self
        codexLimitItem.state = isCodexRuntimeLimitEnabled ? .on : .off
        menu.addItem(codexLimitItem)

        let t3SleepItem = NSMenuItem(
            title: LidMonitor.hasBuiltInLid ? "Sleep When T3 Threads Finish (Lid Closed)" : "Sleep When T3 Threads Finish (Unused)",
            action: #selector(toggleT3Sleep),
            keyEquivalent: ""
        )
        t3SleepItem.target = self
        t3SleepItem.state = isT3SleepEnabled ? .on : .off
        menu.addItem(t3SleepItem)

        let quitBlockersItem = NSMenuItem(
            title: "Quit Apps Keeping the Mac Awake Before Sleep",
            action: #selector(toggleQuitBlockers),
            keyEquivalent: ""
        )
        quitBlockersItem.target = self
        quitBlockersItem.state = isQuitBlockersEnabled ? .on : .off
        menu.addItem(quitBlockersItem)

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItems.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let historyItem = NSMenuItem(title: "Sleep History…", action: #selector(showSleepHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let companionSetupItem = NSMenuItem(
            title: "Companion Setup…",
            action: #selector(showCompanionSetup),
            keyEquivalent: ""
        )
        companionSetupItem.target = self
        menu.addItem(companionSetupItem)

        if isCodexRuntimeLimitEnabled {
            let codexStatusItem = NSMenuItem(
                title: isCodexRunning ? "Codex: Running" : "Codex: Not Running",
                action: nil,
                keyEquivalent: ""
            )
            codexStatusItem.isEnabled = false
            menu.addItem(codexStatusItem)
        }

        if let activity = currentT3ActivityForDisplay() {
            let t3StatusItem = NSMenuItem(title: activity.summary, action: nil, keyEquivalent: "")
            t3StatusItem.isEnabled = false
            menu.addItem(t3StatusItem)
        }

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

    private func makeSnapshot() -> AppSnapshot {
        synchronizeSleepJournal()
        synchronizeWakeSchedule()
        var snapshot = AppSnapshot()
        snapshot.tone = isToggleInFlight ? .busy
            : isSleepPreventionEnabled ? .active
            : isWaitingForCodex ? .waiting
            : sleepAttempt?.phase == .failed ? .warning
            : .off
        snapshot.title = statusTitle
        snapshot.explanation = statusExplanation
        snapshot.isKeepAwakeRequested = isAwakeRequestedForStatus
        snapshot.isSleepPreventionActive = isSleepPreventionEnabled
        snapshot.isBusy = isToggleInFlight || isQuitInProgress
        snapshot.isCodexLimitEnabled = isCodexRuntimeLimitEnabled
        snapshot.isCodexRunning = isCodexRunning
        snapshot.isT3SleepEnabled = isT3SleepEnabled
        snapshot.hasBuiltInLid = LidMonitor.hasBuiltInLid
        if let activity = currentT3ActivityForDisplay() {
            snapshot.t3Status = activity.summary
            if case .busy(let threads) = activity {
                snapshot.t3Threads = threads.map { T3ThreadRow(title: $0.title, isWaiting: $0.isWaiting, isInBackground: $0.isInBackground) }
            }
        }
        snapshot.t3SleepAt = t3SleepAt
        snapshot.isT3RestorePending = isKeepAwakeSuspendedForT3Sleep
        snapshot.isQuitBlockersEnabled = isQuitBlockersEnabled
        let exclusions = quitBlockersExclusions
        snapshot.quitExclusions = exclusions.map { AppChoice(bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snapshot.quitCandidates = sleepBlockingApps().map(\.name)
        var seen = Set<String>()
        snapshot.excludableApps = NSWorkspace.shared.runningApplications.compactMap { app -> AppChoice? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, app.processIdentifier != getpid(),
                  !SleepBlockerApps.isProtected(bundleID: id), exclusions[id] == nil, seen.insert(id).inserted else { return nil }
            return AppChoice(bundleID: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snapshot.helperStatus = helperStatusDescription
        snapshot.isHelperEnabled = helperStatus == .enabled
        snapshot.scheduledSleepDate = scheduledSleepDate
        snapshot.scheduledWakeDate = scheduledWakeDate
        snapshot.canScheduleSleep = helperStatus == .enabled && !isToggleInFlight && !isQuitInProgress
        snapshot.canScheduleWake = helperStatus == .enabled && !isWakeScheduleInFlight && !isQuitInProgress
        snapshot.sleepAttempt = sleepAttempt
        snapshot.lastError = sleepHistoryError ?? lastError
        snapshot.loginItemStatus = loginItems.statusDescription
        snapshot.isLoginItemEnabled = loginItems.isEnabled
        snapshot.companionStatus = companionAccessStatus
        snapshot.isRemoteWakeArmed = companionConfigurationStore.isWakeArmed
        snapshot.isWakeRecoveryActive = isProvisionalWakeLeaseActive
        snapshot.tailscaleAddress = CompanionNetworkInformation.discover().tailscaleIPv4
        snapshot.relayHost = companionConfigurationStore.relayHost
        snapshot.blockers = SleepBlockers.current()
        let info = Bundle.main.infoDictionary
        snapshot.version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return snapshot
    }

    private var statusTitle: String {
        if isToggleInFlight {
            return "Updating Modafinil"
        }

        if isSleepPreventionEnabled {
            return "Sleep prevention is active"
        }

        if isWaitingForCodex {
            return "Waiting for Codex"
        }

        if sleepAttempt?.phase == .pending { return "Sleep requested — verifying" }
        if sleepAttempt?.phase == .failed { return "Sleep was not confirmed" }
        return "Keep-awake is off"
    }

    private var statusExplanation: String {
        if isToggleInFlight {
            return "Modafinil is asking the privileged helper to update the system sleep setting."
        }

        if isSleepPreventionEnabled, isProvisionalWakeLeaseActive {
            return "The Mac woke from a companion request. Modafinil is keeping it awake temporarily while the iPhone reconnects."
        }

        if isSleepPreventionEnabled, isCodexRuntimeLimitEnabled {
            return "Codex is running, so Modafinil is keeping your Mac awake. Sleep prevention will turn off when Codex stops."
        }

        if isSleepPreventionEnabled, isT3SleepEnabled {
            return "Modafinil is keeping your Mac awake. When \(T3SleepWording.condition), it sleeps once T3 Code threads finish."
        }

        if isSleepPreventionEnabled {
            return "Modafinil is keeping your Mac awake until you turn it off or quit the app."
        }

        if isWaitingForCodex {
            return "You asked Modafinil to turn on only for Codex. Codex is not running, so regular sleep behavior is restored for now."
        }

        if isSleepPreventionRequested {
            return "Modafinil is requested, but the current mode does not allow it to apply sleep prevention yet."
        }

        if let attempt = sleepAttempt, [.pending, .failed].contains(attempt.phase) { return attempt.detail }
        if isKeepAwakeSuspendedForT3Sleep {
            return T3SleepWording.restore
        }
        return "Modafinil is not preventing sleep. This does not mean the Mac is currently asleep."
    }

    private var isAwakeRequestedForStatus: Bool {
        isSleepPreventionRequested || isProvisionalWakeLeaseActive
    }

    private var helperStatusDescription: String {
        switch helperStatus {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Needs approval"
        case .notRegistered:
            return "Not registered"
        case .notFound:
            return "Not found"
        @unknown default:
            return "Unknown"
        }
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

    private struct CompanionRemoteError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private static let inactiveSymbolName: String = {
        if NSImage(systemSymbolName: "eye.half.closed.fill", accessibilityDescription: nil) != nil {
            return "eye.half.closed.fill"
        }

        return "eye.slash.fill"
    }()

    private static let codexRuntimeLimitEnabledDefaultsKey = "CodexRuntimeLimitEnabled"
    private static let t3SleepEnabledDefaultsKey = "T3SleepWhenFinishedEnabled"
    private static let t3SleepRestoreDefaultsKey = "T3SleepRestoreKeepAwake"
    private static let quitBlockersDefaultsKey = "QuitSleepBlockersBeforeSleep"
    private static let quitBlockersExclusionsDefaultsKey = "QuitSleepBlockersExclusions"
}
