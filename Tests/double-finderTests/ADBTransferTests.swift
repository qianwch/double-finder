import XCTest
@testable import double_finder

final class ADBTransferTests: XCTestCase {
    struct Fixture {
        let root: URL
        let session: ADBSession
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let stat = root.appendingPathComponent("stat")
            try """
            #!/usr/bin/env python3
            import os,sys
            s=os.lstat(sys.argv[3]); print({'%s':s.st_size,'%Y':int(s.st_mtime),'%f':format(s.st_mode,'x')}[sys.argv[2]])
            """.write(to: stat, atomically: true, encoding: .utf8)
            let adb = root.appendingPathComponent("adb")
            try """
            #!/usr/bin/env python3
            import os,sys,subprocess,shutil,time
            assert sys.argv[1:3]==['-s','fixture']
            args=sys.argv[3:]
            command=args[1].split('\\n(\\n',1)[1].split('\\n) 2>&1',1)[0] if args[0]=='exec-out' else ' '.join(args)
            copying=args[0] in ['push','pull'] or 'cp ' in command
            if copying and 'fail-child' in command: sys.exit(1)
            if copying and 'slow-child' in command: time.sleep(5)
            if args[0]=='exec-out':
                if command.startswith('rm -r ') and 'commit-source' in command:
                    open(\(String(reflecting: root.appendingPathComponent("commit-started").path)), 'w').close()
                    deadline=time.monotonic()+5
                    while not os.path.exists(\(String(reflecting: root.appendingPathComponent("commit-release").path))):
                        if time.monotonic() > deadline: sys.exit(3)
                        time.sleep(0.005)
                env=os.environ.copy(); env['PATH']=\(String(reflecting: root.path))+':'+env['PATH']
                sys.exit(subprocess.call(['/bin/sh','-c',args[1]],env=env))
            elif args[0] in ['pull','push']: shutil.copyfile(args[1],args[2])
            else: sys.exit(2)
            """.write(to: adb, atomically: true, encoding: .utf8)
            for file in [stat, adb] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
            session = ADBSession(device: ADBDevice(serial: "fixture", model: "Phone", state: "device"), executablePath: adb.path)
        }
        func directory(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func file(_ path: String, _ text: String = "payload") throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
    @MainActor func testIdentityAndProviderDispatch() {
        let a = ADBSession(device: ADBDevice(serial: "a", model: "Phone", state: "device"), executablePath: "/fake")
        let b = ADBSession(device: ADBDevice(serial: "b", model: "Phone", state: "device"), executablePath: "/fake")
        XCTAssertEqual(RemoteSession.adb(a).id, "adb://a")
        XCTAssertTrue(RemoteSession.adb(a).sharesNamespace(with: .adb(a)))
        XCTAssertFalse(RemoteSession.adb(a).sharesNamespace(with: .adb(b)))
        XCTAssertTrue(RemoteSession.adb(a).transferProvider(download: true) is ADBTransferProvider)
        XCTAssertTrue(RemoteSession.adb(a).sameStoreProvider(move: true) is ADBTransferProvider)
    }
    @MainActor func testPlannerDirectionsAndOperationRename() async throws {
        let f = try Fixture(); defer { f.close() }
        let remote = RemoteSession.adb(f.session)
        XCTAssertTrue(try TransferPlanner.remoteProvider(from: remote, to: nil, move: false) is ADBTransferProvider)
        XCTAssertTrue(try TransferPlanner.remoteProvider(from: nil, to: remote, move: false) is ADBTransferProvider)
        XCTAssertThrowsError(try TransferPlanner.remoteProvider(from: remote, to: .sftp(SFTPConnection(host: "other", user: "test")), move: true))
        let source = try f.directory("op-source"), destination = try f.directory("op-target")
        try f.file(source + "/original")
        let listing = try await ADBClient(session: f.session).list(source)
        let item = try XCTUnwrap(listing.first)
        let op = ADBTransferProvider(session: f.session, mode: .download).makeOperation(items: [item], destPath: destination, renameTo: "new-name")
        XCTAssertTrue(op.indeterminate)
        try await op.perItemOperation?(item.path)
        XCTAssertEqual(try String(contentsOfFile: destination + "/new-name"), "payload")
    }
    @MainActor func testMaterializedUploadUsesExplicitDirectionAndCleansTemporaryFiles() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.directory("materialized-source"), destination = try f.directory("materialized-target")
        try f.file(source + "/entry")
        let listing = try await ADBClient(session: f.session).list(source)
        let item = try XCTUnwrap(listing.first)
        let temporaryRoot = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).filter { $0.hasPrefix("df-adb-materialize-") })
        let op = ADBMaterializedUploadProvider(srcFS: LocalFS(), session: f.session).makeOperation(items: [item], destPath: destination, renameTo: "saved")
        try await op.perItemOperation?(item.path)
        XCTAssertEqual(try String(contentsOfFile: destination + "/saved"), "payload")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).filter { $0.hasPrefix("df-adb-materialize-") }), before)
        try f.file(source + "/fail-child")
        let failedListing = try await ADBClient(session: f.session).list(source)
        let failedItem = try XCTUnwrap(failedListing.first { $0.name == "fail-child" })
        let failedOp = ADBMaterializedUploadProvider(srcFS: LocalFS(), session: f.session).makeOperation(items: [failedItem], destPath: destination, renameTo: nil)
        do { try await failedOp.perItemOperation?(failedItem.path); XCTFail("Fake upload should fail") } catch {}
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).filter { $0.hasPrefix("df-adb-materialize-") }), before)
        XCTAssertEqual(try String(contentsOfFile: failedItem.path), "payload")
    }
    func testDirectoryMergeHiddenNamesAndRenameBothDirections() async throws {
        let f = try Fixture(); defer { f.close() }
        for mode in [ADBTransferProvider.Mode.download, .upload, .within(move: false)] {
            let source = try f.directory(UUID().uuidString)
            let destination = try f.directory(UUID().uuidString)
            try f.file(source + "/.中文 ' 换行\n", "new")
            try f.file(destination + "/.中文 ' 换行\n", "old")
            try f.file(destination + "/keep", "kept")
            try await ADBTransferProvider(session: f.session, mode: mode).transferTree(from: source, to: destination, isDirectory: true)
            XCTAssertEqual(try String(contentsOfFile: destination + "/.中文 ' 换行\n"), "new")
            XCTAssertEqual(try String(contentsOfFile: destination + "/keep"), "kept")
            let target = destination + "/renamed"
            try await ADBTransferProvider(session: f.session, mode: mode).transferTree(from: source + "/.中文 ' 换行\n", to: target, isDirectory: false)
            XCTAssertEqual(try String(contentsOfFile: target), "new")
        }
    }
    func testMoveRetentionAndCommit() async throws {
        let f = try Fixture(); defer { f.close() }
        for name in ["good", "fail-child", "slow-child"] {
            let source = try f.directory(name + "-source"), destination = try f.directory(name + "-target")
            try f.file(source + "/" + name)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            do {
                try await ADBTransferProvider(session: f.session, mode: .within(move: true)).transferTree(from: source, to: destination, isDirectory: true, isCancelled: { name == "slow-child" && ProcessInfo.processInfo.systemUptime >= deadline })
                XCTAssertEqual(name, "good")
                XCTAssertFalse(FileManager.default.fileExists(atPath: source))
            } catch {
                XCTAssertNotEqual(name, "good")
                XCTAssertEqual(try String(contentsOfFile: source + "/" + name), "payload")
            }
        }
    }
    func testSymlinkIsRejectedForPushPullAndPreservedWithin() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.directory("source"), destination = try f.directory("target")
        try FileManager.default.createSymbolicLink(atPath: source + "/loop", withDestinationPath: source)
        for mode in [ADBTransferProvider.Mode.upload, .download] {
            do { try await ADBTransferProvider(session: f.session, mode: mode).transferTree(from: source, to: destination, isDirectory: true); XCTFail("Symlink must not be dereferenced") } catch {}
        }
        try await ADBTransferProvider(session: f.session, mode: .within(move: false)).transferTree(from: source, to: destination, isDirectory: true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination + "/loop"), source)
    }
    func testDeviceAliasesRejectSameAndDescendantBeforeWriting() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.directory("real")
        try f.file(source + "/payload")
        let alias = f.root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: source)
        for target in [alias, alias + "/nested"] {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            do {
                try await ADBTransferProvider(session: f.session, mode: .within(move: true)).transferTree(from: source, to: target, isDirectory: true, isCancelled: { ProcessInfo.processInfo.systemUptime >= deadline })
                XCTFail("Canonical self-transfer must be rejected")
            } catch {}
            XCTAssertEqual(try String(contentsOfFile: source + "/payload"), "payload")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source + "/nested"))
        }
    }
    func testExistingLeafTargetLinksAreRejectedWithoutChangingReferent() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.directory("leaf-source"), destination = try f.directory("leaf-target")
        try f.file(source + "/foo", "new-content")
        try f.file(source + "/bar", "original")
        try FileManager.default.createSymbolicLink(atPath: destination + "/foo", withDestinationPath: source + "/bar")
        for mode in [ADBTransferProvider.Mode.within(move: true), .upload, .download] {
            do {
                try await ADBTransferProvider(session: f.session, mode: mode).transferTree(from: source, to: destination, isDirectory: true)
                XCTFail("Existing leaf link must reject transfer")
            } catch {}
            XCTAssertEqual(try String(contentsOfFile: source + "/bar"), "original")
            XCTAssertEqual(try String(contentsOfFile: source + "/foo"), "new-content")
            // Keep the fixture independent if a buggy move deleted its source.
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
            try f.file(source + "/foo", "new-content")
            try f.file(source + "/bar", "original")
        }
        let client = ADBClient(session: f.session)
        for direction in ["within", "upload", "download"] {
            do {
                switch direction {
                case "within": try await client.transfer(from: source + "/foo", to: destination + "/foo", move: false)
                case "upload": try await client.upload(localPath: source + "/foo", to: destination + "/foo")
                default: try await client.download(path: source + "/foo", to: destination + "/foo")
                }
                XCTFail("Direct client target link must reject transfer")
            } catch {}
            XCTAssertEqual(try String(contentsOfFile: source + "/bar"), "original")
            try f.file(source + "/bar", "original")
        }
    }
    func testTopLevelDanglingAndDirectoryLinksAreCopiedAsLinks() async throws {
        let f = try Fixture(); defer { f.close() }
        let referent = try f.directory("referent")
        let directoryLink = f.root.appendingPathComponent("directory-link").path
        let danglingLink = f.root.appendingPathComponent("dangling-link").path
        try FileManager.default.createSymbolicLink(atPath: directoryLink, withDestinationPath: referent)
        try FileManager.default.createSymbolicLink(atPath: danglingLink, withDestinationPath: f.root.appendingPathComponent("absent").path)
        let provider = ADBTransferProvider(session: f.session, mode: .within(move: false))
        try await provider.transferTree(from: directoryLink, to: referent + "/copied-link", isDirectory: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: referent + "/copied-link"), referent)
        try await provider.transferTree(from: danglingLink, to: referent + "/copied-dangling", isDirectory: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: referent + "/copied-dangling"), f.root.appendingPathComponent("absent").path)
    }
    func testDirectMaterializeAndWritebackRejectFileSymlinks() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("file").path
        try f.file(source)
        let link = f.root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)
        let client = ADBClient(session: f.session)
        do { try await client.download(path: link, to: f.root.appendingPathComponent("pulled").path); XCTFail("Direct materialize must not dereference") } catch {}
        do { try await client.upload(localPath: link, to: f.root.appendingPathComponent("pushed").path); XCTFail("Writeback must not dereference") } catch {}
    }
    @MainActor func testRemovalCancelsOwnedCommandsAndRejectsStaleSession() async throws {
        let f = try Fixture(); defer { f.close() }
        let store = RemoteSessionStore()
        store.register(.adb(f.session))
        let task = Task { try await ADBClient(session: f.session).shell("sleep 10") }
        try await Task.sleep(nanoseconds: 100_000_000)
        store.remove(id: f.session.id)
        do { _ = try await task.value; XCTFail("Removed session command must cancel") } catch {}
        do { _ = try await ADBClient(session: f.session).shell("true"); XCTFail("Stale session must reject commands") } catch {}
    }
    /// The marker controls process ordering; the polling interval only waits for it.
    private func waitForCommitMarker(_ url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: url.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Delete commit did not start")
    }

    func testSharedCommitRejectsCancellationAfterCopyCompletedWithoutStartingRM() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("commit-source").path
        let destination = f.root.appendingPathComponent("commit-target").path
        try f.file(source)
        let client = ADBClient(session: f.session)
        try await client.transfer(from: source, to: destination, move: false)
        XCTAssertEqual(try String(contentsOfFile: destination), "payload", "The copy must be complete before cancellation")
        // If the final guard regresses, let rm finish so the assertions detect deletion.
        try f.file(f.root.appendingPathComponent("commit-release").path)
        do { try await client.commitRemoval(source, isCancelled: { true }); XCTFail("Last cancellation check must preserve source") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOfFile: source), "payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("commit-started").path), "No rm may start before commit")
    }

    func testDirectAndQueuedDeleteCommitFinishAfterNewTaskQueueAndSessionCancellation() async throws {
        for queued in [false, true] {
            let f = try Fixture(); defer { f.close() }
            let source = f.root.appendingPathComponent("commit-source").path
            let destination = f.root.appendingPathComponent("commit-target").path
            try f.file(source)
            let cancelled = ADBSessionLifetime()
            let task = Task {
                if queued {
                    try await ADBTransferProvider(session: f.session, mode: .within(move: true)).transferTree(
                        from: source, to: destination, isDirectory: false, isCancelled: { cancelled.isRemoved })
                } else {
                    try await ADBClient(session: f.session).transfer(from: source, to: destination, move: true,
                                                                   isCancelled: { cancelled.isRemoved })
                }
            }
            try await waitForCommitMarker(f.root.appendingPathComponent("commit-started"))
            XCTAssertEqual(try String(contentsOfFile: destination), "payload")
            XCTAssertEqual(try String(contentsOfFile: source), "payload", "rm is held before deleting the source")
            task.cancel()
            cancelled.invalidate()
            f.session.invalidate()
            try f.file(f.root.appendingPathComponent("commit-release").path)
            try await task.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: source), "New cancellation must not interrupt deletion already committing")
            XCTAssertEqual(try String(contentsOfFile: destination), "payload")
        }
    }

}
