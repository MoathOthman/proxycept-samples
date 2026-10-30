import XCTest
@testable import ProxyceptRNCore

private actor CorrelationPeer: LogTransport {
    private var bodies: [[String: Any]] = []
    func send(_ request: URLRequest) async throws -> TransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        bodies.append(body)
        let events = body["events"] as! [[String: Any]]
        for event in events {
            let value = event["correlation_id"]!
            guard value is NSNull || ((value as? String).map { !$0.isEmpty && $0.unicodeScalars.count <= 128 } ?? false) else {
                return TransportResponse(statusCode: 422)
            }
        }
        return TransportResponse(statusCode: 200,
            body: Data("{\"accepted\":\(events.count),\"duplicate\":0,\"received_at\":\"2026-10-30T00:00:00Z\"}".utf8))
    }
    func messages() -> [String] { bodies.flatMap { ($0["events"] as! [[String: Any]]).map { $0["message"] as! String } } }
}
final class CorrelationTests: XCTestCase {
    private func configuration(_ directory: URL) -> LoggingConfiguration {
        LoggingConfiguration(baseURL: URL(string: "http://127.0.0.1:18880")!, ingestToken: "plog_ingest_fixture",
            appVersion: "1", build: "1", spoolDirectory: directory)
    }
    func testCoreRejectsEmptyCorrelationWithoutPoisoningNeighbors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = CorrelationPeer(), logger = try ProxyceptLogger(configuration: configuration(directory), transport: peer)
        XCTAssertTrue(logger.log(level: .info, category: "correlation", message: "before"))
        XCTAssertFalse(logger.log(level: .info, category: "correlation", message: "invalid", correlationId: ""))
        XCTAssertFalse(logger.log(level: .info, category: "correlation", message: "long", correlationId: String(repeating: "x", count: 129)))
        XCTAssertTrue(logger.log(level: .info, category: "correlation", message: "after", correlationId: String(repeating: "x", count: 128)))
        await logger.flush()
        let stats = await logger.deliveryStats(), messages = await peer.messages()
        XCTAssertEqual(messages, ["before", "after"]); XCTAssertEqual(stats.accepted, 2)
        XCTAssertEqual(stats.invalid, 2); XCTAssertEqual(stats.rejected, 0); XCTAssertEqual(stats.queued, 0)
        await logger.close()
    }
    func testRecoveredEmptyCorrelationPreservesValidNeighborsAndIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = Metadata(app_version: "1", build: "1", installation_id: "legacy", debug_session_id: "session")
        let correlations: [String?] = [nil, "", "request-1", String(repeating: "x", count: 129)]
        let entries = correlations.enumerated().map { index, correlation in
            QueuedEvent(event: Event(event_id: UUID().uuidString, sequence: Int64(index), client_time: "2026-10-30T00:00:00Z",
                severity: .info, category: "correlation", message: "record-\(index)", attributes: [:], correlation_id: correlation),
                metadata: metadata, enqueuedAt: Date())
        }
        let file = directory.appendingPathComponent("queue.json")
        try JSONEncoder().encode(Spool(installationId: "legacy", nextSequence: 4, entries: entries)).write(to: file)
        let peer = CorrelationPeer(), logger = try ProxyceptLogger(configuration: configuration(directory), transport: peer)
        let recovered = try JSONDecoder().decode(Spool.self, from: Data(contentsOf: file))
        XCTAssertEqual(recovered.entries.map { $0.event.event_id }, [entries[0].event.event_id, entries[2].event.event_id])
        XCTAssertEqual(recovered.nextSequence, 4)
        await logger.flush()
        let stats = await logger.deliveryStats(), messages = await peer.messages()
        XCTAssertEqual(messages, ["record-0", "record-2"]); XCTAssertEqual(stats.accepted, 2)
        XCTAssertEqual(stats.invalid, 2); XCTAssertEqual(stats.corruptSpools, 0); XCTAssertEqual(stats.queued, 0)
        await logger.close()
    }
    func testRNWireRejectsEmptyCorrelationBeforeBatching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = CorrelationPeer(), controller = RNLoggerController(root: directory, transport: peer)
        try await controller.configure(#"{"baseUrl":"http://127.0.0.1:18880","ingestToken":"plog_ingest_fixture","appVersion":"1","build":"1","spoolName":"test","maxQueueEvents":2000,"maxQueueBytes":2097152}"#)
        let before = try await controller.log(#"{"level":"info","category":"correlation","message":"before","attributes":{},"correlationId":null}"#)
        let invalid = try await controller.log(#"{"level":"info","category":"correlation","message":"invalid","attributes":{},"correlationId":""}"#)
        let after = try await controller.log(#"{"level":"info","category":"correlation","message":"after","attributes":{},"correlationId":"request-1"}"#)
        XCTAssertTrue(before); XCTAssertFalse(invalid); XCTAssertTrue(after)
        await controller.flush()
        let messages = await peer.messages(); XCTAssertEqual(messages, ["before", "after"])
        await controller.close()
    }
}
