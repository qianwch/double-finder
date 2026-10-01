import Foundation
import Network

/// A single HTTP byte range. Keep this independent of the player and USB device.
enum MediaByteRange {
    static func parse(_ header: String?, size: Int64) throws -> Range<Int64> {
        guard size >= 0 else { throw URLError(.badServerResponse) }
        guard let header else { return 0..<size }
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else {
            throw URLError(.badServerResponse)
        }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw URLError(.badServerResponse) }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw URLError(.badServerResponse) }
            return max(0, size - suffix)..<size
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw URLError(.badServerResponse) }
        if parts[1].isEmpty { return start..<size }
        guard let end = Int64(parts[1]), end >= start else { throw URLError(.badServerResponse) }
        return start..<(min(end, size - 1) + 1)
    }
}

/// Loopback-only, capability URL for one Android media object. The player uses
/// HTTP Range; USB reads stay bounded and serialized by AndroidDeviceRegistry.
final class AndroidMediaStream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.qian.double-finder.media-stream")
    private let read: @Sendable (UInt64, UInt32) async throws -> Data
    private let path: String
    private let size: Int64
    private let token = UUID().uuidString
    private let cancelled = CancelFlag()
    private var connections: [UUID: NWConnection] = [:] // queue only
    private var tasks: [UUID: Task<Void, Never>] = [:] // queue only

    init(sessionID: String, path: String, size: Int64,
         reader: (@Sendable (UInt64, UInt32) async throws -> Data)? = nil) throws {
        self.path = path; self.size = size
        self.read = reader ?? { offset, count in
            try await AndroidDeviceRegistry.shared.readPartial(sessionID, path: path, offset: offset, count: count)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false // listener handlers run on queue
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    guard let port = self.listener.port else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost)); return
                    }
                    var components = URLComponents()
                    components.scheme = "http"; components.host = "127.0.0.1"; components.port = Int(port.rawValue)
                    components.path = "/\(self.token)/\((self.path as NSString).lastPathComponent)"
                    continuation.resume(returning: components.url!)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                case .cancelled: resumed = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.cancelled.isCancelled else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: self.queue)
                self.receive(connection, id: id, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        cancelled.cancel()
        listener.cancel()
        queue.async { [self] in
            for task in tasks.values { task.cancel() }
            for connection in connections.values { connection.cancel() }
            tasks.removeAll(); connections.removeAll()
        }
    }

    private func finish(_ id: UUID) {
        queue.async { [self] in
            connections.removeValue(forKey: id)?.cancel()
            tasks.removeValue(forKey: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil, !self.cancelled.isCancelled else { self.finish(id); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { self.finish(id) } else { self.receive(connection, id: id, buffered: buffer) }
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
                  first[1].hasPrefix("/\(self.token)/") else { self.finish(id); return }
            let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
                .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            let range: Range<Int64>
            do { range = try MediaByteRange.parse(rangeHeader, size: self.size) }
            catch {
                let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(self.size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in self.finish(id) })
                return
            }
            let partial = rangeHeader != nil
            var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n"
            if partial { header += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(self.size)\r\n" }
            header += "\r\n"
            let headOnly = first[0] == "HEAD"
            self.tasks[id] = Task { [self] in
                defer { self.finish(id) }
                do {
                    try await self.send(Data(header.utf8), to: connection)
                    if headOnly { return }
                    var offset = range.lowerBound
                    while offset < range.upperBound {
                        try Task.checkCancellation()
                        guard !self.cancelled.isCancelled else { throw CancellationError() }
                        let count = UInt32(min(512 * 1024, range.upperBound - offset))
                        let bytes = try await self.read(UInt64(offset), count)
                        guard !bytes.isEmpty, bytes.count <= Int(count) else { throw URLError(.badServerResponse) }
                        try await self.send(bytes, to: connection)
                        offset += Int64(bytes.count)
                    }
                } catch { /* closing the response lets the player surface a read failure */ }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
