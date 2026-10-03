import XCTest
@testable import double_finder

final class ADBClientTests: XCTestCase {
    func testDevicesPreserveAuthorizationAndIgnoreDaemonMessages() {
        let devices = ADBClient.parseDevices("* daemon started successfully *\nList of devices attached\nusb1 device product:x model:Pixel_8 transport_id:1\nusb2 unauthorized\nusb3 offline\n")
        XCTAssertEqual(devices.map(\.serial), ["usb1", "usb2", "usb3"])
        XCTAssertEqual(devices[0].model, "Pixel 8")
        XCTAssertEqual(devices.map(\.isAuthorized), [true, false, false])
    }
    func testMDNSDistinguishesPairingFromConnection() {
        let services = ADBClient.parseMDNSServices("List of discovered mdns services\npixel _adb-tls-pairing._tcp. 192.168.1.2:37000\npixel _adb-tls-connect._tcp. 192.168.1.2:39000\n")
        XCTAssertEqual(services.map(\.kind), [.pairing, .connection])
    }
    func testQuotePreservesShellMetacharacters() throws {
        XCTAssertEqual(try ADBClient.quote("中文\n'$(touch /tmp/never)"), "'中文\n'\\''$(touch /tmp/never)'")
        XCTAssertThrowsError(try ADBClient.quote("a\0b"))
    }
    func testSerialValidation() throws {
        for serial in ["", "-s", "two words", "x\n", "x\0"] { XCTAssertThrowsError(try ADBClient.validateSerial(serial)) }
    }
    func testEndpointValidation() throws {
        for value in ["phone.local:5555", "192.168.1.2:1", "[::1]:65535"] { XCTAssertNoThrow(try ADBClient.validateEndpoint(value)) }
        for value in ["x:0", "x:65536", "x:2;touch", "-x:22", "x y:22", "::1:22", "x:22\n"] { XCTAssertThrowsError(try ADBClient.validateEndpoint(value), value) }
    }
    func testRunnerDrainsBothPipesAndReturnsExitStatus() async throws {
        let result = try await ADBProcessRunner.run(executable: "/usr/bin/python3", arguments: ["-c", "import os; os.write(1,b'a'*200000); os.write(2,b'b'*200000); raise SystemExit(7)"], input: nil, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.stdout.count, 200000)
        XCTAssertEqual(result.stderr.count, 200000)
        XCTAssertEqual(result.exitCode, 7)
    }
    func testRunnerTimeoutAndCancellation() async throws {
        do {
            _ = try await ADBProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], input: nil, timeout: 0.1, isCancelled: { false })
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? ADBError, .timeout) }
        let start = Date()
        do {
            _ = try await ADBProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], input: nil, timeout: 5, isCancelled: { Date().timeIntervalSince(start) > 0.1 })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testTaskCancellationKillsCommandIgnoringTermination() async throws {
        let command = Task { try await ADBProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"], input: nil, timeout: 5, isCancelled: { false }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        command.cancel()
        do { _ = try await command.value; XCTFail("Expected task cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPipeHeldByDescendantDoesNotBlockCompletion() async throws {
        let start = Date()
        _ = try await ADBProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 1 & exit 0"], input: nil, timeout: 5, isCancelled: { false })
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }
    func testQuoteExecutesAsLiteralData() async throws {
        let value = "中文\n'$(printf bad); -value"
        let result = try await ADBProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf %s " + ADBClient.quote(value)], input: nil, timeout: 5, isCancelled: { false })
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), value)
    }
    func testPairCodeUsesStdinAndFailureBodyDoesNotLeakCode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\nread code\n[ \"$#\" = 2 ] || exit 4\nprintf 'Failed to pair: %s' \"$code\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try await ADBClient.pair(executablePath: url.path, endpoint: "phone.local:1234", code: "123456"); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("123456")) }
    }
    func testSuccessfulPairingUsesExactArgumentsAndStdin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("adb")
        let script = "#!/bin/sh\n[ \"$#\" = 2 ] && [ \"$1\" = pair ] && [ \"$2\" = phone.local:1234 ] || exit 4\nread code\n[ \"$code\" = 654321 ] || exit 5\nprintf 'successfully paired to phone.local:1234'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await ADBClient.pair(executablePath: executable.path, endpoint: "phone.local:1234", code: "654321")
    }
    func testShellPinsDeviceAndPreservesArguments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = ADBClient(session: ADBSession(device: ADBDevice(serial: "usb-device-2", model: "", state: "device"), executablePath: url.path))
        let output = try await client.shell("printf '中文'", isCancelled: { false })
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "-s\0usb-device-2\0shell\0printf '中文'\0")
    }
}
