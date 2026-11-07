@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.proxycept.logging.kmp

import kotlinx.cinterop.toKString
import kotlinx.coroutines.*
import kotlinx.datetime.Clock
import platform.Foundation.*
import kotlinx.serialization.json.*
import platform.posix.getenv
import kotlin.test.*

class AppleTransportTest {
    @Test fun nativeDisableAndCloseCancelSlowResponseAndClearSpool() = runBlocking {
        val base = getenv("PROXYCEPT_NATIVE_LOOPBACK_BASE")?.toKString()
        if (base == null) { println("SKIPPED: optional native HTTP fixture"); return@runBlocking }
        val path = NSTemporaryDirectory() + "proxycept-kmp-cancel-" + randomId()
        val configuration = Configuration(base, "plog_ingest_nativeLoopback", path, "1", "1")
        val logger = ProxyceptLogger(configuration)
        try {
            assertTrue(logger.log(Level.INFO, "native-cancel", "slow-trickle")); logger.flush()
            val probe = defaultTransport()
            withTimeout(4000) {
                while (true) {
                    val response = probe.post(endpoint(base), "plog_ingest_nativeLoopback", """{"events":[{"message":"probe"}]}""".encodeToByteArray())
                    if (json.parseToJsonElement(response.body).jsonObject.getValue("slow").jsonPrimitive.int > 0) break
                    delay(10)
                }
            }
            logger.disable(); logger.close(); withTimeout(1500) { logger.awaitClosed() }
            assertEquals(0, logger.stats().accepted)
            val recovered = PrivateStorage(path)
            try { assertTrue(recovered.load(configuration, Clock.System.now().toEpochMilliseconds()).first.isEmpty()) }
            finally { recovered.close() }
            println("PASS: actual Apple transport cancellation and ordered privacy clear")
        } finally { logger.close(); withTimeout(1500) { logger.awaitClosed() }; NSFileManager.defaultManager.removeItemAtPath(path, null) }
    }
    @Test fun nativePostAndCrossOriginRedirectRefusal() = runBlocking {
        // scripts/native-tests.sh provides an isolated loopback fixture. No real ingest credential.
        val base = getenv("PROXYCEPT_NATIVE_LOOPBACK_BASE")?.toKString()
        if (base == null) { println("SKIPPED: optional native HTTP fixture (run scripts/native-tests.sh)"); return@runBlocking }
        require(base.startsWith("http://127.0.0.1:"))
        val transport = defaultTransport()
        fun body(message: String) = """{"events":[{"message":"$message"}]}""".encodeToByteArray()
        val first = transport.post(endpoint(base), "plog_ingest_nativeLoopback", body("native-post"))
        assertEquals(200, first.status)
        assertNotNull(acknowledgement(first.body, 1))
        val redirected = transport.post(endpoint(base), "plog_ingest_nativeLoopback", body("redirect"))
        assertEquals(307, redirected.status)
        val probe = transport.post(endpoint(base), "plog_ingest_nativeLoopback", body("probe"))
        assertEquals(0, json.parseToJsonElement(probe.body).jsonObject.getValue("redirected").jsonPrimitive.int)
        println("PASS: actual Apple transport POST and cross-origin redirect refusal")
    }
}
