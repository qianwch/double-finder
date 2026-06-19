import XCTest
@testable import double_finder

final class S3SignerTests: XCTestCase {

    // AWS docs "Signature Calculations — GET Object" worked example.
    // https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    func testAWSGetObjectVector() {
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE",
                              secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                              region: "us-east-1")
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        var comps = DateComponents()
        comps.year = 2013; comps.month = 5; comps.day = 24
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!

        let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let headers = signer.authorizationHeaders(
            method: "GET", url: url,
            headers: ["Range": "bytes=0-9", "Host": "examplebucket.s3.amazonaws.com"],
            payloadHash: emptyHash, date: date)

        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(headers["x-amz-content-sha256"], emptyHash)
        XCTAssertEqual(headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," +
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," +
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testSha256HexEmpty() {
        XCTAssertEqual(S3Signer.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
