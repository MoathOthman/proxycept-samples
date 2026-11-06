import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TransportResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Implementations must honor request timeouts, avoid redirects and bound response buffering.
public protocol LogTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TransportResponse
}

/// Ephemeral sessions have no cookies, cache or credential store. Every redirect is refused,
/// including same-origin redirects. Response buffering is capped at 64 KiB.
public final class URLSessionLogTransport: NSObject, LogTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> TransportResponse {
        let operation = SessionOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        } onCancel: { operation.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class SessionOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TransportResponse, Error>?
    private var session: URLSession?
    private var cancelled = false
    // Accessed only by the serial URLSession delegate queue.
    private var response: HTTPURLResponse?
    private var body = Data()
    private let limit = 64 * 1_024

    func start(_ request: URLRequest, continuation: CheckedContinuation<TransportResponse, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<TransportResponse, Error>) {
        lock.lock()
        let completion = continuation; continuation = nil
        let session = self.session; self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        completion?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(URLError(.dataLengthExceedsMaximum))); return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - body.count else {
            finish(.failure(URLError(.dataLengthExceedsMaximum))); return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        finish(.success(TransportResponse(statusCode: response.statusCode, headers: headers, body: body)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func ingestURL(_ base: URL) throws -> URL {
    guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
          let host = parts.host?.lowercased(), !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/" else { throw LoggingError.invalidURL }
    let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    guard parts.scheme == "https" || (parts.scheme == "http" && loopback) else {
        throw LoggingError.invalidURL
    }
    parts.path = "/api/logs/ingest"
    guard let result = parts.url else { throw LoggingError.invalidURL }
    return result
}
