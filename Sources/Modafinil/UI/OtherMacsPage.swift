import AppKit
import CoreImage
import ModafinilRemoteProtocol
import SwiftUI

extension RemoteMacsController.Phase {
    var title: String {
        switch self {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .awake: return "Awake · Keep-awake on"
        case .reachable: return "Awake · Sleeps normally"
        case .sleepRequested: return "Going to sleep…"
        case .unreachable: return "Asleep or unreachable"
        case .working(let message): return message
        case .failed: return "Could not complete the request"
        }
    }

    var shortTitle: String {
        switch self {
        case .unknown: return "—"
        case .checking: return "Checking…"
        case .awake: return "Kept awake"
        case .reachable: return "Awake"
        case .sleepRequested: return "Sleeping…"
        case .unreachable: return "Asleep"
        case .working(let message): return message
        case .failed: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .awake: return .green
        case .reachable: return .teal
        case .sleepRequested, .unreachable: return .indigo
        case .checking, .working: return .blue
        case .failed: return .orange
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .awake: return "eye.fill"
        case .reachable: return "desktopcomputer"
        case .sleepRequested, .unreachable: return "moon.zzz.fill"
        case .checking, .working: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown: return "desktopcomputer"
        }
    }
}

struct OtherMacsPage: View {
    @EnvironmentObject private var macs: RemoteMacsController
    @State private var link = ""
    @State private var addMessage: (text: String, isError: Bool)?
    @State private var pairingCodeFor: RemoteMacsController.Mac?
    @State private var sleepConfirmationFor: RemoteMacsController.Mac?

    private static let presets: [(String, Int)] = [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60),
                                                    ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)]

    var body: some View {
        Page {
            if let error = macs.storeError { ErrorBanner(message: error) }
            if macs.macs.isEmpty {
                Card(title: "Control another Mac", symbol: "desktopcomputer") {
                    Text("Wake a Mac mini or another Mac running Modafinil, keep it awake, or put it to sleep from here, the same way the iPhone does.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(macs.macs) { mac in macCard(mac) }
            addCard
            Card(title: "How it works", symbol: "antenna.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Commands go over Tailscale and are signed with that Mac’s secret, kept in this Mac’s keychain.")
                    Text("• Wake sends Wake-on-LAN packets from this Mac when it is on the same home network, and asks the iPad relay at the same time, so it also works away from home.")
                    Text("• The other Mac turns keep-awake on once it answers. Sleep turns keep-awake off and puts it to sleep.")
                    Text("• Status is checked when this page or the menu bar card opens, never in the background.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { macs.refreshAll() }
        .sheet(item: $pairingCodeFor) { mac in PairingCodeSheet(mac: mac, link: macs.pairingLink(mac.id) ?? "") }
        .confirmationDialog("Put \(sleepConfirmationFor?.name ?? "the Mac") to sleep?",
                            isPresented: Binding(get: { sleepConfirmationFor != nil },
                                                 set: { if !$0 { sleepConfirmationFor = nil } }),
                            titleVisibility: .visible) {
            Button("Sleep") {
                if let id = sleepConfirmationFor?.id { Task { await macs.sleepNow(id) } }
                sleepConfirmationFor = nil
            }
            Button("Cancel", role: .cancel) { sleepConfirmationFor = nil }
        } message: {
            Text("Keep-awake turns off and the Mac sleeps. Wake it again from here or from the iPhone.")
        }
    }

    private func macCard(_ mac: RemoteMacsController.Mac) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mac.phase.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(mac.phase.color)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(mac.name).font(.title3.weight(.semibold))
                        Pill(text: mac.phase.shortTitle, color: mac.phase.color)
                    }
                    Text(mac.phase.title).foregroundStyle(.secondary)
                    if case .failed(let message) = mac.phase {
                        Text(message).font(.callout).foregroundStyle(.orange)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let date = mac.scheduledSleepAt, date > Date() {
                        HStack(spacing: 4) {
                            Text("Sleeps in")
                            Text(timerInterval: Date()...date, countsDown: true).monospacedDigit()
                        }
                        .font(.callout).foregroundStyle(.indigo)
                    }
                    if let attempt = mac.sleepAttempt, attempt.phase == .failed,
                       Date().timeIntervalSince1970 - Double(attempt.requestedAt) < 15 * 60 {
                        Text("Last sleep not confirmed: \(attempt.detail)")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(mac.configuration.macHost) · wake \(mac.configuration.targetMAC.replacingOccurrences(of: ",", with: ", "))"
                         + (mac.lastChecked.map { " · checked \(UIFormat.time($0))" } ?? ""))
                        .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    Task { await macs.wakeAndKeepAwake(mac.id) }
                } label: {
                    Label("Wake & Keep Awake", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(mac.phase.isBusy)

                Button {
                    sleepConfirmationFor = mac
                } label: {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                }
                .disabled(mac.phase.isBusy || mac.phase == .unreachable)

                if let date = mac.scheduledSleepAt, date > Date() {
                    Button("Cancel Sleep Timer") { Task { await macs.cancelSleepTimer(mac.id) } }
                        .disabled(mac.phase.isBusy)
                } else {
                    Menu("Sleep After…") {
                        ForEach(Self.presets, id: \.1) { title, minutes in
                            Button(title) { Task { await macs.sleep(mac.id, after: minutes * 60) } }
                        }
                    }
                    .fixedSize()
                    .disabled(mac.phase.isBusy || mac.phase == .unreachable)
                }

                Spacer()
                Button { Task { await macs.refresh(mac.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Check status")
                    .disabled(mac.phase.isBusy)
                Menu {
                    Button("Show iPhone Pairing Code…") { pairingCodeFor = mac }
                    Button("Copy Pairing Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(macs.pairingLink(mac.id) ?? "", forType: .string)
                    }
                    Divider()
                    Button("Remove \(mac.name)", role: .destructive) { macs.remove(mac.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var addCard: some View {
        Card(title: macs.macs.isEmpty ? "Add a Mac" : "Add another Mac", symbol: "plus.circle") {
            Text("On the other Mac, open Modafinil → iPhone → Pairing & Setup… and click Copy Pairing Link. Paste it here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("modafinil://pair?…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Paste") { link = NSPasteboard.general.string(forType: .string) ?? link }
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let addMessage {
                Text(addMessage.text)
                    .font(.callout)
                    .foregroundStyle(addMessage.isError ? .red : .green)
            }
            Text("The link contains that Mac’s private secrets; it is stored only in this Mac’s keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        do {
            let name = try macs.add(pairingLink: link)
            addMessage = ("Added \(name).", false)
            link = ""
        } catch {
            addMessage = (error.localizedDescription, true)
        }
    }
}

/// The other Mac's pairing QR code, so the iPhone can pair with it from here.
private struct PairingCodeSheet: View {
    let mac: RemoteMacsController.Mac
    let link: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair iPhone with \(mac.name)").font(.title3.weight(.semibold))
            if let image = Self.qrCode(link) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
            }
            Text("In Modafinil Companion on the iPhone, choose Add Mac → Scan Pairing Code. The code contains private secrets.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(width: 300)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    static func qrCode(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// One compact row per paired Mac in the menu bar card.
struct OtherMacsPopoverSection: View {
    @EnvironmentObject private var macs: RemoteMacsController

    var body: some View {
        if !macs.macs.isEmpty {
            VStack(spacing: 8) {
                ForEach(macs.macs) { mac in
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(mac.phase.color).frame(width: 18)
                        Text(mac.name).lineLimit(1)
                        Spacer()
                        Text(mac.phase.shortTitle).foregroundStyle(.secondary).lineLimit(1)
                        Button { Task { await macs.wakeAndKeepAwake(mac.id) } } label: {
                            Image(systemName: "power")
                        }
                        .help("Wake \(mac.name) and keep it awake")
                        .disabled(mac.phase.isBusy)
                        .accessibilityIdentifier("popoverWake-\(mac.name)")
                        Button { Task { await macs.sleepNow(mac.id) } } label: {
                            Image(systemName: "moon.zzz.fill")
                        }
                        .help("Put \(mac.name) to sleep")
                        .disabled(mac.phase.isBusy || mac.phase == .unreachable)
                        .accessibilityIdentifier("popoverSleep-\(mac.name)")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
        }
    }
}
