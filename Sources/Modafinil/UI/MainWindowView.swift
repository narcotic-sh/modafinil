import ModafinilShared
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: AppUIModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(
                get: { Optional(model.section) },
                set: { if let section = $0 { model.section = section } }
            )) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            Group {
                switch model.section {
                case .overview: OverviewPage()
                case .timers: TimersPage()
                case .history: HistoryPage()
                case .iPhone: IPhonePage()
                case .otherMacs: OtherMacsPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(model.section.title)
        }
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppUIModel

    var body: some View {
        let snapshot = model.snapshot
        HStack(spacing: 8) {
            Circle().fill(snapshot.tone == .off ? Color.gray : snapshot.tone.color).frame(width: 8, height: 8)
            Text(snapshot.isSleepPreventionActive ? "Keeping awake" : "Normal sleep")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Scrollable page body with consistent margins and a readable maximum width.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Overview

struct OverviewPage: View {
    @EnvironmentObject private var model: AppUIModel

    var body: some View {
        let snapshot = model.snapshot
        Page {
            if let error = snapshot.lastError { ErrorBanner(message: error) }
            HeroCard(snapshot: snapshot) { model.actions?.uiToggleKeepAwake() }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) {
                StatTile(title: "Sleep timer",
                         value: snapshot.scheduledSleepDate.map { _ in "Running" } ?? "Off",
                         detail: snapshot.scheduledSleepDate.map { "Sleeps at \(UIFormat.time($0))" } ?? "Put the Mac to sleep later",
                         symbol: "moon.zzz.fill", tint: .indigo) { model.section = .timers }
                StatTile(title: "Wake alarm",
                         value: snapshot.scheduledWakeDate.map { UIFormat.time($0) } ?? "Off",
                         detail: snapshot.scheduledWakeDate.map { UIFormat.dayAndTime($0) } ?? "Wake the Mac at a set time",
                         symbol: "alarm.fill", tint: .orange) { model.section = .timers }
                StatTile(title: "iPhone",
                         value: snapshot.companionStatus,
                         detail: snapshot.isRemoteWakeArmed ? "Remote wake armed" : "Over Tailscale",
                         symbol: "iphone", tint: .blue) { model.section = .iPhone }
                StatTile(title: "Last sleep",
                         value: snapshot.sleepAttempt.map(UIFormat.sleepResultTitle) ?? "None yet",
                         detail: snapshot.sleepAttempt.flatMap { $0.sleptAt.map { "Slept \(UIFormat.dayAndTime($0))" } },
                         symbol: "clock.badge.checkmark.fill",
                         tint: snapshot.sleepAttempt?.phase == .failed ? .orange : .green) { model.section = .history }
            }

            if snapshot.isCodexLimitEnabled {
                Card(title: "Codex mode", symbol: "terminal") {
                    Text(snapshot.isCodexRunning
                         ? "Codex is running, so keep-awake applies. It turns off when Codex stops."
                         : "Keep-awake applies only while Codex is running. Codex is not running now.")
                        .foregroundStyle(.secondary)
                }
            }

            T3SleepCard(snapshot: snapshot) { model.actions?.uiToggleT3Sleep() }

            BlockersCard(blockers: snapshot.blockers, quitsBeforeSleep: snapshot.isQuitBlockersEnabled)
        }
    }
}

struct T3SleepCard: View {
    let snapshot: AppSnapshot
    let toggle: () -> Void

    var body: some View {
        Card(title: "Sleep when T3 Code finishes", symbol: "moon.stars.fill") {
            Toggle(isOn: Binding(get: { snapshot.isT3SleepEnabled }, set: { _ in toggle() })) {
                Text(T3SleepWording.toggleTitle)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("overviewT3Sleep")
            if !snapshot.isT3SleepEnabled {
                Text(T3SleepWording.off)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let sleepAt = snapshot.t3SleepAt, sleepAt > Date() {
                HStack(spacing: 6) {
                    Text("T3 Code has finished. Sleeping in")
                    Text(timerInterval: Date()...sleepAt, countsDown: true).monospacedDigit()
                }
                .font(.headline)
                .foregroundStyle(.indigo)
            } else if let status = snapshot.t3Status {
                Text(status).font(.headline)
            }
            ForEach(Array(snapshot.t3Threads.prefix(6).enumerated()), id: \.offset) { _, thread in
                HStack {
                    Text(thread.title).lineLimit(1)
                    Spacer()
                    Pill(text: thread.isWaiting ? "Waiting" : thread.isInBackground ? "Background" : "Working",
                         color: thread.isWaiting ? .orange : thread.isInBackground ? .teal : .green)
                }
                .font(.callout)
            }
            if snapshot.t3Threads.count > 6 {
                Text("and \(snapshot.t3Threads.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.isT3SleepEnabled {
            Text(snapshot.isKeepAwakeRequested
                 ? T3SleepWording.rule
                 : snapshot.isT3RestorePending
                 ? T3SleepWording.restore
                 : snapshot.hasBuiltInLid
                 ? "Turn keep-awake on for this to apply. Without it, closing the lid sleeps the Mac right away."
                 : "Turn keep-awake on for this to apply. Without it, the Mac sleeps on its normal idle timer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HeroCard: View {
    let snapshot: AppSnapshot
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            StatusBadge(tone: snapshot.tone, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.title)
                    .font(.title2.weight(.semibold))
                Text(snapshot.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.isWakeRecoveryActive {
                    Pill(text: "Wake recovery active", color: .blue)
                }
            }
            Spacer(minLength: 12)
            Button(action: toggle) {
                Text(snapshot.isKeepAwakeRequested ? "Turn Off" : "Turn On")
                    .frame(minWidth: 90)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(snapshot.isKeepAwakeRequested ? .gray : .green)
            .disabled(snapshot.isBusy)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("keepAwakeToggle")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [snapshot.tone.color.opacity(snapshot.tone == .off ? 0.06 : 0.16),
                                              Color(nsColor: .controlBackgroundColor)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

struct BlockersCard: View {
    let blockers: [SleepBlocker]
    var quitsBeforeSleep = false

    var body: some View {
        Card(title: "Other apps affecting sleep", symbol: "cup.and.saucer.fill") {
            let important = blockers.filter { $0.effect < .background }
            let background = blockers.filter { $0.effect == .background }
            let userActive = blockers.contains { $0.effect == .userActive }
            if important.isEmpty && background.isEmpty && !userActive {
                Text("No other app is preventing sleep right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(important, id: \.pid) { blocker in
                HStack(spacing: 10) {
                    ProcessIcon(pid: blocker.pid)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.processName).fontWeight(.medium)
                        if let detail = blocker.details.first {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Pill(text: blocker.effect.title, color: blocker.effect.color)
                }
            }
            if !background.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 22)
                    Text("macOS background work: \(background.prefix(5).map(\.processName).joined(separator: ", "))\(background.count > 5 ? ", …" : "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if userActive {
                HStack(spacing: 10) {
                    Image(systemName: "person.fill").foregroundStyle(.blue).frame(width: 22)
                    Text("You are using the Mac (display on)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Apps can stop idle sleep while the lid is open. Closing the lid still sleeps the Mac unless Modafinil is on or an external display is connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if quitsBeforeSleep {
                Text("Modafinil asks these apps to quit before it puts the Mac to sleep (except protected and excluded apps).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Timers

struct TimersPage: View {
    @EnvironmentObject private var model: AppUIModel
    @State private var customMinutes = 30
    @State private var wakeDate = Date().addingTimeInterval(3600)

    private static let presets: [(String, Int)] = [("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120), ("4 h", 240)]

    var body: some View {
        let snapshot = model.snapshot
        Page {
            if let error = snapshot.lastError { ErrorBanner(message: error) }
            // Side by side when the window is wide enough, stacked otherwise.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                sleepCard(snapshot)
                wakeCard(snapshot)
            }
        }
        .onAppear {
            if let date = snapshot.scheduledWakeDate { wakeDate = date }
        }
    }

    private func sleepCard(_ snapshot: AppSnapshot) -> some View {
        Card(title: "Sleep Timer", symbol: "moon.zzz.fill") {
            if let date = snapshot.scheduledSleepDate, date > Date() {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timerInterval: Date()...date, countsDown: true)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.indigo)
                    Text("The Mac sleeps at \(UIFormat.time(date)).")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel Timer", role: .destructive) { model.actions?.uiCancelSleepTimer() }
                    .accessibilityIdentifier("cancelSleepTimer")
            } else {
                Text("Turn keep-awake off and put the Mac to sleep after:")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.1) { title, minutes in
                        Button(title) { model.actions?.uiScheduleSleep(after: minutes * 60) }
                            .disabled(!snapshot.canScheduleSleep)
                    }
                }
                HStack(spacing: 8) {
                    Stepper(value: $customMinutes, in: 1...1440, step: 5) {
                        HStack(spacing: 4) {
                            TextField("Minutes", value: $customMinutes, format: .number)
                                .frame(width: 56)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("sleepTimerMinutes")
                            Text("minutes")
                        }
                    }
                    Button("Start") { model.actions?.uiScheduleSleep(after: min(1440, max(1, customMinutes)) * 60) }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(!snapshot.canScheduleSleep)
                        .accessibilityIdentifier("startSleepTimer")
                }
            }
            if let attempt = snapshot.sleepAttempt {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last result: \(UIFormat.sleepResultTitle(attempt))").font(.subheadline.weight(.medium))
                    Text(attempt.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let slept = attempt.sleptAt {
                        Text("Slept \(UIFormat.dayAndTime(slept))" + (attempt.wokeAt.map { " · woke \(UIFormat.dayAndTime($0))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The helper keeps the timer even if this window closes. Quitting Modafinil cancels it.")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.isQuitBlockersEnabled {
                Text("1 minute before the timer ends, apps keeping the Mac awake are asked to quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func wakeCard(_ snapshot: AppSnapshot) -> some View {
        Card(title: "Wake Alarm", symbol: "alarm.fill") {
            if let date = snapshot.scheduledWakeDate {
                Text(UIFormat.time(date))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                Text(UIFormat.dayAndTime(date)).foregroundStyle(.secondary)
            } else {
                Text("Wake the Mac at a set time and turn keep-awake on, up to 30 days ahead.")
                    .foregroundStyle(.secondary)
            }
            DatePicker("Wake at", selection: $wakeDate,
                       in: Date().addingTimeInterval(120)...Date().addingTimeInterval(30 * 24 * 3600),
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .accessibilityIdentifier("wakeDateTime")
            HStack {
                Button(snapshot.scheduledWakeDate == nil ? "Schedule Wake" : "Update Wake") {
                    let rounded = Date(timeIntervalSince1970: floor(wakeDate.timeIntervalSince1970 / 60) * 60)
                    model.actions?.uiScheduleWake(at: rounded)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!snapshot.canScheduleWake)
                .accessibilityIdentifier("scheduleWake")
                if snapshot.scheduledWakeDate != nil {
                    Button("Cancel", role: .destructive) { model.actions?.uiCancelWake() }
                        .disabled(!snapshot.canScheduleWake)
                        .accessibilityIdentifier("cancelWake")
                }
            }
            Text("Keep the Mac on power and Modafinil open to stay awake afterwards. Scheduling does not put it to sleep.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: iPhone

struct IPhonePage: View {
    @EnvironmentObject private var model: AppUIModel

    var body: some View {
        let snapshot = model.snapshot
        Page {
            Card(title: "Companion app", symbol: "iphone") {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 34))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("iPhone access").font(.title3.weight(.semibold))
                            Pill(text: snapshot.companionStatus,
                                 color: snapshot.companionStatus == "Listening" ? .green : .orange)
                        }
                        Text("Control keep-awake, timers and wake from your iPhone over Tailscale. Commands are signed with a secret kept in the Keychain.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Tailscale address").foregroundStyle(.secondary)
                        Text(snapshot.tailscaleAddress ?? "Not connected").textSelection(.enabled)
                    }
                    GridRow {
                        Text("Wake relay").foregroundStyle(.secondary)
                        Text(snapshot.relayHost.flatMap { $0.isEmpty ? nil : $0 } ?? "Not set up").textSelection(.enabled)
                    }
                    GridRow {
                        Text("Remote wake").foregroundStyle(.secondary)
                        Text(snapshot.isRemoteWakeArmed ? "Armed: the next network wake keeps the Mac awake briefly" : "Not armed")
                    }
                }
                Button("Pairing & Setup…") { model.actions?.uiOpenCompanionSetup() }
                    .buttonStyle(.borderedProminent)
            }
            recentActivity
            Card(title: "How remote wake works", symbol: "antenna.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Put the Mac to sleep from the iPhone or with a sleep timer. This arms remote wake.")
                    step(2, "Tap Wake & Keep Awake. The relay at home sends a wake packet to the Mac.")
                    step(3, "The Mac stays awake briefly until the iPhone reconnects and turns keep-awake on.")
                }
                Text("Network wake works on power. On battery, macOS usually ignores wake packets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recentActivity: some View {
        let now = Date()
        let markers = model.timeline(from: now.addingTimeInterval(-7 * 24 * 3600), to: now).markers
            .filter { $0.text.contains("iPhone") }
            .sorted { $0.at > $1.at }
            .prefix(6)
        return Card(title: "Recent iPhone activity", symbol: "clock.arrow.circlepath") {
            if markers.isEmpty {
                Text("No commands from the iPhone in the last 7 days.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    HStack {
                        Text(marker.text.replacingOccurrences(of: " (iPhone)", with: ""))
                        Spacer()
                        Text(UIFormat.dayAndTime(Date(timeIntervalSince1970: marker.at)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                .foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Settings

struct SettingsPage: View {
    @EnvironmentObject private var model: AppUIModel

    var body: some View {
        let snapshot = model.snapshot
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { snapshot.isLoginItemEnabled },
                    set: { _ in model.actions?.uiToggleLoginItem() }))
                Toggle(isOn: Binding(
                    get: { snapshot.isCodexLimitEnabled },
                    set: { _ in model.actions?.uiToggleCodexLimit() })) {
                    Text("Only keep awake while Codex is running")
                    Text(snapshot.isCodexRunning ? "Codex is running" : "Codex is not running")
                }
                Toggle(isOn: Binding(
                    get: { snapshot.isT3SleepEnabled },
                    set: { _ in model.actions?.uiToggleT3Sleep() })) {
                    Text(T3SleepWording.shortTitle)
                    Text(snapshot.t3Status.map { "\($0). " } ?? "")
                        + Text(T3SleepWording.rule)
                }
                .accessibilityIdentifier("t3SleepToggle")
            }
            Section("Before sleeping") {
                Toggle(isOn: Binding(
                    get: { snapshot.isQuitBlockersEnabled },
                    set: { _ in model.actions?.uiToggleQuitBlockers() })) {
                    Text("Quit apps that keep the Mac awake")
                    Text("When Modafinil puts the Mac to sleep (sleep timer, iPhone, or T3 Code finishing), it asks these apps to quit, like ⌘Q, so they can still ask to save. For a sleep timer this happens 1 minute before.")
                }
                .accessibilityIdentifier("quitBlockersToggle")
                LabeledContent("Would quit now",
                               value: snapshot.quitCandidates.isEmpty ? "None" : snapshot.quitCandidates.joined(separator: ", "))
                LabeledContent("Never quit", value: SleepBlockerApps.protectedSummary)
                ForEach(snapshot.quitExclusions, id: \.self) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Button("Remove") {
                            model.actions?.uiSetQuitExclusion(bundleID: app.bundleID, name: app.name, excluded: false)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Never Quit Another App…") {
                    ForEach(snapshot.excludableApps, id: \.self) { app in
                        Button(app.name) {
                            model.actions?.uiSetQuitExclusion(bundleID: app.bundleID, name: app.name, excluded: true)
                        }
                    }
                }
                .disabled(snapshot.excludableApps.isEmpty)
            }
            Section("Privileged helper") {
                LabeledContent("Status", value: snapshot.helperStatus)
                Button("Open Login Items & Extensions…") { model.actions?.uiOpenBackgroundSettings() }
            }
            Section("About") {
                LabeledContent("Version", value: snapshot.version)
                Text("Sleep history is stored only on this Mac for 60 days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Quit Modafinil") { model.actions?.uiQuit() }
                Button("Uninstall Modafinil…", role: .destructive) { model.actions?.uiUninstall() }
            }
        }
        .formStyle(.grouped)
    }
}
