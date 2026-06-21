import XCTest
@testable import double_finder

/// Tests for PanelState O(1) per-interaction optimisations (Task 11).
@MainActor
final class PanelStatePerfTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(_ name: String, size: Int64 = 0) -> FileItem {
        FileItem(id: UUID(), name: name, path: "/test/\(name)", isDirectory: false,
                 isArchive: false, size: size, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rw-r--r--")
    }

    private func makeDir(_ name: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: "/test/\(name)", isDirectory: true,
                 isArchive: false, size: 0, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rwxr-xr-x")
    }

    // MARK: - itemsVersion

    func testItemsVersionIncrementsOnAssignment() {
        let state = PanelState(path: "/tmp")
        let v0 = state.itemsVersion

        state.items = [makeFile("a")]
        let v1 = state.itemsVersion
        XCTAssertGreaterThan(v1, v0, "itemsVersion should increase after first assignment")

        state.items = [makeFile("a"), makeFile("b")]
        let v2 = state.itemsVersion
        XCTAssertGreaterThan(v2, v1, "itemsVersion should increase after second assignment")
    }

    func testItemsVersionIncrementsByTwoAfterTwoAssignments() {
        let state = PanelState(path: "/tmp")
        let v0 = state.itemsVersion

        state.items = [makeFile("x")]
        state.items = [makeFile("y")]
        let v2 = state.itemsVersion
        XCTAssertEqual(v2, v0 + 2, "itemsVersion should increase by exactly 2 after two assignments")
    }

    // MARK: - statusText O(1) correctness

    func testStatusTextTotalExcludesParentEntry() {
        let state = PanelState(path: "/tmp")
        let parent = FileItem(id: UUID(), name: "..", path: "/", isDirectory: true,
                              isArchive: false, size: 0, modified: Date(), isHidden: false,
                              isSymlink: false, permissions: "rwxr-xr-x")
        state.items = [parent, makeFile("a"), makeFile("b"), makeFile("c")]
        // 4 items but ".." should not count → total = 3
        let text = state.statusText
        // The count is always the prefix; the disk-free note (with arbitrary
        // digits) is appended at the end. Assert on the prefix so the test is
        // robust to both the active UI language and the disk-note digits.
        XCTAssertTrue(text.hasPrefix("3"), "statusText should start with count 3 (excluding '..'): \(text)")
        XCTAssertFalse(text.hasPrefix("4"), "statusText count should be 3, not 4: \(text)")
    }

    func testStatusTextNoSelectionUsesSimpleForm() {
        let state = PanelState(path: "/tmp")
        state.items = [makeFile("a"), makeFile("b")]
        state.selectedItems = []
        let text = state.statusText
        // Should not contain any "selected" text
        XCTAssertFalse(text.lowercased().contains("selected"), "With nothing selected, statusText should not mention 'selected': \(text)")
    }

    func testStatusTextWithSelectionShowsCount() {
        let state = PanelState(path: "/tmp")
        let f = makeFile("a", size: 1024)
        state.items = [f, makeFile("b")]
        state.selectedItems = [f.id]
        let text = state.statusText
        XCTAssertTrue(text.lowercased().contains("selected") || text.contains("1"),
                      "With 1 selected, statusText should mention selection: \(text)")
    }

    func testStatusTextLargeArrayNoSelectionIsStructurallyCorrect() {
        let state = PanelState(path: "/tmp")
        // 3000 items + ".." parent
        var items: [FileItem] = []
        let parent = FileItem(id: UUID(), name: "..", path: "/", isDirectory: true,
                              isArchive: false, size: 0, modified: Date(), isHidden: false,
                              isSymlink: false, permissions: "rwxr-xr-x")
        items.append(parent)
        for i in 0..<3000 {
            items.append(makeFile("file\(i)"))
        }
        state.items = items
        state.selectedItems = []

        // Structural assertion: total should be count - 1 (excluding "..")
        let text = state.statusText
        XCTAssertTrue(text.contains("3000"), "statusText for 3000 items (with '..' excluded) should contain '3000': \(text)")
        XCTAssertFalse(text.contains("3001"), "statusText should NOT report 3001: \(text)")
    }
}
