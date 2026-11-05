import XCTest
@testable import double_finder

@MainActor
final class ArchiveRemoteTransferTests: XCTestCase {
    func testLiveSFTPArchiveCopyPackAndRemoteDirectoryExport() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ARCHIVE_SFTP_LIVE"] == "1", "set ARCHIVE_SFTP_LIVE=1 for a live SFTP regression")
        let connection = SFTPConnection(host: env["ARCHIVE_SFTP_HOST"] ?? "localhost",
                                        user: env["ARCHIVE_SFTP_USER"] ?? NSUserName())
        let fs = SFTPFS(connection: connection)
        let remote = "/tmp/df-archive-test-" + UUID().uuidString
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        try await fs.createDirectory(remote)
        do {
            let archive = try await makeArchive(in: local)
            let source = ZipFS(archivePath: archive.path)
            let entries = try await source.listDirectory(archive.path)
            let tree = try XCTUnwrap(entries.first { $0.name == "tree" })
            let copy = MaterializedUploadProvider(srcFS: source, destFS: fs)
                .makeOperation(items: [tree], destPath: remote, renameTo: "copied")
            await run(copy)
            XCTAssertTrue(copy.failures.isEmpty, "\(copy.failures)")
            let copied = local.appendingPathComponent("copied-out")
            try await fs.exportItem(at: remote + "/copied", toLocalDirectory: copied, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("copied/sub/file.txt")), Data("inside archive".utf8))
            let pack = PackProvider(destinationFS: fs).makeOperation(
                archivePath: remote + "/packed.zip", sources: [local.appendingPathComponent("tree").path],
                opts: .init(baseName: "packed", format: .builtIn(.zip), level: 0, password: nil, volumeSize: nil),
                baseDir: nil, total: 14)
            await run(pack)
            XCTAssertTrue(pack.failures.isEmpty, "\(pack.failures)")
            let remoteArchive = RemoteArchiveFS(connection: connection, archivePath: remote + "/packed.zip")
            let output = local.appendingPathComponent("remote-export")
            try await remoteArchive.exportItem(at: remote + "/packed.zip/tree", toLocalDirectory: output, progress: { _ in })
            XCTAssertEqual(try? Data(contentsOf: output.appendingPathComponent("tree/sub/file.txt")), Data("inside archive".utf8))
            var directory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("tree/empty").path, isDirectory: &directory) && directory.boolValue)
        } catch {
            _ = try? await fs.runCheckedCommand("rm -rf -- " + SFTPFS.shellQuote(remote))
            throw error
        }
        _ = try await fs.runCheckedCommand("rm -rf -- " + SFTPFS.shellQuote(remote))
    }

    func testSFTPContentCancellationTerminatesRunningProcess() async throws {
        let started = expectation(description: "content process launched")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let task = Task {
            try await SSHProcessBox.run { box in
                try box.launch(process)
                started.fulfill()
                process.waitUntilExit()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("cancelled content transfer succeeded") }
        catch is CancellationError {}
        XCTAssertFalse(process.isRunning)
    }

    func testLocalOverwriteAndRenameFollowVolumeCaseRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: root.appendingPathComponent("Output.zip"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("OUTPUT 2.zip"))
        let provider = PackProvider(destinationFS: nil)
        let exists = try await provider.outputExists(at: root.appendingPathComponent("output.zip").path)
        XCTAssertEqual(exists, FileManager.default.fileExists(atPath: root.appendingPathComponent("output.zip").path))
        let suggested = try await provider.suggestedName(after: "output", extension: ".zip", directory: root.path, split: false)
        XCTAssertEqual(suggested, exists ? "output 3" : "output 2")
    }

    func testPackingSameNamedVirtualSourcesKeepsBothContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var paths: [String] = []
        for name in ["one", "two"] {
            let leaf = name == "one" ? "File.txt" : "file.txt"
            let file = root.appendingPathComponent(leaf)
            try Data(name.utf8).write(to: file)
            let archive = root.appendingPathComponent(name + ".zip")
            try await LocalFS().createArchive(sources: [file.path], to: archive.path, format: .zip, level: 0, password: nil)
            paths.append(archive.path + "/" + leaf)
        }
        let output = root.appendingPathComponent("output.zip")
        let op = PackProvider(sourceFS: SearchResultsFS(currentPath: root.path), destinationFS: nil).makeOperation(
            archivePath: output.path, sources: paths,
            opts: .init(baseName: "output", format: .builtIn(.zip), level: 0, password: nil, volumeSize: nil),
            baseDir: nil, total: 0)
        await run(op)
        XCTAssertTrue(op.failures.isEmpty, "\(op.failures)")
        let out = root.appendingPathComponent("out")
        for name in ["one", "two"] {
            let leaf = name == "one" ? "File.txt" : "file.txt"
            try await ZipFS(archivePath: output.path).exportItem(at: output.path + "/" + name + ".zip/" + leaf,
                                                               toLocalDirectory: out, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(leaf)), Data(name.utf8))
        }
    }

    func testArchiveDirectoryCaseCollisionCannotSilentlyOverwriteStagedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one"), second = root.appendingPathComponent("two")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let archive = root.appendingPathComponent("source.zip")
        try LibArchive.create(sources: [(first.path, "tree/Foo.txt"), (second.path, "tree/foo.txt")],
                              to: archive.path, format: .zip, level: 0, password: nil)
        let fs = ZipFS(archivePath: archive.path)
        let items = try await fs.listDirectory(archive.path)
        let tree = try XCTUnwrap(items.first { $0.name == "tree" })
        let destination = RecordingSFTPFS()
        let op = MaterializedUploadProvider(srcFS: fs, destFS: destination)
            .makeOperation(items: [tree], destPath: "/remote")
        await run(op)
        let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        if sensitive {
            XCTAssertTrue(op.failures.isEmpty)
            XCTAssertEqual(destination.uploaded["/remote/tree/Foo.txt"], Data("first".utf8))
            XCTAssertEqual(destination.uploaded["/remote/tree/foo.txt"], Data("second".utf8))
        } else {
            XCTAssertEqual(op.failures.count, 1)
            XCTAssertTrue(destination.uploaded.isEmpty)
        }
    }

    private func makeArchive(in root: URL) async throws -> URL {
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("inside archive".utf8).write(to: tree.appendingPathComponent("sub/file.txt"))
        let archive = root.appendingPathComponent("source.zip")
        try await LocalFS().createArchive(sources: [tree.path], to: archive.path, format: .zip, level: 0, password: nil)
        return archive
    }

    func testArchiveTreeAndRenamedFileReachS3ThroughRealHTTP() async throws {
        let server = try LocalS3HTTPFixture(); defer { server.stop() }
        let archive = try await makeArchive(in: server.root)
        let source = PanelState(path: archive.path)
        let destination = PanelState(path: "/bucket/output")
        destination.remote = .s3(S3Connection(name: "fixture", endpoint: server.base.absoluteString, region: "test",
                                             bucket: "bucket", accessKey: "test", pathStyle: true), secret: "test")
        let provider = try MainViewController().transferProvider(forCopyFrom: source, to: destination)
        let items = try await source.fs.listDirectory(archive.path)
        let tree = try XCTUnwrap(items.first { $0.name == "tree" })
        let op = provider.makeOperation(items: [tree], destPath: "/bucket/output", renameTo: "renamed")
        await run(op)
        XCTAssertTrue(op.failures.isEmpty, "\(op.failures)")
        XCTAssertEqual(try server.objects()["output/renamed/sub/file.txt"], Data("inside archive".utf8))
        XCTAssertEqual(try server.objects()["output/renamed/empty/"], Data())
        let children = try await source.fs.listDirectory(archive.path + "/tree/sub")
        let file = try XCTUnwrap(children.first { $0.name == "file.txt" })
        let second = provider.makeOperation(items: [file], destPath: "/bucket/output", renameTo: "renamed.txt")
        await run(second)
        XCTAssertTrue(second.failures.isEmpty, "\(second.failures)")
        XCTAssertEqual(try server.objects()["output/renamed.txt"], Data("inside archive".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testArchiveExportReachesSFTPExactTargetAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await makeArchive(in: root)
        let source = ZipFS(archivePath: archive.path)
        let entries = try await source.listDirectory(archive.path)
        let tree = try XCTUnwrap(entries.first { $0.name == "tree" })
        let destination = RecordingSFTPFS()
        let op = MaterializedUploadProvider(srcFS: source, destFS: destination)
            .makeOperation(items: [tree], destPath: "/remote", renameTo: "renamed")
        await run(op)
        XCTAssertTrue(op.failures.isEmpty, "\(op.failures)")
        XCTAssertEqual(destination.uploaded["/remote/renamed/sub/file.txt"], Data("inside archive".utf8))
        XCTAssertTrue(destination.commands.contains { $0.contains("mkdir -p -- '/remote/renamed/empty'") })
        XCTAssertFalse(destination.localPaths.isEmpty)
        XCTAssertTrue(destination.localPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testPackToS3UploadsAnActualReadableArchive() async throws {
        let server = try LocalS3HTTPFixture(); defer { server.stop() }
        try server.seed("keep.txt", Data("keep".utf8))
        let file = server.root.appendingPathComponent("source.txt")
        try Data("packed content".utf8).write(to: file)
        let store = S3FS(client: S3Client(endpoint: S3Endpoint(base: server.base, region: "test", pathStyle: true),
                                        signer: S3Signer(accessKey: "test", secretKey: "test", region: "test")),
                         currentPath: "/bucket")
        let op = PackProvider(destinationFS: store).makeOperation(
            archivePath: "/bucket/output.zip", sources: [file.path],
            opts: .init(baseName: "output", format: .builtIn(.zip), level: 0, password: nil, volumeSize: nil),
            baseDir: nil, total: 14)
        await run(op)
        XCTAssertTrue(op.failures.isEmpty, "\(op.failures)")
        let bytes = try XCTUnwrap(server.objects()["output.zip"])
        let downloaded = server.root.appendingPathComponent("downloaded.zip")
        try bytes.write(to: downloaded)
        let out = server.root.appendingPathComponent("extracted")
        try await ZipFS(archivePath: downloaded.path).exportItem(
            at: downloaded.path + "/source.txt", toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("source.txt")), Data("packed content".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("packed content".utf8))
    }

    func testSplitPackToSFTPChecksRemoteNamesAndUploadsEveryVolume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let content = Data((0..<8192).map { UInt8($0 % 251) })
        try content.write(to: source)
        let destination = RecordingSFTPFS()
        destination.uploaded["/remote/output.zip.001"] = Data("old".utf8)
        destination.uploaded["/remote/output.zip.999"] = Data("stale".utf8)
        destination.uploaded["/remote/output.zip.txt"] = Data("keep".utf8)
        let provider = PackProvider(destinationFS: destination)
        let existing = try await provider.existingNames(in: "/remote")
        XCTAssertTrue(existing.contains("output.zip.001"))
        let op = provider.makeOperation(archivePath: "/remote/output.zip", sources: [source.path],
            opts: .init(baseName: "output", format: .builtIn(.zip), level: 0, password: nil, volumeSize: 1024),
            baseDir: nil, total: Int64(content.count))
        await run(op)
        XCTAssertTrue(op.failures.isEmpty, "\(op.failures)")
        let names = destination.uploaded.keys.filter { $0.hasSuffix("zip.001") || $0.hasSuffix("zip.002") }
        XCTAssertEqual(names.count, 2)
        XCTAssertNil(destination.uploaded["/remote/output.zip.999"])
        XCTAssertEqual(destination.uploaded["/remote/output.zip.txt"], Data("keep".utf8))
        let joined = destination.uploaded.keys.filter { PackProvider.isVolume(($0 as NSString).lastPathComponent, of: "output.zip") }
            .sorted().reduce(into: Data()) { $0.append(destination.uploaded[$1]!) }
        let archive = root.appendingPathComponent("joined.zip")
        try joined.write(to: archive)
        let out = root.appendingPathComponent("out")
        try await ZipFS(archivePath: archive.path).exportItem(at: archive.path + "/source.bin", toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("source.bin")), content)
        XCTAssertTrue(destination.localPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testPackUploadFailureCleansStagingAndKeepsLocalPathCollision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let collision = root.appendingPathComponent("output.zip")
        try Data("source".utf8).write(to: source)
        try Data("local sentinel".utf8).write(to: collision)
        let destination = RecordingSFTPFS()
        destination.failUpload = true
        let op = PackProvider(destinationFS: destination).makeOperation(
            archivePath: collision.path, sources: [source.path],
            opts: .init(baseName: "output", format: .builtIn(.zip), level: 0, password: nil, volumeSize: nil),
            baseDir: nil, total: 6)
        await run(op)
        XCTAssertEqual(op.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: collision), Data("local sentinel".utf8))
        XCTAssertFalse(destination.localPaths.isEmpty)
        XCTAssertTrue(destination.localPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testFailedSourceExportPreservesExistingLocalArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.zip")
        try Data("existing archive".utf8).write(to: output)
        let missing = root.appendingPathComponent("missing.zip").path
        let op = PackProvider(sourceFS: ZipFS(archivePath: missing), destinationFS: nil).makeOperation(
            archivePath: output.path, sources: [missing + "/file.txt"],
            opts: .init(baseName: "output", format: .builtIn(.zip), level: 0, password: nil, volumeSize: nil),
            baseDir: nil, total: 0)
        await run(op)
        XCTAssertEqual(op.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("existing archive".utf8))
    }

    private func run(_ op: FileOperation) async {
        await withCheckedContinuation { continuation in
            op.onComplete = { continuation.resume() }
            op.start()
        }
    }

    func testArchiveSourcesDoNotUseRawSFTPorS3UploadPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("source.zip")
        try Data().write(to: archive)
        let source = PanelState(path: archive.path + "/folder")
        let destinations: [RemoteSession] = [
            .sftp(SFTPConnection(host: "fixture", user: "test")),
            .s3(S3Connection(name: "fixture", endpoint: "http://127.0.0.1", region: "test",
                             bucket: "bucket", accessKey: "test", pathStyle: true), secret: "test")
        ]
        for session in destinations {
            let destination = PanelState(path: "/bucket/output")
            destination.remote = session
            let provider = try MainViewController().transferProvider(forCopyFrom: source, to: destination)
            XCTAssertFalse(provider is SFTPTransferProvider, "Virtual archive paths cannot be passed to scp")
            XCTAssertFalse(provider is S3TransferProvider, "Virtual archive paths cannot be read as local files")
        }
    }
}

/// Replace SSH transport only; exercise the real SFTPFS import tree and exact paths.
private final class RecordingSFTPFS: SFTPFS {
    var uploaded: [String: Data] = [:]
    var localPaths: [String] = []
    var commands: [String] = []
    var failUpload = false
    init() { super.init(connection: SFTPConnection(host: "fixture", user: "test")) }
    override func runCheckedCommand(_ command: String) async throws -> String {
        commands.append(command)
        return ""
    }
    override func uploadFile(localPath: String, toPath remotePath: String) async throws {
        localPaths.append(localPath)
        if failUpload { throw FSUnsupportedError(message: "fixture upload failed") }
        uploaded[remotePath] = try Data(contentsOf: URL(fileURLWithPath: localPath))
    }
    override func listDirectory(_ path: String) async throws -> [FileItem] {
        uploaded.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.map {
            FileItem(id: UUID(), name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false,
                     isArchive: false, size: Int64(uploaded[$0]!.count), modified: Date(), isHidden: false,
                     isSymlink: false, permissions: "")
        }
    }
    override func delete(_ path: String) async throws { uploaded[path] = nil }
}
