import Foundation
import ModafinilRemoteProtocol
import Network

protocol CompanionServerDelegate: AnyObject {
    func companionServerCurrentState(_ server: CompanionServer) -> RemoteState

    func companionServer(
        _ server: CompanionServer,
        perform command: RemoteCommand,
        argument: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    )
}

final class CompanionServer {
    weak var delegate: CompanionServerDelegate?
    var errorHandler: ((String) -> Void)?
    var authenticatedPeerHandler: ((String) -> Void)?

    private var secret: Data
    private let queue = DispatchQueue(label: "com.narcotic.modafinil.companion")
    private var requestVerifier: RemoteRequestVerifier
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(secret: Data) {
        self.secret = secret
        requestVerifier = RemoteRequestVerifier(secret: secret)
    }

    /// Plain-language listener state for the Mac window, reported on the main queue.
    var statusHandler: ((String) -> Void)?

    private var restartWorkItem: DispatchWorkItem?
    private var waitingCheck: DispatchWorkItem?
    private var restartDelay: TimeInterval = 2
    private var isStopped = false

    func start() throws {
        try queue.sync {
            isStopped = false
            try startOnQueue()
        }
    }

    /// Restarts the listener if it is not running. Called after every wake.
    func ensureRunning() {
        queue.async {
            guard !self.isStopped, self.listener == nil, self.restartWorkItem == nil else { return }
            self.restartDelay = 2
            self.startOrScheduleRestart()
        }
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.waitingCheck?.cancel()
            self.waitingCheck = nil
            self.listener?.cancel()
            self.listener = nil
            self.activeConnections.values.forEach { $0.cancel() }
            self.activeConnections.removeAll()
        }
    }

    private func startOnQueue() throws {
        guard listener == nil else { return }

        let port = NWEndpoint.Port(rawValue: CompanionConfigurationStore.macPort)!
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.restartDelay = 2
                self.waitingCheck?.cancel()
                self.waitingCheck = nil
                self.reportStatus("Listening")
            case .failed(let error):
                self.report(error: "Companion listener failed: \(error.localizedDescription). Restarting…")
                self.dropListenerAndRestart()
            case .waiting(let error):
                self.reportStatus("Waiting for network: \(error.localizedDescription)")
                // A listener stuck waiting is rebuilt rather than trusted to recover.
                let check = DispatchWorkItem { [weak self] in
                    guard let self, self.listener === listener else { return }
                    if case .waiting = listener.state { self.dropListenerAndRestart() }
                }
                self.waitingCheck?.cancel()
                self.waitingCheck = check
                self.queue.asyncAfter(deadline: .now() + 15, execute: check)
            default:
                break
            }
        }
        self.listener = listener
        reportStatus("Starting")
        listener.start(queue: queue)
    }

    private func dropListenerAndRestart() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        waitingCheck?.cancel()
        waitingCheck = nil
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !isStopped, restartWorkItem == nil else { return }
        let delay = restartDelay
        restartDelay = min(60, restartDelay * 2)
        reportStatus("Restarting in \(Int(delay)) s")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.startOrScheduleRestart()
        }
        restartWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startOrScheduleRestart() {
        guard !isStopped else { return }
        do { try startOnQueue() }
        catch {
            report(error: "Companion listener could not start: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func reportStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.statusHandler?(status) }
    }

    func updateSecret(_ secret: Data) {
        queue.async {
            self.secret = secret
            self.requestVerifier = RemoteRequestVerifier(secret: secret)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isAllowedPeer(connection.endpoint) else {
            NSLog("Modafinil rejected companion connection from non-Tailscale peer")
            connection.cancel()
            return
        }

        guard activeConnections.count < 32 else {
            connection.cancel()
            return
        }

        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.activeConnections[connectionID] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
            connection?.cancel()
        }
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4_096
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            guard buffer.count <= RemoteWireCodec.maximumMessageSize else {
                connection.cancel()
                return
            }

            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let nextIndex = buffer.index(after: newlineIndex)
                guard nextIndex == buffer.endIndex else {
                    connection.cancel()
                    return
                }

                handleRequestLine(buffer, connection: connection)
                return
            }

            guard !isComplete else {
                connection.cancel()
                return
            }

            receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func handleRequestLine(_ data: Data, connection: NWConnection) {
        let request: RemoteRequest
        do {
            request = try RemoteWireCodec.decodeLine(RemoteRequest.self, from: data)
        } catch {
            connection.cancel()
            return
        }

        let responseSecret = secret
        do {
            try requestVerifier.verify(request)
        } catch {
            send(
                requestID: request.requestID,
                version: request.version,
                ok: false,
                state: nil,
                message: error.localizedDescription,
                secret: responseSecret,
                on: connection
            )
            return
        }

        if case .hostPort(let host, _) = connection.endpoint { authenticatedPeerHandler?("\(host)") }
        perform(
            request: request,
            responseSecret: responseSecret,
            connection: connection
        )
    }

    private func perform(
        request: RemoteRequest,
        responseSecret: Data,
        connection: NWConnection
    ) {
        guard request.command != .wake else {
            send(
                requestID: request.requestID,
                version: request.version,
                ok: false,
                state: nil,
                message: "Wake requests must be sent to the iPhone relay.",
                secret: responseSecret,
                on: connection
            )
            return
        }

        guard let delegate else {
            send(
                requestID: request.requestID,
                version: request.version,
                ok: false,
                state: nil,
                message: "Modafinil is not ready.",
                secret: responseSecret,
                on: connection
            )
            return
        }

        if request.command == .status {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let state = delegate.companionServerCurrentState(self)
                self.queue.async {
                    self.send(
                        requestID: request.requestID,
                        version: request.version,
                        ok: true,
                        state: state,
                        message: "Status updated.",
                        secret: responseSecret,
                        on: connection
                    )
                }
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }

            delegate.companionServer(
                self,
                perform: request.command,
                argument: request.argument
            ) { result in
                self.queue.async {
                    switch result {
                    case .success(let (state, message)):
                        self.send(
                            requestID: request.requestID,
                            version: request.version,
                            ok: true,
                            state: state,
                            message: message,
                            secret: responseSecret,
                            on: connection
                        )
                    case .failure(let error):
                        self.send(
                            requestID: request.requestID,
                            version: request.version,
                            ok: false,
                            state: nil,
                            message: error.localizedDescription,
                            secret: responseSecret,
                            on: connection
                        )
                    }
                }
            }
        }
    }

    private func send(
        requestID: String,
        version: Int,
        ok: Bool,
        state: RemoteState?,
        message: String,
        secret: Data,
        on connection: NWConnection
    ) {
        let response = RemoteResponse.signed(
            version: RemoteResponse.supportedVersions.contains(version) ? version : 1,
            requestID: requestID,
            ok: ok,
            state: state,
            message: message,
            secret: secret
        )

        do {
            let data = try RemoteWireCodec.encodeLine(response)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }

    private func report(error: String) {
        NSLog("Modafinil \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.errorHandler?(error)
        }
    }

    static func isAllowedPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        var address = host.debugDescription
        if let scopeIndex = address.firstIndex(of: "%") {
            address = String(address[..<scopeIndex])
        }
        address = address.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )

        if let ipv4 = IPv4Address(address) {
            let bytes = [UInt8](ipv4.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 127 ||
                (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }

        if let ipv6 = IPv6Address(address) {
            let bytes = [UInt8](ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } &&
                bytes.last == 1
            let isTailscale = Array(bytes.prefix(6)) == [
                0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0
            ]
            return isLoopback || isTailscale
        }

        return false
    }
}
