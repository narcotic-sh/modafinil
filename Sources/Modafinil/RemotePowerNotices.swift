import Foundation
import ModafinilRemoteProtocol
import Network

/// Pushes only to peers that have already authenticated to our TCP listener.
/// Received notices must match a paired Mac's address AND command secret.
final class RemotePowerNotices {
    private let queue = DispatchQueue(label: "com.narcotic.modafinil.power-notices")
    private var listener: NWListener?
    private var outgoing: [UUID: NWConnection] = [:]
    private var incoming: [UUID: NWConnection] = [:]
    private var lastPublished: Bool?
    private var peerHosts: [String] = UserDefaults.standard.stringArray(forKey: "powerNoticeObservers") ?? []
    private var lastRevision: Int64 = 0
    var onNotice: ((String, Bool) -> Void)?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Modafinil/remote-power", isDirectory: true)

    func start() {
        queue.async { self.startOnQueue() }
    }
    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: RemotePowerNotice.port)!)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel(); self?.listener = nil
                    self?.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startOnQueue() }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch { NSLog("Modafinil power notices: %@", error.localizedDescription) }
    }
    func remember(_ host: String) {
        queue.async {
            guard !self.peerHosts.contains(host) else { return }
            self.peerHosts.append(host)
            self.peerHosts = Array(self.peerHosts.suffix(16))
            UserDefaults.standard.set(self.peerHosts, forKey: "powerNoticeObservers")
        }
    }
    func publish(sleeping: Bool, secret: Data) {
        queue.async {
            guard self.lastPublished != sleeping else { return }
            self.lastPublished = sleeping
            self.lastRevision = max(self.lastRevision + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
            let notice = RemotePowerNotice.signed(sleeping: sleeping, secret: secret, revision: self.lastRevision)
            guard let data = try? RemoteWireCodec.encodeLine(notice) else { return }
            // Repeats tolerate datagram loss. The revision suppresses duplicates
            // and an older sleep notice arriving after a wake notice.
            for delay in [0.0, 0.5, 1.0] {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    for host in self.peerHosts { self.send(data, to: host) }
                }
            }
        }
    }
    private func send(_ data: Data, to host: String) {
        let id = UUID()
        let connection = NWConnection(host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: RemotePowerNotice.port)!, using: .udp)
        outgoing[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                    connection.cancel(); self?.outgoing[id] = nil
                })
            case .failed, .cancelled: connection.cancel(); self.outgoing[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in connection.cancel(); self?.outgoing[id] = nil }
    }
    private func accept(_ connection: NWConnection) {
        guard incoming.count < 16, CompanionServer.isAllowedPeer(connection.endpoint),
              case .hostPort(let host, _) = connection.endpoint else { connection.cancel(); return }
        let address = "\(host)"
        let id = UUID()
        incoming[id] = connection
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            if let data, data.count <= 2048,
               let response = try? RemoteWireCodec.decodeLine(RemoteResponse.self, from: data),
               let pairing = try? RemoteMacStore().load().first(where: { $0.macHost == address }) {
                self.receive(response, pairing: pairing)
            }
            connection.cancel(); self.incoming[id] = nil
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in connection.cancel(); self?.incoming[id] = nil }
    }
    private func receive(_ response: RemoteResponse, pairing: PairingConfiguration) {
        let url = Self.directory.appendingPathComponent(pairing.macHost + ".json")
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let last = (previous?["revision"] as? NSNumber)?.int64Value ?? 0
        guard let notice = RemotePowerNotice.verify(response, secret: pairing.secret, lastRevision: last) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["sleeping": notice.sleeping,
                "revision": notice.revision, "receivedAt": Date().timeIntervalSince1970])
            try data.write(to: url, options: .atomic)
            DispatchQueue.main.async { [weak self] in self?.onNotice?(pairing.macHost, notice.sleeping) }
        } catch { NSLog("Modafinil could not save power notice: %@", error.localizedDescription) }
    }
}
