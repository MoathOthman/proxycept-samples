#if os(macOS)
import XCTest
@testable import ProxyceptLogging

/// An independent loopback HTTP peer exercises the real URLSession implementation.
/// Uses the macOS system Python only in tests; the SDK has no subprocess dependency.
final class URLSessionTests: XCTestCase {
    private let serverScript = #"""
import socket, json, sys
s = socket.socket()
s.bind(('127.0.0.1', 0))
s.listen(4)
s.settimeout(10)
port = s.getsockname()[1]
print(port, flush=True)
c, _ = s.accept()
c.settimeout(10)
data = b''
while b'\r\n\r\n' not in data:
    data += c.recv(4096)
header, body = data.split(b'\r\n\r\n', 1)
length = next(int(x.split(b':', 1)[1]) for x in header.split(b'\r\n') if x.lower().startswith(b'content-length:'))
while len(body) < length:
    body += c.recv(4096)
mode = sys.argv[1]
if mode == 'redirect':
    response = b'HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:' + str(port).encode() + b'/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
elif mode == 'large':
    response = b'HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n' + b'x' * 100000
else:
    payload = json.dumps({'accepted':len(json.loads(body)['events']), 'duplicate':0, 'received_at':'2026-10-29T00:00:00.000Z'}).encode()
    response = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\nConnection: close\r\n\r\n' + payload
try:
    c.sendall(response)
except (BrokenPipeError, ConnectionResetError):
    pass
c.close()
count = 1
if mode == 'redirect':
    s.settimeout(0.5)
    try:
        c, _ = s.accept()
        count += 1
        c.close()
    except socket.timeout:
        pass
print(json.dumps({'header':header.decode(), 'body':body.decode(), 'requests':count}), flush=True)
s.close()
"""#

    private func server(_ mode: String) throws -> (Process, FileHandle, URL) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", serverScript, mode]
        process.standardOutput = output
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }; line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate(); throw URLError(.cannotConnectToHost)
        }
        return (process, output.fileHandleForReading, URL(string: "http://127.0.0.1:\(port)")!)
    }

    func testRealURLSessionWireAgainstLoopbackServer() async throws {
        let (process, output, url) = try server("ack")
        defer { if process.isRunning { process.terminate() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try ProxyceptLogger(configuration: LoggingConfiguration(baseURL: url,
            ingestToken: "plog_ingest_loopback", appVersion: "1.0", build: "12", spoolDirectory: dir))
        client.log(level: .info, category: "wire", message: "Loopback test", correlationId: "e2e-1")
        await client.flush()
        let stats = await client.deliveryStats(); XCTAssertEqual(stats.accepted, 1)
        await client.close()
        let report = try JSONSerialization.jsonObject(with: output.readDataToEndOfFile()) as! [String: Any]
        let header = try XCTUnwrap(report["header"] as? String)
        XCTAssertTrue(header.contains("POST /api/logs/ingest HTTP/1.1"))
        XCTAssertTrue(header.lowercased().contains("authorization: bearer plog_ingest_loopback"))
        let body = try JSONSerialization.jsonObject(with: Data((report["body"] as! String).utf8)) as! [String: Any]
        XCTAssertEqual(body["schema_version"] as? Int, 1)
        XCTAssertEqual((body["events"] as! [[String: Any]])[0]["correlation_id"] as? String, "e2e-1")
    }

    func testRealSessionDoesNotFollowRedirect() async throws {
        let (process, output, url) = try server("redirect")
        defer { if process.isRunning { process.terminate() } }
        var request = URLRequest(url: url.appendingPathComponent("api/logs/ingest"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer plog_ingest_test", forHTTPHeaderField: "Authorization")
        let response = try await URLSessionLogTransport().send(request)
        XCTAssertEqual(response.statusCode, 307)
        let report = try JSONSerialization.jsonObject(with: output.readDataToEndOfFile()) as! [String: Any]
        XCTAssertEqual(report["requests"] as? Int, 1)
    }

    func testRealSessionBoundsResponseMemory() async throws {
        let (process, _, url) = try server("large")
        defer { if process.isRunning { process.terminate() } }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        do { _ = try await URLSessionLogTransport().send(request); XCTFail("Oversize response should fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }
}
#endif
