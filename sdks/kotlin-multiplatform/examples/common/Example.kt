package example

import com.proxycept.logging.kmp.*

// Construct once on an I/O/lifecycle worker; provide a dedicated private no-backup path.
fun example(baseUrl: String, key: String, privateDirectory: String): ProxyceptLogger {
    val logger = LoggingSdk.create(baseUrl, key, privateDirectory, "1.0", "12")
    logger.log(Level.INFO, "checkout", "Checkout tapped", mapOf("screen" to "checkout"), "explicit-correlation-id")
    logger.flush()
    return logger // owner later calls close(), then awaitClosed() from a coroutine
}
