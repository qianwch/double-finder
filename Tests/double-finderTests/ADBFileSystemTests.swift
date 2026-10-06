import XCTest
@testable import double_finder

final class ADBFileSystemTests: XCTestCase {
    func testNULRecordsPreserveNamesAndSymlinks() throws {
        let name = ".中文 ' 文件\n尾"
        let data = Data(([name, "f", "12", "1700000000", "81a4", "", "link", "l", "4", "1700000001", "a1ff", "目录\n"] .joined(separator: "\0") + "\0").utf8)
        let items = try ADBClient.parseListing(data, path: "/sdcard")
        XCTAssertEqual(items.map(\.name), [name, "link"])
        XCTAssertEqual(items[0].path, "/sdcard/" + name)
        XCTAssertTrue(items[0].isHidden)
        XCTAssertEqual(items[0].permissions, "rw-r--r--")
        XCTAssertTrue(items[1].isSymlink)
        XCTAssertFalse(items[1].isDirectory)
    }
    func testMalformedRecordsThrow() {
        for text in ["x\0f\0", "x\0f\012\01\081a4\0", "x\0f\0bad\01\081a4\0\0", "../x\0f\01\01\081a4\0\0"] {
            XCTAssertThrowsError(try ADBClient.parseListing(Data(text.utf8), path: "/sdcard"))
        }
    }
    func testRemovalRejectsDangerousPaths() {
        for path in ["", "/", ".", "..", "/a/..", "////", "/./", "/a/../"] {
            XCTAssertThrowsError(try ADBClient.validateRemovalPath(path))
        }
        XCTAssertNoThrow(try ADBClient.validateRemovalPath("/sdcard/a ' 中文\n"))
    }
    func testFakeDeviceListingErrorsAndExplicitTransferDirections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("中文 ' dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ".换行\n末尾\n"
        try Data("hello".utf8).write(to: directory.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("loop").path, withDestinationPath: directory.path)
        let stat = root.appendingPathComponent("stat")
        let statScript = """
        #!/usr/bin/env python3
        import os,sys
        s=os.lstat(sys.argv[3]); k=sys.argv[2]
        print({'%s':s.st_size,'%Y':int(s.st_mtime),'%f':format(s.st_mode,'x')}[k])
        """
        try statScript.write(to: stat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stat.path)
        let adb = root.appendingPathComponent("adb")
        let log = root.appendingPathComponent("args")
        let adbScript = """
        #!/usr/bin/env python3
        import os,sys,json,subprocess,shutil
        with open(\(String(reflecting: log.path)), 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
        assert sys.argv[1:3]==['-s','test-device']
        if sys.argv[3] in ['pull','push']:
            source,target=sys.argv[4:6]
            if os.path.isdir(source): shutil.copytree(source,target,dirs_exist_ok=True)
            else: shutil.copy2(source,target)
        if sys.argv[3]=='exec-out':
            env=os.environ.copy(); env['PATH']=\(String(reflecting: root.path))+':'+env['PATH']
            sys.exit(subprocess.call(['/bin/sh','-c',sys.argv[4]],env=env))
        """
        try adbScript.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let session = ADBSession(device: ADBDevice(serial: "test-device", model: "", state: "device"), executablePath: adb.path)
        let client = ADBClient(session: session)
        let listing = try await client.list(directory.path)
        XCTAssertEqual(Set(listing.map(\.name)), Set([name,"loop"]))
        XCTAssertTrue(listing.first { $0.name == "loop" }!.isSymlink)
        let size = await ADBFS(session: session, currentPath: directory.path).directorySize(directory.path)
        XCTAssertEqual(size, 5)
        do { _ = try await client.list(root.appendingPathComponent("missing").path); XCTFail("Missing directory returned success") } catch {}
        let fs = ADBFS(session: session, currentPath: directory.path)
        let collision = directory.appendingPathComponent(name)
        try await fs.exportItem(at: collision.path, toLocalDirectory: root.appendingPathComponent("out"), progress: { _ in })
        let remoteTarget = root.appendingPathComponent("remote-renamed")
        try await fs.importItem(from: collision, toPath: remoteTarget.path, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out").appendingPathComponent(name)), Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: remoteTarget), Data("hello".utf8))
        let invalid = URL(string: "https://invalid.example/file")!
        do { try await fs.exportItem(at: collision.path, toLocalDirectory: invalid, progress: { _ in }); XCTFail() }
        catch is FSUnsupportedError {}
        do { try await fs.importItem(from: invalid, toPath: "/sdcard/remote", progress: { _ in }); XCTFail() }
        catch is FSUnsupportedError {}
        let records = try String(contentsOf: log).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
        XCTAssertEqual(records.filter { ["pull", "push"].contains($0[2]) }.map { $0[2] }, ["pull", "push"])
        XCTAssertEqual(records.last?.last, remoteTarget.path)
        XCTAssertEqual(records.filter { $0[2] == "pull" }.first?[3], collision.path)
        for target in [directory.path, directory.path + "/nested", directory.path + "/a/../nested"] {
            do { try await client.transfer(from: directory.path, to: target, move: false); XCTFail("Unsafe target accepted") } catch {}
        }
        try await client.transfer(from: directory.appendingPathComponent(name).path, to: directory.appendingPathComponent("renamed").path, move: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed").path))
        do { try await client.transfer(from: directory.path, to: directory.path, move: true); XCTFail("Directory target must not silently nest") } catch {}
    }
    func testMoveCopiesBeforeDeleteAndPreservesSourceOnFailureOrCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("adb")
        let script = """
        #!/usr/bin/env python3
        import sys,subprocess,time
        command=sys.argv[4]
        if 'cp ' in command and 'slow-source' in command: time.sleep(5)
        if 'cp ' in command and 'failed-source' in command: sys.exit(1)
        sys.exit(subprocess.call(['/bin/sh','-c',command]))
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let client = ADBClient(session: ADBSession(device: ADBDevice(serial: "fixture", model: "", state: "device"), executablePath: adb.path))
        for name in ["success-source", "failed-source", "slow-source"] {
            let source = root.appendingPathComponent(name), target = root.appendingPathComponent(name + "-target")
            try Data("payload".utf8).write(to: source)
            if name == "success-source" {
                try await client.transfer(from: source.path, to: target.path, move: true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
                XCTAssertEqual(try Data(contentsOf: target), Data("payload".utf8))
            } else {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                do {
                    try await client.transfer(from: source.path, to: target.path, move: true,
                                              isCancelled: { name == "slow-source" && ProcessInfo.processInfo.systemUptime >= deadline })
                    XCTFail("Expected copy failure or cancellation")
                } catch {}
                XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
            }
        }
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: directory.appendingPathComponent("child"))
        let destination = root.appendingPathComponent("directory-copy")
        try await client.transfer(from: directory.path, to: destination.path, move: false)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("child")), Data("child".utf8))
        let renamed = root.appendingPathComponent("renamed")
        try await client.rename(from: directory.path, to: renamed.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("child").path))
    }
}
