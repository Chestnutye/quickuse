import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// CoreWLAN 的封装。连接和扫描是阻塞调用，在后台线程执行。
enum WiFiService {
    struct ConnectError: LocalizedError {
        let title: String
        let detail: String
        var errorDescription: String? { "\(title)\n\(detail)" }
    }

    private static var interface: CWInterface? { CWWiFiClient.shared().interface() }
    static var interfaceName: String { interface?.interfaceName ?? "en0" }

    /// 当前连接的 SSID。需要定位权限，否则系统返回 nil。
    static func currentSSID() -> String? { interface?.ssid() }

    static var isPoweredOn: Bool { interface?.powerOn() ?? false }

    /// 这台 Mac 保存过（连过）的网络，按系统优先顺序排列。
    static func savedNetworks() async -> [String] {
        await Task.detached {
            let result = Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interfaceName])
            return result.output
                .split(separator: "\n")
                .dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    static func connect(ssid: String, security: WiFiPreset.Security,
                        username: String?, password: String?) async throws {
        try await Task.detached {
            guard let iface = interface else {
                throw ConnectError(title: "找不到 Wi‑Fi 硬件", detail: "这台 Mac 没有可用的无线网卡。")
            }
            if !iface.powerOn() { try iface.setPower(true) }

            // 按名称定向扫描，隐藏网络也能找到。扫不到说明不在附近，直接停止，不去盲连。
            let found: Set<CWNetwork>
            do {
                found = try iface.scanForNetworks(withName: ssid, includeHidden: true)
            } catch {
                throw ConnectError(title: "扫描 Wi‑Fi 失败", detail: error.localizedDescription)
            }
            guard let network = found.first(where: { $0.ssid == ssid }) ?? found.first else {
                throw ConnectError(title: "附近没有找到「\(ssid)」",
                                   detail: "没有连接。请确认你在这个网络的覆盖范围内，网络名称没有写错。")
            }

            let isEnterprise = [CWSecurity.wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .enterprise]
                .contains { network.supportsSecurity($0) }
            do {
                if isEnterprise {
                    // 用户名、密码为 nil 时，系统会使用之前保存的企业网络凭据。
                    try iface.associate(toEnterpriseNetwork: network, identity: nil,
                                        username: username?.nilIfEmpty, password: password?.nilIfEmpty)
                } else {
                    try iface.associate(to: network, password: password?.nilIfEmpty)
                }
            } catch {
                // CoreWLAN 有时拿不到系统保存的密码，退回 networksetup 再试一次。
                if !isEnterprise, try fallbackJoin(ssid: ssid, password: password) { return }
                throw ConnectError(title: "连接「\(ssid)」失败", detail: describe(error, enterprise: isEnterprise))
            }
        }.value
    }

    private static func fallbackJoin(ssid: String, password: String?) throws -> Bool {
        var args = ["-setairportnetwork", interfaceName, ssid]
        if let password, !password.isEmpty { args.append(password) }
        let result = Shell.run("/usr/sbin/networksetup", args)
        let output = result.output.lowercased()
        return result.status == 0 && !output.contains("could not") && !output.contains("failed") && !output.contains("error")
    }

    private static func describe(_ error: Error, enterprise: Bool) -> String {
        let code = (error as NSError).code
        switch code {
        case -3924, -3905:
            return enterprise ? "用户名或密码不正确，或认证超时。" : "密码不正确。"
        case -3903:
            return "认证失败。请在设置里检查这个预设的密码。"
        default:
            return "\(error.localizedDescription)（代码 \(code)）"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 读取 Wi‑Fi 名称需要定位权限。
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    var isUndetermined: Bool { manager.authorizationStatus == .notDetermined }

    func request() {
        if isUndetermined { manager.requestWhenInUseAuthorization() }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange?() }
    }
}

/// 监听系统 Wi‑Fi 变化事件（回调在后台线程）。
final class WiFiEventMonitor: NSObject, CWEventDelegate {
    var onChange: (() -> Void)?

    func start() {
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        try? client.startMonitoringEvent(with: .powerDidChange)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { fire() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { fire() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { fire() }

    private func fire() {
        DispatchQueue.main.async { self.onChange?() }
    }
}
