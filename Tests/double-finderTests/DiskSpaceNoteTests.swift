import XCTest
@testable import double_finder

/// The status-bar free-space note used to be cached by path only, so it never
/// changed while a panel stayed in one directory (copy/delete didn't move it).
/// It is now stored state refreshed by `refreshDiskSpace()`.
@MainActor
final class DiskSpaceNoteTests: XCTestCase {

    // MARK: - Formatting (pure)

    func testNoteIsEmptyWhenCapacityUnreadable() {
        XCTAssertEqual(PanelState.diskNote(for: nil), "")
    }

    func testNoteMentionsBothFreeAndTotal() {
        let note = PanelState.diskNote(for: (free: 407_270_000_000, total: 2_000_000_000_000))
        XCTAssertTrue(note.contains("407"), "note should carry the free figure: \(note)")
        XCTAssertTrue(note.contains("2"), "note should carry the total figure: \(note)")
        XCTAssertTrue(note.hasPrefix("  ·  "), "note is a status-bar suffix: \(note)")
    }

    func testNoteChangesWhenFreeSpaceChanges() {
        let a = PanelState.diskNote(for: (free: 100_000_000_000, total: 2_000_000_000_000))
        let b = PanelState.diskNote(for: (free: 200_000_000_000, total: 2_000_000_000_000))
        XCTAssertNotEqual(a, b, "a different free figure must produce a different note")
    }

    // MARK: - Refresh

    func testRefreshFillsNoteForLocalPath() {
        let state = PanelState(path: "/tmp")
        XCTAssertEqual(state.diskNote, "", "starts empty until probed")

        let filled = expectation(description: "disk note filled")
        state.onDiskSpaceChange = { filled.fulfill() }
        state.refreshDiskSpace()
        wait(for: [filled], timeout: 5)

        XCTAssertFalse(state.diskNote.isEmpty, "local volume should report capacity")
    }

    func testRefreshClearsNoteWhenPanelGoesRemote() {
        let state = PanelState(path: "/tmp")
        let filled = expectation(description: "disk note filled")
        state.onDiskSpaceChange = { filled.fulfill() }
        state.refreshDiskSpace()
        wait(for: [filled], timeout: 5)
        XCTAssertFalse(state.diskNote.isEmpty)

        // Connecting to a remote makes the local figure meaningless.
        state.sftp = SFTPConnection(host: "h", user: "u")
        let cleared = expectation(description: "disk note cleared")
        state.onDiskSpaceChange = { cleared.fulfill() }
        state.refreshDiskSpace()
        wait(for: [cleared], timeout: 1)

        XCTAssertEqual(state.diskNote, "", "remote listings have no local free space")
    }

    func testRefreshDropsReadingFromAPathWeLeft() {
        let state = PanelState(path: "/tmp")
        let filled = expectation(description: "disk note filled")
        state.onDiskSpaceChange = { filled.fulfill() }
        state.refreshDiskSpace()
        wait(for: [filled], timeout: 5)
        let note = state.diskNote

        // A reading that lands after the panel moved elsewhere must be ignored.
        state.onDiskSpaceChange = { XCTFail("stale reading should not be applied") }
        state.applyDiskSpace((free: 1, total: 2), readAt: "/some/other/path")
        XCTAssertEqual(state.diskNote, note, "note should keep the value read for the current path")
    }
}
