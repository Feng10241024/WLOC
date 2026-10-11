#if LEGACY_LOCAL_SOCKS
import Foundation
import Network

protocol LocalSocks5TCPUpstream: AnyObject {
    func start(
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    )
    func send(
        _ data: Data?,
        isComplete: Bool,
        completion: @escaping (Error?) -> Void
    )
    func receive(
        minimumLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    )
    func cancel()
}

protocol LocalSocks5UDPUpstream: AnyObject {
    func start(
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    )
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping ([Data]?, Error?) -> Void)
    func cancel()
}

protocol LocalSocks5UpstreamFactory: AnyObject {
    func makeTCPUpstream(
        to destination: Socks5Destination,
        callbackQueue: DispatchQueue
    ) -> LocalSocks5TCPUpstream?

    func makeUDPUpstream(
        to destination: Socks5Destination,
        callbackQueue: DispatchQueue
    ) -> LocalSocks5UDPUpstream?
}

enum LocalSocks5ForwardingEvent {
    case tcpAttempt
    case tcpReady
    case tcpResponse
    case tcpFailure(Error)
    case udpAttempt
    case udpReady
    case udpResponse
    case udpFailure(Error)
}

struct LocalSocks5Metrics: Equatable, Sendable {
    var acceptedTCPConnections: UInt64 = 0
    var acceptedUDPFlows: UInt64 = 0
    var tcpOutboundAttempts: UInt64 = 0
    var tcpOutboundReady: UInt64 = 0
    var tcpResponses: UInt64 = 0
    var tcpFailures: UInt64 = 0
    var udpOutboundAttempts: UInt64 = 0
    var udpOutboundReady: UInt64 = 0
    var udpResponses: UInt64 = 0
    var udpFailures: UInt64 = 0
    var lastErrorType: String?
    var lastErrorCode: Int?
}

final class LocalSocks5Server {
    static let port: UInt16 = 19_090
    private static let loopbackAddress = IPv6Address("::1")!

    private enum ListenerKind {
        case tcp
        case udp
    }

    private let queue = DispatchQueue(label: "com.xiaobovlog.WLOC.local-socks5")
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var tcpReady = false
    private var udpReady = false
    private var startCompletion: ((Result<Void, Error>) -> Void)?
    private var tcpSessions: [UUID: LocalSocks5TCPConnection] = [:]
    private var udpSessions: [UUID: LocalSocks5UDPClient] = [:]
    private var upstreamFactory: LocalSocks5UpstreamFactory?
    private var metrics = LocalSocks5Metrics()
    private var reportedOutboundReady = false
    private var reportedResponse = false
    private var probeConnection: NWConnection?
    private var probeCompletion: ((Result<Void, Error>) -> Void)?
    private var probeTimeout: DispatchWorkItem?
    var eventHandler: ((LocalSocks5ForwardingEvent) -> Void)?

    func start(
        upstreamFactory: LocalSocks5UpstreamFactory,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.upstreamFactory = upstreamFactory
            guard self.tcpListener == nil, self.udpListener == nil else {
                completion(.success(()))
                return
            }
            self.metrics = LocalSocks5Metrics()
            self.reportedOutboundReady = false
            self.reportedResponse = false

            do {
                let tcpListener = try NWListener(
                    using: Self.parameters(transport: .tcp)
                )
                let udpListener = try NWListener(
                    using: Self.parameters(transport: .udp)
                )
                self.tcpListener = tcpListener
                self.udpListener = udpListener
                self.startCompletion = completion

                tcpListener.stateUpdateHandler = { [weak self] state in
                    self?.handle(state: state, kind: .tcp)
                }
                udpListener.stateUpdateHandler = { [weak self] state in
                    self?.handle(state: state, kind: .udp)
                }
                tcpListener.newConnectionHandler = { [weak self] connection in
                    self?.acceptTCP(connection)
                }
                udpListener.newConnectionHandler = { [weak self] connection in
                    self?.acceptUDP(connection)
                }

                tcpListener.start(queue: self.queue)
                udpListener.start(queue: self.queue)
            } catch {
                self.stopOnQueue()
                completion(.failure(error))
            }
        }
    }

    func stop() {
        queue.async {
            self.stopOnQueue()
        }
    }

    func snapshot() -> LocalSocks5Metrics {
        queue.sync {
            metrics
        }
    }

    func verifyLoopback(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            guard self.tcpReady, self.tcpListener != nil else {
                completion(.failure(LocalSocks5ServerError.listenerNotReady))
                return
            }
            guard self.probeConnection == nil else {
                completion(.failure(LocalSocks5ServerError.probeAlreadyRunning))
                return
            }

            let connection = NWConnection(
                host: .ipv6(Self.loopbackAddress),
                port: NWEndpoint.Port(rawValue: Self.port)!,
                using: .tcp
            )
            self.probeConnection = connection
            self.probeCompletion = completion
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }
                switch state {
                case .ready:
                    self.sendProbeGreeting()
                case let .failed(error):
                    self.finishProbe(.failure(error))
                case .cancelled:
                    if self.probeCompletion != nil {
                        self.finishProbe(
                            .failure(LocalSocks5ServerError.probeCancelled)
                        )
                    }
                case .setup, .waiting, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishProbe(
                    .failure(LocalSocks5ServerError.probeTimedOut)
                )
            }
            self.probeTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            connection.start(queue: self.queue)
        }
    }

    private func handle(state: NWListener.State, kind: ListenerKind) {
        switch state {
        case .ready:
            switch kind {
            case .tcp:
                tcpReady = true
            case .udp:
                udpReady = true
            }
            if tcpReady, udpReady {
                startCompletion?(.success(()))
                startCompletion = nil
            }
        case let .failed(error):
            startCompletion?(.failure(error))
            startCompletion = nil
            stopOnQueue()
        case .cancelled:
            if startCompletion != nil {
                startCompletion?(.failure(LocalSocks5ServerError.cancelledDuringStart))
                startCompletion = nil
            }
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func acceptTCP(_ connection: NWConnection) {
        guard let upstreamFactory else {
            connection.cancel()
            return
        }
        let id = UUID()
        metrics.acceptedTCPConnections += 1
        let session = LocalSocks5TCPConnection(
            connection: connection,
            relayPort: Self.port,
            queue: queue,
            upstreamFactory: upstreamFactory,
            onEvent: { [weak self] event in
                self?.handle(event)
            }
        ) { [weak self] in
            self?.queue.async {
                self?.tcpSessions[id] = nil
            }
        }
        tcpSessions[id] = session
        session.start()
    }

    private func acceptUDP(_ connection: NWConnection) {
        guard let upstreamFactory else {
            connection.cancel()
            return
        }
        let id = UUID()
        metrics.acceptedUDPFlows += 1
        let session = LocalSocks5UDPClient(
            connection: connection,
            relayPort: Self.port,
            queue: queue,
            upstreamFactory: upstreamFactory,
            onEvent: { [weak self] event in
                self?.handle(event)
            }
        ) { [weak self] in
            self?.queue.async {
                self?.udpSessions[id] = nil
            }
        }
        udpSessions[id] = session
        session.start()
    }

    private func stopOnQueue() {
        if probeCompletion != nil {
            finishProbe(.failure(LocalSocks5ServerError.probeCancelled))
        }
        tcpListener?.cancel()
        udpListener?.cancel()
        tcpListener = nil
        udpListener = nil
        tcpReady = false
        udpReady = false
        tcpSessions.values.forEach { $0.stop() }
        udpSessions.values.forEach { $0.stop() }
        tcpSessions.removeAll()
        udpSessions.removeAll()
        upstreamFactory = nil
    }

    private func sendProbeGreeting() {
        guard let probeConnection else {
            return
        }
        probeConnection.send(
            content: Data([0x05, 0x01, 0x00]),
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if let error {
                    self.finishProbe(.failure(error))
                    return
                }
                self.receiveProbeGreeting()
            }
        )
    }

    private func receiveProbeGreeting() {
        probeConnection?.receive(
            minimumIncompleteLength: 2,
            maximumLength: 2
        ) { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let error {
                self.finishProbe(.failure(error))
                return
            }
            guard data == Data([0x05, 0x00]) else {
                self.finishProbe(
                    .failure(LocalSocks5ServerError.invalidProbeResponse)
                )
                return
            }
            self.metrics = LocalSocks5Metrics()
            self.reportedOutboundReady = false
            self.reportedResponse = false
            self.finishProbe(.success(()))
        }
    }

    private func finishProbe(_ result: Result<Void, Error>) {
        guard let completion = probeCompletion else {
            return
        }
        probeCompletion = nil
        probeTimeout?.cancel()
        probeTimeout = nil
        probeConnection?.stateUpdateHandler = nil
        probeConnection?.cancel()
        probeConnection = nil
        completion(result)
    }

    private func handle(_ event: LocalSocks5ForwardingEvent) {
        switch event {
        case .tcpAttempt:
            metrics.tcpOutboundAttempts += 1
        case .tcpReady:
            metrics.tcpOutboundReady += 1
            guard !reportedOutboundReady else {
                return
            }
            reportedOutboundReady = true
        case .tcpResponse:
            metrics.tcpResponses += 1
            guard !reportedResponse else {
                return
            }
            reportedResponse = true
        case let .tcpFailure(error):
            metrics.tcpFailures += 1
            capture(error)
        case .udpAttempt:
            metrics.udpOutboundAttempts += 1
        case .udpReady:
            metrics.udpOutboundReady += 1
            guard !reportedOutboundReady else {
                return
            }
            reportedOutboundReady = true
        case .udpResponse:
            metrics.udpResponses += 1
            guard !reportedResponse else {
                return
            }
            reportedResponse = true
        case let .udpFailure(error):
            metrics.udpFailures += 1
            capture(error)
        }
        eventHandler?(event)
    }

    private func capture(_ error: Error) {
        let nsError = error as NSError
        metrics.lastErrorType = nsError.domain
        metrics.lastErrorCode = nsError.code
    }

    private enum Transport {
        case tcp
        case udp
    }

    private static func parameters(transport: Transport) -> NWParameters {
        let parameters: NWParameters = switch transport {
        case .tcp:
            .tcp
        case .udp:
            .udp
        }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv6(loopbackAddress),
            port: NWEndpoint.Port(rawValue: port)!
        )
        return parameters
    }
}

enum LocalSocks5ServerError: LocalizedError {
    case cancelledDuringStart
    case listenerNotReady
    case probeAlreadyRunning
    case probeCancelled
    case probeTimedOut
    case invalidProbeResponse
    case outboundResponseTimedOut

    var errorDescription: String? {
        switch self {
        case .cancelledDuringStart:
            "本机 SOCKS5 服务在启动完成前被取消"
        case .listenerNotReady:
            "本机 SOCKS5 服务尚未就绪"
        case .probeAlreadyRunning:
            "本机 SOCKS5 握手自检已在运行"
        case .probeCancelled:
            "本机 SOCKS5 握手自检被取消"
        case .probeTimedOut:
            "本机 SOCKS5 握手自检超时"
        case .invalidProbeResponse:
            "本机 SOCKS5 握手自检返回无效响应"
        case .outboundResponseTimedOut:
            "物理网络直连已建立，但等待回包超时"
        }
    }
}

private final class LocalSocks5TCPConnection {
    private enum Phase {
        case greeting
        case request
        case connecting
        case udpControl
        case bridging
        case stopped
    }

    private let client: NWConnection
    private let relayPort: UInt16
    private let queue: DispatchQueue
    private let upstreamFactory: LocalSocks5UpstreamFactory
    private let onEvent: (LocalSocks5ForwardingEvent) -> Void
    private let onStop: () -> Void
    private var upstream: LocalSocks5TCPUpstream?
    private var buffer = Data()
    private var phase: Phase = .greeting
    private var completedPumpDirections = 0
    private var reportedResponse = false

    init(
        connection: NWConnection,
        relayPort: UInt16,
        queue: DispatchQueue,
        upstreamFactory: LocalSocks5UpstreamFactory,
        onEvent: @escaping (LocalSocks5ForwardingEvent) -> Void,
        onStop: @escaping () -> Void
    ) {
        client = connection
        self.relayPort = relayPort
        self.queue = queue
        self.upstreamFactory = upstreamFactory
        self.onEvent = onEvent
        self.onStop = onStop
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.stop()
            case .setup, .waiting, .preparing, .ready:
                break
            @unknown default:
                break
            }
        }
        client.start(queue: queue)
        receiveHandshake()
    }

    func stop() {
        guard phase != .stopped else {
            return
        }
        phase = .stopped
        client.cancel()
        upstream?.cancel()
        upstream = nil
        onStop()
    }

    private func receiveHandshake() {
        guard phase == .greeting || phase == .request else {
            return
        }
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_535
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processHandshakeBuffer()
            }
            if error != nil || isComplete {
                self.stop()
                return
            }
            if self.phase == .greeting || self.phase == .request {
                self.receiveHandshake()
            }
        }
    }

    private func processHandshakeBuffer() {
        var shouldContinue = true
        while shouldContinue {
            switch phase {
            case .greeting:
                switch Socks5ProtocolCodec.parseGreeting(buffer) {
                case .incomplete:
                    shouldContinue = false
                case .invalid:
                    sendAndStop(Data([0x05, 0xff]))
                    shouldContinue = false
                case let .success(supportsNoAuthentication, consumed):
                    buffer.removeFirst(consumed)
                    guard supportsNoAuthentication else {
                        sendAndStop(Data([0x05, 0xff]))
                        shouldContinue = false
                        continue
                    }
                    client.send(
                        content: Data([0x05, 0x00]),
                        completion: .contentProcessed { [weak self] error in
                            if error != nil {
                                self?.stop()
                            }
                        }
                    )
                    phase = .request
                }
            case .request:
                switch Socks5ProtocolCodec.parseRequest(buffer) {
                case .incomplete:
                    shouldContinue = false
                case .invalid:
                    sendAndStop(Socks5ProtocolCodec.reply(code: 0x07, port: relayPort))
                    shouldContinue = false
                case let .success(request, consumed):
                    buffer.removeFirst(consumed)
                    handle(request)
                    shouldContinue = false
                }
            case .connecting, .udpControl, .bridging, .stopped:
                shouldContinue = false
            }
        }
    }

    private func handle(_ request: Socks5Request) {
        switch request.command {
        case .connect:
            connect(to: request.destination)
        case .udpAssociate:
            phase = .udpControl
            client.send(
                content: Socks5ProtocolCodec.reply(code: 0x00, port: relayPort),
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.stop()
                    } else {
                        self?.receiveUDPControl()
                    }
                }
            )
        }
    }

    private func connect(to destination: Socks5Destination) {
        guard !destination.isProxyLoop(relayPort: relayPort),
              let upstream = upstreamFactory.makeTCPUpstream(
                to: destination,
                callbackQueue: queue
              )
        else {
            sendAndStop(Socks5ProtocolCodec.reply(code: 0x02, port: relayPort))
            return
        }

        phase = .connecting
        let earlyData = buffer
        buffer.removeAll(keepingCapacity: false)
        self.upstream = upstream
        onEvent(.tcpAttempt)
        upstream.start(
            onReady: { [weak self, weak upstream] in
                guard let self, let upstream else {
                    return
                }
                self.onEvent(.tcpReady)
                self.phase = .bridging
                self.client.send(
                    content: Socks5ProtocolCodec.reply(
                        code: 0x00,
                        port: self.relayPort
                    ),
                    completion: .contentProcessed { [weak self, weak upstream] error in
                        guard let self, let upstream else {
                            return
                        }
                        guard error == nil else {
                            self.stop()
                            return
                        }
                        self.beginBridge(
                            upstream: upstream,
                            earlyData: earlyData
                        )
                    }
                )
            },
            onFailure: { [weak self] error in
                guard let self, self.phase != .stopped else {
                    return
                }
                self.onEvent(.tcpFailure(error))
                if self.phase == .connecting {
                    self.sendAndStop(
                        Socks5ProtocolCodec.reply(
                            code: 0x05,
                            port: self.relayPort
                        )
                    )
                } else {
                    self.stop()
                }
            }
        )
    }

    private func beginBridge(
        upstream: LocalSocks5TCPUpstream,
        earlyData: Data
    ) {
        if !earlyData.isEmpty {
            upstream.send(
                earlyData,
                isComplete: false
            ) { [weak self, weak upstream] error in
                guard let self, upstream != nil else {
                    return
                }
                if let error {
                    self.onEvent(.tcpFailure(error))
                    self.stop()
                    return
                }
                self.pumpClientToUpstream()
            }
        } else {
            pumpClientToUpstream()
        }
        pumpUpstreamToClient()
    }

    private func pumpClientToUpstream() {
        guard let upstream, phase == .bridging else {
            return
        }
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_535
        ) { [weak self, weak upstream] data, _, isComplete, error in
            guard let self, let upstream else {
                return
            }
            if let error {
                self.onEvent(.tcpFailure(error))
                self.stop()
                return
            }
            upstream.send(data, isComplete: isComplete) { [weak self] error in
                guard let self else {
                    return
                }
                if let error {
                    self.onEvent(.tcpFailure(error))
                    self.stop()
                    return
                }
                if isComplete {
                    self.completePumpDirection()
                } else {
                    self.pumpClientToUpstream()
                }
            }
        }
    }

    private func pumpUpstreamToClient() {
        guard let upstream, phase == .bridging else {
            return
        }
        upstream.receive(
            minimumLength: 1,
            maximumLength: 65_535
        ) { [weak self] data, isComplete, error in
            guard let self else {
                return
            }
            if let error {
                self.onEvent(.tcpFailure(error))
                self.stop()
                return
            }
            if let data, !data.isEmpty, !reportedResponse {
                reportedResponse = true
                onEvent(.tcpResponse)
            }
            client.send(
                content: data,
                contentContext: .defaultStream,
                isComplete: isComplete,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        return
                    }
                    guard error == nil else {
                        self.stop()
                        return
                    }
                    if isComplete {
                        self.completePumpDirection()
                    } else {
                        self.pumpUpstreamToClient()
                    }
                }
            )
        }
    }

    private func completePumpDirection() {
        completedPumpDirections += 1
        if completedPumpDirections == 2 {
            stop()
        }
    }

    private func receiveUDPControl() {
        guard phase == .udpControl else {
            return
        }
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1024
        ) { [weak self] _, _, isComplete, error in
            guard let self else {
                return
            }
            if error != nil || isComplete {
                self.stop()
            } else {
                self.receiveUDPControl()
            }
        }
    }

    private func sendAndStop(_ data: Data) {
        client.send(
            content: data,
            completion: .contentProcessed { [weak self] _ in
                self?.stop()
            }
        )
    }
}

private final class LocalSocks5UDPClient {
    private let client: NWConnection
    private let relayPort: UInt16
    private let queue: DispatchQueue
    private let upstreamFactory: LocalSocks5UpstreamFactory
    private let onEvent: (LocalSocks5ForwardingEvent) -> Void
    private let onStop: () -> Void
    private var stopped = false
    private var upstreamConnections: [UUID: LocalSocks5UDPUpstream] = [:]

    init(
        connection: NWConnection,
        relayPort: UInt16,
        queue: DispatchQueue,
        upstreamFactory: LocalSocks5UpstreamFactory,
        onEvent: @escaping (LocalSocks5ForwardingEvent) -> Void,
        onStop: @escaping () -> Void
    ) {
        client = connection
        self.relayPort = relayPort
        self.queue = queue
        self.upstreamFactory = upstreamFactory
        self.onEvent = onEvent
        self.onStop = onStop
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.stop()
            case .setup, .waiting, .preparing, .ready:
                break
            @unknown default:
                break
            }
        }
        client.start(queue: queue)
        receive()
    }

    func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        client.cancel()
        upstreamConnections.values.forEach { $0.cancel() }
        upstreamConnections.removeAll()
        onStop()
    }

    private func receive() {
        guard !stopped else {
            return
        }
        client.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let data {
                self.forward(data)
            }
            if error != nil {
                self.stop()
            } else {
                self.receive()
            }
        }
    }

    private func forward(_ data: Data) {
        guard case let .success(datagram, _) =
                Socks5ProtocolCodec.parseUDPDatagram(data),
              !datagram.destination.isProxyLoop(relayPort: relayPort),
              let upstream = upstreamFactory.makeUDPUpstream(
                to: datagram.destination,
                callbackQueue: queue
              )
        else {
            return
        }

        let id = UUID()
        upstreamConnections[id] = upstream
        onEvent(.udpAttempt)
        upstream.start(
            onReady: { [weak self, weak upstream] in
                guard let self, let upstream else {
                    return
                }
                self.onEvent(.udpReady)
                upstream.receive { [weak self] responses, error in
                    guard let self else {
                        return
                    }
                    if let error {
                        self.onEvent(.udpFailure(error))
                        self.finishUpstream(id)
                        return
                    }
                    guard let response = responses?.first,
                          !response.isEmpty
                    else {
                        self.finishUpstream(id)
                        return
                    }
                    var wrapped = datagram.responseHeader
                    wrapped.append(response)
                    self.client.send(
                        content: wrapped,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            if let error {
                                self?.onEvent(.udpFailure(error))
                            } else {
                                self?.onEvent(.udpResponse)
                            }
                            self?.finishUpstream(id)
                        }
                    )
                }
                upstream.send(datagram.payload) { [weak self] error in
                    guard let self else {
                        return
                    }
                    if let error {
                        self.onEvent(.udpFailure(error))
                        self.finishUpstream(id)
                    }
                }
            },
            onFailure: { [weak self] error in
                guard let self else {
                    return
                }
                self.onEvent(.udpFailure(error))
                self.finishUpstream(id)
            }
        )
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.upstreamConnections[id] != nil
            else {
                return
            }
            self.onEvent(
                .udpFailure(LocalSocks5ServerError.outboundResponseTimedOut)
            )
            self.finishUpstream(id)
        }
    }

    private func finishUpstream(_ id: UUID) {
        upstreamConnections.removeValue(forKey: id)?.cancel()
    }
}

private extension Socks5Destination {
    func isProxyLoop(relayPort: UInt16) -> Bool {
        guard port == relayPort else {
            return false
        }
        switch host {
        case let .ipv4(data):
            return data == Data([127, 0, 0, 1])
        case let .domain(name):
            return name == "localhost"
        case let .ipv6(data):
            return data == Data(repeating: 0, count: 15) + Data([1])
        }
    }
}
#endif
