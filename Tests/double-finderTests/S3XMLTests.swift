import XCTest
@testable import double_finder

final class S3XMLTests: XCTestCase {

    func testParseMultipartUploads() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListMultipartUploadsResult>
          <Bucket>b</Bucket><IsTruncated>false</IsTruncated>
          <Upload><Key>big.bin</Key><UploadId>UID1</UploadId><Initiated>2026-06-26T01:02:03.000Z</Initiated></Upload>
          <Upload><Key>dir/x.vhd</Key><UploadId>UID2</UploadId><Initiated>2026-06-25T10:00:00Z</Initiated></Upload>
        </ListMultipartUploadsResult>
        """
        let r = S3XML.multipartUploads(Data(xml.utf8))
        XCTAssertEqual(r.uploads.count, 2)
        XCTAssertEqual(r.uploads[0], S3UploadInfo(key: "big.bin", uploadId: "UID1",
            initiated: ISO8601DateFormatter().date(from: "2026-06-26T01:02:03Z")))
        XCTAssertEqual(r.uploads[1].key, "dir/x.vhd")
        XCTAssertEqual(r.uploads[1].uploadId, "UID2")
        XCTAssertNil(r.nextKeyMarker, "not truncated → no marker")
    }

    func testParseMultipartUploadsTruncated() {
        let xml = """
        <ListMultipartUploadsResult><IsTruncated>true</IsTruncated>
          <NextKeyMarker>k9</NextKeyMarker><NextUploadIdMarker>u9</NextUploadIdMarker>
          <Upload><Key>a</Key><UploadId>U</UploadId></Upload>
        </ListMultipartUploadsResult>
        """
        let r = S3XML.multipartUploads(Data(xml.utf8))
        XCTAssertEqual(r.nextKeyMarker, "k9")
        XCTAssertEqual(r.nextUploadIdMarker, "u9")
        XCTAssertNil(r.uploads[0].initiated, "missing Initiated → nil")
    }

    func testParseCopyPartETag() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CopyPartResult><LastModified>2026-06-26T00:00:00.000Z</LastModified><ETag>"abc123def456"</ETag></CopyPartResult>
        """
        XCTAssertEqual(S3XML.copyPartETag(Data(xml.utf8)), "\"abc123def456\"")
    }

    func testParseCopyPartETagMissing() {
        XCTAssertNil(S3XML.copyPartETag(Data("<Error><Code>NoSuchKey</Code></Error>".utf8)))
    }

    func testParseS3Path() {
        XCTAssertEqual(parseS3Path("/").bucket, nil)
        XCTAssertEqual(parseS3Path("/").key, "")
        let b = parseS3Path("/mybucket")
        XCTAssertEqual(b.bucket, "mybucket"); XCTAssertEqual(b.key, "")
        let k = parseS3Path("/mybucket/a/b/")
        XCTAssertEqual(k.bucket, "mybucket"); XCTAssertEqual(k.key, "a/b/")
        let f = parseS3Path("/mybucket/a/file.txt")
        XCTAssertEqual(f.bucket, "mybucket"); XCTAssertEqual(f.key, "a/file.txt")
    }

    func testParseBuckets() {
        let xml = """
        <?xml version="1.0"?>
        <ListAllMyBucketsResult><Buckets>
          <Bucket><Name>alpha</Name><CreationDate>2020-01-01T00:00:00Z</CreationDate></Bucket>
          <Bucket><Name>beta</Name><CreationDate>2020-01-02T00:00:00Z</CreationDate></Bucket>
        </Buckets></ListAllMyBucketsResult>
        """
        XCTAssertEqual(S3XML.buckets(Data(xml.utf8)), ["alpha", "beta"])
    }

    func testParseListObjects() {
        let xml = """
        <?xml version="1.0"?>
        <ListBucketResult>
          <CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>docs/</Prefix></CommonPrefixes>
          <Contents><Key>readme.txt</Key><Size>12</Size><LastModified>2021-03-04T05:06:07Z</LastModified></Contents>
          <Contents><Key>logo.png</Key><Size>2048</Size><LastModified>2021-03-04T05:06:08Z</LastModified></Contents>
          <NextContinuationToken>TOKEN123</NextContinuationToken>
        </ListBucketResult>
        """
        let r = S3XML.listObjects(Data(xml.utf8))
        XCTAssertEqual(r.prefixes, ["photos/", "docs/"])
        XCTAssertEqual(r.objects.map { $0.key }, ["readme.txt", "logo.png"])
        XCTAssertEqual(r.objects.first?.size, 12)
        XCTAssertEqual(r.nextToken, "TOKEN123")
    }

    func testParseListObjectsFractionalSeconds() {
        let xml = """
        <?xml version="1.0"?>
        <ListBucketResult>
          <Contents><Key>file.txt</Key><Size>42</Size><LastModified>2021-03-04T05:06:07.123Z</LastModified></Contents>
        </ListBucketResult>
        """
        let r = S3XML.listObjects(Data(xml.utf8))
        XCTAssertEqual(r.objects.count, 1)
        let date = r.objects[0].modified
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.year, from: date), 2021)
        XCTAssertEqual(cal.component(.month, from: date), 3)
        XCTAssertEqual(cal.component(.day, from: date), 4)
        XCTAssertEqual(cal.component(.hour, from: date), 5)
        XCTAssertEqual(cal.component(.minute, from: date), 6)
        XCTAssertEqual(cal.component(.second, from: date), 7)
        // Verify it did NOT fall back to Date() — nanosecond component confirms fractional parse
        let ns = cal.component(.nanosecond, from: date)
        XCTAssertTrue(ns >= 100_000_000 && ns < 200_000_000, "Expected ~123ms, got \(ns)ns")
    }

    func testParseError() {
        let xml = "<Error><Code>SignatureDoesNotMatch</Code><Message>bad sig</Message></Error>"
        XCTAssertEqual(S3XML.errorMessage(Data(xml.utf8)), "bad sig")
        XCTAssertNil(S3XML.errorMessage(Data("<ok/>".utf8)))
    }

    func testParseUploadId() {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>ABC123==</UploadId></InitiateMultipartUploadResult>
        """.utf8)
        XCTAssertEqual(S3XML.uploadId(xml), "ABC123==")
    }

    func testParseUploadIdMissing() {
        XCTAssertNil(S3XML.uploadId(Data("<Error><Message>nope</Message></Error>".utf8)))
    }

    func testCompleteMultipartBody() {
        let body = S3XML.completeMultipartBody(parts: [(2, "\"etag2\""), (1, "\"etag1\"")])
        let s = String(decoding: body, as: UTF8.self)
        // sorted by part number; etags preserved verbatim (incl. quotes)
        XCTAssertTrue(s.contains("<CompleteMultipartUpload>"))
        let p1 = s.range(of: "<PartNumber>1</PartNumber>")!
        let p2 = s.range(of: "<PartNumber>2</PartNumber>")!
        XCTAssertTrue(p1.lowerBound < p2.lowerBound, "parts must be sorted ascending")
        XCTAssertTrue(s.contains("<ETag>\"etag1\"</ETag>"))
        XCTAssertTrue(s.contains("<ETag>\"etag2\"</ETag>"))
    }

    func testEndpointURLPathStyle() {
        let ep = S3Endpoint(base: URL(string: "https://minio.local:9000")!,
                            region: "us-east-1", pathStyle: true)
        XCTAssertEqual(ep.url(bucket: "buck", key: "a/b.txt", query: [:]).absoluteString,
                       "https://minio.local:9000/buck/a/b.txt")
        XCTAssertEqual(ep.url(bucket: nil, key: "", query: [:]).absoluteString,
                       "https://minio.local:9000/")
    }

    func testEndpointURLVirtualHosted() {
        let ep = S3Endpoint(base: URL(string: "https://s3.amazonaws.com")!,
                            region: "us-east-1", pathStyle: false)
        XCTAssertEqual(ep.url(bucket: "buck", key: "a.txt", query: [:]).absoluteString,
                       "https://buck.s3.amazonaws.com/a.txt")
    }

    /// The request URL must be sent with the SAME strict RFC3986 encoding the
    /// SigV4 signer uses, or the server rejects it with SignatureDoesNotMatch.
    /// `$`, `+`, space in a key must reach the wire as %24 / %2B / %20.
    func testEndpointEncodesSpecialCharsInPath() {
        let ep = S3Endpoint(base: URL(string: "https://minio.local:9000")!,
                            region: "us-east-1", pathStyle: true)
        let s = ep.url(bucket: "buck", key: "dir/$loader/a+b c.js", query: [:]).absoluteString
        XCTAssertEqual(s, "https://minio.local:9000/buck/dir/%24loader/a%2Bb%20c.js")
    }

    /// Query values must be strict-encoded too (slash → %2F, $ → %24).
    func testEndpointEncodesQuery() {
        let ep = S3Endpoint(base: URL(string: "https://minio.local:9000")!,
                            region: "us-east-1", pathStyle: true)
        let s = ep.url(bucket: "buck", key: "",
                       query: ["list-type": "2", "prefix": "a/$loader/"]).absoluteString
        XCTAssertEqual(s, "https://minio.local:9000/buck?list-type=2&prefix=a%2F%24loader%2F")
    }
}
