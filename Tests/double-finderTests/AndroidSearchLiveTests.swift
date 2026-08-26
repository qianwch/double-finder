import XCTest
@testable import double_finder

/// Live MTP test for Find Files against a real phone: name search over the tree,
/// non-recursive scoping, and the content pass (which pulls candidates over USB).
/// Needs a phone plugged in, unlocked, USB mode "File transfer". Skipped unless
/// `ANDROID_LIVE=1`. Run with:
///   ANDROID_LIVE=1 swift test --filter AndroidSearchLiveTests
///
/// The fixture is written to the device and removed again; the device session is
/// closed in every exit path so the USB claim goes back (libmtp is exclusive).
final class AndroidSearchLiveTests: XCTestCase {

    func testFindFilesOnDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ANDROID_LIVE"] == "1", "set ANDROID_LIVE=1 with a phone attached")
        let devices = AndroidDeviceScanner.detect()
        try XCTSkipUnless(!devices.isEmpty, "no MTP device attached")

        let device = devices[0]
        let registry = AndroidDeviceRegistry.shared
        _ = try await registry.open(device)
        defer { registry.close(device.sessionID) }

        let storages = registry.storages(device.sessionID)
        let storage = try XCTUnwrap(storages.first, "device reports no storage")
        let root = "/\(storage.name)/df_search_\(UUID().uuidString.prefix(8))"
        let fs = AndroidFS(device: device, currentPath: root)

        // --- fixture: two text files, one nested, one binary ---
        let tmp = NSTemporaryDirectory() + "df-android-search-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        func local(_ name: String, _ bytes: Data) throws -> String {
            let p = (tmp as NSString).appendingPathComponent(name)
            try bytes.write(to: URL(fileURLWithPath: p))
            return p
        }
        try await registry.ensureDirectory(device.sessionID, path: root + "/sub")
        try await fs.copy(from: try local("one.txt", Data("alpha needle beta".utf8)), to: root)
        try await fs.copy(from: try local("two.txt", Data("nothing here".utf8)), to: root)
        try await fs.copy(from: try local("three.log", Data("deep NEEDLE".utf8)), to: root + "/sub")
        var binary = Data("needle".utf8); binary.append(contentsOf: [0x00, 0x01])
        try await fs.copy(from: try local("blob.bin", binary), to: root)

        func search(name: String, content: String = "", subfolders: Bool = true) async throws -> [String] {
            let hits = try await FileSearch.run(
                endpoint: .android(device, label: "test", base: root),
                query: FileSearchQuery(namePattern: name, content: content,
                                       subfolders: subfolders, regexName: false),
                report: { _, _ in })
            return hits.map { String($0.path.dropFirst(root.count + 1)) }.sorted()
        }

        // Cleanup must run on the failure path too, and synchronously — a
        // `defer { Task { … } }` would not get to run before the process exits
        // and would leave the fixture on the user's phone.
        var failure: Error?
        do {
            let byName = try await search(name: "*.txt")
            XCTAssertEqual(byName, ["one.txt", "two.txt"])

            let sized = try await search(name: "one.txt")
            XCTAssertEqual(sized, ["one.txt"])

            // Content: recursive, case-insensitive, binary skipped.
            let byContent = try await search(name: "*", content: "needle")
            XCTAssertEqual(byContent, ["one.txt", "sub/three.log"])

            let shallow = try await search(name: "*", content: "needle", subfolders: false)
            XCTAssertEqual(shallow, ["one.txt"])
        } catch {
            failure = error
        }

        try? await fs.delete(root)
        let leftovers = try? await fs.listDirectory(root)
        XCTAssertNil(leftovers, "fixture left on the device at \(root)")
        if let failure = failure { throw failure }
    }
}
