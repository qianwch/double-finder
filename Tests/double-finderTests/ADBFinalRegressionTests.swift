import AppKit
import XCTest
@testable import double_finder

final class ADBFinalRegressionTests: XCTestCase {
    private func fixture() throws -> (URL, ADBSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-final-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("adb")
        try """
        #!/usr/bin/env python3
        import sys,time,zipfile,os
        assert sys.argv[1:3] == ['-s','fixture']
        if sys.argv[3] == 'shell':
            command=sys.argv[4]
            if command.startswith('hold '):
                open(command[5:], 'w').close()
                time.sleep(10)
            elif command == 'printf alive': sys.stdout.write('alive')
        elif sys.argv[3] == 'pull':
            with zipfile.ZipFile(sys.argv[5], 'w') as archive: archive.writestr('inside.txt','payload')
        else: sys.exit(2)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, ADBSession(device: ADBDevice(serial: "fixture", model: "Phone", state: "device"), executablePath: executable.path))
    }

    @MainActor private func waitForLoads(_ panels: [PanelState]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while panels.contains(where: { $0.isLoading }) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(panels.contains(where: { $0.isLoading }))
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: url.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testRepeatedConnectionKeepsBothPanelsArchiveReturnAndCapturedCommandsAliveUntilEject() async throws {
        let (root, original) = try fixture()
        let store = RemoteSessionStore.shared
        store.removeAll()
        defer { store.removeAll(); try? FileManager.default.removeItem(at: root) }
        let left = PanelState(path: root.path), right = PanelState(path: root.path)
        left.connect(.adb(original), initialPath: "/sdcard")
        try await waitForLoads([left])
        let oldReturn = try XCTUnwrap(left.remote)
        let started = root.appendingPathComponent("started")
        let captured = Task { try await ADBClient(session: original).shell("hold " + started.path) }
        try await waitForFile(started)
        let duplicate = ADBSession(device: original.device, executablePath: "/does-not-exist")
        right.connect(.adb(duplicate), initialPath: "/sdcard")
        XCTAssertTrue(right.remote?.adbSession?.lifetime === original.lifetime)
        XCTAssertEqual(right.remote?.adbSession?.executablePath, original.executablePath)
        XCTAssertFalse(original.lifetime.isRemoved)
        try await waitForLoads([right])
        for panel in [left, right] {
            guard let session = panel.remote?.adbSession else { XCTFail("Panel lost its live session"); continue }
            do { let reply = try await ADBClient(session: session).shell("printf alive"); XCTAssertEqual(reply, Data("alive".utf8)) }
            catch { XCTFail("Repeated connection broke a panel: \(error)") }
        }
        let archive = root.appendingPathComponent("book.zip")
        // Use the saved return session exactly as a downloaded archive does.
        try await ADBClient(session: try XCTUnwrap(store.session(withID: original.id)?.adbSession)).download(path: "/sdcard/book.zip", to: archive.path)
        left.enterDownloadedArchive(localArchive: archive.path, from: oldReturn, remoteDir: "/sdcard")
        try await waitForLoads([left])
        right.connect(.adb(ADBSession(device: original.device, executablePath: "/another-missing-adb")), initialPath: "/sdcard")
        try await waitForLoads([right])
        left.goUp()
        XCTAssertTrue(left.remote?.adbSession?.lifetime === original.lifetime)
        XCTAssertFalse(original.lifetime.isRemoved)
        try await waitForLoads([left])
        let sessions = [try XCTUnwrap(left.remote?.adbSession), try XCTUnwrap(right.remote?.adbSession)]
        store.remove(id: original.id)
        for session in sessions {
            do { _ = try await ADBClient(session: session).shell("printf alive"); XCTFail("Eject must reject all panel captures") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        do { _ = try await captured.value; XCTFail("Eject must terminate an already running capture") }
        catch { XCTAssertTrue(error is CancellationError) }
        left.leaveRemovedSessions(existingIDs: store.ids); right.leaveRemovedSessions(existingIDs: store.ids)
        try await waitForLoads([left, right])
        XCTAssertNil(left.remote); XCTAssertNil(right.remote)
        store.register(oldReturn)
        XCTAssertNil(store.session(withID: original.id), "An invalidated archive return must not resurrect")
        left.connect(oldReturn, initialPath: "/sdcard")
        XCTAssertNil(left.remote)
        try await waitForLoads([left])
        // A newly discovered connection is allowed, while an old return resolves to it.
        let fresh = ADBSession(device: original.device, executablePath: original.executablePath)
        right.connect(.adb(fresh), initialPath: "/sdcard")
        left.connect(oldReturn, initialPath: "/sdcard")
        XCTAssertTrue(left.remote?.adbSession?.lifetime === fresh.lifetime)
        try await waitForLoads([left, right])
    }

    @MainActor func testRemoteServicesRejectStaleLocalSelectionAndClearCache() {
        let view = FileListBodyView(frame: .zero)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/local-file")]
        view.serviceURLs = urls
        XCTAssertTrue(view.validRequestor(forSendType: .fileURL, returnType: nil) as? FileListBodyView === view)
        view.allowsLocalFileURLs = false
        XCTAssertTrue(view.serviceURLs.isEmpty)
        // Even if a caller accidentally repopulates the cache, both entry points refuse it.
        view.serviceURLs = urls
        for type in [NSPasteboard.PasteboardType.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")] {
            XCTAssertNil(view.validRequestor(forSendType: type, returnType: nil))
            XCTAssertFalse(view.writeSelection(to: board, types: [type]))
        }
        XCTAssertNil(board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")))
    }
    @MainActor func testDownloadedArchiveExitRemovesOwnedRootButPreservesSharedNeighbors() async throws {
        let (root, session) = try fixture()
        let store = RemoteSessionStore.shared
        store.removeAll()
        defer { store.removeAll(); try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let neighbor = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: neighbor)
        let archive = owned.appendingPathComponent("book.zip")
        try await ADBClient(session: session).download(path: "/sdcard/book.zip", to: archive.path)
        let panel = PanelState(path: root.path)
        panel.connect(.adb(session), initialPath: "/sdcard")
        try await waitForLoads([panel])
        panel.enterDownloadedArchive(localArchive: archive.path, from: .adb(session), remoteDir: "/sdcard",
                                     ownedTemporaryRoot: owned.path)
        try await waitForLoads([panel])
        panel.goUp()
        try await waitForLoads([panel])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: neighbor), Data("keep".utf8))
        // Backends without ownership metadata only delete their downloaded file.
        let sharedArchive = root.appendingPathComponent("shared.zip")
        try await ADBClient(session: session).download(path: "/sdcard/book.zip", to: sharedArchive.path)
        panel.enterDownloadedArchive(localArchive: sharedArchive.path, from: .adb(session), remoteDir: "/sdcard")
        try await waitForLoads([panel])
        panel.goUp()
        try await waitForLoads([panel])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedArchive.path))
        XCTAssertEqual(try Data(contentsOf: neighbor), Data("keep".utf8))
    }

    @MainActor func testCanonicalSessionMergesWirelessEndpointWithoutChangingExecutableOrLifetime() throws {
        let store = RemoteSessionStore()
        defer { store.removeAll() }
        let device = ADBDevice(serial: "fixture", model: "Phone", state: "device")
        let first = ADBSession(device: device, executablePath: "/fixed/adb")
        let duplicate = ADBSession(device: device, executablePath: "/changed/adb", networkEndpoint: "phone.example:5555")
        _ = store.register(.adb(first))
        let effective = try XCTUnwrap(store.register(.adb(duplicate))?.adbSession)
        XCTAssertEqual(effective.executablePath, "/fixed/adb")
        XCTAssertEqual(effective.networkEndpoint, "phone.example:5555")
        XCTAssertTrue(effective.lifetime === first.lifetime)
        XCTAssertFalse(first.lifetime.isRemoved)
        let stale = ADBSession(device: device, executablePath: "/stale/adb", networkEndpoint: "other.example:5555")
        stale.invalidate()
        let resolved = try XCTUnwrap(store.register(.adb(stale))?.adbSession)
        XCTAssertTrue(resolved.lifetime === first.lifetime)
        XCTAssertEqual(resolved.networkEndpoint, "phone.example:5555")
        store.removeAll()
        XCTAssertNil(store.register(.adb(stale)))
        XCTAssertTrue(store.sessions.isEmpty)
    }

}
