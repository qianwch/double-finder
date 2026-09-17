import AppKit

/// GitHub-Releases-based auto-updater: checks `releases/latest`, downloads the
/// DMG asset for the running CPU architecture, verifies it against GitHub's
/// published sha256, then hands off to `UpdateInstaller` to swap the bundle
/// and relaunch. No external framework (project convention: zero third-party
/// dependencies) — the one step with no Swift API (mounting a DMG) shells out
/// to a system tool, same as SFTP already does for ssh/scp.
///
/// Checking and downloading happen silently in the background (on launch, and
/// from Check for Updates…); only the final "restart to install" step ever
/// waits on the user, per product decision — auto-installing over a running
/// session without asking would be a much worse surprise than one extra click.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    private init() {}

    private static let repo = "qianwch/double-finder"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    enum UpdateError: LocalizedError {
        case badResponse(Int)
        case noAssetForArchitecture
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub returned an unexpected response (HTTP \(code))."
            case .noAssetForArchitecture: return "No download was published for this Mac's processor architecture."
            case .digestMismatch: return "The downloaded file did not match the checksum GitHub published for it."
            }
        }
    }

    /// False for the bare dev executable — there is no installed .app to
    /// replace, and CFBundleShortVersionString is still the "0.0.0" placeholder.
    var isPackagedApp: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    private var isChecking = false
    private var currentCheck: Task<Void, Never>?
    /// A release already downloaded and digest-verified this run, kept around
    /// so dismissing "Later" (or an automatic check right after) doesn't
    /// re-download the same DMG.
    private var pendingDownload: (release: GitHubRelease, dmgURL: URL)?
    private var liveSheets: [ObjectIdentifier: NSWindowController] = [:]

    // MARK: - Entry points

    /// Called once from applicationDidFinishLaunching. Silent: no UI unless
    /// (and until) an update is actually ready to install.
    func checkOnLaunchIfDue() {
        guard isPackagedApp, AppSettings.autoUpdateEnabled else { return }
        guard UpdateSchedule.isDue(lastChecked: AppSettings.autoUpdateLastCheckedAt,
                                   intervalDays: AppSettings.autoUpdateIntervalDays) else { return }
        currentCheck = Task { await self.check(interactive: false, host: nil) }
    }

    /// Double Finder ▸ Check for Updates… (menu, and the optional toolbar
    /// button) — same flow, but with progress UI and an "up to date" alert.
    func checkNow(host: NSWindow?) {
        currentCheck = Task { await self.check(interactive: true, host: host) }
    }

    // MARK: - Core flow

    private func check(interactive: Bool, host: NSWindow?) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard isPackagedApp else {
            if interactive {
                showAlert(.warning, tr("This development build cannot check for updates."), host: host)
            }
            return
        }

        // Interactive checks show progress from the very first network call;
        // a silent background check stays invisible until (if) there turns
        // out to be something to install.
        var sheet: UpdateSheet?
        if interactive { sheet = presentSheet(on: host) }

        do {
            let release = try await fetchLatestRelease()
            AppSettings.autoUpdateLastCheckedAt = Date()

            guard AppVersion.isNewer(release.version, than: HelpContent.appVersion) else {
                sheet?.dismiss()
                if interactive {
                    showAlert(.informational,
                             String(format: tr("You're up to date (%@)."), HelpContent.appVersion), host: host)
                }
                return
            }
            guard let asset = release.dmgAsset() else {
                sheet?.dismiss()
                if interactive { showAlert(.warning, tr(UpdateError.noAssetForArchitecture.errorDescription!), host: host) }
                return
            }

            let dmgURL: URL
            if let pending = pendingDownload, pending.release.tagName == release.tagName,
               FileManager.default.fileExists(atPath: pending.dmgURL.path) {
                dmgURL = pending.dmgURL
            } else {
                dmgURL = try await downloadAndVerify(asset: asset) { [weak sheet] fraction in
                    sheet?.setDownloadProgress(fraction)
                }
                pendingDownload = (release, dmgURL)
            }

            // A silent check only creates its sheet once there is something
            // worth interrupting the user for.
            guard let readySheet = sheet ?? presentSheet(on: host) else { return }
            readySheet.onInstall = { [weak self] in self?.install(dmgURL: dmgURL) }
            readySheet.showReady(version: release.version, notes: release.body ?? "")
        } catch is CancellationError {
            sheet?.dismiss()
        } catch let urlError as URLError where urlError.code == .cancelled {
            sheet?.dismiss()
        } catch {
            sheet?.dismiss()
            AppSettings.autoUpdateLastCheckedAt = Date()
            if interactive { showAlert(.critical, tr(error.localizedDescription), host: host) }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.badResponse(code)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadAndVerify(asset: GitHubRelease.Asset, progress: @escaping (Double) -> Void) async throws -> URL {
        let url = try await UpdateDownloader.download(asset.browserDownloadURL, progress: progress)
        if let expected = asset.sha256 {
            let path = url.path
            let actual = try await Task.detached(priority: .utility) {
                try ChecksumAlgorithm.sha256.hashFile(at: path)
            }.value
            guard actual == expected else {
                try? FileManager.default.removeItem(at: url)
                throw UpdateError.digestMismatch
            }
        }
        return url
    }

    private func install(dmgURL: URL) {
        do {
            try UpdateInstaller.installAndRelaunch(dmgURL: dmgURL)
        } catch {
            showAlert(.critical, tr(error.localizedDescription), host: nil)
        }
    }

    // MARK: - Small helpers

    /// Creates and attaches a fresh sheet, or nil when there is no free
    /// window to host it on (never steals one already showing another sheet —
    /// same rule every other sheet entry point in this app follows).
    private func presentSheet(on preferred: NSWindow?) -> UpdateSheet? {
        guard let window = hostWindow(preferred) else { return nil }
        let sheet = UpdateSheet()
        let done = keepAlive(sheet)
        sheet.onCancel = { [weak self] in self?.currentCheck?.cancel() }
        sheet.beginSheet(on: window) { done() }
        return sheet
    }

    private func hostWindow(_ preferred: NSWindow?) -> NSWindow? {
        guard let window = preferred ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        else { return nil }
        return window.attachedSheet == nil ? window : nil
    }

    @discardableResult
    private func keepAlive(_ sheet: NSWindowController) -> () -> Void {
        let key = ObjectIdentifier(sheet)
        liveSheets[key] = sheet
        return { [weak self] in self?.liveSheets.removeValue(forKey: key) }
    }

    private func showAlert(_ style: NSAlert.Style, _ message: String, host: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = tr("Check for Updates")
        alert.informativeText = message
        if let window = hostWindow(host) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
