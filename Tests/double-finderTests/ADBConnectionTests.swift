import XCTest
@testable import double_finder

final class ADBConnectionTests: XCTestCase {
    func testWirelessAddressRoundTripHasNoPairingSecret() throws {
        let connection = ServerConnection.adb(ADBConnection(name: "Pixel", host: "phone.local", port: 39000))
        XCTAssertEqual(ServerConnection(dict: connection.dict), connection)
        XCTAssertEqual(Set(connection.dict.keys), ["kind", "name", "host", "port", "initialPath"])
        XCTAssertNil(ServerConnection(dict: ["kind": "adb", "host": "x", "port": "0"]))
        XCTAssertNil(ServerConnection(dict: ["kind": "adb", "host": "x", "port": "65536"]))
    }
    func testStorePersistsWirelessAddressAndResetKeepsIt() {
        let suite = "ADBConnectionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ServerConnection.adb(ADBConnection(name: "Phone", host: "x.local", port: 1234))
        ServerConnectionStore.add(saved, defaults: defaults)
        defaults.set("/custom/adb", forKey: "ADBExecutablePath")
        SettingsReset.reset(category: "general", in: defaults)
        XCTAssertNil(defaults.string(forKey: "ADBExecutablePath"))
        XCTAssertEqual(ServerConnectionStore.load(defaults: defaults), [saved])
        XCTAssertFalse(String(describing: defaults.array(forKey: "ServerConnections")!).contains("pair"))
    }
    @MainActor func testExplicitEjectDisconnectsEndpointAndQuitOnlyInvalidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("adb")
        let log = root.appendingPathComponent("arguments")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\nexit 9\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = RemoteSessionStore()
        let device = ADBDevice(serial: "adb-wireless-service", model: "Phone", state: "device")
        let session = ADBSession(device: device, executablePath: executable.path, networkEndpoint: "phone.local:1234")
        let failed = expectation(description: "Disconnect failure remains visible")
        let observer = NotificationCenter.default.addObserver(forName: RemoteSessionStore.adbDisconnectFailed, object: nil, queue: .main) { note in
            if note.userInfo?["endpoint"] as? String == "phone.local:1234" { failed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.register(.adb(session)); store.remove(id: session.id)
        XCTAssertTrue(session.lifetime.isRemoved)
        await fulfillment(of: [failed], timeout: 3)
        let recorded = URL(fileURLWithPath: executable.path + ".arguments")
        XCTAssertEqual(try String(contentsOf: recorded), "disconnect\nphone.local:1234\n")
        try FileManager.default.removeItem(at: recorded)
        let quitSession = ADBSession(device: device, executablePath: executable.path, networkEndpoint: "phone.local:1234")
        store.register(.adb(quitSession)); store.removeAll()
        XCTAssertTrue(quitSession.lifetime.isRemoved)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
    func testMDNSConnectionEndpointRequiresExactInstanceRelation() {
        let short = ADBService(name: "adb-phone", kind: .connection, endpoint: "short.local:1111")
        let long = ADBService(name: "adb-phone2", kind: .connection, endpoint: "long.local:2222")
        let pairing = ADBService(name: "adb-phone2", kind: .pairing, endpoint: "pair.local:3333")
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2", services: [short, pairing, long]), "long.local:2222")
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2._adb-tls-connect._tcp", services: [short, long]), nil)
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2_adb-tls-connect._tcp", services: [short, long]), "long.local:2222")
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2_adb-tls-connect._tcp.", services: [short, long]), "long.local:2222")
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2_adb-tls-connect._tcp", services: [ADBService(name: "adb-phone2_adb-tls-connect._tcp", kind: .connection, endpoint: "long.local:2222")]), "long.local:2222")
        XCTAssertNil(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2extra", services: [short, long]))
        XCTAssertNil(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2", services: [short, pairing]))
        XCTAssertEqual(ADBConnectionDraft.networkEndpoint(serial: "phone.local:5555", services: [short]), "phone.local:5555")
        XCTAssertNil(ADBConnectionDraft.networkEndpoint(serial: "adb-phone2", services: [long, ADBService(name: "adb-phone2", kind: .connection, endpoint: "other.local:2222")]))
    }
    func testDraftValidatesSeparateEndpoints() throws {
        XCTAssertEqual(try ADBConnectionDraft.endpoint(host: "::1", port: "39000"), "[::1]:39000")
        for port in ["", "0", "65536", "abc"] { XCTAssertThrowsError(try ADBConnectionDraft.endpoint(host: "x", port: port)) }
        XCTAssertThrowsError(try ADBConnectionDraft.endpoint(host: "x;touch", port: "22"))
    }
    @MainActor func testRailMatchesADBModelAndSerialAndPreservesUnavailableDevices() {
        let devices = [ADBDevice(serial: "usb-123", model: "Pixel 8", state: "unauthorized"), ADBDevice(serial: "usb-456", model: "Phone", state: "offline")]
        let rows = ServerRail.rows(saved: [], devices: [], discovered: [], scanningDevices: false, filter: "usb-123", adbDevices: devices)
        XCTAssertTrue(rows.contains(.adbDevice(devices[0])))
        XCTAssertFalse(devices[0].isAuthorized)
        XCTAssertFalse(devices[1].isAuthorized)
        XCTAssertTrue(ServerRail.rows(saved: [], devices: [], discovered: [], scanningDevices: false, filter: "pixel", adbDevices: devices).contains(.adbDevice(devices[0])))
    }
}
