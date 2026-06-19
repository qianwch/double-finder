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

    /// Build, sign, and send a request; returns (data, httpResponse). Throws S3Error on non-2xx.
    private func send(method: String, bucket: String?, key: String,
                      query: [String: String] = [:], body: Data? = nil,
                      extraHeaders: [String: String] = [:],
                      payloadHash: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = endpoint.url(bucket: bucket, key: key, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        let hash = payloadHash ?? (body.map { S3Signer.sha256Hex($0) } ?? S3Client.unsignedPayload)
        var headers = extraHeaders
        for (k, v) in signer.authorizationHeaders(method: method, url: url, headers: headers,
                                                  payloadHash: hash, date: currentDate()) {
            headers[k] = v
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
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

    func getObject(bucket: String, key: String, toLocalPath: String) async throws {
        let (data, _) = try await send(method: "GET", bucket: bucket, key: key)
        try data.write(to: URL(fileURLWithPath: toLocalPath))
    }

    func putObject(bucket: String, key: String, fromLocalPath: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: fromLocalPath))
        _ = try await send(method: "PUT", bucket: bucket, key: key, body: data)
    }

    func putEmptyObject(bucket: String, key: String) async throws {
        _ = try await send(method: "PUT", bucket: bucket, key: key, body: Data())
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
