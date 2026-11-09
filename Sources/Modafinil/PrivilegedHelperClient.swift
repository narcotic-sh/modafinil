import Foundation
import ModafinilShared

final class PrivilegedHelperClient {
    private var connection: NSXPCConnection?
    private let requestTimeout: TimeInterval = 5

    func setSleepPreventionEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.setSleepPreventionEnabled(enabled) { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not change the sleep setting.")))
                    }
                }
            }
        }
    }

    func setScheduledWake(
        _ timestamp: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.setScheduledWake(timestamp) { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not update the wake schedule (update or re-enable the Mac helper if needed).")))
                    }
                }
            }
        }
    }

    func getSleepPreventionStatus(
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Bool, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.getSleepPreventionStatus { success, enabled, message in
                    if success {
                        finish(.success(enabled))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not read the sleep setting.")))
                    }
                }
            }
        }
    }

    func sleepAfterDisablingSleepPrevention(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.requestTrackedSleep { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not put the Mac to sleep.")))
                    }
                }
            }
        }
    }

    func setSleepTimer(after seconds: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not confirm the sleep timer. Update Modafinil and its helper on this Mac.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let proxy):
                proxy.setSleepTimer(after: seconds) { success, message in
                    finish(success ? .success(()) : .failure(HelperError(message ?? "Could not update the sleep timer.")))
                }
            }
        }
    }

    func shutDownNow(completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not confirm the shutdown. Update Modafinil and its helper on this Mac.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let proxy):
                proxy.shutDownNow { success, message in
                    finish(success ? .success(()) : .failure(HelperError(message ?? "The helper could not shut the Mac down.")))
                }
            }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func remoteProxy(
        completion: @escaping (Result<ModafinilHelperProtocol, Error>) -> Void
    ) {
        let connection = self.connection ?? makeConnection()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                self.invalidate()
                completion(.failure(error))
            }
        }

        guard let typedProxy = proxy as? ModafinilHelperProtocol else {
            completion(.failure(HelperError("Could not create the helper XPC proxy.")))
            return
        }

        completion(.success(typedProxy))
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: ModafinilConstants.helperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ModafinilHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
            }
        }
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
            }
        }
        connection.resume()
        return connection
    }

    struct HelperError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
