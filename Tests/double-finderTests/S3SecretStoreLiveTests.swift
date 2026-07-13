import XCTest
import Security
@testable import double_finder

/// Live Keychain tests — mutate the real login keychain with throwaway fake
/// entries (host "s3secretstore-test.invalid"). Items are created and read by
/// the same test process, so no authorization prompts appear.
/// Gated: run with DF_KEYCHAIN_LIVE=1. Skipped otherwise.
///
/// tearDown removes the whole unified "double-finder" item ONLY if it did not
/// exist before the test (so a user's real secret blob is never destroyed).
final class S3SecretStoreLiveTests: XCTestCase {
    private let host = "s3secretstore-test.invalid"
    private let ak = "TESTACCESSKEY"
    private var unifiedExistedBefore = false

    private func unifiedItemExists() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: S3SecretStore.service,
                                kSecAttrAccount as String: S3SecretStore.account]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DF_KEYCHAIN_LIVE"] == "1",
                          "set DF_KEYCHAIN_LIVE=1 to run live Keychain tests")
        unifiedExistedBefore = unifiedItemExists()
        S3SecretStore.delete(endpointHost: host, accessKey: ak)
    }

    override func tearDown() {
        S3SecretStore.delete(endpointHost: host, accessKey: ak)
        if !unifiedExistedBefore {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: S3SecretStore.service,
                                    kSecAttrAccount as String: S3SecretStore.account]
            SecItemDelete(q as CFDictionary)
        }
    }

    func testSaveLoadDeleteRoundTrip() throws {
        S3SecretStore.save(endpointHost: host, accessKey: ak, secret: "s3cr3t-值")
        XCTAssertEqual(S3SecretStore.load(endpointHost: host, accessKey: ak), "s3cr3t-值")
        XCTAssertTrue(unifiedItemExists())
        S3SecretStore.delete(endpointHost: host, accessKey: ak)
        XCTAssertNil(S3SecretStore.load(endpointHost: host, accessKey: ak))
    }

    func testLazyMigrationFromLegacyItem() throws {
        // Plant a legacy internet-password item the way the old code wrote it.
        var q = S3SecretStore.legacyQuery(endpointHost: host, accessKey: ak)
        q[kSecValueData as String] = Data("legacy-secret".utf8)
        let addStatus = SecItemAdd(q as CFDictionary, nil)
        XCTAssertEqual(addStatus, errSecSuccess)

        // load() must find it, migrate it into the unified blob and delete it.
        XCTAssertEqual(S3SecretStore.load(endpointHost: host, accessKey: ak), "legacy-secret")
        let legacyStatus = SecItemCopyMatching(
            S3SecretStore.legacyQuery(endpointHost: host, accessKey: ak) as CFDictionary, nil)
        XCTAssertEqual(legacyStatus, errSecItemNotFound, "legacy item should be deleted after migration")

        // Second load comes from the unified blob alone.
        XCTAssertEqual(S3SecretStore.load(endpointHost: host, accessKey: ak), "legacy-secret")
    }
}
