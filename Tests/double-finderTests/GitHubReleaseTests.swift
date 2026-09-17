import XCTest
@testable import double_finder

/// Decoding + asset selection against a trimmed real payload shape (see
/// `gh api repos/qianwch/double-finder/releases/latest`). No networking.
final class GitHubReleaseTests: XCTestCase {
    private let json = """
    {
      "tag_name": "1.7.7",
      "name": "1.7.7",
      "body": "### What's new\\n- fixed things",
      "html_url": "https://github.com/qianwch/double-finder/releases/tag/1.7.7",
      "assets": [
        { "name": "Double-Finder-arm64.dmg",
          "browser_download_url": "https://github.com/qianwch/double-finder/releases/download/1.7.7/Double-Finder-arm64.dmg",
          "size": 39267814,
          "digest": "sha256:a272d09f29536164924751a14ae0ca37cc5976a652d855be14bc23e2653f619" },
        { "name": "Double-Finder-x86_64.dmg",
          "browser_download_url": "https://github.com/qianwch/double-finder/releases/download/1.7.7/Double-Finder-x86_64.dmg",
          "size": 43064487,
          "digest": "sha256:9697b5d93954e1ce65bb7912d076d9056e0085041c7dbca1d2f5f2b4d656cb5" },
        { "name": "DoubleFinderPluginKit-SDK-1.7.7.zip",
          "browser_download_url": "https://github.com/qianwch/double-finder/releases/download/1.7.7/DoubleFinderPluginKit-SDK-1.7.7.zip",
          "size": 48919,
          "digest": null }
      ]
    }
    """

    private func decode() throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecodesTheFieldsTheUpdaterNeeds() throws {
        let release = try decode()
        XCTAssertEqual(release.tagName, "1.7.7")
        XCTAssertEqual(release.version, "1.7.7")
        XCTAssertEqual(release.assets.count, 3)
        XCTAssertTrue(release.body?.contains("What's new") == true)
    }

    func testPicksTheDmgForTheGivenArchitecture() throws {
        let release = try decode()
        XCTAssertEqual(release.dmgAsset(for: "arm64")?.name, "Double-Finder-arm64.dmg")
        XCTAssertEqual(release.dmgAsset(for: "x86_64")?.name, "Double-Finder-x86_64.dmg")
        XCTAssertNil(release.dmgAsset(for: "armv7"))
    }

    func testSha256StripsThePrefixAndLowercases() throws {
        let release = try decode()
        let asset = try XCTUnwrap(release.dmgAsset(for: "arm64"))
        XCTAssertEqual(asset.sha256, "a272d09f29536164924751a14ae0ca37cc5976a652d855be14bc23e2653f619")
    }

    func testMissingDigestIsNil() throws {
        let release = try decode()
        let sdkAsset = try XCTUnwrap(release.assets.first { $0.name.hasPrefix("DoubleFinderPluginKit") })
        XCTAssertNil(sdkAsset.sha256)
    }
}
