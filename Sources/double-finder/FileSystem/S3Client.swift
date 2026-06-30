import Foundation

struct S3Error: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Per-task delegate that turns `URLSession`'s cumulative `didSendBodyData` callbacks
/// into incremental byte deltas, so a multipart part reports progress continuously as
/// it's sent (instead of one lump when the whole part finishes). The delegate-queue is
/// serial, so `lastSent` needs no extra locking.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onDelta: (@Sendable (Int64) -> Void)?
    private var lastSent: Int64 = 0
    init(onDelta: (@Sendable (Int64) -> Void)?) { self.onDelta = onDelta }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        // On a retransmit `totalBytesSent` can reset; clamp the delta to ≥0 so we never
        // report negative progress (the op's fraction is min(1,…)-clamped anyway).
        let delta = max(0, totalBytesSent - lastSent)
        lastSent = totalBytesSent
        if delta > 0 { onDelta?(delta) }
    }
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
                        // Streams intra-part progress (byte deltas as the part is sent),
                        // so the bar advances continuously rather than jumping a full part.
                        let etag = try await self.uploadPart(bucket: bucket, key: key, uploadId: uploadId,
                                                             partNumber: part.number, body: body,
                                                             progress: progress)
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

    /// Lists in-progress (incomplete) multipart uploads for a bucket — the storage-
    /// wasting "fragments" left behind when an upload is interrupted before
    /// completion. Paginated via key/upload-id markers.
    func listMultipartUploads(bucket: String) async throws -> [S3UploadInfo] {
        var out: [S3UploadInfo] = []
        var keyMarker: String? = nil, idMarker: String? = nil
        repeat {
            var q = ["uploads": ""]
            if let k = keyMarker { q["key-marker"] = k }
            if let i = idMarker { q["upload-id-marker"] = i }
            let (data, _) = try await send(method: "GET", bucket: bucket, key: "", query: q)
            let r = S3XML.multipartUploads(data)
            out += r.uploads
            keyMarker = r.nextKeyMarker; idMarker = r.nextUploadIdMarker
        } while keyMarker != nil
        return out
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
    /// Uses `upload(for:from:delegate:)` with a per-task progress delegate so `progress`
    /// fires with byte deltas AS the part streams out — not once when it completes.
    /// Signing is unchanged (the part body is in memory, so the payload hash is exact).
    func uploadPart(bucket: String, key: String, uploadId: String,
                    partNumber: Int, body: Data,
                    progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let hash = S3Signer.sha256Hex(body)
        let req = makeSignedRequest(method: "PUT", bucket: bucket, key: key,
                                    query: ["partNumber": "\(partNumber)", "uploadId": uploadId],
                                    payloadHash: hash)
        let delegate = UploadProgressDelegate(onDelta: progress)
        let (data, resp) = try await session.upload(for: req, from: body, delegate: delegate)
        guard let http = resp as? HTTPURLResponse else { throw S3Error(message: "No HTTP response") }
        if !(200...299).contains(http.statusCode) {
            let msg = S3XML.errorMessage(data) ?? "HTTP \(http.statusCode)"
            throw S3Error(message: msg)
        }
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

    /// Server-side copy. Source and destination may live in different buckets of
    /// the **same store** (one endpoint + credentials): the copy-source header
    /// references the source, the PUT targets the destination bucket. No bytes
    /// round-trip through the client.
    func copyObject(srcBucket: String, srcKey: String, dstBucket: String, dstKey: String) async throws {
        let source = "/\(srcBucket)/\(srcKey)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(srcBucket)/\(srcKey)"
        _ = try await send(method: "PUT", bucket: dstBucket, key: dstKey, body: Data(),
                           extraHeaders: ["x-amz-copy-source": source])
    }

    /// Same-bucket convenience (used by rename / move-within-folder).
    func copyObject(bucket: String, srcKey: String, dstKey: String) async throws {
        try await copyObject(srcBucket: bucket, srcKey: srcKey, dstBucket: bucket, dstKey: dstKey)
    }

    /// Server-side copy that scales to large objects: ≤ the multipart threshold →
    /// one PUT copy; larger → concurrent **UploadPartCopy** (handles >5GB, which a
    /// single PUT copy rejects, and reports byte progress). `progress` is called
    /// with each part's byte count as it completes. Honors task cancellation
    /// (cancel → abort the multipart upload; the source object is never touched).
    func copyObject(srcBucket: String, srcKey: String, dstBucket: String, dstKey: String,
                    sourceSize: Int64, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        // 64 MiB parts: keeps the part count low for huge objects, parts big enough
        // that per-request overhead is negligible.
        let plan = S3MultipartPlan.parts(fileSize: sourceSize,
                                         singlePutThreshold: 64 << 20, minPartSize: 64 << 20)
        if plan.isEmpty {
            try await copyObject(srcBucket: srcBucket, srcKey: srcKey, dstBucket: dstBucket, dstKey: dstKey)
            progress?(sourceSize)
            return
        }
        let uploadId = try await createMultipartUpload(bucket: dstBucket, key: dstKey)
        do {
            let etags = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [(Int, String)] in
                var inFlight = 0, idx = 0
                var results: [(Int, String)] = []
                func schedule() {
                    guard idx < plan.count else { return }
                    let part = plan[idx]; idx += 1; inFlight += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let end = part.offset + part.length - 1
                        let etag = try await self.uploadPartCopy(
                            dstBucket: dstBucket, dstKey: dstKey, uploadId: uploadId, partNumber: part.number,
                            srcBucket: srcBucket, srcKey: srcKey, range: "bytes=\(part.offset)-\(end)")
                        progress?(part.length)
                        return (part.number, etag)
                    }
                }
                for _ in 0..<min(4, plan.count) { schedule() }   // 4-way concurrency, like putObject
                while inFlight > 0 {
                    let r = try await group.next()!
                    inFlight -= 1; results.append(r); schedule()
                }
                return results
            }
            try await completeMultipartUpload(bucket: dstBucket, key: dstKey, uploadId: uploadId, parts: etags)
        } catch {
            try? await abortMultipartUpload(bucket: dstBucket, key: dstKey, uploadId: uploadId)
            throw error
        }
    }

    /// One UploadPartCopy: copies a byte range of the source into part `partNumber`
    /// of the destination's multipart upload. Returns the part ETag (from the body).
    func uploadPartCopy(dstBucket: String, dstKey: String, uploadId: String, partNumber: Int,
                        srcBucket: String, srcKey: String, range: String) async throws -> String {
        let source = "/\(srcBucket)/\(srcKey)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(srcBucket)/\(srcKey)"
        let (data, _) = try await send(method: "PUT", bucket: dstBucket, key: dstKey,
                                       query: ["partNumber": "\(partNumber)", "uploadId": uploadId],
                                       extraHeaders: ["x-amz-copy-source": source,
                                                      "x-amz-copy-source-range": range])
        guard let etag = S3XML.copyPartETag(data) else {
            throw S3Error(message: "Part \(partNumber) copy returned no ETag")
        }
        return etag
    }
}
