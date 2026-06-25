import Foundation

struct S3Error: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Low-level S3 REST client (URLSession + SigV4). One instance per connection.
final class S3Client {
    private let endpoint: S3Endpoint
    private let signer: S3Signer
    private let session = URLSession(configuration: .default)
    private static let unsignedPayload = "UNSIGNED-PAYLOAD"

    init(endpoint: S3Endpoint, signer: S3Signer) {
        self.endpoint = endpoint
        self.signer = signer
    }

    private func currentDate() -> Date { Date() }

    /// Builds a fully-signed request (URL + method + SigV4 headers). Caller attaches
    /// the body or `httpBodyStream`. Shared by `send` (buffered) and the streaming paths.
    private func makeSignedRequest(method: String, bucket: String?, key: String,
                                   query: [String: String] = [:],
                                   extraHeaders: [String: String] = [:],
                                   payloadHash: String) -> URLRequest {
        let url = endpoint.url(bucket: bucket, key: key, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        var headers = extraHeaders
        for (k, v) in signer.authorizationHeaders(method: method, url: url, headers: headers,
                                                  payloadHash: payloadHash, date: currentDate()) {
            headers[k] = v
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Build, sign, and send a request; returns (data, httpResponse). Throws S3Error on non-2xx.
    private func send(method: String, bucket: String?, key: String,
                      query: [String: String] = [:], body: Data? = nil,
                      extraHeaders: [String: String] = [:],
                      payloadHash: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let hash = payloadHash ?? (body.map { S3Signer.sha256Hex($0) } ?? S3Client.unsignedPayload)
        var req = makeSignedRequest(method: method, bucket: bucket, key: key,
                                    query: query, extraHeaders: extraHeaders, payloadHash: hash)
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw S3Error(message: "No HTTP response") }
        if !(200...299).contains(http.statusCode) {
            let msg = S3XML.errorMessage(data) ?? "HTTP \(http.statusCode)"
            throw S3Error(message: msg)
        }
        return (data, http)
    }

    func listBuckets() async throws -> [String] {
        let (data, _) = try await send(method: "GET", bucket: nil, key: "")
        return S3XML.buckets(data)
    }

    func listObjects(bucket: String, prefix: String) async throws
        -> (prefixes: [String], objects: [S3ObjectInfo]) {
        var prefixes: [String] = [], objects: [S3ObjectInfo] = []
        var token: String? = nil
        repeat {
            var q = ["list-type": "2", "prefix": prefix, "delimiter": "/"]
            if let t = token { q["continuation-token"] = t }
            let (data, _) = try await send(method: "GET", bucket: bucket, key: "", query: q)
            let r = S3XML.listObjects(data)
            prefixes += r.prefixes; objects += r.objects; token = r.nextToken
        } while token != nil
        return (prefixes, objects)
    }

    func listAllKeys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []; var token: String? = nil
        repeat {
            var q = ["list-type": "2", "prefix": prefix]   // no delimiter → full recursion
            if let t = token { q["continuation-token"] = t }
            let (data, _) = try await send(method: "GET", bucket: bucket, key: "", query: q)
            let r = S3XML.listObjects(data)
            keys += r.objects.map { $0.key }; token = r.nextToken
        } while token != nil
        return keys
    }

    /// Like `listAllKeys` but keeps each object's size + modified date.
    /// No delimiter → recurses the whole tree under `prefix`, paginated.
    func listAllObjects(bucket: String, prefix: String) async throws -> [S3ObjectInfo] {
        var out: [S3ObjectInfo] = []; var token: String? = nil
        repeat {
            var q = ["list-type": "2", "prefix": prefix]
            if let t = token { q["continuation-token"] = t }
            let (data, _) = try await send(method: "GET", bucket: bucket, key: "", query: q)
            let r = S3XML.listObjects(data)
            out += r.objects; token = r.nextToken
        } while token != nil
        return out
    }

    /// Downloads to a local path, streaming via `bytes(for:)` so memory stays flat.
    /// Writes to a `.part` temp file, then atomically renames on success; deletes it
    /// on failure/cancel. `progress` is called with byte deltas as data arrives.
    func getObject(bucket: String, key: String, toLocalPath: String,
                   progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let req = makeSignedRequest(method: "GET", bucket: bucket, key: key,
                                    payloadHash: S3Client.unsignedPayload)
        let (stream, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw S3Error(message: "No HTTP response") }
        guard (200...299).contains(http.statusCode) else {
            throw S3Error(message: "HTTP \(http.statusCode)")
        }
        let tmp = toLocalPath + ".part"
        FileManager.default.createFile(atPath: tmp, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: tmp) else {
            throw S3Error(message: "Cannot open \(tmp) for writing")
        }
        do {
            var buf = Data(); buf.reserveCapacity(1 << 20)
            for try await byte in stream {
                buf.append(byte)
                if buf.count >= (1 << 20) {   // flush ~1 MiB chunks
                    try handle.write(contentsOf: buf)
                    progress?(Int64(buf.count)); buf.removeAll(keepingCapacity: true)
                }
            }
            if !buf.isEmpty { try handle.write(contentsOf: buf); progress?(Int64(buf.count)) }
            try handle.close()
            if FileManager.default.fileExists(atPath: toLocalPath) {
                try FileManager.default.removeItem(atPath: toLocalPath)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: toLocalPath)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
    }

    /// Uploads a local file. Small files → single PUT; large files → concurrent
    /// multipart (peak memory ≈ partSize × concurrency, not the whole file).
    /// `progress` is called with byte deltas as data is sent.
    func putObject(bucket: String, key: String, fromLocalPath: String,
                   progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fromLocalPath)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let plan = S3MultipartPlan.parts(fileSize: size)
        if plan.isEmpty {
            // ≤16 MB: buffering is fine (the OOM problem was only for large files,
            // which now go multipart). Reuse the proven signed-body `send` path.
            let data = try Data(contentsOf: URL(fileURLWithPath: fromLocalPath))
            _ = try await send(method: "PUT", bucket: bucket, key: key, body: data)
            progress?(size)
            return
        }

        let uploadId = try await createMultipartUpload(bucket: bucket, key: key)
        do {
            let etags = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [(Int, String)] in
                var inFlight = 0
                var idx = 0
                var results: [(Int, String)] = []
                func schedule() {
                    guard idx < plan.count else { return }
                    let part = plan[idx]; idx += 1; inFlight += 1
                    group.addTask {
                        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: fromLocalPath))
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(part.offset))
                        let body = try handle.read(upToCount: Int(part.length)) ?? Data()
                        let etag = try await self.uploadPart(bucket: bucket, key: key, uploadId: uploadId,
                                                             partNumber: part.number, body: body)
                        progress?(part.length)
                        return (part.number, etag)
                    }
                }
                for _ in 0..<min(4, plan.count) { schedule() }   // partConcurrency = 4
                while inFlight > 0 {
                    let r = try await group.next()!
                    inFlight -= 1
                    results.append(r)
                    schedule()
                }
                return results
            }
            try await completeMultipartUpload(bucket: bucket, key: key, uploadId: uploadId, parts: etags)
        } catch {
            try? await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
            throw error
        }
    }

    func putEmptyObject(bucket: String, key: String) async throws {
        _ = try await send(method: "PUT", bucket: bucket, key: key, body: Data())
    }

    // MARK: - Multipart upload (low-level)

    func createMultipartUpload(bucket: String, key: String) async throws -> String {
        let (data, _) = try await send(method: "POST", bucket: bucket, key: key, query: ["uploads": ""])
        guard let id = S3XML.uploadId(data) else { throw S3Error(message: "No UploadId in response") }
        return id
    }

    /// Uploads one part; returns its ETag (needed by completeMultipartUpload).
    func uploadPart(bucket: String, key: String, uploadId: String,
                    partNumber: Int, body: Data) async throws -> String {
        let (_, http) = try await send(method: "PUT", bucket: bucket, key: key,
                                       query: ["partNumber": "\(partNumber)", "uploadId": uploadId],
                                       body: body)
        guard let etag = http.value(forHTTPHeaderField: "ETag") else {
            throw S3Error(message: "Part \(partNumber) returned no ETag")
        }
        return etag
    }

    func completeMultipartUpload(bucket: String, key: String, uploadId: String,
                                 parts: [(number: Int, eTag: String)]) async throws {
        let body = S3XML.completeMultipartBody(parts: parts)
        _ = try await send(method: "POST", bucket: bucket, key: key,
                           query: ["uploadId": uploadId], body: body)
    }

    func abortMultipartUpload(bucket: String, key: String, uploadId: String) async throws {
        _ = try await send(method: "DELETE", bucket: bucket, key: key, query: ["uploadId": uploadId])
    }

    func deleteObject(bucket: String, key: String) async throws {
        _ = try await send(method: "DELETE", bucket: bucket, key: key)
    }

    func copyObject(bucket: String, srcKey: String, dstKey: String) async throws {
        let source = "/\(bucket)/\(srcKey)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(bucket)/\(srcKey)"
        _ = try await send(method: "PUT", bucket: bucket, key: dstKey, body: Data(),
                           extraHeaders: ["x-amz-copy-source": source])
    }
}
