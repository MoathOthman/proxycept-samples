import XCTest
@testable import ProxyceptRNCore

private actor Peer: LogTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> TransportResponse {
        requests.append(request)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let events = body["events"] as! [[String: Any]]
        for event in events {
            if let correlation = event["correlation_id"] as? String, correlation.isEmpty || correlation.unicodeScalars.count > 128 {
                return TransportResponse(statusCode: 422)
            }
            let attrs = event["attributes"] as! [String: Any]
            for (key, value) in attrs {
                if key.isEmpty || ((value as? NSNumber).map { abs($0.doubleValue) > 1e308 } ?? false) || value is [String: Any] || value is [Any] {
                    return TransportResponse(statusCode: 422)
                }
            }
        }
        return TransportResponse(statusCode: 200, body: Data("{\"accepted\":\(events.count),\"duplicate\":0,\"received_at\":\"2026-10-30T00:00:00Z\"}".utf8))
    }
    func captured() -> [URLRequest] { requests }
}
final class RNControllerTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../conformance/attribute-vectors.json").standardized
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any])["cases"] as! [[String: Any]]
    }
    private func config() throws -> String {
        let object: [String: Any] = ["baseUrl": "http://127.0.0.1:18880", "ingestToken": "plog_ingest_fixture",
            "appVersion": "1", "build": "1", "spoolName": "test", "maxQueueEvents": 2000, "maxQueueBytes": 2097152,
            "debugSessionId": "rn-fixture"]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func event(_ attributes: [String: Any], message: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["level": "info", "category": "conformance",
            "message": message, "attributes": attributes, "correlationId": NSNull()]), as: UTF8.self)
    }
    func testSharedTenCasesAndMixedValidNeighborsThroughNativeController() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = Peer(), controller = RNLoggerController(root: root, transport: peer)
        try await controller.configure(config())
        _ = try await controller.log(event([:], message: "before"))
        var valid = 2
        let cases = try vectors(); XCTAssertEqual(cases.count, 10)
        for vector in cases {
            let expected = vector["accepted"] as! Bool
            let accepted: Bool
            do { accepted = try await controller.log(event(vector["attributes"] as! [String: Any], message: vector["name"] as! String)) }
            catch { accepted = false }
            XCTAssertEqual(accepted, expected, vector["name"] as! String)
            if expected { valid += 1 }
        }
        _ = try await controller.log(event([:], message: "after"))
        // Stats is an actor/core queue barrier before inspecting the final durable snapshot.
        _ = await controller.deliveryStats()
        let snapshot = try String(contentsOf: root.appendingPathComponent("test/queue.json"), encoding: .utf8)
        XCTAssertFalse(snapshot.contains("plog_ingest_fixture"))
        XCTAssertFalse(snapshot.contains("fixture-secret-do-not-store"))
        XCTAssertTrue(snapshot.contains("[REDACTED]"))
        await controller.flush()
        let stats = try JSONSerialization.jsonObject(with: Data(await controller.deliveryStats().utf8)) as! [String: Any]
        XCTAssertEqual(stats["accepted"] as? Int, valid); XCTAssertEqual(stats["queued"] as? Int, 0)
        let requests = await peer.captured(); XCTAssertEqual(requests.count, 1)
        await controller.close()
    }
    func testNativeConfigurationRejectsHostnameHTTPAndTraversal() async throws {
        let controller = RNLoggerController(root: FileManager.default.temporaryDirectory)
        for replacement in ["http://localhost:18880", "http://example.com", "../escape"] {
            let json = try config().replacingOccurrences(of: replacement == "../escape" ? "\"test\"" : "http:\\/\\/127.0.0.1:18880",
                with: replacement == "../escape" ? "\"../escape\"" : replacement)
            // Use parsed data to avoid JSON slash escaping differences.
            var input = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            if replacement == "../escape" { input["spoolName"] = replacement } else { input["baseUrl"] = replacement }
            do { try await controller.configure(String(decoding: JSONSerialization.data(withJSONObject: input), as: UTF8.self)); XCTFail("Expected rejection") }
            catch { }
        }
    }
}
