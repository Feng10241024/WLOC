import SwiftUI

struct VPNControlSection: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var vpnManager: VPNManager
    let configuration: AppConfiguration
    let isSettingsPageActive: Bool

    @State private var operationInProgress = false
    @State private var operationMessage: String?
    @State private var providerStatusMessage: String?
    @State private var showRemoveConfirmation = false
    @State private var connectionSuccessMonitor: Task<Void, Never>?

    var body: some View {
        Section("本地网络连接（仅限测试设备使用）") {
            Toggle(
                toggleTitle,
                isOn: Binding(
                    get: { store.rewriteEnabled },
                    set: { enabled in
                        Task { await changeRewriteState(enabled) }
                    }
                )
            )
            .disabled(operationInProgress)

            LabeledContent("网络状态", value: vpnManager.status.rawValue)
            LabeledContent("运行模式", value: configuration.tunnelMode.displayName)

            if configuration.tunnelMode == .localForwarding {
                LabeledContent(
                    "重写状态",
                    value: dataPlaneText
                )
            }

            if configuration.tunnelMode == .diagnosticNoTraffic {
                Label(
                    "当前只验证网络权限、Extension 服务生命周期和消息通信；不会接管、解密或修改任何网络流量。",
                    systemImage: "stethoscope"
                )
                .font(.footnote)
                .foregroundStyle(.blue)
            }


            Button(configurationButtonTitle) {
                Task {
                    await installConfiguration()
                }
            }
            .disabled(operationInProgress || configurationUpdateBlocked)

            Button("移除网络配置", role: .destructive) {
                showRemoveConfirmation = true
            }
            .disabled(!vpnManager.isConfigured || operationInProgress)

            if operationInProgress {
                ProgressView()
            }
            if let error = vpnManager.lastError,
               error != providerStatusMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let diagnostic = vpnManager.lastProviderDiagnostic {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostic.displayMessage)
                    Text(diagnostic.timestamp, style: .time)
                }
                .font(.footnote)
                .foregroundStyle(
                    diagnostic.phase.indicatesFailure ? .red : .orange
                )
            }
            if let message = operationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let configurationMessage = store.configurationMessage {
                Text(configurationMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "确定移除 WLOC 网络配置？测试坐标不会被删除。",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除网络配置", role: .destructive) {
                Task {
                    operationInProgress = true
                    defer { operationInProgress = false }
                    do {
                        try await vpnManager.removeConfiguration()
                        await store.setRewriteEnabled(false)
                        operationMessage = "网络配置已移除"
                    } catch {
                        operationMessage = error.localizedDescription
                    }
                }
            }
        }
        .onReceive(vpnManager.$unexpectedDisconnectSequence) { sequence in
            guard sequence > 0 else {
                return
            }
            operationMessage = "网络启动失败或意外断开，已读取最近诊断"
        }
        .task(id: providerStatusPollingEnabled) {
            await pollProviderStatusWhileVisible()
        }
        .onDisappear {
            if !store.rewriteEnabled {
                connectionSuccessMonitor?.cancel()
            }
        }
    }

    private var toggleTitle: String {
        switch configuration.tunnelMode {
        case .diagnosticNoTraffic:
            "启动网络诊断通道"
        case .localForwarding:
            "网络连接"
        case .authorizedRemoteProxy:
            "开启测试数据重写"
        }
    }

    private var configurationButtonTitle: String {
        !vpnManager.isConfigured
            ? "创建网络配置"
            : "创建或更新网络配置"
    }

    private var configurationUpdateBlocked: Bool {
        switch vpnManager.status {
        case .connecting, .connected, .disconnecting:
            true
        case .notConfigured, .disconnected, .failed:
            false
        }
    }

    private var extensionIdentityText: String {
        if vpnManager.providerIdentityVerified {
            return "已验证（build \(vpnManager.providerBuildNumber ?? "未知")）"
        }
        switch vpnManager.status {
        case .connected, .connecting:
            return "等待当前版本握手"
        case .notConfigured, .disconnected, .disconnecting, .failed:
            return "未验证"
        }
    }

    private var dataPlaneText: String {
        if let providerStatusMessage {
            return providerStatusMessage
        }
        guard let runtime = vpnManager.providerRuntimeStatus else {
            return "未验证"
        }
        guard runtime.engineRunning else {
            return "本机重写代理未运行"
        }
        if let proxy = runtime.rewriteProxy {
            var text = "连接 \(proxy.acceptedConnections)，TLS \(proxy.successfulTLSHandshakes)，重写 \(proxy.rewrittenRequests)，未匹配 \(proxy.passThroughRequests)，失败 \(proxy.failures)"
            if let error = proxy.lastErrorType {
                text += "，\(error)"
            }
            return text
        }
        return "网络连接已启动，等待授权域名请求"
    }

    private var providerStatusPollingEnabled: Bool {
        isSettingsPageActive && vpnManager.status == .connected
    }

    private func pollProviderStatusWhileVisible() async {
        guard providerStatusPollingEnabled else {
            providerStatusMessage = nil
            return
        }

        while !Task.isCancelled {
            if let response = await vpnManager.queryProviderStatus() {
                providerStatusMessage = response.message
                    ?? "Extension 正常运行（配置版本 \(response.loadedConfigurationVersion)）"
            } else {
                providerStatusMessage = vpnManager.lastError
                    ?? "未收到 Extension 响应"
            }

            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard providerStatusPollingEnabled else {
                return
            }
        }
    }

    private func installConfiguration() async {
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            try await vpnManager.installConfigurationIfNeeded()
            operationMessage = "网络配置已创建或更新"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    private func changeRewriteState(_ enabled: Bool) async {
        operationInProgress = true
        defer { operationInProgress = false }

        if enabled {
            guard configuration.tunnelMode == .diagnosticNoTraffic
                    || store.mockLocation != nil
            else {
                operationMessage = "请先设置合法的测试坐标"
                return
            }
            do {
                if configuration.tunnelMode == .localForwarding {
                    let service = LocalTestCertificateAuthorityService(
                        appGroupIdentifier:
                            configuration.appGroupIdentifier,
                        allowedHosts: configuration.allowedHosts
                    )
                    _ = try service.prepare()
                }
                await store.setRewriteEnabled(true)
                // Always refresh the system preference before starting. iOS can
                // retain a NETunnelProviderManager preference across a TrollStore
                // uninstall while the App Group container is recreated.
                try await vpnManager.installConfigurationIfNeeded()
                try await vpnManager.start()
                operationMessage = switch configuration.tunnelMode {
                case .diagnosticNoTraffic:
                    "诊断通道正在启动；此模式不接管流量"
                case .localForwarding:
                    nil
                case .authorizedRemoteProxy:
                    nil
                }
                startConnectionSuccessMonitor()
            } catch {
                await store.setRewriteEnabled(false)
                operationMessage = error.localizedDescription
            }
        } else {
            connectionSuccessMonitor?.cancel()
            connectionSuccessMonitor = nil
            vpnManager.stop()
            await store.setRewriteEnabled(false)
            store.reportStatus("网络连接已关闭")
            operationMessage = nil
        }
    }

    private func startConnectionSuccessMonitor() {
        connectionSuccessMonitor?.cancel()
        guard configuration.tunnelMode == .localForwarding else {
            connectionSuccessMonitor = nil
            return
        }
        connectionSuccessMonitor = Task { @MainActor in
            guard await vpnManager.waitForSuccessfulConnection(),
                  !Task.isCancelled
            else {
                return
            }
            store.reportStatus("网络连接已成功开启")
            _ = await LocationShortcutLauncher.runShortcut()
        }
    }
}
