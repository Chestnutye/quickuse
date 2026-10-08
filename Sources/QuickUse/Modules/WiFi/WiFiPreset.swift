import Foundation

struct WiFiPreset: Codable, Identifiable, Hashable {
    enum Security: String, Codable, CaseIterable {
        /// 从“连过的网络”选择，使用系统已保存的凭据，App 不保存密码。
        case system
        /// WPA2/WPA3 个人，密码存钥匙串。
        case personal
        /// WPA2 企业（eduroam 等），用户名存这里，密码存钥匙串。
        case enterprise
        case open

        var label: String {
            switch self {
            case .system: "使用系统已保存的密码"
            case .personal: "WPA2/WPA3 个人"
            case .enterprise: "WPA2 企业（eduroam 等）"
            case .open: "无密码"
            }
        }
    }

    var id = UUID()
    var group: String
    var name: String
    var ssid: String
    var security: Security
    var hidden = false
    var username: String?

    var displayName: String { "\(group) · \(name)" }

    static let keychainService = "QuickUse.WiFi"

    var password: String? {
        get { Keychain.get(service: Self.keychainService, account: id.uuidString) }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, service: Self.keychainService, account: id.uuidString)
            } else {
                Keychain.delete(service: Self.keychainService, account: id.uuidString)
            }
        }
    }
}

@MainActor
final class WiFiPresetStore: ObservableObject {
    @Published var presets: [WiFiPreset] { didSet { storage.save(presets, to: "presets") } }
    private let storage: ModuleStorage

    init(storage: ModuleStorage) {
        self.storage = storage
        presets = storage.load([WiFiPreset].self, from: "presets") ?? []
    }

    /// 按首次出现的顺序列出分组。
    var groups: [String] {
        var seen = Set<String>()
        return presets.map(\.group).filter { seen.insert($0).inserted }
    }

    func upsert(_ preset: WiFiPreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset } else { presets.append(preset) }
    }

    func delete(_ preset: WiFiPreset) {
        preset.password = nil
        presets.removeAll { $0.id == preset.id }
    }

    func preset(forSSID ssid: String?) -> WiFiPreset? {
        presets.first { $0.ssid == ssid }
    }
}
