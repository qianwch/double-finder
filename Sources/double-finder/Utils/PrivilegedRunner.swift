import Foundation

/// Runs a shell command as root through the system authentication dialog
/// (`osascript`'s `do shell script … with administrator privileges`) — the
/// same prompt Finder shows when you delete from /Applications. Used to retry
/// a local copy/move/delete that failed with "permission denied".
enum PrivilegedRunner {
    struct Cancelled: Error {}
    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// POSIX single-quote quoting for one shell word.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a shell command for embedding in an AppleScript string literal.
    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Shell command that redoes a failed local operation with root rights.
    /// delete → `rm -rf`; copy → `cp -pR src dest/`; move → `mv -f src dest/`.
    static func command(for type: OperationType, paths: [String], destination: String?) -> String {
        let q = shellQuote
        switch type {
        case .delete:
            return paths.map { "rm -rf \(q($0))" }.joined(separator: " && ")
        case .copy:
            guard let d = destination else { return "" }
            return paths.map { "cp -pR \(q($0)) \(q(d))/" }.joined(separator: " && ")
        case .move:
            guard let d = destination else { return "" }
            return paths.map { "mv -f \(q($0)) \(q(d))/" }.joined(separator: " && ")
        }
    }

    /// True for the errors a missing write/read permission produces (Cocoa
    /// 513/257, POSIX EACCES/EPERM, or an underlying error that is).
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(under) }
        return false
    }

    /// Runs `command` as root. Blocks its thread while the auth dialog is up —
    /// call from a background task. Throws `Cancelled` when the user dismisses
    /// the dialog, `Failed` (with stderr) when the command itself fails.
    nonisolated static func run(_ command: String) throws {
        let script = "do shell script \"\(appleScriptQuote(command))\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus != 0 else { return }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if text.contains("-128") || text.lowercased().contains("user cancel") { throw Cancelled() }
        throw Failed(message: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
