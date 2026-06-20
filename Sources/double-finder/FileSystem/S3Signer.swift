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

    /// Strict RFC3986-encoded path (keeps "/"). The request MUST be sent with
    /// this exact encoding so the server's canonical request matches ours.
    static func canonicalPath(_ path: String) -> String {
        uriEncode(path.isEmpty ? "/" : path, encodeSlash: false)
    }

    /// Strict-encoded, sorted canonical query string from raw (unencoded) items.
    static func canonicalQueryString(_ items: [(name: String, value: String)]) -> String {
        var encoded: [(String, String)] = []
        for item in items {
            encoded.append((uriEncode(item.name, encodeSlash: true),
                            uriEncode(item.value, encodeSlash: true)))
        }
        encoded.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return encoded.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
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

        // Sign the EXACT bytes on the wire: S3Endpoint builds the URL with strict
        // RFC3986 percent-encoding, so the canonical request must read that
        // encoded path/query back as-is (not re-encode a decoded url.path, which
        // would diverge for keys with "$", "+", spaces, trailing "/").
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = comps?.percentEncodedPath ?? ""
        let canonicalURI = encodedPath.isEmpty ? "/" : encodedPath
        let canonicalQuery = comps?.percentEncodedQuery ?? ""

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
