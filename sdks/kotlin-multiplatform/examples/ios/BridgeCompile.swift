import Foundation
import ProxyceptLoggingKmp

// Invoke on an app-owned background queue: initialization reads bounded private storage.
func makeLoggingClient(baseURL: String, runtimeIngestKey: String, appSupport: URL) -> ProxyceptLogger {
    let directory = appSupport.appendingPathComponent("proxycept-kmp-myapp-dev", isDirectory: true)
    let logger = LoggingSdk.shared.create(baseUrl: baseURL, ingestKey: runtimeIngestKey,
        spoolDirectory: directory.path, appVersion: "1.0", build: "12")
    _ = logger.logJson(level: Level.info, category: "checkout", message: "Checkout tapped",
        attributesJson: #"{"screen":"checkout"}"#, correlationId: "explicit-correlation-id")
    logger.flush()
    return logger
}
func closeLoggingClient(_ logger: ProxyceptLogger) {
    logger.close() // immediately stops admission/dispatch; no blocking I/O on Swift/UI caller
    logger.awaitClosed { error in
        // Directory lease is released; check logger.stats().storageFailures for storage failures.
        _ = error
    }
}
