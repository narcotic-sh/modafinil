import Foundation
import ModafinilRemoteProtocol
import ModafinilT3

/// Setup over SSH, for a Mac without a screen nearby (for example a Mac mini):
///
///     Modafinil --companion-relay-secret            # print this Mac's relay secret
///     Modafinil --companion-set-relay <host> [port] < relay-secret.txt
///     Modafinil --companion-pairing-link            # print this Mac's pairing link
///     Modafinil --remote-mac-add < pairing-link.txt # control another Mac from this one
///     Modafinil --remote-mac-list
///     Modafinil --remote-mac status|wake|sleep|t3sleep-on|t3sleep-off <name or address>
///     Modafinil --t3-activity                       # what "Sleep when T3 finishes" counts here
///     Modafinil --install-helper                    # register the helper; approve it in Login Items
///
/// Secrets travel through standard input and output, never the argument list.
/// Run in the logged-in user's session so the login keychain is available.
enum CompanionCommandLine {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.count > 1 && (arguments[1].hasPrefix("--companion-") || arguments[1].hasPrefix("--remote-mac") || arguments[1] == "--install-helper" || arguments[1] == "--t3-activity")
    }

    static func run(_ arguments: [String]) -> Int32 {
        let command = arguments[1]
        let rest = Array(arguments.dropFirst(2))
        switch command {
        case "--companion-relay-secret":
            print(CompanionConfigurationStore().relaySecret.base64EncodedString())
            return 0
        case "--companion-set-relay":
            guard let host = rest.first, !host.isEmpty else { return fail("Usage: --companion-set-relay <host> [port] < secret") }
            let port = rest.count > 1 ? UInt16(rest[1]) : CompanionConfigurationStore.defaultRelayPort
            guard let port, port > 0 else { return fail("The relay port is invalid.") }
            let store = CompanionConfigurationStore()
            let secret = readLine(strippingNewline: true) ?? ""
            if !secret.isEmpty, !store.importRelaySecret(base64: secret) {
                return fail("Standard input does not hold a 32-byte base64 relay secret.")
            }
            store.updatePairing(relayHost: host, relayPort: port, targetMACs: store.configuredTargetMACs ?? "")
            print("Relay set to \(host):\(port)\(secret.isEmpty ? "" : " with the imported secret").")
            return 0
        case "--companion-pairing-link":
            let store = CompanionConfigurationStore()
            let configuration = store.pairingConfiguration(networkInformation: .discover())
            guard !configuration.macHost.isEmpty else { return fail("Tailscale IPv4 was not found on this Mac.") }
            guard !configuration.relayHost.isEmpty else { return fail("Set the relay first (--companion-set-relay).") }
            guard !configuration.targetMAC.isEmpty else { return fail("No wake address (Ethernet or Wi-Fi) was found.") }
            print(configuration.pairingURL.absoluteString)
            return 0
        case "--remote-mac-add":
            let text = readLine(strippingNewline: true) ?? ""
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
                  let configuration = try? PairingConfiguration(pairingURL: url) else {
                return fail("Standard input does not hold a Modafinil pairing link.")
            }
            do {
                try RemoteMacStore().upsert(configuration)
            } catch {
                return fail(error.localizedDescription)
            }
            print("Added \(configuration.displayName) (\(configuration.macHost)).")
            return 0
        case "--remote-mac":
            guard rest.count == 2, ["status", "wake", "sleep", "t3sleep-on", "t3sleep-off"].contains(rest[0]) else {
                return fail("Usage: --remote-mac status|wake|sleep|t3sleep-on|t3sleep-off <name or address>")
            }
            return runRemoteMacCommand(rest[0], target: rest[1])
        case "--remote-mac-pairing-link":
            guard rest.count == 1,
                  let mac = try? RemoteMacStore().load().first(where: {
                      $0.displayName.localizedCaseInsensitiveContains(rest[0]) || $0.macHost == rest[0]
                  }) else { return fail("Usage: --remote-mac-pairing-link <paired name or address>") }
            print(mac.pairingURL.absoluteString)
            return 0
        case "--remote-mac-list":
            for mac in (try? RemoteMacStore().load()) ?? [] {
                print("\(mac.displayName)\t\(mac.macHost):\(mac.macPort)\trelay \(mac.relayHost):\(mac.relayPort)\twake \(mac.targetMAC)")
            }
            return 0
        case "--t3-activity":
            let activity = T3ActivityReader().read()
            print(activity.summary)
            if case .busy(let threads) = activity {
                for thread in threads { print("  [\(thread.status)] \(thread.title)") }
            }
            if let idle = LidMonitor.userIdleSeconds() { print("Keyboard/mouse idle: \(Int(idle)) s") }
            print(LidMonitor.hasBuiltInLid ? "Rule: lid closed, no external display" : "Rule: nobody used the Mac for 5 min")
            return 0
        case "--install-helper":
            let installer = PrivilegedHelperInstaller()
            if installer.status != .enabled {
                do { try installer.register() } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
            }
            switch installer.status {
            case .enabled: print("Helper enabled."); return 0
            case .requiresApproval:
                print("Helper needs approval: System Settings → General → Login Items & Extensions → Modafinil.")
                installer.openApprovalSettings()
                return 1
            default: return fail("Helper not registered (status \(installer.status.rawValue)).")
            }
        default:
            return fail("Unknown option \(command).")
        }
    }

    /// Runs one command through the same controller as the Other Macs page.
    private static func runRemoteMacCommand(_ action: String, target: String) -> Int32 {
        var code: Int32 = 2
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let controller = RemoteMacsController()
            guard let mac = controller.macs.first(where: {
                $0.name.localizedCaseInsensitiveContains(target) || $0.configuration.macHost == target
            }) else {
                FileHandle.standardError.write(Data("No paired Mac matches \(target).\n".utf8))
                done.signal(); return
            }
            let started = Date()
            switch action {
            case "wake": await controller.wakeAndKeepAwake(mac.id)
            case "sleep": await controller.sleepNow(mac.id)
            case "t3sleep-on", "t3sleep-off": await controller.setT3Sleep(mac.id, enabled: action == "t3sleep-on")
            default: await controller.refresh(mac.id)
            }
            let phase = controller.macs.first { $0.id == mac.id }?.phase ?? .unknown
            var line = "\(mac.name): \(phase.title) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
            if case .failed(let message) = phase { line += " — \(message)" }
            if let t3 = controller.macs.first(where: { $0.id == mac.id })?.t3Sleep {
                line += "\n  Sleep when T3 finishes: \(t3.enabled ? "on" : "off") — \(t3.summary)"
                if let at = t3.sleepAt { line += " (sleeps at \(UIFormat.time(Date(timeIntervalSince1970: TimeInterval(at)))))" }
            }
            print(line)
            switch phase {
            case .failed: code = 1
            case .unreachable: code = action == "sleep" ? 0 : 3
            default: code = 0
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return code
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
