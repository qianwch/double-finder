import XCTest
@testable import double_finder

@MainActor
final class BulkResponsivenessTests: XCTestCase {
    private func item(_ path: String, directory: Bool = false, size: Int64 = 1) -> FileItem {
        FileItem(id: UUID(), name: (path as NSString).lastPathComponent, path: path,
                 isDirectory: directory, isArchive: false, size: size, modified: .distantPast,
                 isHidden: false, isSymlink: false, permissions: "")
    }

    func testPruningPreservesLeavesOrderAndPathBoundaries() {
        let input = ["/a", "/ab", "/a/b", "/a/b/c", "/a-b", "/ab", "/中文", "/中文/书"]
        XCTAssertEqual(TransferPlanner.pruneSelectedAncestors(input.map { item($0) }).map(\.path),
                       ["/ab", "/a/b/c", "/a-b", "/ab", "/中文/书"])
        XCTAssertTrue(TransferPlanner.pruneSelectedAncestors([]).isEmpty)
    }

    func testPruningLargeFlatSelectionDoesNotTakeSeconds() {
        let items = (0..<5000).map { item("/source/file-\($0)") }
        let start = Date()
        let result = TransferPlanner.pruneSelectedAncestors(items)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.map(\.id), items.map(\.id))
        // Broad ceiling: catches the quadratic scan, not small CI timing noise.
        XCTAssertLessThan(elapsed, 1.0, "Selection pruning blocked for \(elapsed)s")
    }

    func testDirectorySortLetsMainActorRun() async {
        let panel = PanelState(path: "/")
        let items = (0..<10000).reversed().map { item(String(format: "/file-%05d", $0)) }
        var uiRan = false
        let ui = Task { @MainActor in uiRan = true }
        let sorted = await panel.sortItemsForDisplay(items)
        XCTAssertTrue(uiRan, "Directory sorting monopolized the main actor")
        XCTAssertEqual(sorted.first?.name, "file-00000")
        XCTAssertEqual(sorted.last?.name, "file-09999")
        XCTAssertEqual(sorted.count, 10000)
        await ui.value
    }

    func testSortChangeDuringBackgroundSortWins() async {
        let panel = PanelState(path: "/")
        let items = (0..<10000).map { item(String(format: "/file-%05d", $0), size: Int64(10000 - $0)) }
        let change = Task { @MainActor in panel.sortColumn = .size }
        let sorted = await panel.sortItemsForDisplay(items)
        await change.value
        XCTAssertEqual(sorted.first?.name, "file-09999")
        XCTAssertEqual(sorted.last?.name, "file-00000")
    }

    func testPanelMemoryKeyUsesLoadedSnapshotWithoutReprobingDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("child"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let panel = PanelState(path: link.appendingPathComponent("child").path)
        panel.loadDirectory()
        for _ in 0..<400 where panel.isLoading { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(panel.isLoading)
        let loadedKey = panel.currentMemoryKey
        XCTAssertEqual(loadedKey, target.appendingPathComponent("child").resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: link)
        // The displayed listing still represents the last completed load. A UI
        // update must not stat the path again (which could now be an offline share).
        XCTAssertEqual(panel.currentMemoryKey, loadedKey)
    }

    /// Only prepares units: no network connection or USB transfer is attempted.
    /// A queued UI callback must run before a large synchronous scan completes.
    func testUploadPreparationLetsMainActorRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data([1, 2, 3]).write(to: file)
        let items = (0..<2000).map { _ in item(file.path) }
        let endpoint = S3Endpoint(base: URL(string: "https://unused.invalid")!, region: "us-east-1", pathStyle: true)
        let client = S3Client(endpoint: endpoint, signer: S3Signer(accessKey: "a", secretKey: "s", region: "us-east-1"))
        let device = AndroidDevice(vendor: "Test", product: "Phone", vendorID: 1, productID: 1,
                                   busLocation: 1, devNumber: 1, rawIndex: 0)
        let operations = [
            S3TransferProvider(client: client, downloading: false).makeOperation(items: items, destPath: "/bucket/prefix"),
            AndroidTransferProvider(device: device, direction: .upload).makeOperation(items: items, destPath: "/1")
        ]
        for op in operations {
            var uiRan = false
            let ui = Task { @MainActor in uiRan = true }
            let units = await op.transferUnitsProvider!()
            XCTAssertTrue(uiRan, "Upload preparation monopolized the main actor")
            XCTAssertEqual(units.count, 2000)
            XCTAssertEqual(units.reduce(0) { $0 + $1.bytes }, 6000)
            await ui.value
        }
    }
}
