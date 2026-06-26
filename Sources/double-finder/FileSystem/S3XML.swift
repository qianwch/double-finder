import Foundation

struct S3ObjectInfo: Equatable {
    let key: String
    let size: Int64
    let modified: Date
}

/// One in-progress (incomplete) multipart upload, as listed by ListMultipartUploads.
struct S3UploadInfo: Equatable {
    let key: String
    let uploadId: String
    let initiated: Date?
}

/// A resolved S3 endpoint; builds request URLs in path-style or virtual-hosted form.
struct S3Endpoint {
    let base: URL          // e.g. https://s3.amazonaws.com or https://minio.local:9000
    let region: String
    let pathStyle: Bool

    func url(bucket: String?, key: String, query: [String: String]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var path = "/"
        if let bucket = bucket {
            if pathStyle {
                path = "/" + bucket + (key.isEmpty ? "" : "/" + key)
            } else {
                comps.host = bucket + "." + (base.host ?? "")
                path = "/" + key
            }
        }
        // Strict RFC3986 encoding (must match the SigV4 signer byte-for-byte).
        comps.percentEncodedPath = S3Signer.canonicalPath(path)
        if !query.isEmpty {
            let items = query.map { (name: $0.key, value: $0.value) }
            comps.percentEncodedQuery = S3Signer.canonicalQueryString(items)
        }
        return comps.url!
    }
}

/// Splits a virtual S3 path "/bucket/key…" into (bucket, key). "/" → (nil, "").
func parseS3Path(_ path: String) -> (bucket: String?, key: String) {
    var p = path
    if p.hasPrefix("/") { p.removeFirst() }
    if p.isEmpty { return (nil, "") }
    guard let slash = p.firstIndex(of: "/") else { return (p, "") }
    let bucket = String(p[..<slash])
    let key = String(p[p.index(after: slash)...])
    return (bucket, key)
}

/// Minimal S3 XML response parsing via XMLParser.
enum S3XML {
    static func buckets(_ data: Data) -> [String] {
        let d = Collector(capture: ["Name"], parent: "Bucket")
        XMLParser(data: data).also { $0.delegate = d }.parse()
        return d.values["Name"] ?? []
    }

    static func listObjects(_ data: Data) -> (prefixes: [String], objects: [S3ObjectInfo], nextToken: String?) {
        let d = ListObjectsCollector()
        XMLParser(data: data).also { $0.delegate = d }.parse()
        return (d.prefixes, d.objects, d.nextToken)
    }

    static func errorMessage(_ data: Data) -> String? {
        let d = Collector(capture: ["Message"], parent: "Error")
        XMLParser(data: data).also { $0.delegate = d }.parse()
        return d.values["Message"]?.first
    }

    static func uploadId(_ data: Data) -> String? {
        let d = Collector(capture: ["UploadId"], parent: "InitiateMultipartUploadResult")
        XMLParser(data: data).also { $0.delegate = d }.parse()
        return d.values["UploadId"]?.first
    }

    /// Parses a ListMultipartUploads response: the in-progress uploads plus the
    /// pagination markers (`NextKeyMarker` / `NextUploadIdMarker` when truncated).
    static func multipartUploads(_ data: Data)
        -> (uploads: [S3UploadInfo], nextKeyMarker: String?, nextUploadIdMarker: String?) {
        let d = MultipartUploadsCollector()
        XMLParser(data: data).also { $0.delegate = d }.parse()
        let next = d.isTruncated ? (d.nextKeyMarker, d.nextUploadIdMarker) : (nil, nil)
        return (d.uploads, next.0, next.1)
    }

    /// UploadPartCopy returns the part's ETag in the XML body (`<CopyPartResult>`),
    /// unlike UploadPart which returns it in the response header.
    static func copyPartETag(_ data: Data) -> String? {
        let d = Collector(capture: ["ETag"], parent: "CopyPartResult")
        XMLParser(data: data).also { $0.delegate = d }.parse()
        return d.values["ETag"]?.first
    }

    /// Builds the CompleteMultipartUpload request body. Parts are sorted by number;
    /// ETags are emitted verbatim (S3 returns them quoted — keep the quotes).
    static func completeMultipartBody(parts: [(number: Int, eTag: String)]) -> Data {
        var xml = "<CompleteMultipartUpload>"
        for p in parts.sorted(by: { $0.number < $1.number }) {
            xml += "<Part><PartNumber>\(p.number)</PartNumber><ETag>\(p.eTag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }
}

private extension XMLParser {
    func also(_ body: (XMLParser) -> Void) -> XMLParser { body(self); return self }
}

/// Collects text of given element names that appear under `parent`.
private final class Collector: NSObject, XMLParserDelegate {
    let capture: Set<String>; let parent: String
    var values: [String: [String]] = [:]
    private var stack: [String] = []
    private var buffer = ""
    init(capture: [String], parent: String) { self.capture = Set(capture); self.parent = parent }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) { stack.append(e); buffer = "" }
    func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        if capture.contains(e), stack.contains(parent) {
            values[e, default: []].append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if stack.last == e { stack.removeLast() }
        buffer = ""
    }
}

private final class MultipartUploadsCollector: NSObject, XMLParserDelegate {
    var uploads: [S3UploadInfo] = []
    var isTruncated = false
    var nextKeyMarker: String?
    var nextUploadIdMarker: String?
    private var stack: [String] = []
    private var buffer = ""
    private var curKey = "", curId = "", curInitiated: Date?
    private static let dfFractional: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f
    }()
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }()

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(e); buffer = ""
        if e == "Upload" { curKey = ""; curId = ""; curInitiated = nil }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let inUpload = stack.dropLast().last == "Upload"
        switch e {
        case "Key" where inUpload: curKey = text
        case "UploadId" where inUpload: curId = text
        case "Initiated" where inUpload: curInitiated = Self.dfFractional.date(from: text) ?? Self.df.date(from: text)
        case "Upload": uploads.append(S3UploadInfo(key: curKey, uploadId: curId, initiated: curInitiated))
        case "IsTruncated": isTruncated = (text == "true")
        case "NextKeyMarker": nextKeyMarker = text
        case "NextUploadIdMarker": nextUploadIdMarker = text
        default: break
        }
        if stack.last == e { stack.removeLast() }
        buffer = ""
    }
}

private final class ListObjectsCollector: NSObject, XMLParserDelegate {
    var prefixes: [String] = []
    var objects: [S3ObjectInfo] = []
    var nextToken: String?
    private var stack: [String] = []
    private var buffer = ""
    private var curKey = "", curSize: Int64 = 0, curDate = Date()
    private static let dfFractional: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f
    }()
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }()

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(e); buffer = ""
        if e == "Contents" { curKey = ""; curSize = 0; curDate = Date() }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case "Prefix" where stack.dropLast().last == "CommonPrefixes": prefixes.append(text)
        case "Key": curKey = text
        case "Size": curSize = Int64(text) ?? 0
        case "LastModified": curDate = Self.dfFractional.date(from: text) ?? Self.df.date(from: text) ?? Date()
        case "Contents": objects.append(S3ObjectInfo(key: curKey, size: curSize, modified: curDate))
        case "NextContinuationToken": nextToken = text
        default: break
        }
        if stack.last == e { stack.removeLast() }
        buffer = ""
    }
}
