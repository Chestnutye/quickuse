import CoreWLAN
import Security
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

    /// 连接时实际用到的凭据。来自系统钥匙串时由调用方缓存，下次直接使用。
    struct Credential: Sendable {
        var username: String?
        var password: String
    }

    /// 连接网络。返回从系统钥匙串新读到的凭据（没有则为 nil）。
    @discardableResult
    static func connect(ssid: String, security: WiFiPreset.Security,
                        username: String?, password: String?) async throws -> Credential? {
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

            func associate(_ username: String?, _ password: String?) throws {
                if isEnterprise {
                    try iface.associate(toEnterpriseNetwork: network, identity: nil,
                                        username: username?.nilIfEmpty, password: password?.nilIfEmpty)
                } else {
                    try iface.associate(to: network, password: password?.nilIfEmpty)
                }
            }

            do {
                try associate(username, password)
                return nil
            } catch {
                // 新版 macOS 不会把系统保存的密码自动交给第三方 App。
                // “使用系统已保存的密码”的预设，去系统钥匙串读出凭据后重试（首次会弹出钥匙串授权）。
                guard security == .system, !isEnterprise else {
                    var detail = describe(error, enterprise: isEnterprise)
                    if isEnterprise && password?.isEmpty != false {
                        detail = "这是企业网络，需要在设置 → Wi‑Fi 预设里为它填写一次密码。"
                    }
                    throw ConnectError(title: "连接「\(ssid)」失败", detail: detail)
                }
                guard let saved = personalCredential(ssid: ssid) else {
                    throw ConnectError(title: "连接「\(ssid)」失败",
                                       detail: "没能读取系统保存的密码（可能在授权时点了拒绝）。可以在设置里编辑这个预设，改为手动填写密码。")
                }
                do {
                    try associate(saved.username, saved.password)
                    return saved
                } catch {
                    throw ConnectError(title: "连接「\(ssid)」失败", detail: describe(error, enterprise: isEnterprise))
                }
            }
        }.value
    }

    enum SavedLookup: Sendable {
        /// 个人网络，已从系统钥匙串读到密码。
        case personal(Credential)
        /// 企业网络（eduroam 等）。系统不允许第三方 App 可靠地读取它的密码，只返回账号名，密码需用户填写。
        case enterprise(username: String?)
        /// 没读到（用户拒绝授权或系统里没有保存）。
        case unavailable
    }

    /// 添加预设时调用。企业网络只读账号名（不读密码、不弹窗）；个人网络读取密码，会弹出一次系统授权。
    static func lookupSaved(ssid: String) async -> SavedLookup {
        await Task.detached {
            if let account = enterpriseAccount(ssid: ssid) { return .enterprise(username: account.isEmpty ? nil : account) }
            if let credential = personalCredential(ssid: ssid) { return .personal(credential) }
            return .unavailable
        }.value
    }

    /// 只读取企业网络凭据条目的属性（账号名），不读取密码，因此不会弹窗。条目不存在返回 nil。
    private static func enterpriseAccount(ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.apple.network.eap.user.item.wlan.ssid.\(ssid)",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any] else { return nil }
        return item[kSecAttrAccount as String] as? String ?? ""
    }

    /// 读取系统钥匙串里个人网络的密码（service 为 “AirPort”）。由 QuickUse 进程自己读取，
    /// 弹窗询问的对象是 QuickUse，即使选了“始终允许”也不会对其他程序放行。
    private static func personalCredential(ssid: String) -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AirPort",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return Credential(username: nil, password: password)
    }

    private static func describe(_ error: Error, enterprise: Bool) -> String {
        let code = (error as NSError).code
        switch code {
        case -3900:
            return "系统拒绝了这次连接（tmpErr）。通常是没有拿到正确的密码，请在设置里检查这个预设。"
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
