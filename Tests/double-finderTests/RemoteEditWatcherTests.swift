import XCTest
@testable import double_finder

final class RemoteEditWatcherTests: XCTestCase {

    func testHasChanged() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_050)
        // unchanged
        XCTAssertFalse(RemoteEditWriteBack.hasChanged(baselineModified: t0, baselineSize: 100,
                                                      currentModified: t0, currentSize: 100))
        // mtime changed
        XCTAssertTrue(RemoteEditWriteBack.hasChanged(baselineModified: t0, baselineSize: 100,
                                                     currentModified: t1, currentSize: 100))
        // size changed
        XCTAssertTrue(RemoteEditWriteBack.hasChanged(baselineModified: t0, baselineSize: 100,
                                                     currentModified: t0, currentSize: 250))
    }

    func testRemoteParentDir() {
        XCTAssertEqual(RemoteEditWriteBack.remoteParentDir(of: "/my-bucket/dir/file.txt"), "/my-bucket/dir")
        XCTAssertEqual(RemoteEditWriteBack.remoteParentDir(of: "/my-bucket/file.txt"), "/my-bucket")
        XCTAssertEqual(RemoteEditWriteBack.remoteParentDir(of: "/home/u/notes/a.md"), "/home/u/notes")
    }

    private func makeTempFile(_ contents: String) -> String {
        let dir = NSTemporaryDirectory() as NSString
        let path = dir.appendingPathComponent("rew-\(UUID().uuidString).txt")
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func attrs(_ path: String) -> (Date, Int64) {
        let a = try! FileManager.default.attributesOfItem(atPath: path)
        return ((a[.modificationDate] as! Date), (a[.size] as! NSNumber).int64Value)
    }

    func testTrackDetectsChangeThenBaselineClears() {
        let path = makeTempFile("hello")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (m, s) = attrs(path)
        let w = RemoteEditWatcher()
        w.track(RemoteEditSession(tempPath: path, remotePath: "/bucket/hello.txt",
                                  serverLabel: "bucket", baselineModified: m, baselineSize: s,
                                  upload: { _, _ in }))
        // No change yet.
        XCTAssertTrue(w.pendingChanges(fileManager: .default).isEmpty)
        // Modify the file (size grows).
        try? "hello world!!".write(toFile: path, atomically: true, encoding: .utf8)
        let changed = w.pendingChanges(fileManager: .default)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.remotePath, "/bucket/hello.txt")
        // After updating the baseline, it's no longer pending.
        let (m2, s2) = attrs(path)
        w.updateBaseline(tempPath: path, modified: m2, size: s2)
        XCTAssertTrue(w.pendingChanges(fileManager: .default).isEmpty)
    }

    func testPendingDropsMissingFile() {
        let path = makeTempFile("x")
        let (m, s) = attrs(path)
        let w = RemoteEditWatcher()
        w.track(RemoteEditSession(tempPath: path, remotePath: "/b/x", serverLabel: "b",
                                  baselineModified: m, baselineSize: s, upload: { _, _ in }))
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(w.pendingChanges(fileManager: .default).isEmpty)
        XCTAssertTrue(w.sessions.isEmpty)   // dropped
    }

    func testTrackDedupesByTempPath() {
        let w = RemoteEditWatcher()
        let s1 = RemoteEditSession(tempPath: "/tmp/a", remotePath: "/b/a", serverLabel: "b",
                                   baselineModified: Date(), baselineSize: 1, upload: { _, _ in })
        let s2 = RemoteEditSession(tempPath: "/tmp/a", remotePath: "/c/a", serverLabel: "c",
                                   baselineModified: Date(), baselineSize: 2, upload: { _, _ in })
        w.track(s1); w.track(s2)
        XCTAssertEqual(w.sessions.count, 1)
        XCTAssertEqual(w.sessions.first?.remotePath, "/c/a")   // replaced
    }
}
