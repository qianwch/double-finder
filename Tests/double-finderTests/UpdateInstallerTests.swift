import XCTest
@testable import double_finder

final class UpdateInstallerTests: XCTestCase {
    func testRunningOldProcessPreventsReplacementAndRelaunch() throws {
        try exercise(pid: ProcessInfo.processInfo.processIdentifier, shouldInstall: false)
    }

    func testExitedOldProcessAllowsReplacementAndRelaunch() throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try old.run()
        old.waitUntilExit()
        try exercise(pid: old.processIdentifier, shouldInstall: true)
    }

    private func exercise(pid: Int32, shouldInstall: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("Old ' App.app")
        let source = root.appendingPathComponent("New App.app")
        let bin = root.appendingPathComponent("bin")
        for dir in [target, source, bin] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        let dmg = root.appendingPathComponent("download.dmg")
        try Data().write(to: dmg)
        let opened = root.appendingPathComponent("opened")
        // Only external macOS tools are substituted; the real generated shell
        // controls process waiting, target deletion, ordering and exit status.
        let commands = [
            "ditto": "shift; /bin/cp -R \"$1\" \"$2\"",
            "hdiutil": "exit 0",
            "open": "touch \(ToolbarCommand.shellQuote(opened.path))"
        ]
        for (name, body) in commands {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let script = root.appendingPathComponent("helper.sh")
        try UpdateInstaller.helperScript(pid: pid, target: target, source: source,
            mountPoint: root.appendingPathComponent("mount"), dmg: dmg,
            logURL: root.appendingPathComponent("log"), waitAttempts: 1)
            .write(to: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path]
        helper.environment = ["PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
        try helper.run()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus == 0, shouldInstall)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version")), shouldInstall ? "new" : "old")
        XCTAssertEqual(fm.fileExists(atPath: opened.path), shouldInstall)
        XCTAssertEqual(fm.fileExists(atPath: dmg.path), !shouldInstall)
    }
}
