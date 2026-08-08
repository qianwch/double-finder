import XCTest
@testable import double_finder

/// Named column sets — uses the real UserDefaults key, so snapshot/restore.
final class ColumnSetsTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: "ColumnSets")
        UserDefaults.standard.removeObject(forKey: "ColumnSets")
    }

    override func tearDown() {
        if let v = saved { UserDefaults.standard.set(v, forKey: "ColumnSets") }
        else { UserDefaults.standard.removeObject(forKey: "ColumnSets") }
    }

    func testRoundTrip() {
        ColumnSets.save(name: "Full", columns: ["size", "date", "kind"])
        ColumnSets.save(name: "Slim", columns: ["size"])
        XCTAssertEqual(ColumnSets.all(), [ColumnSet(name: "Full", columns: ["size", "date", "kind"]),
                                          ColumnSet(name: "Slim", columns: ["size"])])
    }

    func testSaveReplacesSameName() {
        ColumnSets.save(name: "Full", columns: ["size"])
        ColumnSets.save(name: "Full", columns: ["size", "date"])
        XCTAssertEqual(ColumnSets.all(), [ColumnSet(name: "Full", columns: ["size", "date"])])
    }

    func testRemove() {
        ColumnSets.save(name: "A", columns: ["size"])
        ColumnSets.save(name: "B", columns: ["date"])
        ColumnSets.remove(name: "A")
        XCTAssertEqual(ColumnSets.all().map(\.name), ["B"])
    }

    func testGarbageEntriesSkipped() {
        UserDefaults.standard.set([["name": "ok", "columns": ["size"]],
                                   ["columns": ["x"]],            // no name
                                   ["name": "", "columns": []],   // empty name
                                   ["name": "bad"]],              // no columns
                                  forKey: "ColumnSets")
        XCTAssertEqual(ColumnSets.all(), [ColumnSet(name: "ok", columns: ["size"])])
    }
}
