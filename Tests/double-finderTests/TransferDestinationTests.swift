import XCTest
@testable import double_finder

/// TC-style destination parsing for the Copy/Move confirm dialog: single item →
/// the field is prefilled with `<destDir>/<name>` and editing the last component
/// renames on transfer; multiple items → prefilled with `<destDir>/*.*` and the
/// mask is stripped back to the directory.
final class TransferDestinationTests: XCTestCase {

    private func notADir(_ path: String) -> Bool { false }

    // MARK: multiple items

    func testMultiMaskStripsToDirectory() {
        let d = TransferDestination.parse("/dst/*.*", singleSourceName: nil, isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertNil(d.renameTo)
    }

    func testMultiPlainDirectory() {
        let d = TransferDestination.parse("/dst/sub", singleSourceName: nil, isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst/sub")
        XCTAssertNil(d.renameTo)
    }

    func testMultiTrailingSlash() {
        let d = TransferDestination.parse("/dst/sub/", singleSourceName: nil, isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst/sub")
        XCTAssertNil(d.renameTo)
    }

    // MARK: single item

    func testSingleUneditedDefaultKeepsName() {
        let d = TransferDestination.parse("/dst/f.txt", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertNil(d.renameTo)
    }

    func testSingleEditedLastComponentRenames() {
        let d = TransferDestination.parse("/dst/g.txt", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertEqual(d.renameTo, "g.txt")
    }

    func testSingleUneditedDefaultIsNotDirProbed() {
        // Source folder "dir" and dest already has a folder "dir": the unedited
        // default "/dst/dir" must mean "overwrite/merge /dst/dir", never
        // "copy into /dst/dir" (which would nest dir/dir).
        let d = TransferDestination.parse("/dst/dir", singleSourceName: "dir", isExistingDir: { _ in true })
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertNil(d.renameTo)
    }

    func testSingleExistingDirectoryTargetMeansCopyInto() {
        let d = TransferDestination.parse("/elsewhere/folder", singleSourceName: "f.txt",
                                          isExistingDir: { $0 == "/elsewhere/folder" })
        XCTAssertEqual(d.dir, "/elsewhere/folder")
        XCTAssertNil(d.renameTo)
    }

    func testSingleTrailingSlashForcesDirectory() {
        let d = TransferDestination.parse("/dst/sub/", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst/sub")
        XCTAssertNil(d.renameTo)
    }

    func testSingleMaskStripsToDirectory() {
        let d = TransferDestination.parse("/dst/*.*", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertNil(d.renameTo)
    }

    func testRootDestination() {
        let d = TransferDestination.parse("/", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/")
        XCTAssertNil(d.renameTo)
    }

    func testSingleRenameAtRoot() {
        let d = TransferDestination.parse("/g.txt", singleSourceName: "f.txt", isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/")
        XCTAssertEqual(d.renameTo, "g.txt")
    }

    // MARK: virtual listing (search results / branch view) leaf normalization

    /// Regression: copying a single file from a search-results / branch-view
    /// listing, whose `name` is a display *path* ("subA/report.docx"). Feeding
    /// the raw path-name into the prefill/parse mis-detects a rename into a
    /// non-existent "<dst>/subA" sub-folder — the copy then fails with
    /// "file doesn't exist". The pipeline flattens `name` to its leaf first.
    func testTransferNameFlattensDisplayPathToLeaf() {
        XCTAssertEqual(TransferDestination.transferName(for: "subA/report.docx"), "report.docx")
        XCTAssertEqual(TransferDestination.transferName(for: "a/b/deep/notes.md"), "notes.md")
    }

    func testTransferNameLeavesPlainLeafUntouched() {
        XCTAssertEqual(TransferDestination.transferName(for: "report.docx"), "report.docx")
    }

    /// The pre-fix bug, pinned: the raw display-path name parses as a rename into
    /// a sub-folder that doesn't exist at the destination.
    func testDisplayPathNameMisparsesAsSubfolderRename() {
        let name = "subA/report.docx"
        let prefill = "/dst/" + name
        let d = TransferDestination.parse(prefill, singleSourceName: name, isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst/subA")       // non-existent sub-folder → copy fails
        XCTAssertEqual(d.renameTo, "report.docx")
    }

    /// The fix end-to-end: flattening the name to its leaf before prefill/parse
    /// yields a plain flat copy into the destination directory, no rename.
    func testFlattenedNameParsesAsFlatCopyIntoDestDir() {
        let leaf = TransferDestination.transferName(for: "subA/report.docx")
        let prefill = "/dst/" + leaf
        let d = TransferDestination.parse(prefill, singleSourceName: leaf, isExistingDir: notADir)
        XCTAssertEqual(d.dir, "/dst")
        XCTAssertNil(d.renameTo)
    }
}

/// Rename-aware self-transfer guard: copying a file to its own directory under a
/// NEW name is legitimate (TC allows it); under the same name it stays blocked.
final class SelfTransferRenameTests: XCTestCase {
    func testRenameInSameDirIsAllowed() {
        let blocked = FileOperation.selfTransferSources(["/a/f.txt"], destDir: "/a", renameTo: "g.txt")
        XCTAssertTrue(blocked.isEmpty)
    }

    func testSameNameViaRenameIsBlocked() {
        let blocked = FileOperation.selfTransferSources(["/a/f.txt"], destDir: "/a", renameTo: "f.txt")
        XCTAssertEqual(blocked, ["/a/f.txt"])
    }

    func testFolderIntoItselfStillBlockedWithRename() {
        let blocked = FileOperation.selfTransferSources(["/a/dir"], destDir: "/a/dir/sub", renameTo: "copy")
        XCTAssertEqual(blocked, ["/a/dir"])
    }
}

/// Rename-on-transfer threading through the pure backend path builders.
final class RenameOnTransferPathTests: XCTestCase {
    func testS3DownloadSingleFileRename() {
        XCTAssertEqual(
            S3TransferPlanner.downloadLocalPath(key: "dir/o.bin", folderKey: nil,
                                                destDir: "/dst", renameTo: "new.bin"),
            "/dst/new.bin")
    }

    func testS3DownloadFolderRenameReplacesRootOnly() {
        XCTAssertEqual(
            S3TransferPlanner.downloadLocalPath(key: "photos/2024/a.jpg", folderKey: "photos/",
                                                destDir: "/dst", renameTo: "pics"),
            "/dst/pics/2024/a.jpg")
    }

    func testS3UploadSingleFileRename() {
        XCTAssertEqual(
            S3TransferPlanner.uploadKey(localPath: "/src/f.txt", folderRoot: nil,
                                        destPrefix: "pre/", renameTo: "g.txt"),
            "pre/g.txt")
    }

    func testS3UploadFolderRenameReplacesRootOnly() {
        XCTAssertEqual(
            S3TransferPlanner.uploadKey(localPath: "/src/dir/sub/f.txt", folderRoot: "/src/dir",
                                        destPrefix: "pre/", renameTo: "renamed"),
            "pre/renamed/sub/f.txt")
    }

    func testSFTPServerCopyCommandRename() {
        XCTAssertEqual(
            SFTPFS.serverTransferCommand(from: "/home/u/f.txt", toDir: "/home/u/dst",
                                         move: false, renameTo: "g.txt"),
            "cp -af -- '/home/u/f.txt' '/home/u/dst/g.txt'")
    }

    func testSFTPServerMoveCommandWithoutRenameUnchanged() {
        XCTAssertEqual(
            SFTPFS.serverTransferCommand(from: "/a/f", toDir: "/b", move: true),
            "mv -f -- '/a/f' '/b/'")
    }
}
