import Combine
import Foundation
import Network
import UIKit

enum LocalProfileInstallationError: LocalizedError {
    case serverAlreadyRunning
    case listenerUnavailable
    case invalidDownloadURL
    case safariUnavailable

    var errorDescription: String? {
        switch self {
        case .serverAlreadyRunning:
            "证书描述文件下载服务已在运行"
        case .listenerUnavailable:
            "无法启动一次性本机证书下载服务"
        case .invalidDownloadURL:
            "无法生成证书描述文件下载地址"
        case .safariUnavailable:
            "无法打开 Safari 下载证书描述文件"
        }
    }
}

@MainActor
final class LocalProfileInstallationService: ObservableObject {
    @Published private(set) var isServing = false

    private var server: OneShotProfileHTTPServer?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    func openInSafari(profileURL: URL) async throws {
        stop()
        let data = try Data(contentsOf: profileURL)
        guard TestConfigurationProfileFactory.rootCertificateDER(
            from: data
        ) != nil else {
            throw TestCertificateAssetError.invalidCertificateAssets
        }

        let server = OneShotProfileHTTPServer(profileData: data)
        server.onStop = { [weak self] in
            Task { @MainActor in
                self?.finishServing()
            }
        }
        self.server = server
        beginBackgroundTask()

        do {
            let downloadURL = try await server.start()
            isServing = true
            guard await UIApplication.shared.open(downloadURL) else {
                throw LocalProfileInstallationError.safariUnavailable
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        server?.stop()
        server = nil
        finishServing()
    }

    private func beginBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "WLOCConfigurationProfileDownload"
        ) { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func finishServing() {
        isServing = false
        server = nil
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

final class OneShotProfileHTTPServer: @unchecked Sendable {
    var onStop: (() -> Void)?

    private let queue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.profile-download"
    )
    private let profileData: Data
    private let requestPath: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var didServeProfile = false

    init(profileData: Data) {
        self.profileData = profileData
        requestPath = "/\(UUID().uuidString)/\(TestCertificateAssetPaths.configurationProfileName)"
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.listener == nil else {
                    continuation.resume(
                        throwing:
                            LocalProfileInstallationError.serverAlreadyRunning
                    )
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: "127.0.0.1",
                        port: .any
                    )
                    let listener = try NWListener(using: parameters)
                    self.startContinuation = continuation
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handle(state: state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.serve(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.stopOnQueue()
        }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(
                    string: "http://127.0.0.1:\(port.rawValue)\(requestPath)"
                  )
            else {
                failStart(LocalProfileInstallationError.invalidDownloadURL)
                return
            }
            startContinuation?.resume(returning: url)
            startContinuation = nil
            queue.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.stopOnQueue()
            }
        case let .failed(error):
            failStart(error)
        case .cancelled:
            finishStop()
        case .setup, .waiting:
            break
        @unknown default:
            failStart(LocalProfileInstallationError.listenerUnavailable)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024
        ) { [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else {
                return
            }
            let request = data.flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let expectedPrefix = "GET \(requestPath) HTTP/1."
            guard !didServeProfile,
                  request.hasPrefix(expectedPrefix)
            else {
                sendNotFound(on: connection)
                return
            }
            didServeProfile = true
            let head = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-apple-aspen-config",
                "Content-Disposition: attachment; filename=\"\(TestCertificateAssetPaths.configurationProfileName)\"",
                "Cache-Control: no-store",
                "X-Content-Type-Options: nosniff",
                "Content-Length: \(profileData.count)",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            var response = Data(head.utf8)
            response.append(profileData)
            connection.send(
                content: response,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.queue.asyncAfter(deadline: .now() + 3) {
                        connection.cancel()
                        self?.stopOnQueue()
                    }
                }
            )
        }
    }

    private func sendNotFound(on connection: NWConnection) {
        let response = Data(
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .utf8
        )
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 1) {
                    connection.cancel()
                }
            }
        )
    }

    private func failStart(_ error: Error) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        stopOnQueue()
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        if let continuation = startContinuation {
            continuation.resume(
                throwing: LocalProfileInstallationError.listenerUnavailable
            )
            startContinuation = nil
        }
        finishStop()
    }

    private func finishStop() {
        guard listener == nil else {
            return
        }
        let callback = onStop
        onStop = nil
        callback?()
    }
}
