import XCTest
@testable import double_finder

final class ToolbarCommandTests: XCTestCase {

    private func expand(_ t: String) -> String {
        ToolbarCommand.expand(t, activeDir: "/tmp/a dir", otherDir: "/dst",
                              cursorName: "it's.txt", selectedPaths: ["/x/1.txt", "/x/2 b.txt"])
    }

    func testPlaceholders() {
        XCTAssertEqual(expand("ls %P"), "ls '/tmp/a dir'")
        XCTAssertEqual(expand("cp %S %T"), "cp '/x/1.txt' '/x/2 b.txt' '/dst'")
        XCTAssertEqual(expand("echo %N"), "echo 'it'\\''s.txt'")
        XCTAssertEqual(expand("no placeholders"), "no placeholders")
    }

    func testPercentEscapes() {
        XCTAssertEqual(expand("100%%"), "100%")
        XCTAssertEqual(expand("%%P"), "%P")                       // escaped, not expanded
        XCTAssertEqual(expand("%z"), "%z")                        // unknown passes through
        XCTAssertEqual(expand("50%"), "50%")                      // trailing bare percent
    }

    func testShellQuote() {
        XCTAssertEqual(ToolbarCommand.shellQuote("plain"), "'plain'")
        XCTAssertEqual(ToolbarCommand.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ToolbarCommand.shellQuote(""), "''")
    }

    func testCustomButtonRoundTripAndValidation() {
        let b = CustomToolbarButton(title: "Hi", symbol: "hammer", command: "echo hi")
        XCTAssertTrue(b.id.hasPrefix("custom."))
        XCTAssertEqual(CustomToolbarButton(dictionary: b.asDictionary), b)
        XCTAssertNil(CustomToolbarButton(dictionary: ["id": "notcustom", "title": "x", "command": "y"]))
        XCTAssertNil(CustomToolbarButton(dictionary: ["id": "custom.1", "title": "", "command": "y"]))
        XCTAssertNil(CustomToolbarButton(dictionary: ["id": "custom.1", "title": "x", "command": ""]))
    }

    func testStoreRoundTrip() {
        let saved = UserDefaults.standard.object(forKey: "CustomToolbarButtons")
        defer {
            if let v = saved { UserDefaults.standard.set(v, forKey: "CustomToolbarButtons") }
            else { UserDefaults.standard.removeObject(forKey: "CustomToolbarButtons") }
        }
        UserDefaults.standard.removeObject(forKey: "CustomToolbarButtons")
        let b = CustomToolbarButton(title: "Deploy", symbol: "paperplane", command: "make deploy %P")
        CustomToolbarButtons.add(b)
        XCTAssertEqual(CustomToolbarButtons.all(), [b])
        CustomToolbarButtons.remove(id: b.id)
        XCTAssertTrue(CustomToolbarButtons.all().isEmpty)
    }
}
