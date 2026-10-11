import Foundation
import Darwin
import leaf

struct LeafTunnelSnapshot: Equatable, Sendable {
    let running: Bool
    let lastDirectActivitySeconds: UInt32?
    let lastExitCode: Int32?
}

/// Lifecycle adapter for the pinned Apache-2.0 leaf networking core.
///
/// `leaf_run` blocks its calling thread. A file-backed configuration lets the
/// host use Leaf's official `leaf_reload` control path as a bounded readiness
/// probe. This verifies that the runtime is registered without sending an
/// external health-check request.
final class LeafTunnelService {
    private enum State {
        case stopped
        case starting
        case running
        case stopping
    }

    private static let runtimeID: UInt16 = 1
    private static let successCode: Int32 = 0
    private static let runtimeManagerUnavailableCode: Int32 = 7
    private static let readinessAttempts = 60

    private let workerQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.leaf-core",
        qos: .userInitiated
    )
    private let controlQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.leaf-core-control"
    )
    private let stateQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.leaf-core-state"
    )

    private var state: State = .stopped
    private var generation = UUID()
    private var startupCompletion: ((Result<Void, Error>) -> Void)?
    private var stopCompletions: [() -> Void] = []
    private var lastExitCode: Int32?
    private var stopWasRequested = false
    private var configurationURL: URL?
    private var transferredTunnelFileDescriptor: Int32?

    var unexpectedExitHandler: ((Error) -> Void)?

    func start(
        tunnelFileDescriptor: Int32,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard tunnelFileDescriptor >= 0 else {
            throw LeafTunnelConfigurationError.invalidTunnelDescriptor
        }
        let duplicatedTunnelFileDescriptor = fcntl(
            tunnelFileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard duplicatedTunnelFileDescriptor >= 0 else {
            throw LeafTunnelError.cannotDuplicateTunnelDescriptor(
                systemCode: errno
            )
        }
        var descriptorTransferred = false
        defer {
            if !descriptorTransferred {
                Darwin.close(duplicatedTunnelFileDescriptor)
            }
        }

        let configuration = try LeafTunnelConfiguration.make(
            tunnelFileDescriptor: duplicatedTunnelFileDescriptor
        )
        guard setenv("ENABLE_IPV6", "true", 1) == 0,
              setenv("PREFER_IPV6", "false", 1) == 0
        else {
            throw LeafTunnelError.environmentSetupFailed
        }

        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wloc-leaf-\(UUID().uuidString).json",
                isDirectory: false
            )
        guard let configurationData = configuration.data(using: .utf8) else {
            throw LeafTunnelConfigurationError.encodingFailed
        }
        try configurationData.write(
            to: configurationURL,
            options: [.atomic]
        )
        var configurationTransferred = false
        defer {
            if !configurationTransferred {
                try? FileManager.default.removeItem(at: configurationURL)
            }
        }

        let validationCode = configurationURL.path.withCString {
            leaf_test_config($0)
        }
        guard validationCode == Self.successCode else {
            throw LeafTunnelError.configurationRejected(
                code: validationCode
            )
        }

        let currentGeneration = try stateQueue.sync { () throws -> UUID in
            guard state == .stopped else {
                throw LeafTunnelError.alreadyRunning
            }
            state = .starting
            generation = UUID()
            startupCompletion = completion
            lastExitCode = nil
            stopWasRequested = false
            self.configurationURL = configurationURL
            transferredTunnelFileDescriptor =
                duplicatedTunnelFileDescriptor
            return generation
        }
        // Leaf's tun 0.7 wrapper closes the raw descriptor when its device is
        // destroyed. Transfer only our duplicate; NetworkExtension retains
        // ownership of the original packet-flow descriptor.
        descriptorTransferred = true
        configurationTransferred = true

        workerQueue.async { [weak self] in
            let result = configurationURL.path.withCString {
                leaf_run(Self.runtimeID, $0)
            }
            self?.stateQueue.async {
                self?.handleEngineExit(
                    code: result,
                    generation: currentGeneration
                )
            }
        }
        scheduleReadinessProbe(
            generation: currentGeneration,
            remainingAttempts: Self.readinessAttempts
        )
    }

    func stop(completion: @escaping () -> Void) {
        stateQueue.async {
            switch self.state {
            case .stopped:
                completion()
            case .starting, .running:
                self.state = .stopping
                self.stopWasRequested = true
                self.stopCompletions.append(completion)
                self.requestShutdown(
                    generation: self.generation,
                    remainingAttempts: 40
                )
            case .stopping:
                self.stopCompletions.append(completion)
            }
        }
    }

    func snapshot() -> LeafTunnelSnapshot {
        let current = stateQueue.sync {
            (state == .running, lastExitCode)
        }
        guard current.0 else {
            return LeafTunnelSnapshot(
                running: false,
                lastDirectActivitySeconds: nil,
                lastExitCode: current.1
            )
        }

        var seconds: UInt32 = 0
        let code = LeafTunnelConfiguration.directOutboundTag.withCString {
            leaf_get_since_last_active(
                Self.runtimeID,
                $0,
                &seconds
            )
        }
        return LeafTunnelSnapshot(
            running: true,
            lastDirectActivitySeconds:
                code == Self.successCode ? seconds : nil,
            lastExitCode: current.1
        )
    }

    private func scheduleReadinessProbe(
        generation: UUID,
        remainingAttempts: Int
    ) {
        controlQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                return
            }
            let code = leaf_reload(Self.runtimeID)
            self.stateQueue.async {
                guard self.generation == generation,
                      self.state == .starting
                else {
                    return
                }

                if code == Self.successCode {
                    self.state = .running
                    let completion = self.startupCompletion
                    self.startupCompletion = nil
                    completion?(.success(()))
                    return
                }

                if code != Self.runtimeManagerUnavailableCode {
                    self.state = .stopping
                    self.stopWasRequested = true
                    let completion = self.startupCompletion
                    self.startupCompletion = nil
                    completion?(
                        .failure(
                            LeafTunnelError.readinessProbeFailed(code: code)
                        )
                    )
                    self.requestShutdown(
                        generation: generation,
                        remainingAttempts: 40
                    )
                    return
                }

                guard remainingAttempts > 1 else {
                    self.state = .stopping
                    self.stopWasRequested = true
                    let completion = self.startupCompletion
                    self.startupCompletion = nil
                    completion?(.failure(LeafTunnelError.startTimedOut))
                    self.requestShutdown(
                        generation: generation,
                        remainingAttempts: 40
                    )
                    return
                }

                // ERR_RUNTIME_MANAGER is expected until Leaf finishes
                // constructing and registering its runtime.
                self.scheduleReadinessProbe(
                    generation: generation,
                    remainingAttempts: remainingAttempts - 1
                )
            }
        }
    }

    private func requestShutdown(
        generation: UUID,
        remainingAttempts: Int
    ) {
        controlQueue.async { [weak self] in
            guard let self else {
                return
            }
            let accepted = leaf_shutdown(Self.runtimeID)
            guard !accepted else {
                self.scheduleStopWatchdog(generation: generation)
                return
            }
            guard remainingAttempts > 1 else {
                self.scheduleStopWatchdog(generation: generation)
                return
            }
            self.controlQueue.asyncAfter(deadline: .now() + 0.05) {
                self.stateQueue.async {
                    guard self.generation == generation,
                          self.state == .stopping
                    else {
                        return
                    }
                    self.requestShutdown(
                        generation: generation,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            }
        }
    }

    private func scheduleStopWatchdog(generation: UUID) {
        controlQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.stateQueue.async {
                guard let self,
                      self.generation == generation,
                      self.state == .stopping
                else {
                    return
                }
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                // Keep the service in `.stopping`: the blocking Leaf thread did
                // not join, so this process must not reuse the runtime ID or FD.
                // iOS may now finish terminating the extension.
                completions.forEach { $0() }
            }
        }
    }

    private func handleEngineExit(
        code: Int32,
        generation: UUID
    ) {
        guard self.generation == generation else {
            return
        }
        let previousState = state
        let expected = stopWasRequested || previousState == .stopping
        state = .stopped
        lastExitCode = code
        let configurationURL = self.configurationURL
        self.configurationURL = nil
        // Leaf owns and closes the duplicated descriptor. Never close it again
        // here because its integer value may already have been reused.
        transferredTunnelFileDescriptor = nil
        if let configurationURL {
            try? FileManager.default.removeItem(at: configurationURL)
        }

        if let completion = startupCompletion {
            startupCompletion = nil
            if expected {
                completion(.failure(LeafTunnelError.startCancelled))
            } else {
                completion(.failure(LeafTunnelError.engineExited(code: code)))
            }
        } else if !expected {
            unexpectedExitHandler?(
                LeafTunnelError.engineExited(code: code)
            )
        }

        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}

enum LeafTunnelError: LocalizedError, Equatable {
    case alreadyRunning
    case cannotDuplicateTunnelDescriptor(systemCode: Int32)
    case environmentSetupFailed
    case configurationRejected(code: Int32)
    case startCancelled
    case startTimedOut
    case readinessProbeFailed(code: Int32)
    case engineExited(code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "leaf 用户态网络核心已经启动"
        case let .cannotDuplicateTunnelDescriptor(systemCode):
            "无法复制 Packet Tunnel 文件描述符（系统错误 \(systemCode)）"
        case .environmentSetupFailed:
            "无法为 leaf 用户态网络核心启用 IPv6"
        case let .configurationRejected(code):
            "leaf 拒绝了本地直连配置（错误码 \(code)）"
        case .startCancelled:
            "leaf 用户态网络核心启动已取消"
        case .startTimedOut:
            "leaf 用户态网络核心在 3 秒内未就绪"
        case let .readinessProbeFailed(code):
            "leaf 就绪检测失败（错误码 \(code)）"
        case let .engineExited(code):
            "leaf 用户态网络核心退出（错误码 \(code)）"
        }
    }
}
