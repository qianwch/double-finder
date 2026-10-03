import Foundation
import Darwin

struct ADBClient: Sendable {
    let session: ADBSession

    func shell(_ script: String, timeout: TimeInterval = 30,
               isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        let lifetime = session.lifetime
        guard !lifetime.isRemoved else { throw CancellationError() }
        return try await Self.remoteShell(session: session, script: script, timeout: timeout,
                                          isCancelled: { lifetime.isRemoved || isCancelled() })
    }

    /// exec-out avoids legacy shell CRLF conversion. A private trailer checks
    /// the remote status even on adbd versions which always exit with zero.
    static func remoteShell(session: ADBSession, script: String, timeout: TimeInterval = 30,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        try validateSerial(session.device.serial)
        guard !script.contains("\0") else { throw ADBError.invalidArgument }
        let marker = "DF_ADB_" + UUID().uuidString
        let tools = ["printf", "stat", "readlink", "realpath", "cp", "mv", "rm", "mkdir", "chmod"]
        // Prefer every native command; use only an already installed BusyBox.
        // Functions are generated from fixed names, never user-controlled data.
        let fallback = tools.map { tool in
            "command -v \(tool) >/dev/null 2>&1 || \(tool)() { if [ -n \"$df_busybox\" ]; then \"$df_busybox\" \(tool) \"$@\"; else echo 'Missing Android command: \(tool)' >&2; return 127; fi; }"
        }.joined(separator: "\n")
        let command = """
        df_busybox=''
        for df_candidate in /system/bin/busybox /system/xbin/busybox; do
          if [ -x "$df_candidate" ]; then df_busybox=$df_candidate; break; fi
        done
        if [ -z "$df_busybox" ]; then df_busybox=$(command -v busybox 2>/dev/null); fi
        \(fallback)
        (
        \(script)
        ) 2>&1
        df_status=$?
        printf '\\000\(marker):%s\\000' "$df_status"
        """
        let data = try await checked(executable: session.executablePath,
                                     arguments: ["-s", session.device.serial, "exec-out", command],
                                     timeout: timeout, isCancelled: isCancelled)
        let prefix = Data(("\0" + marker + ":").utf8)
        guard data.last == 0, let range = data.range(of: prefix, options: .backwards),
              let status = Int(String(decoding: data[range.upperBound..<data.index(before: data.endIndex)], as: UTF8.self)) else {
            throw ADBError.commandFailed("Missing ADB remote status (Android printf or exec-out unavailable).")
        }
        let body = Data(data[..<range.lowerBound])
        guard status == 0 else {
            let message = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.commandFailed(message.isEmpty ? "ADB remote command failed (\(status))." : message)
        }
        return body
    }

    func checked(arguments: [String], timeout: TimeInterval = 30,
                 isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        let lifetime = session.lifetime
        guard !lifetime.isRemoved else { throw CancellationError() }
        return try await Self.checked(executable: session.executablePath, arguments: arguments, timeout: timeout,
                                      isCancelled: { lifetime.isRemoved || isCancelled() })
    }

    static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw ADBError.invalidArgument }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func validateSerial(_ serial: String) throws {
        guard !serial.isEmpty, !serial.hasPrefix("-"),
              !serial.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw ADBError.invalidArgument }
    }

    @discardableResult static func validateEndpoint(_ endpoint: String) throws -> String {
        guard endpoint.range(of: "^(?:\\[[0-9A-Fa-f:.%]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):[0-9]+$", options: .regularExpression) != nil,
              !endpoint.contains("\n"), !endpoint.contains("\r"),
              let port = Int(endpoint.split(separator: ":").last ?? ""), (1...65535).contains(port) else { throw ADBError.invalidArgument }
        if endpoint.hasPrefix("[") {
            let host = String(endpoint.dropFirst().prefix { $0 != "]" })
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw ADBError.invalidArgument }
        }
        return endpoint
    }

    static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no"].contains(fields[1]), (try? validateSerial(fields[0])) != nil else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return ADBDevice(serial: fields[0], model: model, state: fields[1])
        }
    }

    static func parseMDNSServices(_ text: String) -> [ADBService] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, (try? validateEndpoint(fields[2])) != nil else { return nil }
            let type = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let kind: ADBService.Kind
            if type == "_adb-tls-pairing._tcp" { kind = .pairing }
            else if type == "_adb-tls-connect._tcp" { kind = .connection }
            else { return nil }
            return ADBService(name: fields[0], kind: kind, endpoint: fields[2])
        }
    }

    static func resolveExecutable(configuredPath: String?) -> String? {
        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = []
        if let configuredPath, !configuredPath.isEmpty { paths.append((configuredPath as NSString).expandingTildeInPath) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key] { paths.append(root + "/platform-tools/adb") }
        }
        paths += [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        return paths.first { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func devices(executablePath: String) async throws -> [ADBDevice] {
        parseDevices(String(decoding: try await checked(executable: executablePath, arguments: ["devices", "-l"]), as: UTF8.self))
    }
    static func mdnsServices(executablePath: String) async throws -> [ADBService] {
        parseMDNSServices(String(decoding: try await checked(executable: executablePath, arguments: ["mdns", "services"]), as: UTF8.self))
    }
    static func pair(executablePath: String, endpoint: String, code: String) async throws {
        try validateEndpoint(endpoint)
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ADBError.invalidArgument }
        // Suppress all pairing diagnostics: adb may echo the secret on failure.
        do {
            let result = try await ADBProcessRunner.run(executable: executablePath, arguments: ["pair", endpoint], input: Data((code + "\n").utf8))
            guard result.exitCode == 0, String(decoding: result.stdout, as: UTF8.self).lowercased().contains("successfully paired") else { throw ADBError.pairingFailed }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ADBError.pairingFailed }
    }
    static func connect(executablePath: String, endpoint: String) async throws {
        try validateEndpoint(endpoint)
        let body = String(decoding: try await checked(executable: executablePath, arguments: ["connect", endpoint]), as: UTF8.self).lowercased()
        guard body.contains("connected to") && !body.contains("failed") && !body.contains("unable") else { throw ADBError.commandFailed("ADB connection failed.") }
    }
    static func disconnect(executablePath: String, endpoint: String) async throws {
        try validateEndpoint(endpoint)
        _ = try await checked(executable: executablePath, arguments: ["disconnect", endpoint])
    }

    static func checked(executable: String, arguments: [String], timeout: TimeInterval = 30,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        let result = try await ADBProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout, isCancelled: isCancelled)
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.commandFailed(message.isEmpty ? "ADB command failed (\(result.exitCode))." : message)
        }
        return result.stdout
    }
}
