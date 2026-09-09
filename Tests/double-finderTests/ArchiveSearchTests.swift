import XCTest
@testable import double_finder

/// Find Files inside archives: the pure scoping rules, the batch planner, and
/// real end-to-end runs over zip / 7z (plain, solid, encrypted) built on the fly.
final class ArchiveSearchTests: XCTestCase {

    // MARK: - Pure logic

    private func entry(_ path: String, size: Int64 = 1, isDir: Bool = false) -> LibArchive.Entry {
        LibArchive.Entry(path: path, size: size, mtime: nil, isDir: isDir)
    }

    func testArchiveCandidatesScopeToTheInternalPrefix() {
        let entries = [entry("readme.txt"), entry("docs", isDir: true), entry("docs/guide.txt"),
                       entry("docs/deep/notes.txt"), entry("src/main.swift")]
        let m = SearchNameMatcher(pattern: "*.txt", isRegex: false)
        let whole = FileSearch.archiveCandidates(entries, archivePath: "/a/p.zip", internalPrefix: "",
                                                 matcher: m, subfolders: true)
        XCTAssertEqual(whole.map(\.path), ["/a/p.zip/readme.txt", "/a/p.zip/docs/guide.txt",
                                           "/a/p.zip/docs/deep/notes.txt"])
        let docs = FileSearch.archiveCandidates(entries, archivePath: "/a/p.zip", internalPrefix: "docs",
                                                matcher: m, subfolders: true)
        XCTAssertEqual(docs.map(\.path), ["/a/p.zip/docs/guide.txt", "/a/p.zip/docs/deep/notes.txt"])
        let shallow = FileSearch.archiveCandidates(entries, archivePath: "/a/p.zip", internalPrefix: "docs",
                                                   matcher: m, subfolders: false)
        XCTAssertEqual(shallow.map(\.path), ["/a/p.zip/docs/guide.txt"])
    }

    func testArchiveCandidatesSkipDirectoriesAndMatchOnTheLeaf() {
        // "docs" the folder must not match a "docs" name pattern; "docs/docs.txt" must.
        let entries = [entry("docs", isDir: true), entry("docs/docs.txt"), entry("other/"), entry("x/docs")]
        let m = SearchNameMatcher(pattern: "docs", isRegex: false)
        let hits = FileSearch.archiveCandidates(entries, archivePath: "/p.zip", internalPrefix: "",
                                                matcher: m, subfolders: true)
        XCTAssertEqual(hits.map(\.path), ["/p.zip/docs/docs.txt", "/p.zip/x/docs"])
    }

    func testScanBatchesRespectTheByteLimit() {
        let hits = [SearchHit(path: "a", size: 60), SearchHit(path: "b", size: 50),
                    SearchHit(path: "c", size: 200), SearchHit(path: "d", size: 10)]
        let batches = FileSearch.archiveScanBatches(hits, limit: 100)
        XCTAssertEqual(batches.map { $0.map(\.path) }, [["a"], ["b"], ["c"], ["d"]])
        let loose = FileSearch.archiveScanBatches(hits, limit: 1000)
        XCTAssertEqual(loose.count, 1)
        XCTAssertTrue(FileSearch.archiveScanBatches([]).isEmpty)
    }

    func testIsArchiveHitNeedsARealArchiveOnDisk() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        XCTAssertTrue(FileSearch.isArchiveHit(zip + "/readme.txt"))
        XCTAssertFalse(FileSearch.isArchiveHit(zip))                        // the archive file itself is on disk
        XCTAssertFalse(FileSearch.isArchiveHit(dir + "/readme.txt"))
        XCTAssertFalse(FileSearch.isArchiveHit(dir + "/missing.zip/readme.txt"))   // no archive there
    }

    // MARK: - End to end

    private func makeWorkDir() throws -> String {
        // Resolved with realpath(3) up front: the local walk reports enumerator
        // paths, which come back as /private/var/… while NSTemporaryDirectory()
        // says /var/… — and Foundation's symlink resolvers strip "/private" again.
        let raw = NSTemporaryDirectory() + "archsearch-\(ProcessInfo.processInfo.globallyUniqueString)"
        try FileManager.default.createDirectory(atPath: raw + "/src/docs/deep", withIntermediateDirectories: true)
        guard let real = realpath(raw, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        let dir = String(cString: real)
        try "top level NEEDLE here".write(toFile: dir + "/src/readme.txt", atomically: true, encoding: .utf8)
        try "guide without the word".write(toFile: dir + "/src/docs/guide.txt", atomically: true, encoding: .utf8)
        try "deep needle".write(toFile: dir + "/src/docs/deep/notes.txt", atomically: true, encoding: .utf8)
        var binary = Data("needle".utf8); binary.append(0x00); binary.append(0x01)
        try binary.write(to: URL(fileURLWithPath: dir + "/src/docs/blob.bin"))
        return dir
    }

    private var sources: (String) -> [(absPath: String, entryName: String)] {
        { dir in [(dir + "/src/readme.txt", "readme.txt"), (dir + "/src/docs", "docs")] }
    }

    private func makeZip(in dir: String, name: String, password: String? = nil) throws -> String {
        let path = dir + "/" + name
        try LibArchive.create(sources: sources(dir), to: path, format: .zip, level: 5, password: password)
        return path
    }

    private func query(_ name: String, content: String = "", subfolders: Bool = true,
                       archives: Bool = false) -> FileSearchQuery {
        FileSearchQuery(namePattern: name, content: content, subfolders: subfolders,
                        regexName: false, searchArchives: archives)
    }

    private func leaves(_ hits: [SearchHit]) -> [String] { hits.map { ($0.path as NSString).lastPathComponent } }

    func testNameSearchInsideAZipCarriesSizes() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        let hits = try await FileSearch.run(endpoint: .archive(archivePath: zip, password: nil, base: zip),
                                            query: query("*.txt"), report: { _, _ in })
        XCTAssertEqual(hits.map(\.path), [zip + "/docs/deep/notes.txt", zip + "/docs/guide.txt", zip + "/readme.txt"])
        XCTAssertEqual(hits.last?.size, Int64("top level NEEDLE here".utf8.count))
    }

    func testSearchIsScopedToTheFolderThePanelIsIn() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        let inDocs = try await FileSearch.run(endpoint: .archive(archivePath: zip, password: nil, base: zip + "/docs"),
                                              query: query("*"), report: { _, _ in })
        XCTAssertEqual(leaves(inDocs), ["blob.bin", "notes.txt", "guide.txt"])
        let shallow = try await FileSearch.run(endpoint: .archive(archivePath: zip, password: nil, base: zip + "/docs"),
                                               query: query("*", subfolders: false), report: { _, _ in })
        XCTAssertEqual(leaves(shallow), ["blob.bin", "guide.txt"])
    }

    func testContentSearchInsideAZipSkipsBinaries() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        let hits = try await FileSearch.run(endpoint: .archive(archivePath: zip, password: nil, base: zip),
                                            query: query("*", content: "needle"), report: { _, _ in })
        XCTAssertEqual(leaves(hits), ["notes.txt", "readme.txt"])   // blob.bin is binary → skipped
        // The temp extraction folder must be gone afterwards.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("DoubleFinder-Search-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "temp scan folders left behind: \(leftovers)")
    }

    func testContentSearchInsideASolid7z() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let arc = dir + "/p.7z"
        try SevenZipEngine.create(sources: sources(dir), to: arc, level: 5, password: nil)
        let hits = try await FileSearch.run(endpoint: .archive(archivePath: arc, password: nil, base: arc),
                                            query: query("*", content: "needle"), report: { _, _ in })
        XCTAssertEqual(leaves(hits), ["notes.txt", "readme.txt"])
    }

    func testContentSearchInsideAnEncrypted7zUsesTheEngine() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let arc = dir + "/secret.7z"
        try SevenZipEngine.create(sources: sources(dir), to: arc, level: 5, password: "pw")
        let hits = try await FileSearch.run(endpoint: .archive(archivePath: arc, password: "pw", base: arc),
                                            query: query("*", content: "needle"), report: { _, _ in })
        XCTAssertEqual(leaves(hits), ["notes.txt", "readme.txt"])
    }

    func testLocalWalkLooksInsideArchivesOnlyWhenAsked() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        // Without the flag: only the archive file itself can match.
        let plain = try await FileSearch.run(endpoint: .local(base: dir),
                                             query: query("readme*"), report: { _, _ in })
        XCTAssertEqual(plain.map(\.path), [dir + "/src/readme.txt"])
        // With it: the entry inside the zip is a hit too, with a virtual path.
        let deep = try await FileSearch.run(endpoint: .local(base: dir),
                                            query: query("readme*", archives: true), report: { _, _ in })
        XCTAssertEqual(deep.map(\.path), [zip + "/readme.txt", dir + "/src/readme.txt"])
        // Content matching reaches inside as well.
        let content = try await FileSearch.run(endpoint: .local(base: dir),
                                               query: query("*", content: "NEEDLE here", archives: true),
                                               report: { _, _ in })
        XCTAssertEqual(content.map(\.path), [zip + "/readme.txt", dir + "/src/readme.txt"])
    }

    func testLocalWalkSkipsAnArchiveItCannotOpen() async throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try makeZip(in: dir, name: "open.zip")
        try Data("this is not a zip".utf8).write(to: URL(fileURLWithPath: dir + "/broken.zip"))
        let arc = dir + "/locked.7z"
        try SevenZipEngine.create(sources: sources(dir), to: arc, level: 5, password: "pw", encryptHeaders: true)
        // Corrupt + password-protected archives are skipped, the open one is searched.
        let hits = try await FileSearch.run(endpoint: .local(base: dir),
                                            query: query("guide*", archives: true), report: { _, _ in })
        XCTAssertEqual(hits.map(\.path), [dir + "/open.zip/docs/guide.txt", dir + "/src/docs/guide.txt"])
    }

    // MARK: - Panel rows

    func testSearchResultItemsListArchiveEntriesFromTheirMetadata() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let zip = try makeZip(in: dir, name: "p.zip")
        let inner = zip + "/docs/guide.txt"
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = [inner: SearchHit(path: inner, size: 42, modified: when)]
        let items = PanelState.searchResultItems(paths: [dir + "/src/readme.txt", inner, dir + "/gone.txt"],
                                                 base: dir, showHidden: true, archiveMeta: meta)
        XCTAssertEqual(items.map(\.name), ["src/readme.txt", "p.zip/docs/guide.txt"])
        XCTAssertEqual(items[1].size, 42)
        XCTAssertEqual(items[1].modified, when)
        XCTAssertFalse(items[1].isDirectory)
        // Without the metadata a virtual path is dropped, as before.
        let bare = PanelState.searchResultItems(paths: [inner], base: dir, showHidden: true)
        XCTAssertTrue(bare.isEmpty)
    }
}
