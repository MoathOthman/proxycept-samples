package com.proxycept.logging

import com.google.gson.JsonParser
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.test.*

class RequestTaggingTest {
    private val header = "X-Proxycept-Correlation-ID"
    private val invalid = listOf("", "a".repeat(129), "id\r\nX-Injected: 1", "id\n", "id\r", "tab\there",
        "nul\u0000", "del\u007F", "has space", "café", "emoji😀")
    // openConnection() does not connect, so no network is used.
    private fun connection() = URL("https://api.example.com/orders").openConnection() as HttpURLConnection
    private fun isUuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

    @Test fun headerNameIsExact() {
        assertEquals("X-Proxycept-Correlation-ID", ProxyceptLogger.CORRELATION_HEADER)
    }

    @Test fun generatesUuidWhenNone() {
        val c = connection()
        val id = ProxyceptLogger.tag(c)
        assertTrue(isUuid(id))
        assertEquals(id, c.getRequestProperty(header))
        val headers = mutableMapOf("Accept" to "application/json")
        val other = ProxyceptLogger.tagHeaders(headers)
        assertTrue(isUuid(other)); assertNotEquals(id, other)
        assertEquals(mapOf("Accept" to "application/json", header to other), headers)
    }

    @Test fun reusesExistingValidHeaderCaseInsensitively() {
        val c = connection()
        c.setRequestProperty("x-proxycept-correlation-id", "existing-id-42")
        assertEquals("existing-id-42", ProxyceptLogger.tag(c))
        assertEquals("existing-id-42", c.getRequestProperty(header))
        val headers = mutableMapOf("x-proxycept-correlation-id" to "existing-id-42")
        assertEquals("existing-id-42", ProxyceptLogger.tagHeaders(headers))
        assertEquals(mapOf(header to "existing-id-42"), headers)
    }

    @Test fun explicitIdHonoredAndOverridesExisting() {
        val c = connection()
        c.setRequestProperty(header, "existing-id")
        assertEquals("checkout-7", ProxyceptLogger.tag(c, "checkout-7"))
        assertEquals("checkout-7", c.getRequestProperty(header))
        val max = "a".repeat(128)
        val headers = mutableMapOf(header.uppercase() to "existing-id")
        assertEquals(max, ProxyceptLogger.tagHeaders(headers, max))
        assertEquals(mapOf(header to max), headers)
    }

    @Test fun invalidExplicitIdIsNeverSentAndFreshUuidReturned() {
        for (value in invalid) {
            val c = connection()
            val id = ProxyceptLogger.tag(c, value)
            assertNotEquals(value, id); assertTrue(isUuid(id), "fresh UUID for ${value.length}-char input")
            assertEquals(id, c.getRequestProperty(header))
            val headers = mutableMapOf<String, String>()
            val mapped = ProxyceptLogger.tagHeaders(headers, value)
            assertTrue(isUuid(mapped)); assertEquals(mapOf(header to mapped), headers)
            assertFalse(ProxyceptLogger.isValidCorrelationId(value))
        }
    }

    @Test fun invalidExistingHeaderIsReplaced() {
        val headers = mutableMapOf(header to "has space", "x-proxycept-correlation-id" to "b".repeat(129))
        val id = ProxyceptLogger.tagHeaders(headers)
        assertTrue(isUuid(id)); assertEquals(mapOf(header to id), headers)
        val c = connection()
        c.setRequestProperty(header, "has space")
        val fresh = ProxyceptLogger.tag(c)
        assertTrue(isUuid(fresh)); assertEquals(fresh, c.getRequestProperty(header))
    }

    @Test fun returnedIdRoundTripsIntoLogCorrelation() {
        val dir = Files.createTempDirectory("proxycept-tag-").toFile()
        val bodies = java.util.Collections.synchronizedList(mutableListOf<String>())
        val transport = Transport { _, _, body ->
            val text = String(body, Charsets.UTF_8); bodies.add(text)
            val count = JsonParser.parseString(text).asJsonObject.getAsJsonArray("events").size()
            Response(200, """{"accepted":$count,"duplicate":0,"received_at":"2026-11-06T00:00:00.000Z"}""")
        }
        val logger = ProxyceptLogger(Configuration("http://127.0.0.1:18880", "plog_ingest_testSecret123", dir, "1.0", "1"),
            transport, { 1_793_275_200_000L }, { 0.0 }, Executors.newSingleThreadScheduledExecutor(), false)
        try {
            val generated = ProxyceptLogger.tag(connection())
            val explicit = ProxyceptLogger.tagHeaders(mutableMapOf(), "z".repeat(128))
            assertTrue(logger.log(Level.INFO, "orders", "generated", correlationId = generated))
            assertTrue(logger.log(Level.INFO, "orders", "explicit", correlationId = explicit))
            logger.drain()
            assertEquals(1, bodies.size)
            val ids = JsonParser.parseString(bodies[0]).asJsonObject.getAsJsonArray("events")
                .map { it.asJsonObject.get("correlation_id").asString }
            assertEquals(listOf(generated, explicit), ids)
        } finally { logger.close(); dir.deleteRecursively() }
    }
}
