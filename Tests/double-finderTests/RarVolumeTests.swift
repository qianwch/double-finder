import XCTest
@testable import double_finder

/// Multi-volume RAR ("x.part1.rar" + "x.part2.rar"…): every volume has its own
/// headers, so the set is handed to libarchive as a file list and it switches
/// volumes itself. Fixtures need the `rar` tool (brew install rar); skips otherwise.
final class RarVolumeTests: XCTestCase {
    private let fm = FileManager.default
    private var dir = ""

    private static let rarTool = ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.rarTool == nil, "needs the rar tool to build the fixture")
        dir = NSTemporaryDirectory() + "rarvol-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir + "/src/sub", withIntermediateDirectories: true)
        // Random bytes: a patterned buffer compresses to under one volume and
        // the fixture silently comes out as a single "x.rar".
        var rng = SystemRandomNumberGenerator()
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try big.write(to: URL(fileURLWithPath: dir + "/src/big.bin"))
        try "hi".write(toFile: dir + "/src/sub/a.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if !dir.isEmpty { try? fm.removeItem(atPath: dir) }
    }

    /// RAR5 volumes of 100 KB → x.part1.rar, x.part2.rar, x.part3.rar.
    private func makeVolumes(_ extra: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.rarTool!)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["a", "-y", "-v100k", "-ma5"] + extra + ["x.rar", "src"]   // no -inul: this rar build exits 1 with it
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "rar failed to build the fixture")
        return dir + "/x.part1.rar"
    }

    func testSetIsRecognisedFromTheFirstVolumeOnly() throws {
        let first = try makeVolumes()
        let volumes = SplitVolumes.set(forFirstVolume: first)
        XCTAssertEqual(volumes.map { ($0 as NSString).lastPathComponent }, ["x.part1.rar", "x.part2.rar", "x.part3.rar"])
        XCTAssertTrue(SplitVolumes.isFirstVolume(first))
        XCTAssertTrue(SplitVolumes.isRarSet(first))
        XCTAssertFalse(SplitVolumes.isFirstVolume(dir + "/x.part2.rar"))
        XCTAssertEqual(SplitVolumes.set(forFirstVolume: dir + "/x.part2.rar").count, 1)
        XCTAssertEqual(ZipFS.kind(of: first), .rar)
    }

    /// The panel's entry path: the listing shows the full size of a file that
    /// spans three volumes, and extraction gives back every byte.
    func testListAndExtractAcrossVolumes() throws {
        let first = try makeVolumes()
        let entries = try ZipFS.entryDetails(archivePath: first, kind: .rar)
        XCTAssertTrue(entries.contains { $0.path == "src/big.bin" && $0.size == 300_000 }, "\(entries)")
        XCTAssertTrue(entries.contains { $0.path == "src/sub/a.txt" && $0.size == 2 })

        let out = dir + "/out"
        try ZipFS.extractAll(archivePath: first, to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out + "/src/big.bin")),
                       try Data(contentsOf: URL(fileURLWithPath: dir + "/src/big.bin")))

        // A single entry copied out lands flat, like from any other archive.
        let one = dir + "/one"
        try ZipFS.extractEntry(archivePath: first, entry: "src/sub/a.txt", to: one, kind: .rar)
        XCTAssertEqual(try String(contentsOfFile: one + "/a.txt", encoding: .utf8), "hi")
        XCTAssertFalse(fm.fileExists(atPath: one + "/src"))
    }

    /// A missing volume must surface as an error, never as a silently truncated file.
    func testMissingVolumeFailsLoudly() throws {
        let first = try makeVolumes()
        try fm.removeItem(atPath: dir + "/x.part3.rar")
        XCTAssertEqual(SplitVolumes.set(forFirstVolume: first).count, 2)
        let out = dir + "/out"
        XCTAssertThrowsError(try ZipFS.extractAll(archivePath: first, to: out))
    }

    /// Old-style naming ("x.rar" + "x.r00" + "x.r01"…) is the same set for libarchive.
    func testOldStyleNamingIsEnumerated() throws {
        let first = try makeVolumes()
        // Rename the new-style set into the old-style one.
        try fm.moveItem(atPath: first, toPath: dir + "/o.rar")
        try fm.moveItem(atPath: dir + "/x.part2.rar", toPath: dir + "/o.r00")
        try fm.moveItem(atPath: dir + "/x.part3.rar", toPath: dir + "/o.r01")
        let volumes = SplitVolumes.set(forFirstVolume: dir + "/o.rar")
        XCTAssertEqual(volumes.map { ($0 as NSString).lastPathComponent }, ["o.rar", "o.r00", "o.r01"])
        XCTAssertTrue(SplitVolumes.isRarSet(dir + "/o.rar"))
        let out = dir + "/out"
        try ZipFS.extractAll(archivePath: dir + "/o.rar", to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out + "/src/big.bin")),
                       try Data(contentsOf: URL(fileURLWithPath: dir + "/src/big.bin")))
    }
}
