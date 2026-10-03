import Foundation
import Darwin

struct ADBCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

enum ADBError: Error, LocalizedError, Equatable {
    case invalidArgument, timeout, commandFailed(String), pairingFailed
    var errorDescription: String? {
        switch self {
        case .invalidArgument: return "Invalid ADB argument."
        case .timeout: return "ADB command timed out."
        case .commandFailed(let message): return message
        case .pairingFailed: return "ADB pairing failed. Check the pairing address and code."
        }
    }
}

private final class ADBCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum ADBProcessRunner {
    /// Nonblocking reads keep both output pipes flowing and bound cleanup even if
    /// a descendant retains a pipe after the command exits.
    static func run(executable: String, arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 30,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> ADBCommandResult {
        let cancellation = ADBCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execute(executable: executable, arguments: arguments, input: input, timeout: timeout, cancelled: { cancellation.cancelled || isCancelled() })) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func execute(executable: String, arguments: [String], input: Data?, timeout: TimeInterval,
                                cancelled: () -> Bool) throws -> ADBCommandResult {
        if cancelled() { throw CancellationError() }
        let process = Process()
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        // A small input (pairing code) goes through stdin; never argv or diagnostics.
        process.standardInput = stdin
        try process.run()
        out.fileHandleForWriting.closeFile()
        err.fileHandleForWriting.closeFile()
        stdin.fileHandleForReading.closeFile()
        defer {
            out.fileHandleForReading.closeFile()
            err.fileHandleForReading.closeFile()
            stdin.fileHandleForWriting.closeFile()
        }
        let outFD = out.fileHandleForReading.fileDescriptor
        let errFD = err.fileHandleForReading.fileDescriptor
        let inFD = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        for fd in [outFD, errFD, inFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var stdout = Data(), stderr = Data()
        var outEOF = false, errEOF = false, inputOffset = 0, inputClosed = false
        let payload = input ?? Data()
        let start = ProcessInfo.processInfo.systemUptime
        var exitedAt: TimeInterval?
        var failure: Error?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil && (cancelled() || now - start >= timeout) {
                failure = cancelled() ? CancellationError() : ADBError.timeout
                if process.isRunning {
                    process.terminate()
                    // SIGKILL ensures even a command ignoring SIGTERM is reaped.
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            drain(outFD, into: &stdout, eof: &outEOF)
            drain(errFD, into: &stderr, eof: &errEOF)
            if !inputClosed {
                if inputOffset < payload.count {
                    let count = payload.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: inputOffset), min(4096, payload.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { inputOffset = payload.count }
                }
                if inputOffset == payload.count {
                    stdin.fileHandleForWriting.closeFile()
                    inputClosed = true
                }
            }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if (outEOF && errEOF) || now - exitedAt! >= 0.2 { break }
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        return ADBCommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private static func drain(_ fd: Int32, into data: inout Data, eof: inout Bool) {
        guard !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<32 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else {
                if count == 0 || (errno != EAGAIN && errno != EINTR) { eof = true }
                break
            }
        }
    }
}
