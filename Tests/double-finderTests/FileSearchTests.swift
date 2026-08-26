import XCTest
@testable import double_finder

final class FileSearchTests: XCTestCase {

    // MARK: - Name matching

    func testSubstringMatchIsCaseInsensitive() {
        let m = SearchNameMatcher(pattern: "report", isRegex: false)
        XCTAssertTrue(m.matches("Q3-REPORT.txt"))
        XCTAssertTrue(m.matches("report"))
        XCTAssertFalse(m.matches("summary.txt"))
        XCTAssertFalse(m.matchesEverything)
    }

    func testWildcardMatch() {
        let m = SearchNameMatcher(pattern: "*.md", isRegex: false)
        XCTAssertTrue(m.matches("README.MD"))
        XCTAssertFalse(m.matches("README.txt"))
    }

    func testStarMeansEverything() {
        let m = SearchNameMatcher(pattern: "*", isRegex: false)
        XCTAssertTrue(m.matchesEverything)
        XCTAssertTrue(m.matches("anything at all"))
        XCTAssertNil(m.findGlob)   // nothing to push into find -iname
    }

    func testRegexMatch() {
        let m = SearchNameMatcher(pattern: "^a.*\\.log$", isRegex: true)
        XCTAssertTrue(m.matches("access.log"))
        XCTAssertFalse(m.matches("error.log"))
        XCTAssertNil(m.findGlob)   // find has no equivalent → filter client-side
    }

    func testFindGlobPushDown() {
        XCTAssertEqual(SearchNameMatcher(pattern: "report", isRegex: false).findGlob, "*report*")
        XCTAssertEqual(SearchNameMatcher(pattern: "*.md", isRegex: false).findGlob, "*.md")
        // Non-ASCII stays client-side: `-iname` compares bytes, our substring
        // test is normalization-aware, so pushing it down could drop hits.
        XCTAssertNil(SearchNameMatcher(pattern: "技术", isRegex: false).findGlob)
        XCTAssertTrue(SearchNameMatcher(pattern: "技术", isRegex: false).matches("MetaIT 技术架构.docx"))
    }

    // MARK: - Content matching

    func testContentMatchesAcrossEncodings() {
        let utf8 = Data("hello 世界".utf8)
        XCTAssertTrue(SearchContentMatcher.matches(utf8, needle: "世界"))
        XCTAssertTrue(SearchContentMatcher.matches(utf8, needle: "HELLO"))   // case-insensitive
        XCTAssertFalse(SearchContentMatcher.matches(utf8, needle: "nope"))

        let gb = "重要日志 warning".data(using: EncodingDetector.gb18030)!
        XCTAssertTrue(SearchContentMatcher.matches(gb, needle: "重要日志"))
    }

    func testBinaryFilesNeverMatch() {
        var binary = Data("secret".utf8)
        binary.append(contentsOf: [0x00, 0x01, 0x02])
        XCTAssertTrue(SearchContentMatcher.isBinary(binary))
        XCTAssertFalse(SearchContentMatcher.matches(binary, needle: "secret"))
    }

    func testBOMDefeatsTheNULHeuristic() {
        // UTF-16 is full of NULs; the BOM says "text" explicitly.
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("token".data(using: .utf16LittleEndian)!)
        XCTAssertFalse(SearchContentMatcher.isBinary(utf16))
        XCTAssertTrue(SearchContentMatcher.matches(utf16, needle: "token"))
    }

    func testEmptyNeedleMatchesAnything() {
        XCTAssertTrue(SearchContentMatcher.matches(Data([0x00]), needle: ""))
    }

    // MARK: - SFTP command building

    func testListCommandQuotesAndScopes() {
        let cmd = SFTPSearchCommand.list(base: "/home/it's here", glob: "*.log", subfolders: true)
        XCTAssertTrue(cmd.hasPrefix("find '/home/it'\\''s here' -type f -iname '*.log'"))
        XCTAssertTrue(cmd.contains("-printf '%s\\t%T@\\t%p\\n'"))
        XCTAssertFalse(cmd.contains("-maxdepth"))
    }

    func testMaxdepthPrecedesTests() {
        let cmd = SFTPSearchCommand.list(base: "/srv", glob: nil, subfolders: false)
        let depth = try! XCTUnwrap(cmd.range(of: "-maxdepth 1"))
        let type = try! XCTUnwrap(cmd.range(of: "-type f"))
        XCTAssertLessThan(depth.lowerBound, type.lowerBound)   // GNU find requires this order
        XCTAssertFalse(cmd.contains("-iname"))
    }

    func testGrepCommandUsesExecPlus() {
        let cmd = SFTPSearchCommand.grep(base: "/srv", glob: nil, subfolders: true, text: "pass'word")
        // -exec … {} + is POSIX (BusyBox has it, `xargs -r` it does not).
        XCTAssertTrue(cmd.contains("-exec grep -l -I -i -F -e 'pass'\\''word' -- {} +"))
    }

    func testParseListLine() throws {
        let hit = try XCTUnwrap(SFTPSearchCommand.parseListLine("1234\t1700000000.5\t/srv/a b.txt"))
        XCTAssertEqual(hit.path, "/srv/a b.txt")
        XCTAssertEqual(hit.size, 1234)
        XCTAssertEqual(hit.modified.timeIntervalSince1970, 1700000000.5, accuracy: 0.001)
        // A tab inside the name survives: the path is everything after field 2.
        XCTAssertEqual(SFTPSearchCommand.parseListLine("1\t2\t/a\tb")?.path, "/a\tb")
        XCTAssertNil(SFTPSearchCommand.parseListLine("no tabs here"))
        XCTAssertNil(SFTPSearchCommand.parseListLine("x\ty\t/srv/a"))   // non-numeric fields
    }

    // MARK: - S3 candidate mapping

    private func s3Objects(_ keys: [String]) -> [S3ObjectInfo] {
        keys.map { S3ObjectInfo(key: $0, size: 7, modified: Date(timeIntervalSince1970: 1700000000)) }
    }

    func testS3CandidatePathsAreBucketAbsolute() {
        // The panel sits at /data/logs, so prefix = "logs/" — a hit's path must be
        // /data/<full key>, NOT the panel path + rel (which would double "logs/").
        let hits = FileSearch.s3Candidates(
            s3Objects(["logs/app.log", "logs/deep/app.log"]),
            bucket: "data", prefix: "logs/",
            matcher: SearchNameMatcher(pattern: "*.log", isRegex: false), subfolders: true)
        XCTAssertEqual(hits.map(\.path), ["/data/logs/app.log", "/data/logs/deep/app.log"])
        XCTAssertEqual(hits[0].size, 7)
    }

    func testS3CandidatesSkipFolderMarkersAndHonourSubfolders() {
        let objects = s3Objects(["logs/", "logs/app.log", "logs/deep/app.log"])
        let all = SearchNameMatcher(pattern: "*", isRegex: false)
        let shallow = FileSearch.s3Candidates(objects, bucket: "data", prefix: "logs/",
                                              matcher: all, subfolders: false)
        XCTAssertEqual(shallow.map(\.path), ["/data/logs/app.log"])
        let deep = FileSearch.s3Candidates(objects, bucket: "data", prefix: "logs/",
                                           matcher: all, subfolders: true)
        XCTAssertEqual(deep.count, 2)   // the "logs/" placeholder is never a hit
    }

    func testS3CandidatesMatchOnTheLeafName() {
        let hits = FileSearch.s3Candidates(
            s3Objects(["logs/deep/report.txt", "logs/report-dir/other.txt"]),
            bucket: "data", prefix: "logs/",
            matcher: SearchNameMatcher(pattern: "report", isRegex: false), subfolders: true)
        XCTAssertEqual(hits.map(\.path), ["/data/logs/deep/report.txt"])
    }

    // MARK: - Remote result items

    func testRemoteSearchResultItemsUseSuppliedMetadata() {
        let hits = [SearchHit(path: "/home/u/logs/a.log", size: 42,
                              modified: Date(timeIntervalSince1970: 1700000000))]
        let meta = Dictionary(hits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let items = PanelState.remoteSearchResultItems(paths: hits.map(\.path),
                                                       base: "/home/u", meta: meta)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "logs/a.log")      // relative to the search base
        XCTAssertEqual(items[0].path, "/home/u/logs/a.log")
        XCTAssertEqual(items[0].size, 42)
        XCTAssertFalse(items[0].isDirectory)
    }

    func testRemoteSearchResultItemsFallBackToLeafOutsideBase() {
        // S3 keys are absolute inside the bucket, so a hit can sit outside the
        // panel path the search started from.
        let items = PanelState.remoteSearchResultItems(paths: ["/bucket/deep/key.txt"],
                                                       base: "/bucket/other", meta: [:])
        XCTAssertEqual(items[0].name, "key.txt")
        XCTAssertEqual(items[0].size, 0)
    }

    // MARK: - One-directory-at-a-time walk (Android / MTP)

    /// Fake tree: dir path -> children. Mirrors what AndroidFS.listDirectory returns.
    private func lister(_ tree: [String: [(String, Bool)]],
                        failing: Set<String> = [],
                        visited: (@Sendable (String) -> Void)? = nil)
        -> (String) async throws -> [FileItem] {
        return { dir in
            visited?(dir)
            if failing.contains(dir) { throw MTPError(message: "unreadable \(dir)") }
            return (tree[dir] ?? []).map { name, isDir in
                FileItem(id: UUID(), name: name,
                         path: dir == "/" ? "/" + name : dir + "/" + name,
                         isDirectory: isDir, isArchive: false, size: 11,
                         modified: Date(timeIntervalSince1970: 1700000000),
                         isHidden: false, isSymlink: false, permissions: "")
            }
        }
    }

    private func makeProgress() -> SearchProgress { SearchProgress(report: { _, _ in }) }

    func testWalkRecursesAndMatchesOnTheLeafName() async throws {
        let tree: [String: [(String, Bool)]] = [
            "/Internal": [("DCIM", true), ("note.txt", false)],
            "/Internal/DCIM": [("Camera", true), ("readme.txt", false)],
            "/Internal/DCIM/Camera": [("IMG_1.jpg", false), ("deep.txt", false)],
        ]
        let hits = try await FileSearch.walk(
            base: "/Internal", subfolders: true,
            matcher: SearchNameMatcher(pattern: "*.txt", isRegex: false),
            progress: makeProgress(), list: lister(tree))
        XCTAssertEqual(hits.map(\.path).sorted(),
                       ["/Internal/DCIM/Camera/deep.txt", "/Internal/DCIM/readme.txt",
                        "/Internal/note.txt"])
        XCTAssertEqual(hits.first?.size, 11)   // metadata rides along, no second stat
    }

    func testWalkStopsAtOneLevelWhenSubfoldersIsOff() async throws {
        let tree: [String: [(String, Bool)]] = [
            "/Internal": [("DCIM", true), ("note.txt", false)],
            "/Internal/DCIM": [("deep.txt", false)],
        ]
        var seen: [String] = []
        let lock = NSLock()
        let hits = try await FileSearch.walk(
            base: "/Internal", subfolders: false,
            matcher: SearchNameMatcher(pattern: "*", isRegex: false),
            progress: makeProgress(),
            list: lister(tree, visited: { d in lock.lock(); seen.append(d); lock.unlock() }))
        XCTAssertEqual(hits.map(\.path), ["/Internal/note.txt"])
        XCTAssertEqual(seen, ["/Internal"], "must not descend — each listing is a USB round-trip")
    }

    /// The first listing failing means the device is gone; that has to surface
    /// rather than look like "no matches".
    func testWalkPropagatesTheFirstListingFailure() async {
        let l = lister([:], failing: ["/Internal"])
        do {
            _ = try await FileSearch.walk(base: "/Internal", subfolders: true,
                                          matcher: SearchNameMatcher(pattern: "*", isRegex: false),
                                          progress: makeProgress(), list: l)
            XCTFail("expected the first listing error to propagate")
        } catch {
            XCTAssertTrue("\(error)".contains("unreadable"))
        }
    }

    /// …but one unreadable folder deeper in must not abort the whole search.
    func testWalkSkipsDeeperUnreadableFolders() async throws {
        let tree: [String: [(String, Bool)]] = [
            "/Internal": [("good", true), ("bad", true)],
            "/Internal/good": [("found.txt", false)],
        ]
        let hits = try await FileSearch.walk(
            base: "/Internal", subfolders: true,
            matcher: SearchNameMatcher(pattern: "*", isRegex: false),
            progress: makeProgress(),
            list: lister(tree, failing: ["/Internal/bad"]))
        XCTAssertEqual(hits.map(\.path), ["/Internal/good/found.txt"])
    }

    // MARK: - Remote folder size (Space key)

    func testParseDuSize() {
        // GNU du: "<bytes>\t<path>"
        XCTAssertEqual(SFTPFS.parseDuSize("123456\t/home/ubuntu/logs\n"), 123456)
        // Some du variants pad with spaces instead of a tab.
        XCTAssertEqual(SFTPFS.parseDuSize("4096   /srv\n"), 4096)
        // Only the first line counts (du -s should emit one, but be strict anyway).
        XCTAssertEqual(SFTPFS.parseDuSize("42\t/a\n99\t/b\n"), 42)
        XCTAssertNil(SFTPFS.parseDuSize(""))
        XCTAssertNil(SFTPFS.parseDuSize("du: cannot access\n"))
    }

    func testRemoteSizeConcurrencyIsBounded() {
        // Each probe is a full round-trip; one per row of a big listing would
        // open that many ssh connections at once.
        XCTAssertEqual(PanelState.remoteSizeConcurrency(android: false), 4)
        // libmtp is funnelled through one serial queue per device — more tasks
        // would only pile up in front of the user's next action.
        XCTAssertEqual(PanelState.remoteSizeConcurrency(android: true), 1)
    }

    // MARK: - Local end-to-end

    private func makeTree() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("df-search-\(UUID().uuidString)")
        let sub = (dir as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try "alpha needle beta".write(toFile: (dir as NSString).appendingPathComponent("one.txt"),
                                      atomically: true, encoding: .utf8)
        try "nothing here".write(toFile: (dir as NSString).appendingPathComponent("two.txt"),
                                 atomically: true, encoding: .utf8)
        try "deep NEEDLE".write(toFile: (sub as NSString).appendingPathComponent("three.log"),
                                atomically: true, encoding: .utf8)
        var binary = Data("needle".utf8); binary.append(0x00)
        try binary.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("blob.bin")))
        return dir
    }

    func testLocalNameSearchRecursesAndReportsProgress() async throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var scannedSeen = 0
        let hits = try await FileSearch.run(
            endpoint: .local(base: dir),
            query: FileSearchQuery(namePattern: "*.txt", content: "", subfolders: true, regexName: false),
            report: { _, scanned in scannedSeen = max(scannedSeen, scanned) })
        XCTAssertEqual(hits.map { ($0.path as NSString).lastPathComponent }, ["one.txt", "two.txt"])
        XCTAssertGreaterThan(scannedSeen, 0)     // the final flush always reports
        XCTAssertGreaterThan(hits[0].size, 0)
    }

    func testLocalContentSearchSkipsBinariesAndFindsSubfolders() async throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let hits = try await FileSearch.run(
            endpoint: .local(base: dir),
            query: FileSearchQuery(namePattern: "*", content: "needle", subfolders: true, regexName: false),
            report: { _, _ in })
        let names = hits.map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(names, ["one.txt", "three.log"])   // blob.bin is binary → skipped
    }

    func testSubfoldersOffStaysShallow() async throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let hits = try await FileSearch.run(
            endpoint: .local(base: dir),
            query: FileSearchQuery(namePattern: "*", content: "needle", subfolders: false, regexName: false),
            report: { _, _ in })
        XCTAssertEqual(hits.map { ($0.path as NSString).lastPathComponent }, ["one.txt"])
    }

    func testCancellationStopsTheWalk() async throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let task = Task.detached { () -> [SearchHit] in
            try await FileSearch.run(
                endpoint: .local(base: dir),
                query: FileSearchQuery(namePattern: "*", content: "", subfolders: true, regexName: false),
                report: { _, _ in })
        }
        task.cancel()
        // A cancelled local walk returns what it had rather than throwing — the
        // sheet discards it either way; what matters is that it stops promptly.
        let hits = try await task.value
        XCTAssertLessThanOrEqual(hits.count, 4)
    }
}
