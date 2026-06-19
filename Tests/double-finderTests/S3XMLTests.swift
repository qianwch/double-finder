import XCTest
@testable import double_finder

final class S3XMLTests: XCTestCase {

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
}
