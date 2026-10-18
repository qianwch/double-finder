import XCTest
@testable import double_finder

/// Sorting must update every expanded directory without collapsing the tree or reloading it.
@MainActor
final class PanelSortingTests: XCTestCase {
    private var root: URL!
    private var savedFoldersFirst: Any?

    override func setUpWithError() throws {
        savedFoldersFirst = UserDefaults.standard.object(forKey: "FoldersFirst")
        AppSettings.foldersFirst = true
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PanelSorting-\(UUID().uuidString)")
        for directory in ["", "folder", "folder/nested"] {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, size, modified) in [("a-large.txt", 30, 300.0), ("z-small.txt", 10, 100.0)] {
                let file = url.appendingPathComponent(name)
                try Data(repeating: 0, count: size).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                                      ofItemAtPath: file.path)
            }
        }
    }

    override func tearDownWithError() throws {
        if let savedFoldersFirst {
            UserDefaults.standard.set(savedFoldersFirst, forKey: "FoldersFirst")
        } else {
            UserDefaults.standard.removeObject(forKey: "FoldersFirst")
        }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func expandedPanel() async throws -> PanelState {
        let panel = PanelState(path: root.path)
        panel.loadDirectory()
        for _ in 0..<400 where panel.isLoading { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(panel.isLoading)
        for relativePath in ["folder", "folder/nested"] {
            let path = root.appendingPathComponent(relativePath).path
            let directory = try XCTUnwrap(panel.items.first { $0.path == path },
                                          "Missing \(path); loaded \(panel.items.map(\.path))")
            let childPath = root.appendingPathComponent(relativePath + "/a-large.txt").path
            panel.toggleExpand(directory)
            for _ in 0..<400 where !panel.items.contains(where: { $0.path == childPath }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(panel.items.contains { $0.path == childPath })
        }
        return panel
    }

    private func relativePaths(_ panel: PanelState) -> [String] {
        panel.items.filter { $0.name != ".." }.map { String($0.path.dropFirst(root.path.count + 1)) }
    }

    /// Header changes synchronously reorder both expanded levels and notify with preserved path-based state.
    func testChangingColumnSortsEveryExpandedLevelAndPreservesState() async throws {
        let panel = try await expandedPanel()
        let cursorPath = root.appendingPathComponent("folder/nested/a-large.txt").path
        panel.cursorIndex = try XCTUnwrap(panel.items.firstIndex { $0.path == cursorPath })
        let selectedPaths: Set<String> = [cursorPath, root.appendingPathComponent("a-large.txt").path]
        panel.selectedItems = Set(panel.items.filter { selectedPaths.contains($0.path) }.map(\.id))
        let expandedPaths = panel.expandedPaths
        let expected = ["folder", "folder/nested", "folder/nested/z-small.txt", "folder/nested/a-large.txt",
                        "folder/z-small.txt", "folder/a-large.txt", "z-small.txt", "a-large.txt"]

        for column: PanelState.SortColumn in [.modified, .size] {
            if panel.sortColumn != .name || !panel.sortAscending {
                panel.applySort(column: .name)
            }
            XCTAssertEqual(relativePaths(panel),
                           ["folder", "folder/nested", "folder/nested/a-large.txt", "folder/nested/z-small.txt",
                            "folder/a-large.txt", "folder/z-small.txt", "a-large.txt", "z-small.txt"])
            var notificationCount = 0
            panel.onChange = {
                notificationCount += 1
                XCTAssertEqual(self.relativePaths(panel), expected)
                XCTAssertEqual(panel.currentItem?.path, cursorPath)
                XCTAssertEqual(Set(panel.selectedPaths), selectedPaths)
            }
            defer { panel.onChange = nil }
            let version = panel.itemsVersion
            panel.applySort(column: column)
            XCTAssertEqual(relativePaths(panel), expected)
            XCTAssertEqual(panel.items.map(\.depth), [0, 0, 1, 2, 2, 1, 1, 0, 0])
            XCTAssertEqual(panel.expandedPaths, expandedPaths)
            XCTAssertGreaterThan(panel.itemsVersion, version)
            XCTAssertEqual(notificationCount, 1)
        }
    }

    /// Clicking the active column reverses children immediately, including nested directories.
    func testSameColumnTogglesExpandedChildrenInBothDirections() async throws {
        let panel = try await expandedPanel()
        let ascending = relativePaths(panel)
        panel.applySort(column: .name)
        XCTAssertFalse(panel.sortAscending)
        XCTAssertEqual(relativePaths(panel),
                       ["folder", "folder/nested", "folder/nested/z-small.txt", "folder/nested/a-large.txt",
                        "folder/z-small.txt", "folder/a-large.txt", "z-small.txt", "a-large.txt"])
        panel.applySort(column: .name)
        XCTAssertTrue(panel.sortAscending)
        XCTAssertEqual(relativePaths(panel), ascending)
    }

    /// Reapplying settings must intermix folders inside expanded parents as well as at the root.
    func testResortAppliesFoldersFirstToExpandedChildren() async throws {
        let panel = try await expandedPanel()
        let foldersFirst = relativePaths(panel)
        AppSettings.foldersFirst = false
        panel.resort()
        XCTAssertEqual(relativePaths(panel),
                       ["a-large.txt", "folder", "folder/a-large.txt", "folder/nested",
                        "folder/nested/a-large.txt", "folder/nested/z-small.txt", "folder/z-small.txt", "z-small.txt"])
        AppSettings.foldersFirst = true
        panel.resort()
        XCTAssertEqual(relativePaths(panel), foldersFirst)
    }
}
