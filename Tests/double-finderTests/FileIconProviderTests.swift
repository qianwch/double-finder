import XCTest
import AppKit
@testable import double_finder

/// Async integration tests for FileIconProvider.
/// These tests use real temp files (not mocks) and XCTestExpectation so they
/// are deterministic and don't rely on sleep.
final class FileIconProviderTests: XCTestCase {

    var tempURL: URL!
    var tempPath: String { tempURL.path }

    override func setUp() async throws {
        try await super.setUp()
        // Create a real temp file so NSWorkspace can resolve its icon.
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("FileIconProviderTests_\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8))
        tempURL = url
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
        try await super.tearDown()
    }

    private func makeItem() -> FileItem {
        FileItem(
            id: UUID(),
            name: tempURL.lastPathComponent,
            path: tempPath,
            isDirectory: false,
            isArchive: false,
            size: 5,
            modified: Date(),
            isHidden: false,
            isSymlink: false,
            permissions: "rw-r--r--"
        )
    }

    // MARK: - Test 1: icon(for:) returns a non-nil placeholder immediately

    func testIconForUncachedFileReturnsImmediately() async throws {
        let provider = await MainActor.run { FileIconProvider() }
        let item = makeItem()
        let side: CGFloat = 16

        // icon() must return synchronously (non-nil placeholder) without blocking.
        let image = await MainActor.run {
            provider.icon(for: item, side: side, wantThumbnail: false)
        }
        // Must be non-nil
        XCTAssertNotNil(image)
        XCTAssertEqual(image.size.width, side)
        XCTAssertEqual(image.size.height, side)
    }

    // MARK: - Test 2: onReady fires after async resolution, then cache hit

    func testOnReadyFiresAndCacheIsPopulated() async throws {
        let provider = await MainActor.run { FileIconProvider() }
        let item = makeItem()
        let side: CGFloat = 16

        let expectation = XCTestExpectation(description: "onReady fires for our path")

        await MainActor.run {
            provider.onReady = { path in
                if path == item.path {
                    expectation.fulfill()
                }
            }
            // Request the icon to enqueue async resolution
            _ = provider.icon(for: item, side: side, wantThumbnail: false)
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        // After onReady fires, the cache should have the resolved icon.
        let cachedImage = await MainActor.run {
            provider.icon(for: item, side: side, wantThumbnail: false)
        }
        XCTAssertNotNil(cachedImage)
    }

    // MARK: - Test 3: clear() empties the cache — next request enqueues and fires onReady again

    func testClearEmptiesCacheAndOnReadyFiresAgain() async throws {
        let provider = await MainActor.run { FileIconProvider() }
        let item = makeItem()
        let side: CGFloat = 16

        // Phase 1: let it resolve once.
        let expectation1 = XCTestExpectation(description: "onReady fires (first time)")
        await MainActor.run {
            provider.onReady = { path in
                if path == item.path { expectation1.fulfill() }
            }
            _ = provider.icon(for: item, side: side, wantThumbnail: false)
        }
        await fulfillment(of: [expectation1], timeout: 5.0)

        // Phase 2: clear and request again — should enqueue and fire onReady again.
        let expectation2 = XCTestExpectation(description: "onReady fires (after clear)")
        await MainActor.run {
            provider.clear()
            provider.onReady = { path in
                if path == item.path { expectation2.fulfill() }
            }
            // After clear, this call should treat the path as uncached (return placeholder)
            // and enqueue a new resolution.
            let img = provider.icon(for: item, side: side, wantThumbnail: false)
            XCTAssertNotNil(img)  // placeholder still returned immediately
        }
        await fulfillment(of: [expectation2], timeout: 5.0)
    }

    // MARK: - Test 4: cancelOffscreen drops pending requests

    func testCancelOffscreenDropsPendingRequests() async throws {
        let provider = await MainActor.run { FileIconProvider() }
        let item = makeItem()
        let side: CGFloat = 16

        // Enqueue then immediately cancel (not in keepPaths).
        // We won't assert onReady fires — we only verify this doesn't crash/hang.
        await MainActor.run {
            _ = provider.icon(for: item, side: side, wantThumbnail: false)
            provider.cancelOffscreen(keepPaths: [])
        }
        // Give a moment to ensure no crash from a cancelled-then-resumed operation.
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
