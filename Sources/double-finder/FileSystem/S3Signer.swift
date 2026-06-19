import Foundation
import CryptoKit

/// AWS Signature Version 4 signer for S3 requests. Pure logic — given a request
/// it returns the headers to attach. Reproduces AWS's documented example exactly.
struct S3Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service = "s3"

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// RFC3986 encoding for a URI path segment set. `encodeSlash=false` keeps "/".
    private static func uriEncode(_ s: String, encodeSlash: Bool) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        var allowed = CharacterSet(charactersIn: unreserved)
        if !encodeSlash { allowed.insert(charactersIn: "/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Returns headers to add to the request: Authorization, x-amz-date,
    /// x-amz-content-sha256.
    func authorizationHeaders(method: String, url: URL,
                              headers: [String: String], payloadHash: String,
                              date: Date) -> [String: String] {
        let amz = DateFormatter()
        amz.locale = Locale(identifier: "en_US_POSIX")
        amz.timeZone = TimeZone(identifier: "UTC")
        amz.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = amz.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        // Assemble the headers we sign: caller's + the amz ones.
        var signed = headers
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        if signed["Host"] == nil, let host = url.host { signed["Host"] = host }

        // Canonical headers: lower-case name, trimmed value, sorted by name.
        let lowered = signed.map { (k, v) in
            (k.lowercased(), v.trimmingCharacters(in: .whitespaces))
        }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = lowered.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = lowered.map { $0.0 }.joined(separator: ";")

        // Canonical URI (path, slashes preserved) + canonical query (sorted, encoded).
        let canonicalURI = Self.uriEncode(url.path.isEmpty ? "/" : url.path, encodeSlash: false)
        let rawQueryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encodedQueryItems: [(String, String)] = rawQueryItems.map { item in
            let k = Self.uriEncode(item.name, encodeSlash: true)
            let v = Self.uriEncode(item.value ?? "", encodeSlash: true)
            return (k, v)
        }
        let sortedQueryItems = encodedQueryItems.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let canonicalQuery = sortedQueryItems.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let canonicalRequest = [
            method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        // Signing key derivation.
        let kDate = Self.hmac(Data("AWS4\(secretKey)".utf8), Data(dateStamp.utf8))
        let kRegion = Self.hmac(kDate, Data(region.utf8))
        let kService = Self.hmac(kRegion, Data(service.utf8))
        let kSigning = Self.hmac(kService, Data("aws4_request".utf8))
        let signature = Self.hmac(kSigning, Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKey)/\(scope)," +
            "SignedHeaders=\(signedHeaders)," +
            "Signature=\(signature)"

        return ["Authorization": authorization,
                "x-amz-date": amzDate,
                "x-amz-content-sha256": payloadHash]
    }
}
