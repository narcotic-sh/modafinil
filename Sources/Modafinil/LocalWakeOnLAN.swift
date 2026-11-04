import Darwin
import Foundation

/// Sends Wake-on-LAN magic packets from this Mac to its own local networks. When
/// this Mac is at home it reaches a sleeping Mac directly, without the iPad relay.
/// Away from home the packets go nowhere, which is harmless.
enum LocalWakeOnLAN {
    /// Returns the number of packets handed to the network.
    @discardableResult
    static func send(targets: String) -> Int {
        let addresses = targets.split(separator: ",").compactMap { parseMAC(String($0)) }
        guard !addresses.isEmpty else { return 0 }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return 0 }
        defer { close(socket) }
        var enabled: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var sent = 0
        let destinations = broadcastAddresses() + [in_addr_t(0xffff_ffff)]
        for mac in addresses {
            let packet = magicPacket(mac)
            for destination in destinations {
                for port: UInt16 in [9, 7] {
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    address.sin_addr.s_addr = destination
                    let result = packet.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(socket, bytes.baseAddress, bytes.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if result == packet.count { sent += 1 }
                }
            }
        }
        return sent
    }

    static func magicPacket(_ mac: [UInt8]) -> Data {
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }

    static func parseMAC(_ text: String) -> [UInt8]? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard parts.count == 6, bytes.count == 6, bytes[0] & 1 == 0 else { return nil }
        return bytes
    }

    /// Subnet broadcast addresses (network byte order) of active IPv4 LAN interfaces,
    /// skipping loopback, Tailscale and other point-to-point tunnels.
    private static func broadcastAddresses() -> [in_addr_t] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [in_addr_t] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let broadcast = entry.pointee.ifa_dstaddr, broadcast.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let value = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if value != 0, !result.contains(value) { result.append(value) }
        }
        return result
    }
}
