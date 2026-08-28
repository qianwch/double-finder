import XCTest
@testable import double_finder

@MainActor
final class ServerRailTests: XCTestCase {

    private func sftp(_ name: String, _ host: String, user: String = "root", port: Int = 22) -> ServerConnection {
        .sftp(SFTPConnection(host: host, user: user, port: port,
                             keyPath: "~/.ssh/id_rsa", remotePath: "~", name: name))
    }
    private func s3(_ name: String, endpoint: String, bucket: String = "") -> ServerConnection {
        .s3(S3Connection(name: name, endpoint: endpoint, region: "r", bucket: bucket,
                         accessKey: "AK", pathStyle: true))
    }
    private func service(_ name: String, host: String) -> NetworkBrowser.Service {
        NetworkBrowser.Service(name: name, kind: .smb, host: host, port: nil)
    }

    // MARK: - Subtitles (the reason rows got a second line at all)

    func testSubtitleTellsSimilarlyNamedEntriesApart() {
        XCTAssertEqual(sftp("xac", "10.0.0.1").subtitle, "root@10.0.0.1")
        // A non-default port is worth showing; 22 is not.
        XCTAssertEqual(sftp("x", "h", port: 2222).subtitle, "root@h:2222")
        // Bucket first: it is what differs between two connections to one endpoint,
        // and the rail is narrow enough that the head is what survives truncation.
        XCTAssertEqual(s3("a", endpoint: "https://obs.example.com", bucket: "logs").subtitle,
                       "logs · obs.example.com")
        XCTAssertEqual(s3("a", endpoint: "https://obs.example.com").subtitle, "obs.example.com")
        XCTAssertEqual(ServerConnection.smb(SMBConnection(name: "nas", host: "nas.local")).subtitle,
                       "nas.local")
    }

    // MARK: - Rail composition

    func testSectionsAndEmptyStates() {
        let rows = ServerRail.rows(saved: [sftp("xac", "h")], devices: [], discovered: [],
                                   scanningDevices: false, filter: "")
        // Saved section, its one entry, then Discovered with its empty-state line.
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], .header(tr("Saved")))
        XCTAssertEqual(rows[1], .saved(sftp("xac", "h")))
        XCTAssertEqual(rows[2], .header(tr("Discovered")))
        if case .note = rows[3] {} else { XCTFail("expected an empty-state note") }
        // No phone plugged in and no scan running: the section is absent, not empty.
        XCTAssertFalse(rows.contains(.header(tr("Connected devices"))))
    }

    func testDeviceSectionAppearsWhileScanning() {
        let rows = ServerRail.rows(saved: [], devices: [], discovered: [],
                                   scanningDevices: true, filter: "")
        XCTAssertTrue(rows.contains(.header(tr("Connected devices"))))
        XCTAssertTrue(rows.contains(.note(tr("Scanning…"))))
    }

    func testFilterKeepsOnlyMatchesAndDropsEmptyHeaders() {
        let rows = ServerRail.rows(saved: [sftp("xac", "10.0.0.1"), s3("changping", endpoint: "https://obs.example.com")],
                                   devices: [], discovered: [service("nas", host: "nas.local")],
                                   scanningDevices: false, filter: "chang")
        XCTAssertEqual(rows, [.header(tr("Saved")), .saved(s3("changping", endpoint: "https://obs.example.com"))])
        // A header with nothing under it would read as "this section is empty",
        // which is a lie during a search — so Discovered is gone entirely.
        XCTAssertFalse(rows.contains(.header(tr("Discovered"))))
    }

    func testFilterMatchesTheSubtitleToo() {
        let rows = ServerRail.rows(saved: [sftp("xac", "10.17.100.88")], devices: [], discovered: [],
                                   scanningDevices: false, filter: "10.17")
        XCTAssertEqual(rows.count, 2)
    }

    func testNoMatchesGivesOneNote() {
        let rows = ServerRail.rows(saved: [sftp("xac", "h")], devices: [], discovered: [],
                                   scanningDevices: false, filter: "zzz")
        XCTAssertEqual(rows, [.note(tr("No matches"))])
    }

    func testOnlyEntriesAreSelectable() {
        XCTAssertFalse(ServerRailRow.header("x").isSelectable)
        XCTAssertFalse(ServerRailRow.note("x").isSelectable)
        XCTAssertTrue(ServerRailRow.saved(sftp("x", "h")).isSelectable)
        XCTAssertTrue(ServerRailRow.discovered(service("n", host: "h")).isSelectable)
    }
}

/// `update` is what makes continuous editing safe — the window has no Save button.
final class ServerConnectionUpdateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ServerConnectionUpdateTests")!
        defaults.removePersistentDomain(forName: "ServerConnectionUpdateTests")
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: "ServerConnectionUpdateTests")
        super.tearDown()
    }

    private func sftp(_ name: String, _ host: String) -> ServerConnection {
        .sftp(SFTPConnection(host: host, user: "root", port: 22,
                             keyPath: "k", remotePath: "~", name: name))
    }

    func testRenameMovesTheEntryInsteadOfForkingIt() {
        ServerConnectionStore.add(sftp("a", "h1"), defaults: defaults)
        ServerConnectionStore.add(sftp("b", "h2"), defaults: defaults)
        ServerConnectionStore.update(oldKey: "sftp|a", to: sftp("a2", "h1"), defaults: defaults)
        let names = ServerConnectionStore.load(defaults: defaults).map(\.name)
        // Renamed in place: `add` would have appended a second row and left "a".
        XCTAssertEqual(names, ["a2", "b"])
    }

    func testEditKeepsPosition() {
        ServerConnectionStore.add(sftp("a", "h1"), defaults: defaults)
        ServerConnectionStore.add(sftp("b", "h2"), defaults: defaults)
        ServerConnectionStore.update(oldKey: "sftp|a", to: sftp("a", "changed"), defaults: defaults)
        let loaded = ServerConnectionStore.load(defaults: defaults)
        XCTAssertEqual(loaded.map(\.name), ["a", "b"])
        XCTAssertEqual(loaded[0].subtitle, "root@changed")
    }

    func testRenameOntoAnExistingNameDoesNotLeaveTwoRowsWithOneName() {
        ServerConnectionStore.add(sftp("a", "h1"), defaults: defaults)
        ServerConnectionStore.add(sftp("b", "h2"), defaults: defaults)
        ServerConnectionStore.update(oldKey: "sftp|a", to: sftp("b", "h1"), defaults: defaults)
        let names = ServerConnectionStore.load(defaults: defaults).map(\.name)
        XCTAssertEqual(names, ["b"])
        XCTAssertEqual(ServerConnectionStore.load(defaults: defaults)[0].subtitle, "root@h1")
    }

    func testUpdatingSomethingUnknownFallsBackToAdd() {
        ServerConnectionStore.update(oldKey: "sftp|ghost", to: sftp("new", "h"), defaults: defaults)
        XCTAssertEqual(ServerConnectionStore.load(defaults: defaults).map(\.name), ["new"])
    }

    func testLastConnectedFollowsARename() {
        let original = sftp("a", "h")
        ServerConnectionStore.add(original, defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        ServerConnectionStore.markConnected(original, at: when, defaults: defaults)
        let renamed = sftp("a2", "h")
        ServerConnectionStore.update(oldKey: original.storeKey, to: renamed, defaults: defaults)
        XCTAssertEqual(ServerConnectionStore.lastConnected(renamed, defaults: defaults), when)
        XCTAssertNil(ServerConnectionStore.lastConnected(original, defaults: defaults))
    }

    func testDeleteAlsoDropsTheTimestamp() {
        let c = sftp("a", "h")
        ServerConnectionStore.add(c, defaults: defaults)
        ServerConnectionStore.markConnected(c, defaults: defaults)
        ServerConnectionStore.delete(name: "a", kind: .sftp, defaults: defaults)
        XCTAssertNil(ServerConnectionStore.lastConnected(c, defaults: defaults))
    }
}

/// The connect path's secret rule. Its own test because getting it wrong
/// shipped: once the form stopped pre-filling the secret (that Keychain read
/// froze the window on selection), Connect passed the empty field straight
/// through and every saved S3 connection signed with no key.
final class S3SecretResolutionTests: XCTestCase {
    func testEmptyFieldFallsBackToTheStoredKey() {
        XCTAssertEqual(S3SecretStore.resolveSecret(typed: "", stored: "stored"), "stored")
    }

    func testATypedKeyWins() {
        XCTAssertEqual(S3SecretStore.resolveSecret(typed: "typed", stored: "stored"), "typed")
    }

    func testNothingTypedAndNothingStoredIsNil() {
        XCTAssertNil(S3SecretStore.resolveSecret(typed: "", stored: nil))
    }

    /// The Keychain must not be touched when the field already has a key —
    /// reading it is the call that can raise a modal prompt.
    func testStoredIsNotEvaluatedWhenSomethingWasTyped() {
        var reads = 0
        func read() -> String? { reads += 1; return "stored" }
        _ = S3SecretStore.resolveSecret(typed: "typed", stored: read())
        XCTAssertEqual(reads, 0)
        _ = S3SecretStore.resolveSecret(typed: "", stored: read())
        XCTAssertEqual(reads, 1)
    }
}
