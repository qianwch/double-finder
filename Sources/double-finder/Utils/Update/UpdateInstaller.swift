import AppKit

/// Replaces the running .app with the one inside a downloaded DMG, then
/// relaunches. Mounting a disk image has no public Swift API short of the
/// low-level DiskArbitration C framework, so this shells out to
/// /usr/bin/hdiutil — the same "no dependency, but a couple of system tools
/// have no Swift equivalent" trade-off FileSystem/RemoteArchiveFS already
/// makes for ssh/scp. The actual bundle swap happens after quitting, from a
/// detached helper script: the app cannot safely rewrite its own bundle's
/// resource files (Info.plist, the localization pack, plugins…) while it is
/// still reading them, even though replacing the *executable* underneath a
/// running process is itself harmless on macOS.
enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case mountFailed(String)
        case appNotFoundInImage
        case bundleIdentifierMismatch

        var errorDescription: String? {
            switch self {
            case .mountFailed(let why): return "Could not open the update disk image: \(why)"
            case .appNotFoundInImage: return "The update disk image did not contain Double Finder.app."
            case .bundleIdentifierMismatch: return "The downloaded update is not Double Finder."
            }
        }
    }

    private static let expectedBundleID = "net.qian.double-finder"

    /// Mounts `dmgURL`, sanity-checks the .app inside it, writes a small
    /// relaunch-helper shell script, launches it detached, then terminates
    /// this process. The helper waits for this process to exit, swaps the
    /// bundle with `ditto --noqtn` (the same flag package_app.sh uses for its
    /// own local installs — it both copies and strips the quarantine flag
    /// that would otherwise trip Gatekeeper), and reopens the app.
    static func installAndRelaunch(dmgURL: URL) throws {
        let mountPoint = try mount(dmgURL)
        let sourceApp = try locateApp(in: mountPoint)
        try verifyBundleIdentifier(sourceApp)

        let targetApp = Bundle.main.bundleURL
        let scriptURL = try writeHelperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                              target: targetApp, source: sourceApp,
                                              mountPoint: mountPoint, dmg: dmgURL)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()

        NSApp.terminate(nil)
    }

    private static func mount(_ dmg: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // -mountrandom /tmp: a private, non-Finder-visible mount point, so it
        // can't collide with a volume the user happens to have mounted by hand.
        proc.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-mountrandom", "/tmp", "-plist"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        try proc.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw InstallError.mountFailed("hdiutil exited with status \(proc.terminationStatus)")
        }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw InstallError.mountFailed("no mount point reported")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private static func locateApp(in mountPoint: URL) throws -> URL {
        let apps = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw InstallError.appNotFoundInImage }
        return app
    }

    private static func verifyBundleIdentifier(_ app: URL) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == expectedBundleID else {
            throw InstallError.bundleIdentifierMismatch
        }
    }

    private static func writeHelperScript(pid: Int32, target: URL, source: URL,
                                          mountPoint: URL, dmg: URL) throws -> URL {
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DoubleFinderUpdater.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        let q = ToolbarCommand.shellQuote
        let script = """
        #!/bin/sh
        exec >> \(q(logURL.path)) 2>&1
        echo "--- $(date) updating to \(q(source.lastPathComponent))"
        PID=\(pid)
        for i in $(seq 1 150); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done
        rm -rf \(q(target.path))
        ditto --noqtn \(q(source.path)) \(q(target.path))
        hdiutil detach \(q(mountPoint.path)) -quiet -force
        rm -f \(q(dmg.path))
        open \(q(target.path))
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoubleFinderUpdateHelper-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}
