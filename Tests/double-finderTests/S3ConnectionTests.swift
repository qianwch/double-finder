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

    func testLegacySecretQueryShape() {
        let q = S3SecretStore.legacyQuery(endpointHost: "minio.local", accessKey: "AKID")
        XCTAssertEqual(q[kSecAttrServer as String] as? String, "minio.local")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "AKID")
        XCTAssertNotNil(q[kSecClass as String])
    }

    func testBlobKey() {
        XCTAssertEqual(S3SecretStore.blobKey(endpointHost: "minio.local", accessKey: "AKID"),
                       "minio.local|AKID")
    }

    func testBlobRoundTrip() {
        let dict = ["minio.local|AKID": "s3cr3t", "s3.amazonaws.com|AKIB": "另一个/秘钥=="]
        let back = S3SecretStore.decodeBlob(S3SecretStore.encodeBlob(dict))
        XCTAssertEqual(back, dict)
    }

    func testDecodeBlobToleratesGarbage() {
        XCTAssertEqual(S3SecretStore.decodeBlob(Data("not json".utf8)), [:])
        XCTAssertEqual(S3SecretStore.decodeBlob(Data()), [:])
    }

    func testUnifiedItemAttributes() {
        XCTAssertEqual(S3SecretStore.service, "double-finder")
    }
}
