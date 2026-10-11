#if LEGACY_LOCAL_SOCKS
import Foundation
import HevSocks5Tunnel

struct UserSpaceTunnelSnapshot: Equatable, Sendable {
    let running: Bool
    let transmittedPackets: UInt64
    let transmittedBytes: UInt64
    let receivedPackets: UInt64
    let receivedBytes: UInt64
}

final class UserSpaceTunnelService {
    private enum State {
        case stopped
        case starting
        case running
        case stopping
    }

    private let workerQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.hev-tun2socks",
        qos: .userInitiated
    )
    private let controlQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.hev-tun2socks-control"
    )
    private let stateQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.hev-tun2socks-state"
    )
    private var state: State = .stopped
    var unexpectedExitHandler: ((Error) -> Void)?

    func start(
        socksHost: String,
        socksPort: UInt16,
        tunnelFileDescriptor: Int32
    ) throws {
        guard tunnelFileDescriptor >= 0 else {
            throw UserSpaceTunnelError.tunnelDescriptorUnavailable
        }
        let configuration = try UserSpaceTunnelConfiguration.make(
            socksHost: socksHost,
            socksPort: socksPort
        )
        let canStart = stateQueue.sync { () -> Bool in
            guard state == .stopped else {
                return false
            }
            state = .starting
            return true
        }
        guard canStart else {
            throw UserSpaceTunnelError.alreadyRunning
        }
        workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.stateQueue.sync {
                if self.state == .starting {
                    self.state = .running
                }
            }

            let bytes = Array(configuration.utf8)
            let result = bytes.withUnsafeBufferPointer { buffer in
                hev_socks5_tunnel_main_from_str(
                    buffer.baseAddress,
                    UInt32(buffer.count),
                    tunnelFileDescriptor
                )
            }
            let wasExpectedStop = self.stateQueue.sync { () -> Bool in
                let expected = self.state == .stopping
                self.state = .stopped
                return expected
            }
            if !wasExpectedStop {
                self.unexpectedExitHandler?(
                    UserSpaceTunnelError.engineExited(code: result)
                )
            }
        }
    }

    func stop() {
        let shouldStop = stateQueue.sync { () -> Bool in
            switch state {
            case .starting, .running:
                state = .stopping
                return true
            case .stopped, .stopping:
                return false
            }
        }
        guard shouldStop else {
            return
        }
        controlQueue.async {
            hev_socks5_tunnel_quit()
        }
    }

    func snapshot() -> UserSpaceTunnelSnapshot {
        let isRunning = stateQueue.sync {
            state == .running
        }
        guard isRunning else {
            return UserSpaceTunnelSnapshot(
                running: false,
                transmittedPackets: 0,
                transmittedBytes: 0,
                receivedPackets: 0,
                receivedBytes: 0
            )
        }

        var txPackets = 0
        var txBytes = 0
        var rxPackets = 0
        var rxBytes = 0
        hev_socks5_tunnel_stats(
            &txPackets,
            &txBytes,
            &rxPackets,
            &rxBytes
        )
        return UserSpaceTunnelSnapshot(
            running: true,
            transmittedPackets: UInt64(txPackets),
            transmittedBytes: UInt64(txBytes),
            receivedPackets: UInt64(rxPackets),
            receivedBytes: UInt64(rxBytes)
        )
    }

}

enum UserSpaceTunnelError: LocalizedError {
    case alreadyRunning
    case tunnelDescriptorUnavailable
    case engineExited(code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "本机用户态网络栈已经启动"
        case .tunnelDescriptorUnavailable:
            "未找到 Packet Tunnel 的 utun 文件描述符"
        case let .engineExited(code):
            "本机用户态网络栈异常退出（代码 \(code)）"
        }
    }
}
#endif
