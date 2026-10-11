import SwiftUI

struct CertificateSection: View {
    let configuration: AppConfiguration

    @Environment(\.openURL) private var openURL
    @StateObject private var profileInstaller =
        LocalProfileInstallationService()
    @State private var status: CertificateValidationStatus = .notChecked
    @State private var showDownloadConfirmation = false
    @State private var localSnapshot:
        LocalTestCertificateAuthoritySnapshot?
    @State private var localError: String?
    @State private var preparingLocalCA = false

    var body: some View {
        Section("授权证书（仅限测试设备使用）") {
            if configuration.tunnelMode == .localForwarding {
                Button(
                    localSnapshot == nil
                        ? "生成授权 CA"
                        : "更新授权 CA"
                ) {
                    showDownloadConfirmation = true
                }
                .disabled(preparingLocalCA)

                if let localSnapshot {
                    Button {
                        Task {
                            await openProfileInSafari(
                                localSnapshot.configurationProfileURL
                            )
                        }
                    } label: {
                        Label(
                            "在 Safari 下载描述文件",
                            systemImage: "safari"
                        )
                    }
                    .disabled(profileInstaller.isServing)

                    Text(
                        "SHA-256：\(localSnapshot.fingerprintDisplay)"
                    )
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    Text(
                        "叶证书有效期至 \(localSnapshot.manifest.leafNotAfter.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button("下载测试证书") {
                    showDownloadConfirmation = true
                }
                .disabled(configuration.certificateDownloadURL == nil)
            }

            if preparingLocalCA {
                ProgressView("正在生成本机授权证书")
            }
            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("查看安装步骤") {
                Text("""
                1. 生成并点击“在 Safari 下载描述文件”
                2. Safari 提示下载后，立即打开系统“设置”→“已下载描述文件”
                3. 完成描述文件安装
                4. 前往“通用”→“关于本机”→“证书信任设置”→“WLOC Authorized Test Root”
                5. 开启“WLOC Authorized Test Root”的完全信任
                6. 返回本 App 点击下方的网络连接，并安装网络配置文件
                """)
                .font(.footnote)
            }
        }
        .task {
            guard configuration.tunnelMode == .localForwarding else {
                return
            }
            localSnapshot = try? localCAService.loadSnapshot()
        }
        .alert("安装授权证书前请确认", isPresented: $showDownloadConfirmation) {
            Button("取消", role: .cancel) {}
            if configuration.tunnelMode == .localForwarding {
                Button("生成专用测试 CA") {
                    Task {
                        await prepareLocalCA()
                    }
                }
            } else {
                Button("使用系统浏览器下载") {
                    if let url = configuration.certificateDownloadURL {
                        openURL(url)
                    }
                }
            }
        } message: {
            Text("该证书仅用于在测试设备上修改白名单内的授权 TLS 会话；WLOC 只修改两个 gs-loc*.apple.com 主机的 /clls/wloc Protobuf 响应，WLOC 不会自动安装或自动信任证书。")
        }
    }

    private var localCAService: LocalTestCertificateAuthorityService {
        LocalTestCertificateAuthorityService(
            appGroupIdentifier: configuration.appGroupIdentifier,
            allowedHosts: configuration.allowedHosts
        )
    }

    private var certificateService: CertificateService {
        let url = configuration.tunnelMode == .localForwarding
            ? localCAService.certificateValidationURL
            : configuration.certificateValidationURL
        return CertificateService(validationURL: url)
    }

    @MainActor
    private func prepareLocalCA() async {
        preparingLocalCA = true
        localError = nil
        defer { preparingLocalCA = false }
        let service = localCAService
        do {
            localSnapshot = try service.prepare()
            status = .notChecked
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func openProfileInSafari(_ url: URL) async {
        localError = nil
        do {
            try await profileInstaller.openInSafari(profileURL: url)
        } catch {
            localError = error.localizedDescription
        }
    }

    private var statusColor: Color {
        switch status {
        case .valid:
            .green
        case .untrusted, .networkFailure, .serviceUnavailable:
            .orange
        default:
            .secondary
        }
    }
}
