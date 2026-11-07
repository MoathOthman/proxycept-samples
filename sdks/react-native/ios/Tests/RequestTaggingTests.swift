import XCTest
@testable import ProxyceptRNCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor RecordingTransport: LogTransport {
    var bodies: [Data] = []
    func send(_ request: URLRequest) async throws -> TransportResponse {
        let body = request.httpBody ?? Data()
        bodies.append(body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let count = (json["events"] as! [Any]).count
        return TransportResponse(statusCode: 200,
            body: Data("{\"accepted\":\(count),\"duplicate\":0,\"received_at\":\"2026-11-06T00:00:00Z\"}".utf8))
    }
    func captured() -> [Data] { bodies }
}

final class RequestTaggingTests: XCTestCase {
    private let header = "X-Proxycept-Correlation-ID"
    private func request() -> URLRequest { URLRequest(url: URL(string: "https://api.example.com/orders")!) }

    func testHeaderNameIsExact() {
        XCTAssertEqual(ProxyceptLogger.correlationHeader, "X-Proxycept-Correlation-ID")
    }

    func testGeneratesUUIDWhenNoneAndSetsHeader() {
        var request = request()
        let id = ProxyceptLogger.tag(&request)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(request.value(forHTTPHeaderField: header), id)
        var other = self.request()
        XCTAssertNotEqual(ProxyceptLogger.tag(&other), id)
    }

    func testReusesExistingValidHeaderCaseInsensitively() {
        var request = request()
        request.setValue("existing-id-42", forHTTPHeaderField: "x-proxycept-correlation-id")
        XCTAssertEqual(ProxyceptLogger.tag(&request), "existing-id-42")
        XCTAssertEqual(request.value(forHTTPHeaderField: header), "existing-id-42")
    }

    func testExplicitIdHonoredAndOverridesExistingHeader() {
        var request = request()
        request.setValue("existing-id", forHTTPHeaderField: header)
        XCTAssertEqual(ProxyceptLogger.tag(&request, correlationId: "checkout-7"), "checkout-7")
        XCTAssertEqual(request.value(forHTTPHeaderField: header), "checkout-7")
        let max = String(repeating: "a", count: 128)
        XCTAssertEqual(ProxyceptLogger.tag(&request, correlationId: max), max)
    }

    func testInvalidExplicitIdIsNeverSentAndFreshUUIDReturned() {
        let invalid = ["", String(repeating: "a", count: 129), "id\r\nX-Injected: 1", "id\n", "id\r",
                       "tab\there", "nul\u{0}", "del\u{7F}", "has space", "caf\u{E9}", "emoji\u{1F600}"]
        for value in invalid {
            var request = request()
            let id = ProxyceptLogger.tag(&request, correlationId: value)
            XCTAssertNotEqual(id, value)
            XCTAssertNotNil(UUID(uuidString: id), "fresh UUID for \(value.debugDescription)")
            XCTAssertEqual(request.value(forHTTPHeaderField: header), id)
            XCTAssertFalse(ProxyceptLogger.isValidCorrelationId(value))
        }
    }

    func testInvalidExistingHeaderIsReplaced() {
        for value in ["has space", String(repeating: "b", count: 129)] {
            var request = request()
            request.setValue(value, forHTTPHeaderField: header)
            let id = ProxyceptLogger.tag(&request)
            XCTAssertNotNil(UUID(uuidString: id))
            XCTAssertEqual(request.value(forHTTPHeaderField: header), id)
        }
    }

    func testReturnedIdRoundTripsIntoLogCorrelation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxycept-tag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingTransport()
        let logger = try ProxyceptLogger(configuration: LoggingConfiguration(
            baseURL: URL(string: "http://127.0.0.1:18880")!, ingestToken: "plog_ingest_testsecret",
            appVersion: "1.0", build: "1", debugSessionId: "tag-session", spoolDirectory: directory),
            transport: transport, now: { Date(timeIntervalSince1970: 1_798_272_000) }, jitter: { 0.5 }, startTimer: false)
        var request = request()
        let generated = ProxyceptLogger.tag(&request)
        let explicit = ProxyceptLogger.tag(&request, correlationId: String(repeating: "z", count: 128))
        XCTAssertTrue(logger.log(level: .info, category: "orders", message: "generated", correlationId: generated))
        XCTAssertTrue(logger.log(level: .info, category: "orders", message: "explicit", correlationId: explicit))
        await logger.flush()
        let bodies = await transport.captured()
        XCTAssertEqual(bodies.count, 1)
        let json = try JSONSerialization.jsonObject(with: bodies[0]) as! [String: Any]
        let ids = (json["events"] as! [[String: Any]]).map { $0["correlation_id"] as? String }
        XCTAssertEqual(ids, [generated, explicit])
        await logger.close()
    }
}
