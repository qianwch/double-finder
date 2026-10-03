import XCTest
@testable import double_finder

final class ADBIntegrationTests: XCTestCase {
    private func fixture() throws -> (URL, ADBSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let adb = root.appendingPathComponent("adb")
        let script = """
        #!/usr/bin/env python3
        import sys,os,json,shutil,time,zipfile
        args=sys.argv[1:]
        assert args[:2]==['-s','fixture']
        with open(\(String(reflecting: root.appendingPathComponent("log").path)),'a') as f: f.write(json.dumps(args)+'\\n')
        if args[2]=='shell':
            command=args[3]
            if 'slow' in command: time.sleep(5)
            if 'for f in' in command:
                def row(name,kind): sys.stdout.buffer.write(('\\0'.join([name,kind,'7','1700000000','a1ff' if kind=='l' else '81a4','/remote' if kind=='l' else ''])+'\\0').encode())
                row('book.txt','f'); row('book.zip','f'); row('loop','l')
        elif args[2]=='pull':
            if 'failure' in args[3]: sys.exit(1)
            if args[3].endswith('.zip'):
                with zipfile.ZipFile(args[4],'w') as z: z.writestr('inside.txt','payload')
            else:
                with open(args[4],'wb') as f: f.write(b'payload')
        elif args[2]=='push':
            if 'failure' in args[4]: sys.exit(1)
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        return (root, ADBSession(device: ADBDevice(serial: "fixture", model: "Test phone", state: "device"), executablePath: adb.path))
    }

    func testSearchRemoteEndpointAvoidsSymlinkLoopAndDownloadsContent() async throws {
        let (root, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = SearchEndpoint.adb(session, base: "/remote")
        XCTAssertTrue(endpoint.isRemote)
        XCTAssertTrue(endpoint.hitsAreVirtual)
        XCTAssertFalse(endpoint.canSearchArchives)
        let hits = try await FileSearch.run(endpoint: endpoint, query: FileSearchQuery(namePattern: "*.txt", content: "payload", subfolders: true, regexName: false), report: { _, _ in })
        XCTAssertEqual(hits.map(\.path), ["/remote/book.txt"])
        let map = try await SyncScan.scan(.generic(ADBFS(session: session, currentPath: "/remote"), base: "/remote"), filterJunk: false)
        XCTAssertEqual(Set(map.keys), ["book.txt", "book.zip"])
        let log = try String(contentsOf: root.appendingPathComponent("log"))
        XCTAssertFalse(log.contains("/remote/loop"))
        XCTAssertTrue(log.contains("pull"))
    }

    func testSearchCancellationStopsListing() async throws {
        let (root, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await FileSearch.run(endpoint: .adb(session, base: "/slow"), query: FileSearchQuery(namePattern: "*", content: "", subfolders: true, regexName: false), report: { _, _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testSyncUploadDownloadAndWriteBackUseExactPathsAndPreserveSource() async throws {
        let (root, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let edited = local.appendingPathComponent("edited-temp.txt"); try Data("edited".utf8).write(to: edited)
        let fs = ADBFS(session: session, currentPath: "/remote")
        try await SyncDirsSheet.uploadGeneric(fs, localPath: edited.path, to: "/remote/nested/original.txt", above: "/remote")
        try await ADBEditWriteBack.upload(session: session, localPath: edited.path, remotePath: "/remote/original.txt")
        try await SyncDirsSheet.runFileTransfer(rel: "book.zip", from: .generic(fs, base: "/remote"), to: .local(base: local.path), report: { _ in })
        try await SyncDirsSheet.runFileTransfer(rel: "edited-temp.txt", from: .local(base: local.path), to: .generic(fs, base: "/remote"), report: { _ in })
        try await SyncDirsSheet.runFileTransfer(rel: "book.zip", from: .generic(fs, base: "/remote"), to: .generic(fs, base: "/destination"), report: { _ in })
        let archive = local.appendingPathComponent("book.zip")
        let zip = ZipFS(archivePath: archive.path)
        let archiveItems = try await zip.listDirectory(archive.path)
        XCTAssertEqual(archiveItems.filter { $0.name != ".." }.map(\.name), ["inside.txt"])
        let panel = PanelState(path: "/remote")
        panel.remote = .adb(session)
        XCTAssertTrue(panel.searchEndpoint?.isRemote == true)
        XCTAssertTrue(panel.fs is ADBFS)
        do { try await SyncDirsSheet.uploadGeneric(fs, localPath: edited.path, to: "/remote/failure", above: "/remote"); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: edited), Data("edited".utf8))
        let records = try String(contentsOf: root.appendingPathComponent("log")).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
        XCTAssertEqual(records.filter { $0[2] == "push" }.map { $0.last! }, ["/remote/nested/original.txt", "/remote/original.txt", "/remote/edited-temp.txt", "/destination/book.zip", "/remote/failure"])
        XCTAssertEqual(records.first { $0[2] == "pull" }?[3], "/remote/book.zip")
    }
}
