import XCTest
@testable import ProxyceptLogging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor GatedTransport: LogTransport {
    private var gate: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var requests: [URLRequest] = []
    private let firstStatus: Int
    init(firstStatus: Int = 200) { self.firstStatus = firstStatus }
    func send(_ request: URLRequest) async throws -> TransportResponse {
        requests.append(request)
        let first = requests.count == 1
        if first {
            await withCheckedContinuation { continuation in
                gate = continuation; started = true
                observers.forEach { $0.resume() }; observers.removeAll()
            }
        }
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let count = (json["events"] as! [Any]).count
        return TransportResponse(statusCode: first ? firstStatus : 200,
            body: Data("{\"accepted\":\(count),\"duplicate\":0,\"received_at\":\"2026-10-29T00:00:00Z\"}".utf8))
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func captured() -> [URLRequest] { requests }
}

final class ConcurrencyTests: XCTestCase {
    private func configuration(_ directory: URL) -> LoggingConfiguration {
        LoggingConfiguration(baseURL: URL(string: "https://logs.example.com")!,
            ingestToken: "plog_ingest_initial", appVersion: "1", build: "1", spoolDirectory: directory)
    }

    func testConcurrentFlushesShareSingleRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = GatedTransport()
        let client = try ProxyceptLogger(configuration: configuration(dir), transport: transport)
        client.log(level: .info, category: "concurrency", message: "one")
        let first = Task { await client.flush() }
        await transport.waitForStart()
        let second = Task { await client.flush() }
        await transport.release()
        await first.value; await second.value
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.accepted, 1)
        await client.close()
    }

    func testDisableIgnoresInFlightAcknowledgement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = GatedTransport()
        let client = try ProxyceptLogger(configuration: configuration(dir), transport: transport)
        client.log(level: .info, category: "concurrency", message: "one")
        let flush = Task { await client.flush() }
        await transport.waitForStart(); await client.disable(); await transport.release()
        await flush.value; await client.close()
        let stats = await client.deliveryStats()
        XCTAssertEqual(stats.queued, 0); XCTAssertEqual(stats.accepted, 0); XCTAssertTrue(stats.disabled)
    }

    func testCredentialRotationIgnoresStaleAuthenticationFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = GatedTransport(firstStatus: 401)
        let client = try ProxyceptLogger(configuration: configuration(dir), transport: transport)
        client.log(level: .info, category: "concurrency", message: "one")
        let first = Task { await client.flush() }
        await transport.waitForStart()
        try await client.reconfigure(ingestToken: "plog_ingest_rotated")
        await transport.release(); await first.value
        await client.flush()
        let stats = await client.deliveryStats(), requests = await transport.captured()
        XCTAssertFalse(stats.authenticationStopped); XCTAssertEqual(stats.accepted, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer plog_ingest_rotated")
        await client.close()
    }

    func testStorageFailureRetainsMemoryAndRecovers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try ProxyceptLogger(configuration: configuration(dir), transport: GatedTransport())
        let file = dir.appendingPathComponent("queue.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        client.log(level: .warning, category: "storage", message: "retained")
        var stats = await client.deliveryStats()
        XCTAssertGreaterThan(stats.storageFailures, 0); XCTAssertEqual(stats.queued, 1)
        try FileManager.default.removeItem(at: file)
        stats = await client.deliveryStats()
        XCTAssertEqual(stats.queued, 1)
        let snapshot = try JSONDecoder().decode(Spool.self, from: Data(contentsOf: file))
        XCTAssertEqual(snapshot.entries.count, 1)
        await client.close()
    }
}
