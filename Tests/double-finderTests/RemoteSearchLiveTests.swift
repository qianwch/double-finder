import XCTest
@testable import double_finder

/// Live SFTP end-to-end test for Find Files against a remote host: name search,
/// server-side content grep (binaries skipped), non-recursive scoping and
/// cancellation. Skipped unless `SFTP_LIVE=1`. Run with:
///   SFTP_LIVE=1 swift test --filter RemoteSearchLiveTests
final class RemoteSearchLiveTests: XCTestCase {

    private let connection = SFTPConnection(
        host: "10.17.20.55", user: "ubuntu", port: 22,
        keyPath: "~/.ssh/id_rsa", remotePath: "/home/ubuntu", name: "df-test")

    private var fs: SFTPFS { SFTPFS(connection: connection) }

    private func search(root: String, name: String, content: String = "",
                        subfolders: Bool = true, regex: Bool = false) async throws -> [String] {
        let hits = try await FileSearch.run(
            endpoint: .sftp(connection, base: root),
            query: FileSearchQuery(namePattern: name, content: content,
                                   subfolders: subfolders, regexName: regex),
            report: { _, _ in })
        return hits.map { String($0.path.dropFirst(root.count + 1)) }.sorted()
    }

    func testRemoteFindFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SFTP_LIVE"] == "1", "set SFTP_LIVE=1 to run the live SFTP test")

        let root = "/home/ubuntu/df_search_\(ProcessInfo.processInfo.globallyUniqueString)"
        let q = SFTPFS.shellQuote(root)
        _ = try await fs.runCommand(
            "mkdir -p \(q)/sub && " +
            "printf 'alpha needle beta\\n' > \(q)/one.txt && " +
            "printf 'nothing here\\n' > \(q)/two.txt && " +
            "printf 'deep NEEDLE\\n' > \(q)/sub/three.log && " +
            "printf 'needle\\000\\001' > \(q)/blob.bin && " +
            "printf 'needle here\\n' > '\(root)/name with spaces.txt'")

        // --- name only, recursive: the *.txt files at both levels ---
        let byName = try await search(root: root, name: "*.txt")
        XCTAssertEqual(byName, ["name with spaces.txt", "one.txt", "two.txt"])

        // --- size + mtime ride along, so Feed to Panel has real columns ---
        let sized = try await FileSearch.run(
            endpoint: .sftp(connection, base: root),
            query: FileSearchQuery(namePattern: "one.txt", content: "",
                                   subfolders: true, regexName: false),
            report: { _, _ in })
        XCTAssertEqual(sized.count, 1)
        XCTAssertEqual(sized[0].size, 18)
        XCTAssertGreaterThan(sized[0].modified.timeIntervalSince1970, 1_600_000_000)

        // --- content: case-insensitive, recursive, and blob.bin must NOT match ---
        let byContent = try await search(root: root, name: "*", content: "needle")
        XCTAssertEqual(byContent, ["name with spaces.txt", "one.txt", "sub/three.log"])

        // --- name + content combined ---
        let combined = try await search(root: root, name: "*.log", content: "needle")
        XCTAssertEqual(combined, ["sub/three.log"])

        // --- regex names can't be pushed into find -iname; filtering still exact ---
        let byRegex = try await search(root: root, name: "^one\\.txt$", content: "needle", regex: true)
        XCTAssertEqual(byRegex, ["one.txt"])

        // --- subfolders off stays at the top level ---
        let shallow = try await search(root: root, name: "*", content: "needle", subfolders: false)
        XCTAssertEqual(shallow, ["name with spaces.txt", "one.txt"])

        try await cleanUp(root)
    }

    /// Deliberately NOT `defer { Task { … } }`: a detached task is not guaranteed
    /// to run before the test process exits, so that shape silently leaves the
    /// fixture on the server (it really did, in the S3 sibling of this test).
    private func cleanUp(_ root: String) async throws {
        _ = try? await fs.runCommand("rm -rf \(SFTPFS.shellQuote(root))")
        let leftovers = try await fs.runCommand("ls -d \(SFTPFS.shellQuote(root)) 2>/dev/null")
        XCTAssertTrue(leftovers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "fixture left on the server: \(leftovers)")
    }

    /// A remote search must actually stop: cancelling kills the ssh process
    /// instead of leaving `find` running with nobody to read it.
    func testCancellationReturnsPromptly() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SFTP_LIVE"] == "1", "set SFTP_LIVE=1 to run the live SFTP test")

        let started = Date()
        let task = Task.detached { [connection] in
            try await FileSearch.run(
                endpoint: .sftp(connection, base: "/"),
                query: FileSearchQuery(namePattern: "*", content: "zzz-no-such-token-zzz",
                                       subfolders: true, regexName: false),
                report: { _, _ in })
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "cancelling a remote search must not wait for find / to finish")
    }
}

/// Live SFTP test for the Space-key folder size (`SFTPFS.directorySize`).
/// Skipped unless `SFTP_LIVE=1`.
final class SFTPDirectorySizeLiveTests: XCTestCase {
    private let connection = SFTPConnection(
        host: "10.17.20.55", user: "ubuntu", port: 22,
        keyPath: "~/.ssh/id_rsa", remotePath: "/home/ubuntu", name: "df-test")
    private var fs: SFTPFS { SFTPFS(connection: connection) }

    func testDirectorySizeMatchesTheFilesWePut() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SFTP_LIVE"] == "1", "set SFTP_LIVE=1 to run the live SFTP test")

        let root = "/home/ubuntu/df_dusize_\(ProcessInfo.processInfo.globallyUniqueString)"
        let q = SFTPFS.shellQuote(root)
        // 3000 + 5000 bytes across two levels; `du` counts allocated blocks for
        // the directories too, so assert a lower bound plus a sane ceiling.
        _ = try await fs.runCommand(
            "mkdir -p \(q)/sub && head -c 3000 /dev/zero > \(q)/a.bin && " +
            "head -c 5000 /dev/zero > \(q)/sub/b.bin")

        var failure: Error?
        do {
            let size = await fs.directorySize(root)
            XCTAssertGreaterThanOrEqual(size, 8000, "must include the nested file")
            XCTAssertLessThan(size, 200_000, "should not be wildly off (got \(size))")
            // A single file's parent with nothing else in it.
            let subSize = await fs.directorySize(root + "/sub")
            XCTAssertGreaterThanOrEqual(subSize, 5000)
            XCTAssertLessThan(subSize, size)
        } catch { failure = error }

        _ = try? await fs.runCommand("rm -rf \(q)")
        let leftovers = try await fs.runCommand("ls -d \(q) 2>/dev/null")
        XCTAssertTrue(leftovers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let failure = failure { throw failure }
    }
}
