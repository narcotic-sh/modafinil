import Darwin
import Foundation
import ModafinilRemoteProtocol

struct CompanionNetworkInformation {
    let tailscaleIPv4: String?
    let wifiInterface: String?
    let wifiMACAddress: String?
    let wifiHardwareMACAddress: String?
    /// Addresses of connected wired Ethernet ports (a Mac mini's built-in port).
    /// Wake-on-LAN over a cable is the most reliable wake path, so they come first.
    var ethernetMACAddresses: [String] = []

    static func discover() -> Self {
        let ports = discoverHardwarePorts()
        let wifi = ports.first { $0.name == "Wi-Fi" }
        let ethernet = ports.filter(\.isWiredEthernet)
            .filter { isActive(interface: $0.interface) }
            // Wired ports have no private address, and the hardware address is not
            // redacted the way macOS 27 redacts `ifconfig` output for apps.
            .compactMap { $0.hardwareMAC?.lowercased() ?? currentMACAddress(interface: $0.interface) }
        return Self(
            tailscaleIPv4: discoverTailscaleIPv4(),
            wifiInterface: wifi?.interface,
            wifiMACAddress: wifi.flatMap { currentMACAddress(interface: $0.interface) },
            wifiHardwareMACAddress: wifi?.hardwareMAC,
            ethernetMACAddresses: ethernet
        )
    }

    /// Prefer connected Ethernet, then the live per-network Wi-Fi address, retain the
    /// hardware fallback, then preserve configured extra interfaces within the relay's
    /// four-target cap.
    func wakeTargetMACs(configured: String? = nil) -> String? {
        var addresses: [String] = []
        let candidates = ethernetMACAddresses + [wifiMACAddress, wifiHardwareMACAddress].compactMap { $0 }
            + (configured?.components(separatedBy: ",") ?? [])
        for candidate in candidates {
            guard let valid = PairingConfiguration.normalizedWakeTargets(candidate),
                  valid != Self.redactedMACAddress, !addresses.contains(valid) else { continue }
            addresses.append(valid)
            if addresses.count == 4 { break }
        }
        return addresses.isEmpty ? nil : addresses.joined(separator: ",")
    }

    private static func discoverTailscaleIPv4() -> String? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else {
            return nil
        }
        defer { freeifaddrs(firstInterface) }

        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            defer { interface = current.pointee.ifa_next }

            guard
                current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let address = current.pointee.ifa_addr
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let value = String(cString: host)
            if isTailscaleIPv4(value) {
                return value
            }
        }

        return nil
    }

    private static func isTailscaleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    struct HardwarePort {
        let name: String
        let interface: String
        let hardwareMAC: String?

        /// "Ethernet" (built in), "Thunderbolt Ethernet Slot 1", "USB 10/100/1000 LAN".
        /// "Ethernet Adapter (en4)" entries are virtual and never wake the Mac.
        var isWiredEthernet: Bool {
            (name.contains("Ethernet") && !name.hasPrefix("Ethernet Adapter")) || name.hasSuffix(" LAN")
        }
    }

    static func discoverHardwarePorts() -> [HardwarePort] {
        guard let output = try? Shell.run(
            "/usr/sbin/networksetup",
            ["-listallhardwareports"]
        ) else {
            return []
        }
        return parseHardwarePorts(output)
    }

    static func parseHardwarePorts(_ output: String) -> [HardwarePort] {
        var ports: [HardwarePort] = []
        for block in output.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: .newlines)
            func value(_ prefix: String) -> String? {
                lines.first(where: { $0.hasPrefix(prefix) })?
                    .dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let name = value("Hardware Port: "), let interface = value("Device: ") else { continue }
            ports.append(HardwarePort(name: name, interface: interface, hardwareMAC: value("Ethernet Address: ")))
        }
        return ports
    }

    /// True when the interface reports a connected link ("status: active").
    private static func isActive(interface: String) -> Bool {
        guard let output = try? Shell.run("/sbin/ifconfig", [interface]) else { return false }
        return output.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "status: active"
        }
    }

    private static func currentMACAddress(interface: String) -> String? {
        guard let output = try? Shell.run("/sbin/ifconfig", [interface]) else {
            return nil
        }

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "ether" else { continue }

            let candidate = String(fields[1]).lowercased()
            // macOS 27 reports 02:00:00:00:00:00 to apps instead of the real address.
            guard isMACAddress(candidate), candidate != redactedMACAddress else { continue }
            return candidate
        }

        return nil
    }

    private static let redactedMACAddress = "02:00:00:00:00:00"

    private static func isMACAddress(_ value: String) -> Bool {
        let bytes = value.split(separator: ":")
        return bytes.count == 6 && bytes.allSatisfy {
            $0.count == 2 && UInt8($0, radix: 16) != nil
        }
    }
}
