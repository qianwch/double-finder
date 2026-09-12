import XCTest
@testable import double_finder
final class FileColumnLayoutTests: XCTestCase {
    func testNameFlexFillsRemaining() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size","date"], widths: [:])
        // size=80, date=130 (defaults) → name = 600-210 = 390
        XCTAssertEqual(l.columns.first?.id, "name")
        XCTAssertEqual(l.nameWidth, 390, accuracy: 0.5)
    }
    func testColumnAtXAndDivider() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size"], widths: [:])
        XCTAssertEqual(l.column(atX: 5), "name")
        XCTAssertEqual(l.column(atX: 595), "size")
        XCTAssertEqual(l.resizeDivider(atX: l.xRange(of: "name")!.upperBound, tolerance: 4), "name")
        XCTAssertNil(l.resizeDivider(atX: 300, tolerance: 4))
    }
    func testWidthOverridePersisted() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size"], widths: ["size": 120])
        XCTAssertEqual(l.xRange(of: "size").map { $0.upperBound - $0.lowerBound }, 120)
    }
}

/// Header drag-to-reorder (2026-09-12): drop slots, insertion line and the
/// pure list edits behind it.
final class FileColumnReorderTests: XCTestCase {
    // name = 600-80-130-130 = 260 wide, then size 80 (260–340), date 130 (340–470), kind 130 (470–600)
    private let layout = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date", "kind"], widths: [:])

    func testDropSlotFlipsAtColumnCentres() {
        XCTAssertEqual(layout.dropSlot(atX: 10), 0, "anywhere over Name → first optional slot")
        XCTAssertEqual(layout.dropSlot(atX: 290), 0, "left half of size → before size")
        XCTAssertEqual(layout.dropSlot(atX: 310), 1, "right half of size → after size")
        XCTAssertEqual(layout.dropSlot(atX: 400), 1)
        XCTAssertEqual(layout.dropSlot(atX: 450), 2)
        XCTAssertEqual(layout.dropSlot(atX: 590), 3, "past the last centre → end")
        XCTAssertEqual(layout.dropSlot(atX: 5000), 3)
    }

    func testDropLineXIsTheSlotBoundary() {
        XCTAssertEqual(layout.dropLineX(forSlot: 0), 260)
        XCTAssertEqual(layout.dropLineX(forSlot: 1), 340)
        XCTAssertEqual(layout.dropLineX(forSlot: 3), 600)
    }

    func testMovedHandlesBothDirectionsAndNoOps() {
        let ids = ["size", "date", "kind"]
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "kind", toSlot: 0), ["kind", "size", "date"])
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "size", toSlot: 3), ["date", "kind", "size"])
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "size", toSlot: 2), ["date", "size", "kind"])
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "size", toSlot: 0), ids, "dropping on its own slot")
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "size", toSlot: 1), ids, "slot right after itself = no move")
        XCTAssertEqual(FileColumnLayout.moved(ids, id: "nope", toSlot: 1), ids)
    }

    func testInsertedKeepsUserOrderAndSlotsByCatalogueRank() {
        let canonical = ["size", "date", "added", "created", "kind", "perms"]
        // User reordered to kind, size; turning on "date" lands after size (the last lower-ranked one).
        XCTAssertEqual(FileColumnLayout.inserted(["kind", "size"], adding: "date", canonical: canonical),
                       ["kind", "size", "date"])
        XCTAssertEqual(FileColumnLayout.inserted(["kind", "size"], adding: "added", canonical: canonical),
                       ["kind", "size", "added"])
        // Nothing ranks lower than size → front.
        XCTAssertEqual(FileColumnLayout.inserted(["kind", "date"], adding: "size", canonical: canonical),
                       ["size", "kind", "date"])
        XCTAssertEqual(FileColumnLayout.inserted(["size"], adding: "size", canonical: canonical), ["size"])
        XCTAssertEqual(FileColumnLayout.inserted([], adding: "plugin.x.y", canonical: canonical), ["plugin.x.y"])
        // Unknown ids rank last, so a plugin column goes to the end.
        XCTAssertEqual(FileColumnLayout.inserted(["size", "date"], adding: "plugin.x.y", canonical: canonical),
                       ["size", "date", "plugin.x.y"])
    }

    func testLayoutHonorsVisibleOrder() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["kind", "size"], widths: [:])
        XCTAssertEqual(l.columns.map { $0.id }, ["name", "kind", "size"])
    }
}
