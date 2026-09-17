import Foundation

/// The CPU architecture the running binary was built for, matching how
/// ci.yml names the two per-architecture DMGs ("Double-Finder-arm64.dmg" /
/// "Double-Finder-x86_64.dmg" — see package_app.sh's "follows the host
/// architecture" note). Compile-time, not `uname -m`: Rosetta would report the
/// host Mac's architecture, not the slice this process is actually running.
enum CPUArchitecture {
    static var current: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

/// Minimal slice of the GitHub Releases API this app needs, decoded straight
/// from `GET /repos/<owner>/<repo>/releases/latest` — which already excludes
/// drafts and prereleases, so the CI's rolling "latest" prerelease tag (used
/// for continuous main-branch builds, see spec/build.md) never surfaces here.
/// Pure decoding + asset selection — no networking.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        /// "sha256:<hex>" when GitHub computed one (all current uploads do); nil
        /// for older assets uploaded before GitHub added asset digests.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        /// The sha256 hex digest GitHub published for this asset, lowercased.
        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst("sha256:".count)).lowercased()
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
    }

    /// The version string to compare against the running app, with any
    /// leading "v" already meaningless to `AppVersion` either way.
    var version: String { tagName }

    /// The DMG asset for a given CPU architecture (package_app.sh's naming).
    func dmgAsset(for arch: String = CPUArchitecture.current) -> Asset? {
        assets.first { $0.name == "Double-Finder-\(arch).dmg" }
    }
}
