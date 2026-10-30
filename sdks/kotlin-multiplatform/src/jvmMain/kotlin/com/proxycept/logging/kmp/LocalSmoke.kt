package com.proxycept.logging.kmp

import java.net.URI
import kotlinx.coroutines.*

/** Development-only entry point; never accepts credentials as arguments or prints them. */
fun main(): Unit = runBlocking {
    val environment = System.getenv()
    val base = environment["PROXYCEPT_TEST_BASE_URL"] ?: error("Missing local test configuration")
    val origin = URI(base)
    require(origin.host in setOf("127.0.0.1", "[::1]", "::1")) { "Smoke runner only permits numeric loopback" }
    val key = environment["PROXYCEPT_TEST_INGEST_KEY"] ?: error("Missing local test credential")
    val session = environment["PROXYCEPT_TEST_DEBUG_SESSION"] ?: error("Missing test session")
    val directory = environment["PROXYCEPT_TEST_SPOOL_DIR"] ?: error("Missing private test directory")
    val logger = ProxyceptLogger(Configuration(base, key, directory, "kmp-smoke", "1", debugSessionId = session))
    try {
        check(logger.log(Level.INFO, "kmp-integration", "Cross-platform SDK smoke", mapOf("password" to "must-be-redacted")))
        logger.flush()
        withTimeout(30_000) {
            while (logger.stats().accepted + logger.stats().duplicates < 1 || logger.stats().queuedEvents != 0) {
                check(!logger.stats().stoppedForAuthentication) { "Local test credential rejected" }
                delay(50)
            }
        }
        println("PASS: KMP common core and JVM transport acknowledged and drained")
    } finally { logger.close(); withTimeout(20_000) { logger.awaitClosed() } }
}
