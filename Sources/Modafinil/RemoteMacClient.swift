import Foundation
import ModafinilRemoteProtocol
import Network
import os

/// Sends one signed request to another Mac or to the wake relay. Ported from
/// Modafinil Companion (iPhone) so both clients behave the same.

struct RemoteMacClient {
    let secret: Data
    var protocolVersion: Int = RemoteRequest.currentVersion

    static func indicatesUnavailableDevice(_ error: Error) -> Bool {
        (error as? RemoteClientError)?.indicatesUnavailableDevice == true
    }

    /// Worth asking the relay again: it was unreachable or briefly unable to send.
    static func indicatesRetryableRelayFailure(_ error: Error) -> Bool {
        guard let error = error as? RemoteClientError else { return false }
        return error.indicatesUnavailableDevice || error.isRetryableRelayRejection
    }

    static func indicatesServerUpdateRequired(_ error: Error) -> Bool {
        if case .serverUpdateRequired = error as? RemoteClientError { return true }
        return false
    }

    func send(
        _ command: RemoteCommand,
        argument: String = "",
        host: String,
        port: UInt16,
        timeout: TimeInterval = 6,
        label: String = ""
    ) async throws -> RemoteResponse {
        let request = RemoteRequest.signed(
            version: protocolVersion,
            command: command,
            argument: argument,
            secret: secret
        )
        let requestData = try RemoteWireCodec.encodeLine(request)
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteClientError.invalidPort
        }
        let operation = RemoteRequestOperation(
            request: request,
            requestData: requestData,
            secret: secret,
            host: host,
            port: networkPort,
            timeout: timeout,
            label: label.isEmpty ? "\(command.rawValue) v\(protocolVersion)" : label
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private let remoteMacLog = Logger(subsystem: "com.narcotic.modafinil", category: "remote-macs")

private final class RemoteRequestOperation: @unchecked Sendable {
    private let request: RemoteRequest
    private let requestData: Data
    private let secret: Data
    private let connection: NWConnection
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.narcotic.modafinil.remote-mac-request")

    private var buffer = Data()
    private var completion: (@Sendable (Result<RemoteResponse, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRequested = false
    private let label: String
    private let host: String
    private let startedAt = ContinuousClock.now
    private var lastWaitingError: NWError?

    init(
        request: RemoteRequest,
        requestData: Data,
        secret: Data,
        host: String,
        port: NWEndpoint.Port,
        timeout: TimeInterval,
        label: String
    ) {
        self.label = label
        self.host = host
        self.request = request
        self.requestData = requestData
        self.secret = secret
        self.timeout = timeout
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: .tcp
        )
    }

    func start(
        completion: @escaping @Sendable (Result<RemoteResponse, Error>) -> Void
    ) {
        queue.async { [self, completion] in
            self.completion = completion
            guard !self.cancellationRequested else {
                self.finish(.failure(CancellationError()))
                return
            }

            self.trace("start \(self.host) timeout \(Int(self.timeout)) s")
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.trace("timed out" + (self.lastWaitingError.map { " (last: \($0.debugDescription))" } ?? ""))
                self.finish(.failure(RemoteClientError.timedOut(waiting: self.lastWaitingError)))
            }
            self.timeoutWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: workItem)

            self.connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            self.connection.start(queue: self.queue)
        }
    }

    func cancel() {
        queue.async { [self] in
            cancellationRequested = true
            if completion != nil {
                finish(.failure(CancellationError()))
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .waiting(let error):
            lastWaitingError = error
            trace("waiting: \(error.debugDescription)")
        case .preparing:
            trace("preparing")
        default:
            break
        }
        switch state {
        case .ready:
            trace("ready via \(connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?")")
            connection.send(
                content: requestData,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.trace("send failed: \(error.debugDescription)")
                        self.finish(.failure(RemoteClientError.transport(error)))
                    } else {
                        self.receive()
                    }
                }
            )
        case .failed(let error):
            trace("failed: \(error.debugDescription)")
            finish(.failure(RemoteClientError.transport(error)))
        case .cancelled:
            if completion != nil {
                finish(.failure(RemoteClientError.connectionClosed))
            }
        default:
            break
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: RemoteWireCodec.maximumMessageSize
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
            }
            if self.buffer.count > RemoteWireCodec.maximumMessageSize {
                self.finish(.failure(RemoteClientError.invalidResponse))
                return
            }
            if let newline = self.buffer.firstIndex(of: 0x0a) {
                let line = self.buffer.prefix(through: newline)
                self.decodeResponse(Data(line))
                return
            }
            if let error {
                self.trace("receive failed: \(error.debugDescription)")
                self.finish(.failure(RemoteClientError.transport(error)))
            } else if isComplete {
                self.trace("closed by peer before a response")
                self.finish(.failure(RemoteClientError.connectionClosed))
            } else {
                self.receive()
            }
        }
    }

    private func decodeResponse(_ data: Data) {
        do {
            let response = try RemoteWireCodec.decodeLine(
                RemoteResponse.self,
                from: data
            )
            guard response.requestID == request.requestID else {
                throw RemoteClientError.mismatchedResponse
            }
            guard response.isAuthentic(secret: secret) else {
                throw RemoteClientError.unauthenticatedResponse
            }
            guard response.version == request.version else {
                throw RemoteClientError.serverUpdateRequired
            }
            let now = Int64(Date().timeIntervalSince1970)
            guard abs(now - response.timestamp) <= 120 else {
                throw RemoteClientError.staleResponse
            }
            guard response.ok else {
                if response.message == "The request protocol version is unsupported." {
                    throw RemoteClientError.serverUpdateRequired
                }
                throw RemoteClientError.remoteRejected(response.message)
            }
            finish(.success(response))
        } catch {
            finish(.failure(error))
        }
    }

    private func trace(_ message: String) {
        let elapsed = startedAt.duration(to: .now)
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        remoteMacLog.debug("[\(self.label, privacy: .public)] +\(ms) ms \(message, privacy: .public)")
    }

    private func finish(_ result: Result<RemoteResponse, Error>) {
        guard let completion else { return }
        switch result {
        case .success(let response): trace("ok: \(response.message)")
        case .failure(let error) where error is CancellationError: trace("cancelled")
        case .failure(let error): trace("error: \(error.localizedDescription)")
        }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}

private enum RemoteClientError: LocalizedError {
    case serverUpdateRequired
    case timedOut(waiting: NWError?)
    case connectionClosed
    case transport(NWError)
    case invalidPort
    case invalidResponse
    case mismatchedResponse
    case unauthenticatedResponse
    case staleResponse
    case remoteRejected(String)

    var errorDescription: String? {
        switch self {
        case .serverUpdateRequired:
            return "Update Modafinil on that Mac to use this feature."
        case .timedOut(let waiting):
            guard let waiting else { return "The device did not respond in time." }
            return "The device did not respond in time (" + Self.describe(waiting) + ")."
        case .connectionClosed:
            return "The connection closed before a response arrived."
        case .transport(let error):
            let text = Self.describe(error)
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        case .invalidPort:
            return "The pairing configuration contains an invalid network port."
        case .invalidResponse:
            return "The device sent an invalid response."
        case .mismatchedResponse:
            return "The response did not match this request."
        case .unauthenticatedResponse:
            return "The response could not be authenticated."
        case .staleResponse:
            return "The response timestamp was too old."
        case .remoteRejected(let message):
            return message
        }
    }

    /// Plain wording for network errors. `NWError.localizedDescription` is only
    /// "The operation couldn’t be completed. (Network.NWError error 54 …)".
    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            let text: String
            switch code {
            case .ECONNREFUSED: text = "the connection was refused"
            case .ECONNRESET: text = "the connection was reset"
            case .ECONNABORTED: text = "the connection was interrupted, for example because the app went to the background or the network changed"
            case .ENETDOWN: text = "the network is down"
            case .ENETUNREACH: text = "no network route is available"
            case .EHOSTUNREACH, .EHOSTDOWN: text = "the device cannot be reached"
            case .ETIMEDOUT: text = "the connection timed out"
            case .ENOTCONN, .EPIPE: text = "the connection closed"
            case .EADDRNOTAVAIL: text = "no network address is available"
            default: text = String(cString: strerror(code.rawValue)).lowercased()
            }
            return "\(text) [POSIX \(code.rawValue)]"
        case .dns(let code):
            return "the address could not be resolved [DNS \(code)]"
        case .tls(let status):
            return "the secure connection failed [TLS \(status)]"
        default:
            return "network error [\(error.debugDescription)]"
        }
    }

    /// Relay rejections that a later request can get past: its Wi-Fi was briefly
    /// down or its replay store was busy. Authentication and clock errors are final.
    var isRetryableRelayRejection: Bool {
        guard case .remoteRejected(let message) = self else { return false }
        return message.contains("Wi-Fi broadcast interface")
            || message.contains("Replay protection is unavailable")
            || message.contains("Replay cache capacity")
            || message.contains("Duplicate request")
            || message.contains("Timed out while reading")
            || message.contains("Connection closed before a complete request")
    }

    var indicatesUnavailableDevice: Bool {
        switch self {
        case .timedOut, .connectionClosed, .transport:
            return true
        case .invalidPort,
             .serverUpdateRequired,
             .invalidResponse,
             .mismatchedResponse,
             .unauthenticatedResponse,
             .staleResponse,
             .remoteRejected:
            return false
        }
    }
}
