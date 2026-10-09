import XCTest
@testable import QuickUse

/// 每个测试用独立的模块目录和钥匙串条目，结束后清理，不影响真实数据。
final class ModuleStorageTests: XCTestCase {
    private var storage: ModuleStorage!

    override func setUp() {
        storage = ModuleStorage(moduleID: "tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storage.directory)
    }

    func testRoundTrip() {
        storage.save(["a", "b"], to: "list")
        XCTAssertEqual(storage.load([String].self, from: "list"), ["a", "b"])
    }

    func testMissingFileReturnsNilWithoutBackup() throws {
        XCTAssertNil(storage.load([String].self, from: "missing"))
        XCTAssertTrue(try files().isEmpty)
    }

    func testUnreadableFileIsBackedUpNotOverwritten() throws {
        let original = Data(#"{"old": "format"}"#.utf8)
        try original.write(to: storage.directory.appendingPathComponent("rules.json"))

        XCTAssertNil(storage.load([String].self, from: "rules"))
        // 调用方随后按空数据保存一次，备份不能被覆盖。
        storage.save([String](), to: "rules")

        let backups = try files().filter { $0.hasPrefix("rules.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: storage.directory.appendingPathComponent(backups[0])), original)
        XCTAssertEqual(storage.load([String].self, from: "rules"), [])
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: storage.directory.path)
    }
}

final class KeychainTests: XCTestCase {
    private let service = "QuickUse.Tests.\(UUID().uuidString)"

    override func tearDown() {
        Keychain.delete(service: service, account: "a")
    }

    func testSetUpdatesExistingItem() {
        XCTAssertFalse(Keychain.exists(service: service, account: "a"))
        XCTAssertTrue(Keychain.set("one", service: service, account: "a"))
        XCTAssertEqual(Keychain.get(service: service, account: "a"), "one")
        XCTAssertTrue(Keychain.set("two", service: service, account: "a"))
        XCTAssertEqual(Keychain.get(service: service, account: "a"), "two")
        Keychain.delete(service: service, account: "a")
        XCTAssertFalse(Keychain.exists(service: service, account: "a"))
    }
}

@MainActor
final class WiFiPresetStoreTests: XCTestCase {
    private var storage: ModuleStorage!
    private var store: WiFiPresetStore!
    private var preset = WiFiPreset(group: "家", name: "测试", ssid: "QuickUseTestSSID", security: .personal)

    override func setUp() async throws {
        storage = ModuleStorage(moduleID: "tests-\(UUID().uuidString)")
        store = WiFiPresetStore(storage: storage)
        store.upsert(preset)
    }

    override func tearDown() async throws {
        store.setPassword(nil, for: preset)
        try? FileManager.default.removeItem(at: storage.directory)
    }

    func testPasswordCacheFollowsKeychain() {
        XCTAssertFalse(store.hasPassword(preset))

        store.setPassword("secret", for: preset)
        XCTAssertTrue(store.hasPassword(preset))
        XCTAssertEqual(preset.password, "secret")

        // 重新加载时从钥匙串恢复缓存。
        XCTAssertTrue(WiFiPresetStore(storage: storage).hasPassword(preset))

        // 空字符串表示删除（编辑器“仍然保存”和改为无密码时用到）。
        store.setPassword("", for: preset)
        XCTAssertFalse(store.hasPassword(preset))
        XCTAssertNil(preset.password)
    }

    func testDeleteRemovesPassword() {
        store.setPassword("secret", for: preset)
        store.delete(preset)
        XCTAssertFalse(store.hasPassword(preset))
        XCTAssertNil(preset.password)
        XCTAssertTrue(store.presets.isEmpty)
    }
}
