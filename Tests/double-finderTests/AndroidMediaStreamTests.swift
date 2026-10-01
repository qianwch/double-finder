import XCTest
@testable import double_finder

final class AndroidMediaStreamTests: XCTestCase {
    func testRangeResponseReadsOnlyRequestedBytes() async throws {
        let stream = try AndroidMediaStream(sessionID: "test", path: "/phone/video.mp4", size: 10_000_000,
            reader: { offset, count in
                XCTAssertEqual(offset, 9_999_900)
                XCTAssertEqual(count, 100)
                return Data(repeating: 42, count: Int(count))
            })
        defer { stream.stop() }
        let url = try await stream.start()
        var request = URLRequest(url: url)
        request.setValue("bytes=-100", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 9999900-9999999/10000000")
        XCTAssertEqual(data, Data(repeating: 42, count: 100))
    }

    func testHeadAndInvalidRangeDoNotReadUSB() async throws {
        let stream = try AndroidMediaStream(sessionID: "test", path: "/phone/video.mp4", size: 100,
            reader: { _, _ in XCTFail("HEAD/invalid range must not read USB"); return Data() })
        defer { stream.stop() }
        let url = try await stream.start()
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "100")
        request.httpMethod = "GET"
        request.setValue("bytes=100-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
    }

    func testStopCancelsInFlightReader() async throws {
        let started = expectation(description: "read started")
        let cancelled = expectation(description: "read cancelled")
        let stream = try AndroidMediaStream(sessionID: "test", path: "/phone/video.mp4", size: 100,
            reader: { _, _ in
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { cancelled.fulfill(); throw error }
                return Data()
            })
        defer { stream.stop() }
        let url = try await stream.start()
        let request = Task { try? await URLSession.shared.data(from: url) }
        await fulfillment(of: [started], timeout: 3)
        stream.stop()
        await fulfillment(of: [cancelled], timeout: 3)
        request.cancel()
    }
}
