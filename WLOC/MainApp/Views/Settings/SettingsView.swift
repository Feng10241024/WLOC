// Modified from xiaobovlog/WLOC for public release. See NOTICE.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var vpnManager: VPNManager
    let configuration: AppConfiguration
    let isActive: Bool
    @State private var showShortcutLaunchError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            let result = await LocationShortcutLauncher.prepare()
                            switch result {
                            case .failed:
                                showShortcutLaunchError = true
                            case .openedShortcut, .openedInstaller, .openedAppStore:
                                break
                            }
                        }
                    } label: {
                        Label(
                            "点击安装“定位服务”快捷指令",
                            systemImage: "command"
                        )
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                CertificateSection(configuration: configuration)

                VPNControlSection(
                    store: store,
                    vpnManager: vpnManager,
                    configuration: configuration,
                    isSettingsPageActive: isActive
                )
                CoordinateEditorSection(
                    store: store,
                    vpnManager: vpnManager
                )
                Section("严格域名白名单") {
                    ForEach(configuration.allowedHosts.sorted(), id: \.self) { host in
                        Text(host)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("仅匹配 gs-loc.apple.com 与 gs-loc-cn.apple.com 的 /clls/wloc Protobuf 响应")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            }
            .navigationTitle("设置")
            .alert("无法打开快捷指令", isPresented: $showShortcutLaunchError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("无法打开快捷指令或 App Store，请稍后重试。")
            }
        }
    }
}
