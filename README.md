# WLOC — Apple 开发者定位测试工具

本项目基于 [xiaobovlog/WLOC](https://github.com/xiaobovlog/WLOC) 二次开发，保留 Apache-2.0 许可证与原作者署名。主要改动为地点搜索、独立收藏页、经纬度与精度收藏、显式使用位置及发布隐私检查，见 [NOTICE](NOTICE)。

[下载公开版本与 IPA](https://github.com/Feng10241024/WLOC/releases) · [源码仓库](https://github.com/Feng10241024/WLOC)

[中文](#中文) | [English](#english)

---

## 中文

### 项目简介

WLOC 是一款面向 Apple 平台开发者的定位测试工具，主要用于在开发与 QA 环境中模拟不同地理位置，帮助开发者验证地图、区域化内容、位置触发逻辑及其他定位相关功能。

本项目包含一个 iOS 主应用和一个 Packet Tunnel Extension。它在用户明确授权并完成测试环境配置后，通过受限的网络定位响应重写流程提供测试位置。它不会直接修改 GPS 硬件读数，实际效果可能受到系统定位策略、GPS 信号、网络环境和系统缓存影响。

> **仅限授权测试：** 本项目仅可用于你拥有或已获得明确授权的设备、应用、账号和网络。请勿将其用于欺骗服务、规避平台规则、伪造生产环境数据或任何未经授权的用途。

### 主要功能

- 使用 SwiftUI 构建的 iOS 主应用。
- 通过地图选点或手动输入设置测试坐标。
- 输入地点名称或地址搜索，选择结果后地图移动到附近，再长按选定具体位置。
- 独立收藏页，支持地图选点、地点名称、经纬度和精度三种添加方式。
- 一键保存名称、地址、坐标和精度；支持改名、再次使用、删除，重启后保留。
- 支持 WGS-84 与中国大陆地图显示所需的 GCJ-02 坐标转换。
- 使用 App Group 在主应用与 Packet Tunnel Extension 之间同步配置。
- 提供 VPN 配置的创建、启动、停止、移除和诊断功能。
- 在授权测试环境中处理指定的网络定位响应。
- 本机生成测试 CA，并要求用户手动安装和信任测试证书。
- 对 Host、端口、路径和响应格式执行严格匹配，避免无边界处理流量。

### 地点搜索与地址收藏

1. 点击底部“收藏”，选择“地图选点”“地点名称”或“输入坐标”。
2. 地图选点：返回首页长按地图，蓝色标记和底部地点卡片会更新。“收藏”和“使用此位置”保持可见，点“收藏”直接保存，不会弹出强制命名窗口。联网时尝试识别地址，失败仍可收藏。
3. 地点名称：输入“武汉火车站”，搜索并核对结果地址，点击结果直接收藏。首页搜索也可选择地点并一键收藏，还可继续长按微调。
4. 输入坐标：沿用原设置页的经度、纬度和精度规则；输入精度（米，大于 0），名称可不填，点“加入收藏”。无效输入会在表单中显示原因，修正后可再次保存。
5. 收藏列表显示名称、地址（如有）、经纬度和精度。点右上角“…”可修改名称或删除；修改名称在普通表单中保存，不使用带输入框的系统 alert。
6. 只有点“使用此位置”才应用到当前测试位置和网络配置，并尝试运行已有“定位服务”快捷指令。浏览、搜索、选点和收藏都不会自动跳走。地图红色标记表示当前测试位置，蓝色表示已选地点。
7. 同一位置不会重复添加。收藏保存在本机，关闭并重新打开应用后仍可使用；旧版本收藏继续可读，旧记录未保存精度时沿用当前精度。

地点搜索使用 Apple MapKit，需要联网。可添加城市名区分同名地点。首页、收藏列表和手动输入都沿用原项目的 GCJ-02 显示规则；内部完整坐标保存和使用 WGS-84，不会因显示时的小数舍入而改变。

### 本地开发与验证

公开仓库使用 `main` 分支和经过检查的发布历史，后续改动按功能提交。提交请使用 GitHub noreply 邮箱，避免把个人邮箱写入公开历史。

在项目目录运行：

```bash
./scripts/test.sh
```

需要 macOS 14 或更高版本及 Swift 6 或更高版本。脚本运行 macOS 上的逻辑测试，覆盖搜索状态、失败重试、过期响应处理，以及收藏的保存、读取、删除、去重和输入校验。测试使用独立的 UserDefaults 测试域和可控搜索服务，不改动真实收藏，不发起线上搜索。

同一组测试已加入 Xcode 的 `WLOCTests` Target 和 `WLOC` Scheme。完整 iOS 编译、界面操作和 VPN 行为仍需要完整 Xcode 及测试设备；macOS 逻辑测试不能代替这些验证。

测试脚本还核对 Debug / Release 的 App Group、Provider ID 和巨魔商店签名权限，防止主应用与 VPN 扩展使用不同配置。

发布前运行 `python3 scripts/verify_publication_privacy.py --repository . --ref main --ipa dist/WLOC-1.1-build16-TrollStore.ipa`。检查覆盖公开分支可达的所有提交、历史文件及解压后的 IPA；发现个人路径、私人提交邮箱、凭据、证书私钥或个人 Xcode 状态文件时会阻止发布。公开包关闭覆盖率插桩，并在签名前清理调试元数据。个人收藏、定位设置和设备生成的测试 CA／私钥均不作为发布文件上传。该检查用于减少误上传，不能代替对新增文件内容的人工审查。

真机验收步骤：分别通过地图、地点名称、经纬度和精度添加收藏 → 确认操作中没有跳到快捷指令、当前测试位置未提前改变 → 修改名称 → 重启确认仍在 → 点击“使用此位置”核对当前经纬度和精度 → 删除并重启确认已移除。另检查空搜索、无结果、断网、无效坐标和精度，以及搜索结果收藏与地图同点收藏是否回到同一位置。

`WLOCUITests` 覆盖地图一键收藏、首页搜索选点和底部操作按钮、直接收藏搜索结果、重复添加、坐标输入纠错、改名、重启保留、显式应用精度和删除。Debug 界面测试使用独立 UserDefaults 域及确定性的搜索／地址服务，不访问真实收藏或 VPN，也不会跳到快捷指令；Release IPA 使用真实服务。模拟器测试证明表单和数据流，iOS 16.3.1／TrollStore／VPN 和其他 App 的实际定位仍需真机验证。

安装 iOS Simulator runtime 后运行 `./scripts/test-ui.sh`。脚本创建专用临时模拟器，运行完清理该测试设备；结果和日志保留在 `DerivedData`。也可传入已有模拟器 UDID（该设备会保留）。缺少 runtime 时可先运行 `xcodebuild -downloadPlatform iOS -architectureVariant arm64`。

### 系统要求

- iOS 16 或更高版本。
- 能够打开并构建本工程的 Xcode 版本。
- Apple Developer 账号及可用于 Network Extension 的签名权限。
- 一台真实 iOS 测试设备。模拟器无法完整验证 Packet Tunnel、VPN 配置、证书信任和真实定位行为。

### 签名与安装说明

由于应用内置 Packet Tunnel Extension，主应用和 Extension 都必须使用包含对应权限的签名配置。通常需要：

- 为主应用和 Packet Tunnel Extension 分别配置唯一的 Bundle Identifier。
- 为两个 Target 配置一致的 App Group。
- 为对应 App ID 启用 Network Extensions / Packet Tunnel Provider 能力。
- 使用包含上述 entitlement 的有效 Provisioning Profile。
- 确保主应用中记录的 Provider Bundle Identifier 与 Extension 的 Bundle Identifier 完全一致。

仅使用 P12 证书进行普通重签通常无法补充 Apple Developer Portal 未授权的 Network Extension entitlement。因此，这类安装包可能无法安装、无法保存 VPN 配置，或无法启动 Packet Tunnel 和定位测试功能。


### 构建

1. 使用 Xcode 打开 `WLOC.xcodeproj`。
2. 为主应用和 Packet Tunnel Extension 选择你自己的开发团队。
3. 修改 Bundle Identifier、App Group 和 Provider Bundle Identifier，使它们保持一致。
4. 在 Signing & Capabilities 中确认 App Groups 和 Packet Tunnel Provider 权限已正确配置。
5. 选择真实测试设备并构建运行。

如果你的开发者账号或 Provisioning Profile 不包含 Network Extension 权限，普通源码编译可能成功，但真机上的 VPN 配置和 Packet Tunnel 仍会失败。

#### 巨魔商店 IPA（已有 TrollStore 的测试设备）

在已初始化的完整 Xcode 环境中运行：

```bash
./scripts/test.sh
./scripts/build-trollstore-ipa.sh
```

输出为 `dist/WLOC-TrollStore.ipa`，另保留包含版本号和 build 号的副本（公开版为 `dist/WLOC-1.1-build16-TrollStore.ipa`），同时生成 SHA-256 校验文件。脚本编译 Release 的 iPhone 版本，保留完整 Packet Tunnel Extension，并使用仓库中的 `TrollStoreEntitlements` 为主应用和扩展作 ad-hoc 签名。它不需要登录开发者账号；该签名携带权限供 TrollStore 安装时保留，不能通过普通 Xcode 安装流程代替开发者签名。参见 [TrollStore 官方说明](https://github.com/opa334/TrollStore#features)。编译日志在 `DerivedData/Logs/iphoneos-build.log`。

普通 Xcode 签名的团队设置已留空，开发者需选择自己的团队。巨魔签名模板的示例标识沿用上游公开配置，不包含发布者的个人证书、账号凭据或设备信息。IPA 中包含许可和来源说明。

打包前会验证实际签名权限、App Group、Provider ID、arm64 / iPhoneOS 架构及最低系统版本，当前按测试设备 iOS 16.3.1 检查。不要随意更改 Bundle ID 或 App Group，以免已有 VPN 配置、共享配置或收藏与新版本不一致。

将 IPA 通过 AirDrop 或文件传输到 iPhone，选择用 TrollStore 打开并安装。应用名称为“WiFi Location”。安装后：

1. 按上面的地点搜索与地址收藏步骤检查新增功能。
2. 在设置页查看并完成测试证书的安装步骤，在 iPhone 系统设置中手动开启该测试证书的信任。
3. 返回应用安装网络配置并连接 VPN，然后到需要测试的 App 检查定位。

IPA 的编译、权限和打包验证不代表真机定位模拟已通过。项目只重写指定的网络定位响应，其他 App 是否采用该位置仍受 GPS、系统缓存和网络定位策略影响。真机遇到问题时，保留应用的诊断信息和具体报错用于继续排查。

### 使用边界与免责声明

- 本项目仅用于开发、QA、安全研究及其他已获授权的测试场景。
- 只能测试你拥有或已获得明确授权的设备、应用、账号、服务和网络。
- 不得关闭系统 TLS 校验、绕过证书固定或拦截未授权的第三方流量。
- 测试设备不应长期信任测试 CA；测试结束后应移除测试证书和 VPN 配置。
- 使用者需自行遵守所在地法律法规、Apple 开发者协议、平台规则和相关服务条款。
- 本项目按“原样”提供，不对适用性、稳定性、安装结果或使用后果作任何保证。

### 致谢

感谢以下项目提供的思路、研究资料和社区实践：

- [Yu9191/wloc](https://github.com/Yu9191/wloc)
- [FFF686868/proxypin-wloc-spoofer](https://github.com/FFF686868/proxypin-wloc-spoofer)



---

## English

### Overview

WLOC is a location-testing tool for developers building software for Apple platforms. Its primary purpose is to simulate different geographic locations in development and QA environments, making it easier to test maps, regional content, location-triggered logic, and other location-related features.

The project contains an iOS host application and a Packet Tunnel Extension. After the user explicitly authorizes and configures the test environment, it provides a test location through a restricted network-location response-rewriting flow. It does not directly alter hardware GPS readings, and its behavior may be affected by system location policies, GPS signal strength, network conditions, and system caches.

> **Authorized testing only:** Use this project only with devices, applications, accounts, and networks that you own or are explicitly authorized to test. Do not use it to deceive services, evade platform rules, falsify production data, or perform any unauthorized activity.

### Features

- A SwiftUI-based iOS host application.
- Test-coordinate selection through a map or manual input.
- Place-name/address search that centers the map before the user selects a precise point.
- A dedicated favorites tab with map, search and coordinate entry, editable names, saved accuracy and deletion.
- One-tap saving; only the explicit Use action applies a selected location and invokes the existing shortcut.
- WGS-84 and GCJ-02 conversion for map presentation in mainland China.
- App Group configuration sharing between the host application and the Packet Tunnel Extension.
- VPN configuration creation, start, stop, removal, and diagnostics.
- Restricted network-location response processing in authorized test environments.
- On-device generation of a test CA, with manual certificate installation and trust required from the user.
- Strict matching of hosts, ports, paths, and response formats to prevent unbounded traffic processing.

### Requirements

- iOS 16 or later.
- A version of Xcode capable of opening and building the project.
- An Apple Developer account with signing permissions for Network Extensions.
- A physical iOS test device. The Simulator cannot fully validate Packet Tunnel behavior, VPN configuration, certificate trust, or real-world location behavior.

### Signing and Installation

Because the application includes a Packet Tunnel Extension, both the host application and the extension must be signed with profiles containing the required capabilities. In most cases, you must:

- Assign unique Bundle Identifiers to the host application and Packet Tunnel Extension.
- Configure the same App Group for both targets.
- Enable Network Extensions / Packet Tunnel Provider for the corresponding App IDs.
- Use valid Provisioning Profiles containing the required entitlements.
- Ensure that the Provider Bundle Identifier stored by the host application exactly matches the extension's Bundle Identifier.

Ordinary re-signing with only a P12 certificate generally cannot add a Network Extension entitlement that has not been authorized through the Apple Developer Portal. Such a build may fail to install, fail to save its VPN configuration, or be unable to start the Packet Tunnel and location-testing functionality.


### Building

1. Open `WLOC.xcodeproj` in Xcode.
2. Select your own development team for the host application and Packet Tunnel Extension.
3. Update the Bundle Identifiers, App Group, and Provider Bundle Identifier so that they are consistent.
4. Confirm that App Groups and Packet Tunnel Provider are correctly configured under Signing & Capabilities.
5. Select a physical test device and build the project.

Source compilation may succeed even when your developer account or Provisioning Profile lacks the Network Extension capability. In that case, VPN configuration and Packet Tunnel startup will still fail on a physical device.

### Authorized Use and Disclaimer

- This project is intended only for development, QA, security research, and other explicitly authorized testing scenarios.
- Test only devices, applications, accounts, services, and networks that you own or are explicitly authorized to test.
- Do not disable system TLS validation, bypass certificate pinning, or intercept unauthorized third-party traffic.
- A test device should not permanently trust a test CA. Remove the test certificate and VPN configuration after testing.
- Users are responsible for complying with applicable laws, the Apple Developer agreements, platform policies, and relevant service terms.
- The project is provided “as is,” without warranties regarding fitness, stability, installation, or the consequences of use.

### Acknowledgements

Thanks to the following projects for their ideas, research materials, and community work:

- [Yu9191/wloc](https://github.com/Yu9191/wloc)
- [FFF686868/proxypin-wloc-spoofer](https://github.com/FFF686868/proxypin-wloc-spoofer)
