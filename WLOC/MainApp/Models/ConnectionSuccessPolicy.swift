import Foundation

enum ConnectionSuccessPolicy {
    nonisolated static func isSatisfied(
        vpnStatus: VPNConnectionStatus,
        providerIdentityVerified: Bool,
        runtimeStatus: TunnelRuntimeStatus?
    ) -> Bool {
        guard vpnStatus == .connected,
              providerIdentityVerified,
              let runtimeStatus,
              runtimeStatus.mode == .localForwarding,
              runtimeStatus.engineRunning
        else {
            return false
        }
        return true
    }
}
