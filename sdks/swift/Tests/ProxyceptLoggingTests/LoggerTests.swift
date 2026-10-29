import XCTest
@testable import ProxyceptLogging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_798_272_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor FakeTransport: LogTransport {
    enum Reply { case status(Int, [String: String]), malformed, network, partial, duplicate }
    var replies: [Reply]
    var requests: [URLRequest] = []
    var calledOnMain = false
    init(_ replies: [Reply] = []) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> TransportResponse {
        calledOnMain = calledOnMain || Thread.isMainThread
        requests.append(request)
        // Model the backend's atomic attribute validation: any invalid event rejects
        // the entire batch. Keep this independent of the SDK validation helper.
        let batch = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let events = batch["events"] as! [[String: Any]]
        for event in events {
            let attributes = event["attributes"] as! [String: Any]
            if attributes.contains(where: { key, value in
                key.isEmpty || key.unicodeScalars.count > 64 ||
                ((value as? NSNumber).map { !$0.doubleValue.isFinite || abs($0.doubleValue) > 1e308 } ?? false)
            }) {
                return TransportResponse(statusCode: 422)
            }
        }
        let reply = replies.isEmpty ? .status(200, [:]) : replies.removeFirst()
        switch reply {
        case .duplicate:
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let count = (json["events"] as! [Any]).count
            return TransportResponse(statusCode: 200, body: Data("{\"accepted\":0,\"duplicate\":\(count),\"received_at\":\"2026-10-26T00:00:00Z\"}".utf8))
        case .network: throw URLError(.notConnectedToInternet)
        case .malformed: return TransportResponse(statusCode: 200, body: Data("{}".utf8))
        case .partial: return TransportResponse(statusCode: 200, body: Data(#"{"accepted":0,"duplicate":0,"received_at":"2026-10-26T00:00:00Z"}"#.utf8))
        case .status(let code, let headers):
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let count = (body["events"] as! [Any]).count
            return TransportResponse(statusCode: code, headers: headers,
                body: Data("{\"accepted\":\(count),\"duplicate\":0,\"received_at\":\"2026-10-26T00:00:00.000Z\"}".utf8))
        }
    }
    func captured() -> [URLRequest] { requests }
    func mainThread() -> Bool { calledOnMain }
}

final class LoggerTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxycept-test-\(UUID().uuidString)")
        directories.append(url)
        return url
    }
    private func configuration(_ directory: URL? = nil) -> LoggingConfiguration {
        LoggingConfiguration(baseURL: URL(string: "http://127.0.0.1:18880")!, ingestToken: "plog_ingest_testsecret",
            appVersion: "1.0", build: "12", debugSessionId: "test-debug-session", spoolDirectory: directory ?? self.directory())
    }
    private func logger(_ config: LoggingConfiguration? = nil, _ transport: FakeTransport = FakeTransport(),
                        _ clock: Clock = Clock(), timer: Bool = false) throws -> ProxyceptLogger {
        try ProxyceptLogger(configuration: config ?? configuration(), transport: transport,
                            now: { clock.now() }, jitter: { 0.5 }, startTimer: timer)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }
    private func append(_ client: ProxyceptLogger, count: Int) async {
        for i in 0..<count {
            client.log(level: .info, category: "checkout", message: "message \(i)")
            _ = await client.deliveryStats()
        }
    }

    func testFrozenWireAndOffMainTransport() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport)
        client.log(level: .warning, category: "checkout", message: "Checkout tapped",
                   attributes: ["screen": .string("checkout"), "count": .number(2), "ok": .bool(true), "nil": .null],
                   correlationId: "request-123")
        await client.flush()
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first), json = try body(request)
        XCTAssertEqual(request.url?.path, "/api/logs/ingest")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer plog_ingest_testsecret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertEqual(Set(json.keys), ["schema_version", "app_version", "build", "installation_id", "debug_session_id", "events"])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["debug_session_id"] as? String, "test-debug-session")
        XCTAssertNotNil(UUID(uuidString: json["installation_id"] as! String))
        let event = (json["events"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(event.keys), ["event_id", "sequence", "client_time", "severity", "category", "message", "attributes", "correlation_id"])
        XCTAssertNotNil(UUID(uuidString: event["event_id"] as! String))
        XCTAssertEqual(event["sequence"] as? Int, 0)
        XCTAssertEqual(event["severity"] as? String, "warning")
        XCTAssertEqual(event["correlation_id"] as? String, "request-123")
        XCTAssertTrue((event["client_time"] as! String).contains(".000Z"))
        let stats = await client.deliveryStats()
        XCTAssertEqual(stats.accepted, 1); XCTAssertEqual(stats.queued, 0)
        let main = await transport.mainThread(); XCTAssertFalse(main)
        await client.close()
    }

    func testRedactsBeforeSpoolIncludingKeysMetadataAndCorrelation() async throws {
        let dir = directory()
        var config = configuration(dir)
        config.appVersion = "plog_ingest_hidden"
        config.redaction.additionalPatterns = ["CUSTOM-[0-9]+"]
        let client = try logger(config)
        client.log(level: .error, category: "user@example.com", message: "Bearer abc password=secret CUSTOM-123",
            attributes: ["api-key": .string("sensitive"), "plog_ingest_othersecret": .string("user@example.com")],
            correlationId: "plog_ingest_testsecret")
        _ = await client.deliveryStats()
        let data = try Data(contentsOf: dir.appendingPathComponent("queue.json"))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["plog_ingest_", "abc", "password=secret", "CUSTOM-123", "user@example.com", "sensitive"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("[REDACTED]"))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("queue.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #if os(iOS)
        let backup = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(backup.isExcludedFromBackup, true)
        XCTAssertEqual(attrs[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        // macOS /tmp reports false despite a successful setResourceValues call; it is
        // already excluded by the OS. iOS protection/backup assertions require iOS tests.
        await client.close()
    }

    func testRestartRetainsEventIDsSequenceAndInstallation() async throws {
        let dir = directory(), transport = FakeTransport([.network])
        var client: ProxyceptLogger? = try logger(configuration(dir), transport)
        await append(client!, count: 2)
        await client!.flush()
        let first = try body((await transport.captured())[0])
        await client!.close(); client = nil
        let nextTransport = FakeTransport()
        let next = try logger(configuration(dir), nextTransport)
        next.log(level: .debug, category: "startup", message: "restarted")
        await next.flush()
        let second = try body((await nextTransport.captured())[0])
        XCTAssertEqual(first["installation_id"] as? String, second["installation_id"] as? String)
        let original = first["events"] as! [[String: Any]], replay = second["events"] as! [[String: Any]]
        XCTAssertEqual(original[0]["event_id"] as? String, replay[0]["event_id"] as? String)
        XCTAssertEqual(replay.map { $0["sequence"] as! Int }, [0, 1, 2])
        await next.close()
    }

    func testCountAndByteBoundsDropOldest() async throws {
        var config = configuration(); config.maxEvents = 3
        let transport = FakeTransport(), client = try logger(config, transport)
        await append(client, count: 5)
        var stats = await client.deliveryStats()
        XCTAssertEqual(stats.queued, 3); XCTAssertEqual(stats.droppedOldest, 2)
        await client.flush()
        let events = try body((await transport.captured())[0])["events"] as! [[String: Any]]
        XCTAssertEqual(events.map { $0["sequence"] as! Int }, [2, 3, 4])
        await client.close()
        config = configuration(); config.maxBytes = 1_024
        let small = try logger(config)
        for _ in 0..<3 { small.log(level: .info, category: "test", message: String(repeating: "x", count: 700)); _ = await small.deliveryStats() }
        stats = await small.deliveryStats()
        XCTAssertGreaterThan(stats.droppedOldest, 0)
        XCTAssertLessThanOrEqual(try Data(contentsOf: config.spoolDirectory.appendingPathComponent("queue.json")).count, 1_024)
        await small.close()
    }

    func testFiftyEventBatchLimitAndNullCorrelation() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport)
        await append(client, count: 105); await client.flush()
        let requests = await transport.captured()
        XCTAssertEqual(try requests.map { (try body($0)["events"] as! [Any]).count }, [50, 50, 5])
        for request in requests {
            XCTAssertLessThanOrEqual(request.httpBody!.count, 256 * 1_024)
            let event = (try body(request)["events"] as! [[String: Any]])[0]
            XCTAssertTrue(event["correlation_id"] is NSNull)
        }
        await client.close()
    }

    func testExpiredEventsRemovedFromDiskWithoutSending() async throws {
        let clock = Clock(), config = configuration(), transport = FakeTransport()
        let client = try logger(config, transport, clock)
        await append(client, count: 2); clock.advance(3 * 24 * 60 * 60)
        await client.flush()
        let stats = await client.deliveryStats(), requests = await transport.captured()
        XCTAssertEqual(stats.expired, 2); XCTAssertEqual(stats.queued, 0); XCTAssertTrue(requests.isEmpty)
        let stored = try JSONDecoder().decode(Spool.self, from: Data(contentsOf: config.spoolDirectory.appendingPathComponent("queue.json")))
        XCTAssertTrue(stored.entries.isEmpty)
        await client.close()
    }

    func testAuthenticationStopsUntilCredentialReconfiguration() async throws {
        for code in [401, 403] {
            let transport = FakeTransport([.status(code, [:])]), client = try logger(nil, transport)
            await append(client, count: 1); await client.flush(); await client.flush()
            var stats = await client.deliveryStats(), requests = await transport.captured()
            XCTAssertTrue(stats.authenticationStopped); XCTAssertEqual(requests.count, 1)
            try await client.reconfigure(ingestToken: "plog_ingest_rotated")
            await client.flush()
            stats = await client.deliveryStats(); requests = await transport.captured()
            XCTAssertEqual(stats.queued, 0); XCTAssertFalse(stats.authenticationStopped)
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer plog_ingest_rotated")
            await client.close()
        }
    }

    func testBackoffForNetworkServerAndInvalidAcknowledgement() async throws {
        for reply in [FakeTransport.Reply.network, .status(503, [:]), .malformed, .partial] {
            let clock = Clock(), transport = FakeTransport([reply]), client = try logger(nil, transport, clock)
            await append(client, count: 1); await client.flush(); await client.flush()
            let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
            var stats = await client.deliveryStats(); XCTAssertEqual(stats.queued, 1); XCTAssertEqual(stats.failures, 1)
            clock.advance(3); await client.flush()
            stats = await client.deliveryStats(); XCTAssertEqual(stats.queued, 0)
            await client.close()
        }
    }

    func testRetryAfterSecondsAndHTTPDate() async throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        for dateHeader in [false, true] {
            let clock = Clock()
            let value = dateHeader ? formatter.string(from: clock.now().addingTimeInterval(60)) : "60"
            let transport = FakeTransport([.status(429, ["Retry-After": value])]), client = try logger(nil, transport, clock)
            await append(client, count: 1); await client.flush(); clock.advance(59); await client.flush()
            let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
            clock.advance(2); await client.flush()
            let stats = await client.deliveryStats(); XCTAssertEqual(stats.accepted, 1)
            await client.close()
        }
    }

    func test413ShrinksBatchThenDropsSingleOversize() async throws {
        let transport = FakeTransport([.status(413, [:]), .status(413, [:])]), client = try logger(nil, transport)
        await append(client, count: 3); await client.flush()
        let requests = await transport.captured()
        XCTAssertEqual(try requests.map { (try body($0)["events"] as! [Any]).count }, [3, 1, 1, 1])
        let stats = await client.deliveryStats()
        XCTAssertEqual(stats.rejected, 1); XCTAssertEqual(stats.accepted, 2); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testPermanentFailureDropsBatch() async throws {
        let transport = FakeTransport([.status(400, [:])]), client = try logger(nil, transport)
        await append(client, count: 2); await client.flush()
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.rejected, 2); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testDisablePurgesAndClosePreserves() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport)
        await append(client, count: 2); await client.disable()
        client.log(level: .info, category: "test", message: "after disable")
        await client.flush()
        var stats = await client.deliveryStats()
        XCTAssertTrue(stats.disabled); XCTAssertEqual(stats.queued, 0); XCTAssertEqual(stats.rejected, 1)
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
        let closed = try logger(); await append(closed, count: 1); await closed.close()
        stats = await closed.deliveryStats(); XCTAssertEqual(stats.queued, 1); XCTAssertTrue(stats.disabled)
    }

    func testInvalidAndUTF8OversizeEventsRejected() async throws {
        let client = try logger()
        XCTAssertFalse(client.log(level: .info, category: "x", message: String(repeating: "x", count: 4_097)))
        XCTAssertFalse(client.log(level: .info, category: "x", message: "x", attributes: ["n": .number(.infinity)]))
        XCTAssertFalse(client.log(level: .info, category: "x", message: "x", correlationId: String(repeating: "x", count: 129)))
        XCTAssertFalse(client.log(level: .info, category: "x", message: "x", attributes: [String(repeating: "k", count: 65): .null]))
        XCTAssertTrue(client.log(level: .info, category: "x", message: String(repeating: "😀", count: 4_096)))
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.invalid, 5); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testInvalidAttributesNeverPoisonMixedBatch() async throws {
        let config = configuration(), transport = FakeTransport(), client = try logger(config, transport)
        XCTAssertTrue(client.log(level: .info, category: "test", message: "before", attributes: ["screen": .string("home")]))
        let beyond = Double(1e308).nextUp
        let invalid: [[String: LogValue]] = [
            ["": .string("empty key")], ["n": .number(beyond)], ["n": .number(-beyond)],
            ["n": .number(.greatestFiniteMagnitude)], ["n": .number(-Double.greatestFiniteMagnitude)],
            ["n": .number(.nan)], ["n": .number(-Double.infinity)]
        ]
        for attributes in invalid {
            XCTAssertFalse(client.log(level: .info, category: "test", message: "invalid", attributes: attributes))
        }
        XCTAssertTrue(client.log(level: .info, category: "test", message: "limits",
            attributes: ["positive": .number(1e308), "negative": .number(-1e308),
                "zero": .number(0), "bool": .bool(true), "null": .null]))
        XCTAssertTrue(client.log(level: .info, category: "test", message: "after"))
        let queued = await client.deliveryStats()
        XCTAssertEqual(queued.queued, 3); XCTAssertEqual(queued.invalid, invalid.count)
        let stored = try JSONDecoder().decode(Spool.self,
            from: Data(contentsOf: config.spoolDirectory.appendingPathComponent("queue.json")))
        XCTAssertEqual(stored.entries.map { $0.event.message }, ["before", "limits", "after"])
        await client.flush()
        let requests = await transport.captured(), stats = await client.deliveryStats()
        XCTAssertEqual(requests.count, 1)
        let events = try body(XCTUnwrap(requests.first))["events"] as! [[String: Any]]
        XCTAssertEqual(events.map { $0["message"] as! String }, ["before", "limits", "after"])
        XCTAssertEqual(stats.accepted, 3); XCTAssertEqual(stats.rejected, 0); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testInvalidLegacyAttributesDoNotDiscardValidSpoolNeighbors() async throws {
        let clock = Clock(), config = configuration(), transport = FakeTransport()
        try FileManager.default.createDirectory(at: config.spoolDirectory, withIntermediateDirectories: true)
        let metadata = Metadata(app_version: config.appVersion, build: config.build,
            installation_id: "legacy-installation", debug_session_id: config.debugSessionId)
        let attributes: [[String: LogValue]] = [["valid": .bool(true)], ["": .null],
            ["large": .number(1.5e308)], ["negative": .number(-1.5e308)], ["valid": .number(-1e308)]]
        let entries = attributes.enumerated().map { index, attributes in
            QueuedEvent(event: Event(event_id: UUID().uuidString, sequence: Int64(index),
                client_time: "2026-10-26T00:00:00.000Z", severity: .info, category: "legacy",
                message: "event-\(index)", attributes: attributes, correlation_id: nil),
                metadata: metadata, enqueuedAt: clock.now())
        }
        let snapshot = Spool(installationId: "legacy-installation", nextSequence: 5, entries: entries)
        let file = config.spoolDirectory.appendingPathComponent("queue.json")
        try JSONEncoder().encode(snapshot).write(to: file)
        let client = try logger(config, transport, clock)
        var stats = await client.deliveryStats()
        XCTAssertEqual(stats.invalid, 3); XCTAssertEqual(stats.queued, 2); XCTAssertEqual(stats.corruptSpools, 0)
        let recovered = try JSONDecoder().decode(Spool.self, from: Data(contentsOf: file))
        XCTAssertEqual(recovered.entries.map { $0.event.sequence }, [0, 4])
        XCTAssertEqual(recovered.nextSequence, 5)
        await client.flush()
        stats = await client.deliveryStats()
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(stats.accepted, 2)
        XCTAssertEqual(stats.rejected, 0); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testCorruptAndOversizeSpoolRecovery() async throws {
        for data in [Data("{broken".utf8), Data(repeating: 1, count: 2 * 1_024 * 1_024 + 1)] {
            let config = configuration()
            try FileManager.default.createDirectory(at: config.spoolDirectory, withIntermediateDirectories: true)
            try data.write(to: config.spoolDirectory.appendingPathComponent("queue.json"))
            let client = try logger(config)
            let stats = await client.deliveryStats(); XCTAssertEqual(stats.corruptSpools, 1); XCTAssertEqual(stats.queued, 0)
            client.log(level: .info, category: "test", message: "recovered")
            await client.flush(); await client.close()
        }
    }

    func testExclusiveSpoolOwnership() async throws {
        let config = configuration(), first = try logger(config)
        XCTAssertThrowsError(try logger(config)) { XCTAssertEqual($0 as? LoggingError, .spoolInUse) }
        await first.close()
    }

    func testEndpointAndTokenValidation() throws {
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com/base", "https://example.com?q=1", "https://example.com/#x", "file:///tmp/test", "http://localhost.evil"] {
            var c = configuration()
            c = LoggingConfiguration(baseURL: URL(string: value)!, ingestToken: c.ingestToken, appVersion: "1", build: "1", spoolDirectory: c.spoolDirectory)
            XCTAssertThrowsError(try logger(c), value)
        }
        for value in ["https://example.com", "http://localhost:18880", "http://127.0.0.1", "http://[::1]:18880"] {
            XCTAssertNoThrow(try ingestURL(URL(string: value)!))
        }
        var c = configuration()
        c = LoggingConfiguration(baseURL: c.baseURL, ingestToken: "plog_ingest_bad\r\nHeader: leak", appVersion: "1", build: "1", spoolDirectory: c.spoolDirectory)
        XCTAssertThrowsError(try logger(c))
    }

    func testForegroundTimerFlushesAtTwoSeconds() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport, timer: true)
        await append(client, count: 1)
        try await Task.sleep(nanoseconds: 2_400_000_000)
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
        await client.close()
    }

    func testBackgroundPausesAutomaticDelivery() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport, timer: true)
        client.setForegroundActive(false); await append(client, count: 1)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
        await client.flush()
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.accepted, 1)
        await client.close()
    }

    func testDuplicateAcknowledgementCommitsQueue() async throws {
        let transport = FakeTransport([.duplicate]), client = try logger(nil, transport)
        await append(client, count: 2); await client.flush()
        let stats = await client.deliveryStats()
        XCTAssertEqual(stats.duplicate, 2); XCTAssertEqual(stats.accepted, 0); XCTAssertEqual(stats.queued, 0)
        await client.close()
    }

    func testDecodedBatchByteLimit() async throws {
        let transport = FakeTransport(), client = try logger(nil, transport)
        for _ in 0..<40 {
            client.log(level: .info, category: "large", message: String(repeating: "x", count: 4_096),
                attributes: ["a": .string(String(repeating: "y", count: 512)),
                    "b": .string(String(repeating: "y", count: 512)),
                    "c": .string(String(repeating: "y", count: 512)),
                    "d": .string(String(repeating: "y", count: 512)),
                    "e": .string(String(repeating: "y", count: 512)),
                    "f": .string(String(repeating: "y", count: 512))])
            _ = await client.deliveryStats()
        }
        await client.flush()
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
        for request in requests { XCTAssertLessThanOrEqual(request.httpBody!.count, 256 * 1_024) }
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.accepted, 40)
        await client.close()
    }

    func testRestartSeparatesOriginalSessionMetadata() async throws {
        let dir = directory()
        var first: ProxyceptLogger? = try logger(configuration(dir))
        await append(first!, count: 1); await first!.close(); first = nil
        var config = configuration(dir); config.debugSessionId = "second-session"; config.appVersion = "2.0"
        let transport = FakeTransport(), second = try logger(config, transport)
        await append(second, count: 1); await second.flush()
        let bodies = try await transport.captured().map { try body($0) }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["debug_session_id"] as? String, "test-debug-session")
        XCTAssertEqual(bodies[1]["debug_session_id"] as? String, "second-session")
        XCTAssertEqual(bodies[0]["app_version"] as? String, "1.0")
        XCTAssertEqual(bodies[1]["app_version"] as? String, "2.0")
        await second.close()
    }

    func testUnicodeScalarLimitsAndSymlinkDirectoryRefusal() throws {
        let client = try logger()
        let composed = "e" + String(repeating: "\u{0301}", count: 4_096)
        XCTAssertEqual(composed.count, 1)
        XCTAssertFalse(client.log(level: .info, category: "test", message: composed))
        let target = directory(), link = directory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try logger(configuration(link)))
    }

    func testRedirectDelegateRejectsCrossOriginAndSameOrigin() {
        let transport = URLSessionLogTransport(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://logs.example.com/api/logs/ingest")!
        for destination in ["https://attacker.example.com/steal", "https://logs.example.com/other"] {
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination])!
            let task = session.dataTask(with: original)
            var invoked = false
            transport.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: destination)!)) { request in
                    invoked = true; XCTAssertNil(request)
                }
            XCTAssertTrue(invoked)
        }
    }
}
