import XCTest
import DoubleFinderPluginKit
@testable import double_finder

/// The plugin layer: registration through PluginManager, the enable switch,
/// drive identity in RemoteSessionStore, and the VirtualFS adapter over a
/// PluginFileSystemSession. Uses an in-process fake plugin — no bundle needed.
@MainActor
final class PluginKitTests: XCTestCase {

    // MARK: Fixtures

    final class FakeSession: PluginFileSystemSession {
        let label = "Fake"
        var files: [String: Data] = ["/a.txt": Data("hello".utf8), "/dir/b.txt": Data("bb".utf8)]
        var dirs: Set<String> = ["/dir"]
        var disconnected = false
        var moved: [(String, String)] = []

        func list(_ directory: String) async throws -> [PluginFileEntry] {
            let dir = directory == "/" ? "" : directory
            var out: [PluginFileEntry] = []
            for d in dirs where (d as NSString).deletingLastPathComponent == (dir.isEmpty ? "/" : dir) {
                out.append(PluginFileEntry(name: (d as NSString).lastPathComponent, isDirectory: true))
            }
            for (p, data) in files where (p as NSString).deletingLastPathComponent == (dir.isEmpty ? "/" : dir) {
                out.append(PluginFileEntry(name: (p as NSString).lastPathComponent, isDirectory: false,
                                           size: Int64(data.count)))
            }
            return out.sorted { $0.name < $1.name }
        }
        func download(_ path: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
            guard let d = files[path] else { throw PluginError.failed("missing \(path)") }
            try d.write(to: localURL); progress(Int64(d.count))
        }
        func upload(_ localURL: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
            let d = try Data(contentsOf: localURL); files[path] = d; progress(Int64(d.count))
        }
        func delete(_ path: String) async throws {
            files[path] = nil; dirs.remove(path)
            for k in files.keys where k.hasPrefix(path + "/") { files[k] = nil }
        }
        func createDirectory(_ path: String) async throws { dirs.insert(path) }
        func rename(_ path: String, to newName: String) async throws {
            let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
            if let d = files.removeValue(forKey: path) { files[target] = d }
        }
        func move(_ path: String, toDirectory directory: String) async throws { moved.append((path, directory)) }
        func disconnect() { disconnected = true }
    }

    final class FakeFS: FileSystemPlugin {
        let identifier = "fake"
        let displayName = "Fake Drive"
        let session = FakeSession()
        func connect(host: PluginHost) async throws -> PluginFileSystemSession { session }
    }

    final class FakeViewer: ViewerPlugin {
        let identifier = "fake-viewer"
        let displayName = "Fake Viewer"
        func canView(url: URL, sample: Data) -> Bool { url.pathExtension == "fake" }
        func makeView(for url: URL) throws -> NSView { NSView() }
    }

    final class FakeCommand: CommandPlugin {
        let identifier = "fake-cmd"
        let title = "Fake Command"
        var ran = 0
        func perform(_ context: PluginCommandContext) async throws { ran += 1 }
    }

    final class FakePlugin: NSObject, DFPlugin {
        static var activations = 0
        static var deactivations = 0
        static var failActivation = false
        let info = PluginInfo(identifier: "test.fake", name: "Fake", version: "0.1")
        let fs = FakeFS()
        let viewer = FakeViewer()
        let command = FakeCommand()
        required override init() { super.init() }
        func activate(host: PluginHost) throws {
            if Self.failActivation { throw PluginError.failed("nope") }
            Self.activations += 1
        }
        func deactivate() { Self.deactivations += 1 }
        var fileSystems: [FileSystemPlugin] { [fs] }
        var viewers: [ViewerPlugin] { [viewer] }
        var commands: [CommandPlugin] { [command] }
    }

    private var savedDisabled: [String]?

    override func setUp() async throws {
        savedDisabled = UserDefaults.standard.stringArray(forKey: PluginManager.disabledKey)
        UserDefaults.standard.removeObject(forKey: PluginManager.disabledKey)
        PluginManager.shared.unload(id: "test.fake")
        RemoteSessionStore.shared.removeAll()
        FakePlugin.activations = 0; FakePlugin.deactivations = 0; FakePlugin.failActivation = false
    }

    override func tearDown() async throws {
        PluginManager.shared.unload(id: "test.fake")
        RemoteSessionStore.shared.removeAll()
        if let saved = savedDisabled {
            UserDefaults.standard.set(saved, forKey: PluginManager.disabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PluginManager.disabledKey)
        }
    }

    // MARK: PluginManager

    func testBuiltInLoadRegistersEveryExtension() {
        let rec = PluginManager.shared.load(builtIn: FakePlugin.self)
        XCTAssertEqual(rec.state, .active)
        XCTAssertEqual(FakePlugin.activations, 1)
        let m = PluginManager.shared
        XCTAssertEqual(m.fileSystems.filter { $0.pluginID == "test.fake" }.count, 1)
        XCTAssertEqual(m.viewers.filter { $0.pluginID == "test.fake" }.count, 1)
        XCTAssertEqual(m.commands.filter { $0.pluginID == "test.fake" }.count, 1)
        XCTAssertNotNil(m.fileSystem(driveID: "plugin://test.fake/fake"))
        XCTAssertNotNil(m.command(id: "test.fake/fake-cmd"))
        XCTAssertNotNil(m.viewer(for: URL(fileURLWithPath: "/x/y.fake"), sample: Data()))
        XCTAssertNil(m.viewer(for: URL(fileURLWithPath: "/x/y.txt"), sample: Data()))
        XCTAssertEqual(m.provides(rec), "\(tr("File system")) · \(tr("Viewer")) · \(tr("Command"))")
    }

    func testDuplicateIdentifierIsRefused() {
        PluginManager.shared.load(builtIn: FakePlugin.self)
        let second = PluginManager.shared.load(builtIn: FakePlugin.self)
        guard case .failed = second.state else { return XCTFail("duplicate must be refused") }
        XCTAssertEqual(FakePlugin.activations, 1)
        // Cleanup of the duplicate record: unload removes the first match only;
        // remove the failed twin too.
        PluginManager.shared.unload(id: "test.fake")
        PluginManager.shared.unload(id: "test.fake")
    }

    func testActivationFailureIsRecordedNotThrown() {
        FakePlugin.failActivation = true
        let rec = PluginManager.shared.load(builtIn: FakePlugin.self)
        XCTAssertEqual(rec.state, .failed("nope"))
        XCTAssertTrue(PluginManager.shared.fileSystems.filter { $0.pluginID == "test.fake" }.isEmpty)
    }

    func testDisableEjectsDrivesAndDropsExtensions() {
        let rec = PluginManager.shared.load(builtIn: FakePlugin.self)
        let fake = rec.plugin as! FakePlugin
        let drive = PluginDriveSession(driveID: "plugin://test.fake/fake", pluginID: "test.fake",
                                       symbol: "x", session: fake.fs.session)
        RemoteSessionStore.shared.register(.plugin(drive))
        XCTAssertEqual(RemoteSessionStore.shared.sessions.count, 1)

        PluginManager.shared.setEnabled("test.fake", false)
        XCTAssertTrue(PluginManager.shared.disabledIDs.contains("test.fake"))
        XCTAssertTrue(PluginManager.shared.fileSystems.filter { $0.pluginID == "test.fake" }.isEmpty)
        XCTAssertTrue(RemoteSessionStore.shared.sessions.isEmpty, "disabling must eject the plugin's drives")
        XCTAssertTrue(fake.fs.session.disconnected, "ejecting must tell the session to disconnect")
        XCTAssertEqual(FakePlugin.deactivations, 1)
        XCTAssertEqual(PluginManager.shared.records.first { $0.info.identifier == "test.fake" }?.state, .disabled)

        PluginManager.shared.setEnabled("test.fake", true)
        XCTAssertFalse(PluginManager.shared.disabledIDs.contains("test.fake"))
        XCTAssertEqual(FakePlugin.activations, 2)
        XCTAssertEqual(PluginManager.shared.fileSystems.filter { $0.pluginID == "test.fake" }.count, 1)
    }

    func testDisabledPluginStaysInactiveOnLoad() {
        UserDefaults.standard.set(["test.fake"], forKey: PluginManager.disabledKey)
        let rec = PluginManager.shared.load(builtIn: FakePlugin.self)
        XCTAssertEqual(rec.state, .disabled)
        XCTAssertEqual(FakePlugin.activations, 0)
    }

    func testBrokenBundleIsRecordedAsFailure() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("df-\(UUID().uuidString).dfplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rec = PluginManager.shared.load(bundleAt: tmp)
        defer { PluginManager.shared.unload(id: rec.info.identifier) }
        guard case .failed(let why) = rec.state else { return XCTFail("a bundle without Info.plist must fail") }
        XCTAssertTrue(why.contains(PluginKit.apiVersionInfoKey), why)
    }

    // MARK: RemoteSession

    func testPluginDriveSessionIdentityAndEject() {
        let session = FakeSession()
        let drive = PluginDriveSession(driveID: "plugin://p/fs", pluginID: "p", symbol: "s", session: session)
        let remote = RemoteSession.plugin(drive)
        XCTAssertEqual(remote.id, "plugin://p/fs")
        XCTAssertEqual(remote.label, "Fake")
        XCTAssertEqual(remote.icon, "s")
        RemoteSessionStore.shared.register(remote)
        RemoteSessionStore.shared.register(remote)
        XCTAssertEqual(RemoteSessionStore.shared.sessions.count, 1)
        RemoteSessionStore.shared.remove(id: remote.id)
        XCTAssertTrue(session.disconnected)
    }

    // MARK: PluginFS adapter

    private func makeFS() -> (PluginFS, FakeSession) {
        let session = FakeSession()
        let drive = PluginDriveSession(driveID: "plugin://p/fs", pluginID: "p", symbol: "s", session: session)
        return (PluginFS(drive: drive, currentPath: "/"), session)
    }

    func testListMapsEntriesToFullPaths() async throws {
        let (fs, _) = makeFS()
        let root = try await fs.listDirectory("/")
        XCTAssertEqual(root.map { $0.path }, ["/a.txt", "/dir"])
        XCTAssertEqual(root.map { $0.isDirectory }, [false, true])
        let sub = try await fs.listDirectory("/dir")
        XCTAssertEqual(sub.map { $0.path }, ["/dir/b.txt"])
        XCTAssertEqual(PluginFS.join("/", "x"), "/x")
        XCTAssertEqual(PluginFS.join("/a", "x"), "/a/x")
        XCTAssertEqual(PluginFS.parent(of: "/a"), "/")
    }

    func testCopyDirectionFollowsWhetherSourceExistsLocally() async throws {
        let (fs, session) = makeFS()
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("df-pluginfs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Drive → local: a directory tree lands under <dest>/<leaf>.
        try await fs.copy(from: "/dir", to: tmp)
        let got = try String(contentsOfFile: (tmp as NSString).appendingPathComponent("dir/b.txt"), encoding: .utf8)
        XCTAssertEqual(got, "bb")

        // Local → drive: the file exists on disk, so it is an upload.
        let local = (tmp as NSString).appendingPathComponent("up.txt")
        try "up".write(toFile: local, atomically: true, encoding: .utf8)
        try await fs.copy(from: local, to: "/dir")
        XCTAssertEqual(session.files["/dir/up.txt"], Data("up".utf8))
    }

    func testMoveWithinDriveUsesPluginMoveThenRelayFallback() async throws {
        let (fs, session) = makeFS()
        try await fs.move(from: "/a.txt", to: "/dir")
        XCTAssertEqual(session.moved.count, 1, "the plugin's own move is preferred")

        // A session without move/copy → relay (download, upload, delete source).
        let bare = BareSession()
        let drive = PluginDriveSession(driveID: "plugin://p/bare", pluginID: "p", symbol: "s", session: bare)
        let bareFS = PluginFS(drive: drive, currentPath: "/")
        try await bare.createDirectory("/out")
        try await bareFS.move(from: "/x.txt", to: "/out")
        XCTAssertNil(bare.files["/x.txt"])
        XCTAssertEqual(bare.files["/out/x.txt"], Data("x".utf8))
    }

    /// Minimal session: no copy/move → the protocol defaults throw `.unsupported`.
    final class BareSession: PluginFileSystemSession {
        let label = "Bare"
        var files: [String: Data] = ["/x.txt": Data("x".utf8)]
        var dirs: Set<String> = []
        func list(_ directory: String) async throws -> [PluginFileEntry] {
            let parentOf: (String) -> String = { ($0 as NSString).deletingLastPathComponent }
            return dirs.filter { parentOf($0) == directory }.map { PluginFileEntry(name: ($0 as NSString).lastPathComponent, isDirectory: true) }
                + files.filter { parentOf($0.key) == directory }.map { PluginFileEntry(name: ($0.key as NSString).lastPathComponent, isDirectory: false, size: Int64($0.value.count)) }
        }
        func download(_ path: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
            guard let d = files[path] else { throw PluginError.failed("missing") }
            try d.write(to: localURL)
        }
        func upload(_ localURL: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
            files[path] = try Data(contentsOf: localURL)
        }
        func delete(_ path: String) async throws { files[path] = nil }
        func createDirectory(_ path: String) async throws { dirs.insert(path) }
        func rename(_ path: String, to newName: String) async throws {}
    }

    // MARK: Transfer provider

    func testTransferProviderVerbsAndTitles() {
        let (fs, _) = makeFS()
        let dl = PluginTransferProvider(drive: fs.drive, mode: .download)
        let ul = PluginTransferProvider(drive: fs.drive, mode: .upload)
        let mv = PluginTransferProvider(drive: fs.drive, mode: .within(move: true))
        XCTAssertEqual(dl.verb, tr("Download"))
        XCTAssertEqual(ul.verb, tr("Upload"))
        XCTAssertEqual(mv.verb, tr("Move"))
        let item = FileItem(id: UUID(), name: "a.txt", path: "/a.txt", isDirectory: false, isArchive: false,
                            size: 5, modified: Date(), isHidden: false, isSymlink: false, permissions: "")
        let op = dl.makeOperation(items: [item], destPath: "/tmp/x", renameTo: nil)
        XCTAssertEqual(op.totalBytes, 5)
        XCTAssertEqual(op.type, .copy)
        XCTAssertEqual(mv.makeOperation(items: [item], destPath: "/dir", renameTo: nil).type, .move)
    }
}

// MARK: - Round two: packers, columns, shortcuts, plugin-drive search

@MainActor
final class PluginKitRoundTwoTests: XCTestCase {

    /// In-memory archive: a fixed entry table, contents = the entry path.
    final class FakePacker: PackerPlugin {
        let identifier = "fake-pak"
        let displayName = "Fake PAK"
        let fileExtensions = ["fpak", "tar.fpak"]
        var opens = 0
        func open(_ url: URL) throws -> PluginArchiveSession {
            opens += 1
            guard FileManager.default.fileExists(atPath: url.path) else { throw PluginError.failed("missing") }
            return FakeArchive()
        }
    }

    final class FakeArchive: PluginArchiveSession {
        func entries() throws -> [PluginArchiveEntry] {
            [PluginArchiveEntry(path: "readme.txt", size: 10),
             PluginArchiveEntry(path: "docs/a.txt", size: 10),
             PluginArchiveEntry(path: "docs/sub/b.txt", size: 14),
             PluginArchiveEntry(path: "../evil.txt", size: 1)]      // must be skipped
        }
        func extract(_ entryPath: String, to localURL: URL) throws {
            try Data(entryPath.utf8).write(to: localURL)
        }
    }

    final class ColumnsPlugin: ContentPlugin {
        let identifier = "cols"
        let columns = [PluginColumn(id: "len", title: "Name Length", defaultWidth: 70)]
        func value(column: String, path: String, isDirectory: Bool) -> String? {
            "\((path as NSString).lastPathComponent.count)"
        }
    }

    final class RoundTwoPlugin: NSObject, DFPlugin {
        let info = PluginInfo(identifier: "test.round2", name: "Round Two")
        let packer = FakePacker()
        let cols = ColumnsPlugin()
        let cmd = PluginKitTests.FakeCommand()
        required override init() { super.init() }
        func activate(host: PluginHost) throws {}
        var packers: [PackerPlugin] { [packer] }
        var contentProviders: [ContentPlugin] { [cols] }
        var commands: [CommandPlugin] { [cmd] }
    }

    private var tmp = ""

    override func setUp() async throws {
        PluginManager.shared.unload(id: "test.round2")
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("df-r2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PluginManager.shared.unload(id: "test.round2")
        UserDefaults.standard.removeObject(forKey: "kb.plugin.test.round2/fake-cmd")
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func load() -> RoundTwoPlugin {
        PluginManager.shared.load(builtIn: RoundTwoPlugin.self).plugin as! RoundTwoPlugin
    }

    func testPackerSuffixesFlowIntoArchiveDetectionAndFSRouting() throws {
        XCTAssertFalse(FileItem.isArchiveFileName("game.fpak"))
        _ = load()
        XCTAssertTrue(FileItem.isArchiveFileName("game.fpak"))
        XCTAssertTrue(FileItem.isArchiveFileName("GAME.TAR.FPAK"))
        XCTAssertNotNil(ArchivePluginRegistry.packer(forFileName: "x.tar.fpak"))
        // A real file with the suffix is an archive root; the FS is the plugin adapter.
        let pak = (tmp as NSString).appendingPathComponent("game.fpak")
        try Data("PACK".utf8).write(to: URL(fileURLWithPath: pak))
        XCTAssertEqual(PanelState.archiveRoot(in: pak + "/docs/a.txt"), pak)
        XCTAssertTrue(PanelState.fileSystem(for: pak + "/docs") is PluginArchiveFS)
        PluginManager.shared.unload(id: "test.round2")
        XCTAssertFalse(FileItem.isArchiveFileName("game.fpak"), "disabling must retract the suffix")
    }

    func testPluginArchiveFSListsInfersFoldersAndCopiesOut() async throws {
        let plugin = load()
        let pak = (tmp as NSString).appendingPathComponent("game.fpak")
        try Data("PACK".utf8).write(to: URL(fileURLWithPath: pak))
        let fs = PluginArchiveFS(archivePath: pak, packer: plugin.packer)

        let root = try await fs.listDirectory(pak)
        XCTAssertEqual(root.map { $0.name }, ["docs", "readme.txt"])
        XCTAssertEqual(root.map { $0.isDirectory }, [true, false])
        XCTAssertEqual(root[0].path, pak + "/docs")
        let docs = try await fs.listDirectory(pak + "/docs")
        XCTAssertEqual(docs.map { $0.name }, ["sub", "a.txt"])

        // Copy-out of a folder lands flat under its own name, tree preserved.
        let out = (tmp as NSString).appendingPathComponent("out")
        try await fs.copy(from: pak + "/docs", to: out)
        let b = try String(contentsOfFile: out + "/docs/sub/b.txt", encoding: .utf8)
        XCTAssertEqual(b, "docs/sub/b.txt")
        // Single file copy-out.
        try await fs.copy(from: pak + "/readme.txt", to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out + "/readme.txt"))

        // Extract-all keeps the whole tree and drops the escaping entry.
        let all = (tmp as NSString).appendingPathComponent("all")
        try PluginArchiveFS.extractAll(archivePath: pak, packer: plugin.packer, to: all)
        XCTAssertTrue(FileManager.default.fileExists(atPath: all + "/docs/sub/b.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (tmp as NSString).appendingPathComponent("evil.txt")))
        let size = await fs.directorySize(pak + "/docs")
        XCTAssertEqual(size, 24)
    }

    func testContentColumnsAppearInLayoutAndResolveValues() async {
        XCTAssertFalse(FileColumnLayout.optionalColumns.contains { $0.id == "plugin.test.round2.len" })
        _ = load()
        let col = FileColumnLayout.optionalColumns.first { $0.id == "plugin.test.round2.len" }
        XCTAssertEqual(col?.title, "Name Length")
        XCTAssertEqual(col?.width, 70)
        // The layout honours a visible plugin column like a built-in one.
        let layout = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "plugin.test.round2.len"], widths: [:])
        XCTAssertEqual(layout.columns.map { $0.id }, ["name", "size", "plugin.test.round2.len"])

        // Values: first ask queues a fetch ("" now), the notification follows with the value.
        let file = (tmp as NSString).appendingPathComponent("hello.txt")
        try? "x".write(toFile: file, atomically: true, encoding: .utf8)
        let item = FileItem(id: UUID(), name: "hello.txt", path: file, isDirectory: false, isArchive: false,
                            size: 1, modified: Date(), isHidden: false, isSymlink: false, permissions: "")
        let exp = expectation(forNotification: PluginColumnValues.didUpdate, object: nil)
        XCTAssertEqual(PluginColumnValues.shared.text(columnID: "plugin.test.round2.len", item: item), "")
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(PluginColumnValues.shared.text(columnID: "plugin.test.round2.len", item: item), "9")
    }

    func testPluginCommandsAreBindableAndOnToolbar() {
        _ = load()
        let cmd = BindableCommand.plugin(id: "test.round2/fake-cmd", title: "Fake Command")
        XCTAssertTrue(KeyBindings.bindableCommands.contains(cmd))
        XCTAssertEqual(cmd.defaultHint, "—")
        let combo = KeyCombo(keyCode: 3, modifiers: [.command, .option, .control])
        KeyBindings.set(combo, for: cmd)
        XCTAssertEqual(KeyBindings.bindable(for: combo), cmd)
        KeyBindings.set(nil, for: cmd)
        XCTAssertNil(KeyBindings.bindable(for: combo))
        XCTAssertNotNil(PluginManager.shared.command(toolbarID: "plugin.test.round2/fake-cmd"))
        // The shared registry lists it for Settings ▸ Toolbar and builds its button.
        XCTAssertTrue(CommandRegistry.toolbarChoices.contains { $0.id == "plugin.test.round2/fake-cmd" && $0.label == "Fake Command" })
        var pluginRan: [String] = []
        let items = CommandRegistry.toolbarItems(runBuiltIn: { _ in }, runPlugin: { pluginRan.append($0) })
        items.first { $0.id == "plugin.test.round2/fake-cmd" }?.action()
        XCTAssertEqual(pluginRan, ["test.round2/fake-cmd"])
    }

    func testFindFilesWalksAPluginDrive() async throws {
        let session = PluginKitTests.FakeSession()
        let drive = PluginDriveSession(driveID: "plugin://p/fs", pluginID: "p", symbol: "s", session: session)
        let endpoint = SearchEndpoint.plugin(drive, base: "/")
        XCTAssertTrue(endpoint.isRemote)
        XCTAssertEqual(endpoint.displayBase, "Fake:/")
        var query = FileSearchQuery(namePattern: "*.txt", content: "", subfolders: true, regexName: false)
        var hits = try await FileSearch.run(endpoint: endpoint, query: query, report: { _, _ in })
        XCTAssertEqual(hits.map { $0.path }, ["/a.txt", "/dir/b.txt"])
        query = FileSearchQuery(namePattern: "*", content: "hello", subfolders: true, regexName: false)
        hits = try await FileSearch.run(endpoint: endpoint, query: query, report: { _, _ in })
        XCTAssertEqual(hits.map { $0.path }, ["/a.txt"])
    }
}

// MARK: - Round three: archive session cache, crash quarantine, generic sync

@MainActor
final class PluginKitRoundThreeTests: XCTestCase {
    private var tmp = ""

    override func setUp() async throws {
        PluginManager.shared.unload(id: "test.round2")
        PluginArchiveSessionCache.shared.removeAll()
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("df-r3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PluginManager.shared.unload(id: "test.round2")
        PluginArchiveSessionCache.shared.removeAll()
        UserDefaults.standard.removeObject(forKey: PluginManager.loadingMarkerKey)
        UserDefaults.standard.removeObject(forKey: PluginManager.quarantineKey)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testArchiveSessionIsReusedUntilTheFileChanges() async throws {
        let plugin = PluginManager.shared.load(builtIn: PluginKitRoundTwoTests.RoundTwoPlugin.self).plugin
            as! PluginKitRoundTwoTests.RoundTwoPlugin
        let pak = (tmp as NSString).appendingPathComponent("a.fpak")
        try Data("PACK".utf8).write(to: URL(fileURLWithPath: pak))
        let fs = PluginArchiveFS(archivePath: pak, packer: plugin.packer)
        _ = try await fs.listDirectory(pak)
        _ = try await fs.listDirectory(pak + "/docs")
        _ = await fs.directorySize(pak)
        XCTAssertEqual(plugin.packer.opens, 1, "three operations, one open")

        // Rewriting the archive (size changes) invalidates the cached session.
        try Data("PACK-v2".utf8).write(to: URL(fileURLWithPath: pak))
        _ = try await fs.listDirectory(pak)
        XCTAssertEqual(plugin.packer.opens, 2)

        // Deactivating the packer drops every session it opened.
        PluginManager.shared.setEnabled("test.round2", false)
        PluginManager.shared.setEnabled("test.round2", true)
        _ = try await fs.listDirectory(pak)
        XCTAssertEqual(plugin.packer.opens, 3)
    }

    func testLeftoverLoadingMarkerQuarantinesTheBundle() throws {
        let bundleURL = URL(fileURLWithPath: tmp).appendingPathComponent("Crashy.dfplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        // Simulate: last launch died while this bundle was loading.
        UserDefaults.standard.set("Crashy.dfplugin", forKey: PluginManager.loadingMarkerKey)
        PluginManager.shared.quarantineCrashedBundleIfAny()
        XCTAssertNil(UserDefaults.standard.string(forKey: PluginManager.loadingMarkerKey))
        XCTAssertTrue(PluginManager.shared.quarantined.contains("Crashy.dfplugin"))

        // Loading it now is refused before any of its code would run.
        let rec = PluginManager.shared.load(bundleAt: bundleURL)
        defer { PluginManager.shared.unload(id: rec.info.identifier) }
        guard case .failed(let why) = rec.state else { return XCTFail("quarantined bundle must not load") }
        XCTAssertTrue(why.contains(tr("Crashed while loading last time — Rescan retries it")), why)

        // Rescan with retry lifts the quarantine (the bundle is then judged on
        // its own merits again — here: no Info.plist).
        PluginManager.shared.rescanBundles(retryQuarantined: true)
        XCTAssertTrue(PluginManager.shared.quarantined.isEmpty)
    }

    func testGenericSyncScanWalksAPluginDrive() async throws {
        let session = PluginKitTests.FakeSession()
        let drive = PluginDriveSession(driveID: "plugin://p/fs", pluginID: "p", symbol: "s", session: session)
        let fs = PluginFS(drive: drive, currentPath: "/")
        let map = try await SyncScan.scan(.generic(fs, base: "/"))
        XCTAssertEqual(Set(map.keys), ["a.txt", "dir/b.txt"])
        XCTAssertEqual(map["dir/b.txt"]?.size, 2)
        let sub = try await SyncScan.scan(.generic(fs, base: "/dir"))
        XCTAssertEqual(Array(sub.keys), ["b.txt"])
    }
}

// MARK: - Round four: packer plugins that create archives

@MainActor
final class PluginKitPackerCreateTests: XCTestCase {

    /// A writable fake format: a JSON file listing entries with base64 data.
    final class JSONPacker: PackerPlugin {
        let identifier = "json-pak"
        let displayName = "JSON Pack"
        let fileExtensions = ["jpak"]
        let canCreate = true
        var created: [PluginArchiveSource] = []

        final class Session: PluginArchiveSession {
            let list: [(String, Data)]
            init(url: URL) throws {
                let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: String]] ?? []
                list = obj.map { ($0["path"]!, Data(base64Encoded: $0["data"]!)!) }
            }
            func entries() throws -> [PluginArchiveEntry] {
                list.map { PluginArchiveEntry(path: $0.0, size: Int64($0.1.count)) }
            }
            func extract(_ entryPath: String, to localURL: URL) throws {
                guard let e = list.first(where: { $0.0 == entryPath }) else { throw PluginError.failed("missing") }
                try e.1.write(to: localURL)
            }
        }

        func open(_ url: URL) throws -> PluginArchiveSession { try Session(url: url) }

        func create(_ url: URL, sources: [PluginArchiveSource],
                    progress: @escaping @Sendable (Int64) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) throws {
            created = sources
            let obj = try sources.map { ["path": $0.entryPath,
                                         "data": try Data(contentsOf: URL(fileURLWithPath: $0.localPath)).base64EncodedString()] }
            try JSONSerialization.data(withJSONObject: obj).write(to: url)
            progress(Int64(sources.count))
        }
    }

    final class ReadOnlyPacker: PackerPlugin {
        let identifier = "ro"
        let displayName = "Read Only"
        let fileExtensions = ["ro"]
        func open(_ url: URL) throws -> PluginArchiveSession { throw PluginError.failed("n/a") }
    }

    final class CreatePlugin: NSObject, DFPlugin {
        let info = PluginInfo(identifier: "test.create", name: "Create")
        let json = JSONPacker()
        let ro = ReadOnlyPacker()
        required override init() { super.init() }
        func activate(host: PluginHost) throws {}
        var packers: [PackerPlugin] { [json, ro] }
    }

    private var tmp = ""

    override func setUp() async throws {
        PluginManager.shared.unload(id: "test.create")
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("df-r4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp + "/src/sub", withIntermediateDirectories: true)
        try "one".write(toFile: tmp + "/src/a.txt", atomically: true, encoding: .utf8)
        try "two".write(toFile: tmp + "/src/sub/b.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        PluginManager.shared.unload(id: "test.create")
        PluginArchiveSessionCache.shared.removeAll()
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testOnlyCreatingPackersAppearInPackFormats() {
        let before = PackFormat.all.count
        _ = PluginManager.shared.load(builtIn: CreatePlugin.self)
        let names = PackFormat.all.map { $0.displayName }
        XCTAssertEqual(PackFormat.all.count, before + 1)
        XCTAssertTrue(names.contains("JSON Pack (.jpak)"))
        XCTAssertFalse(names.contains { $0.hasPrefix("Read Only") })
        let plugin = PackFormat.all.last!
        XCTAssertEqual(plugin.fileExtension, "jpak")
        XCTAssertFalse(plugin.supportsEncryption)
        XCTAssertFalse(plugin.supportsSplit)
    }

    func testCreateExpandsFoldersAndRoundTrips() async throws {
        let plugin = PluginManager.shared.load(builtIn: CreatePlugin.self).plugin as! CreatePlugin
        let out = tmp + "/out.jpak"
        // A folder source keeps its own name as the top level (no baseDir).
        try await PluginArchiveFS.createArchive(sources: [tmp + "/src"], to: out, packer: plugin.json,
                                                baseDir: nil, progress: { _ in }, shouldCancel: { false })
        XCTAssertEqual(Set(plugin.json.created.map { $0.entryPath }), ["src/a.txt", "src/sub/b.txt"])

        // The result browses and extracts through the same plugin.
        let fs = PluginArchiveFS(archivePath: out, packer: plugin.json)
        let root = try await fs.listDirectory(out)
        XCTAssertEqual(root.map { $0.name }, ["src"])
        try await fs.copy(from: out + "/src/sub/b.txt", to: tmp + "/x")
        XCTAssertEqual(try String(contentsOfFile: tmp + "/x/b.txt", encoding: .utf8), "two")

        // Rewriting the same path must not serve the stale cached session.
        try await PluginArchiveFS.createArchive(sources: [tmp + "/src/a.txt"], to: out, packer: plugin.json,
                                                baseDir: nil, progress: { _ in }, shouldCancel: { false })
        let again = try await fs.listDirectory(out)
        XCTAssertEqual(again.map { $0.name }, ["a.txt"])
    }

    func testReadOnlyPackerRefusesCreate() {
        let ro = ReadOnlyPacker()
        XCTAssertFalse(ro.canCreate)
        XCTAssertThrowsError(try ro.create(URL(fileURLWithPath: tmp + "/x.ro"), sources: [],
                                           progress: { _ in }, isCancelled: { false }))
    }
}
