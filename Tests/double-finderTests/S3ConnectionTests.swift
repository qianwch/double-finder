import XCTest
@testable import double_finder

final class S3ConnectionTests: XCTestCase {

    func testDictRoundTrip() {
        let c = S3Connection(name: "minio", endpoint: "https://minio.local:9000",
                             region: "us-east-1", bucket: "data", accessKey: "AKID",
                             pathStyle: true)
        let back = S3Connection(dict: c.dict)
        XCTAssertEqual(back, c)
    }

    func testDictRejectsMissing() {
        XCTAssertNil(S3Connection(dict: ["name": "x"]))   // no endpoint
    }

    func testSecretQueryShape() {
        let q = S3SecretStore.query(endpointHost: "minio.local", accessKey: "AKID")
        XCTAssertEqual(q[kSecAttrServer as String] as? String, "minio.local")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "AKID")
        XCTAssertNotNil(q[kSecClass as String])
    }
}
