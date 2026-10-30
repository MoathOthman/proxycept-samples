@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package com.proxycept.logging.kmp

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

internal class MemoryStorage : Storage {
    override val installationId = "11111111-1111-4111-8111-111111111111"
    var records = emptyList<Record>()
    var failures = false
    var closed = false
    override fun load(policy: Configuration, now: Long) = records to 0L
    override fun save(records: List<Record>) { if (failures) error("injected storage failure"); this.records = records.toList() }
    override fun close() { closed = true }
}
internal class FakeTransport : Transport {
    val bodies = ArrayList<String>()
    var reply: suspend (String) -> Response = { body ->
        val size = json.parseToJsonElement(body).jsonObject.getValue("events").jsonArray.size
        Response(200, """{"accepted":$size,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""")
    }
    override suspend fun post(endpoint: String, ingestKey: String, body: ByteArray): Response {
        assertEquals("http://127.0.0.1:18880/api/logs/ingest", endpoint)
        assertTrue(ingestKey.startsWith("plog_ingest_"))
        val value = body.decodeToString(); bodies.add(value); return reply(value)
    }
}
internal class Harness(scope: CoroutineScope, count: Int = 2000, bytes: Int = MAX_BYTES, val store: MemoryStorage = MemoryStorage()) {
    var time = 1_793_361_600_000L
    val fake = FakeTransport()
    val config = Configuration("http://127.0.0.1:18880", "plog_ingest_commonTest", "/private/unused-memory-test", "1", "12", maxQueueEvents = count, maxQueueBytes = bytes)
    val logger = ProxyceptLogger(config, fake, store, CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job])), { time }, { 0.0 }, false)
}
class CommonBehaviorTest {
    @Test fun redactionPrecedesPersistenceAndCallerMapIsCopied() = runTest {
        val h = Harness(backgroundScope)
        val attrs = mutableMapOf<String, Any?>("password" to "must-not-store", "screen" to "original")
        assertTrue(h.logger.log(Level.INFO, "checkout", "Bearer abc user@example.com plog_ingest_commonTest", attrs, "corr"))
        attrs["screen"] = "changed"
        assertEquals(1, h.logger.stats().queuedEvents)
        runCurrent()
        val disk = h.store.records.single().line
        listOf("must-not-store", "abc", "user@example.com", "plog_ingest_commonTest", "changed").forEach { assertFalse(disk.contains(it)) }
        assertTrue(disk.contains("original"))
        h.logger.flush(); runCurrent()
        assertEquals(1, h.logger.stats().accepted)
        assertTrue(h.store.records.isEmpty())
        h.logger.close(); runCurrent(); h.logger.awaitClosed()
    }
    @Test fun scalarLimitsRejectEmptyNestedAndOverflow() = runTest {
        val h = Harness(backgroundScope)
        for (attrs in listOf(mapOf("" to "bad"), mapOf("nested" to listOf(1)), mapOf("nested" to mapOf("a" to 1)),
            mapOf("v" to Double.MAX_VALUE), mapOf("v" to -Double.MAX_VALUE), mapOf("v" to Double.NaN), mapOf("v" to Double.POSITIVE_INFINITY))) {
            assertFalse(h.logger.log(Level.ERROR, "a", "invalid", attrs))
        }
        assertTrue(h.logger.log(Level.INFO, "a".repeat(100), "b".repeat(5000), mapOf("up" to 1e308, "down" to -1e308)))
        assertFalse(h.logger.log(Level.INFO, "a", "界".repeat(4096)))
        runCurrent()
        val event = h.store.records.single().event
        assertEquals(80, event.getValue("category").jsonPrimitive.content.length)
        assertEquals(4096, event.getValue("message").jsonPrimitive.content.length)
        assertEquals(8, h.logger.stats().dropped)
        h.logger.close(); runCurrent()
    }
    @Test fun boundsBatchAndByteLimit() = runTest {
        val h = Harness(backgroundScope, count = 2, bytes = 8192)
        repeat(4) { assertTrue(h.logger.log(Level.INFO, "a", "message-$it " + "x".repeat(3000))) }
        assertEquals(2, h.logger.stats().queuedEvents)
        assertEquals(2, h.logger.stats().droppedOldest)
        assertTrue(h.logger.stats().queuedBytes <= 8192)
        h.logger.flush(); runCurrent()
        assertFalse(h.fake.bodies.single().contains("message-0"))
        h.logger.close(); runCurrent()
        val many = Harness(backgroundScope)
        repeat(61) { many.logger.log(Level.INFO, "a", "x".repeat(4096)) }
        many.logger.flush(); runCurrent(); many.logger.flush(); runCurrent()
        assertEquals(listOf(50, 11), many.fake.bodies.map { json.parseToJsonElement(it).jsonObject.getValue("events").jsonArray.size })
        assertTrue(many.fake.bodies.all { it.encodeToByteArray().size <= 256 * 1024 })
        many.logger.close(); runCurrent()
    }
    @Test fun persistenceFailureBlocksTransportAndRecoveryRetainsIds() = runTest {
        val h = Harness(backgroundScope)
        h.store.failures = true
        assertTrue(h.logger.log(Level.INFO, "a", "persist-first"))
        h.logger.flush(); runCurrent()
        assertTrue(h.fake.bodies.isEmpty()); assertEquals(1, h.logger.stats().queuedEvents)
        assertTrue(h.logger.stats().storageFailures > 0)
        h.store.failures = false; h.logger.flush(); runCurrent()
        assertEquals(1, h.logger.stats().accepted)
        h.logger.close(); runCurrent()
    }
    @Test fun retriesStableIdsAndAtomicAcknowledgement() = runTest {
        val h = Harness(backgroundScope)
        h.logger.log(Level.INFO, "a", "retry")
        h.fake.reply = { Response(503) }
        h.logger.flush(); runCurrent(); h.logger.flush(); runCurrent()
        assertEquals(1, h.fake.bodies.size)
        assertEquals(h.time + 500, h.logger.stats().nextAttemptAtMillis)
        h.time += 500
        h.fake.reply = { Response(200, """{"accepted":0,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""") }
        h.logger.flush(); runCurrent(); assertEquals(1, h.logger.stats().queuedEvents)
        h.time += 1000
        h.fake.reply = { Response(200, """{"accepted":0,"duplicate":1,"received_at":"2026-10-30T12:00:00Z"}""") }
        h.logger.flush(); runCurrent()
        assertEquals(1, h.logger.stats().duplicates)
        assertEquals(1, h.fake.bodies.distinct().size)
        h.logger.close(); runCurrent()
    }
    @Test fun malformedAckTypesAndDatesAreRejected() {
        for (body in listOf("{}", """{"accepted":"1","duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""",
            """{"accepted":1,"duplicate":0,"received_at":"2026-99-30T12:00:00Z"}""",
            """{"accepted":1.0,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""")) assertNull(acknowledgement(body, 1))
    }
    @Test fun authenticationStopExpiryAndReconfigure() = runTest {
        for (code in listOf(401, 403)) {
            val h = Harness(backgroundScope)
            h.logger.log(Level.INFO, "a", "expire")
            h.fake.reply = { Response(code) }; h.logger.flush(); runCurrent()
            assertTrue(h.logger.stats().stoppedForAuthentication)
            assertFalse(h.logger.log(Level.INFO, "a", "blocked"))
            h.time += EXPIRY; h.logger.flush(); runCurrent()
            assertEquals(1, h.logger.stats().expired)
            h.logger.reconfigure(h.config); runCurrent()
            assertTrue(h.logger.log(Level.INFO, "a", "again"))
            h.logger.close(); runCurrent(); h.logger.awaitClosed()
            assertEquals(1, h.store.records.size)
        }
    }
    @Test fun retryAfterAndPayloadReduction() = runTest {
        val h = Harness(backgroundScope)
        repeat(4) { h.logger.log(Level.WARNING, "a", "b") }
        h.fake.reply = { Response(429, retryAfter = "120") }; h.logger.flush(); runCurrent()
        assertEquals(h.time + 120_000, h.logger.stats().nextAttemptAtMillis)
        h.time += 120_000
        h.fake.reply = { Response(413) }
        repeat(3) { h.logger.flush(); runCurrent() }
        assertEquals(listOf(4, 4, 2, 1), h.fake.bodies.map { json.parseToJsonElement(it).jsonObject.getValue("events").jsonArray.size })
        assertEquals(1, h.logger.stats().dropped)
        assertEquals(120_000, retryAfter("120", h.time))
        assertEquals(0, retryAfter("invalid", h.time))
        assertEquals(120_000, retryAfter("Fri, 30 Oct 2026 12:02:00 GMT", kotlinx.datetime.Instant.parse("2026-10-30T12:00:00Z").toEpochMilliseconds()))
        h.logger.close(); runCurrent()
    }
    @Test fun staleAcknowledgementAfterDisableCannotResurrectQueue() = runTest {
        val h = Harness(backgroundScope)
        val release = CompletableDeferred<Unit>()
        h.fake.reply = { release.await(); Response(200, """{"accepted":1,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""") }
        h.logger.log(Level.INFO, "a", "stale"); h.logger.flush(); runCurrent()
        h.logger.disable(); assertFalse(h.logger.log(Level.INFO, "a", "disabled"))
        release.complete(Unit); runCurrent()
        assertEquals(0, h.logger.stats().accepted); assertTrue(h.store.records.isEmpty())
        h.logger.reconfigure(h.config); h.logger.log(Level.INFO, "a", "new"); runCurrent()
        h.logger.close(); runCurrent(); h.logger.awaitClosed()
        assertEquals("new", h.store.records.single().event.getValue("message").jsonPrimitive.content)
    }
    @Test fun longPlainMessagesAndConservativeEmailTokenMasking() {
        val policy = Configuration("https://example.com", "plog_ingest_longTest", "/private/unused-memory-test", "1", "1")
        val long = "a".repeat(100_000)
        assertEquals(long, Scrub.text(long, policy))
        assertEquals("hello [REDACTED] world\n[REDACTED]", Scrub.text("hello qa@example.com world\nother@internal", policy))
    }
    @Test fun emptyAndRedactorErasedCorrelationsNormalizeWithoutPoisoningNeighbors() = runTest {
        val h = Harness(backgroundScope)
        val custom = Configuration(h.config.baseUrl, h.config.ingestKey, h.config.spoolDirectory, "1", "12",
            debugSessionId = h.config.debugSessionId, redactor = Redactor { it.replace("erase-correlation", "") })
        h.logger.reconfigure(custom)
        assertTrue(h.logger.log(Level.INFO, "ids", "before", correlationId = "corr-before"))
        assertTrue(h.logger.log(Level.INFO, "ids", "empty", correlationId = ""))
        assertTrue(h.logger.logJson(Level.INFO, "ids", "erased", "{}", "erase-correlation"))
        assertTrue(h.logger.log(Level.INFO, "ids", "after", correlationId = "corr-after"))
        runCurrent()
        assertEquals(JsonNull, h.store.records[1].event.getValue("correlation_id"))
        assertEquals(JsonNull, h.store.records[2].event.getValue("correlation_id"))
        h.fake.reply = { body ->
            val events = json.parseToJsonElement(body).jsonObject.getValue("events").jsonArray
            if (events.any { it.jsonObject.getValue("correlation_id").jsonPrimitive.contentOrNull == "" }) Response(422)
            else Response(200, """{"accepted":${events.size},"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""")
        }
        h.logger.flush(); runCurrent()
        assertEquals(4, h.logger.stats().accepted)
        assertTrue(h.fake.bodies.single().contains("before") && h.fake.bodies.single().contains("after"))
        h.logger.close(); runCurrent()
    }
    @Test fun legacyEmptyAndErasedCorrelationsKeepStableIdsAndValidNeighbors() = runTest {
        val h = Harness(backgroundScope)
        repeat(3) { h.logger.log(Level.INFO, "ids", "neighbor-$it", correlationId = "correlation-$it") }
        runCurrent()
        val originals = h.store.records.toList()
        val custom = Configuration(h.config.baseUrl, h.config.ingestKey, h.config.spoolDirectory, "1", "12",
            redactor = Redactor { it.replace("erase-correlation", "") })
        for (correlation in listOf("", "erase-correlation")) {
            val changed = JsonObject(originals[1].tree() + ("event" to JsonObject(originals[1].event +
                ("correlation_id" to JsonPrimitive(correlation))))).toString()
            val recovered = listOf(originals[0].line, changed, originals[2].line).map { Record.recover(it, custom) }
            assertEquals(originals.map { it.id }, recovered.map { it.id })
            assertEquals(JsonNull, recovered[1].event.getValue("correlation_id"))
            val store = MemoryStorage().also { it.records = recovered }
            val reopened = Harness(backgroundScope, store = store)
            reopened.logger.flush(); runCurrent()
            assertEquals(3, reopened.logger.stats().accepted)
            assertFalse(reopened.fake.bodies.single().contains("\"correlation_id\":\"\""))
            reopened.logger.close(); runCurrent()
        }
        h.logger.close(); runCurrent()
    }
    @Test fun legacyEmptyOrScrubbedMetadataIdentifiersDropOnlyBadRecord() = runTest {
        val h = Harness(backgroundScope)
        repeat(3) { h.logger.log(Level.INFO, "ids", "neighbor-$it") }; runCurrent()
        val records = h.store.records.toList()
        val custom = Configuration(h.config.baseUrl, h.config.ingestKey, h.config.spoolDirectory, "1", "12",
            redactor = Redactor { it.replace("erase-identifier", "") })
        for (key in listOf("installation_id", "debug_session_id")) for (invalid in listOf("", "erase-identifier")) {
            val corrupted = JsonObject(records[1].tree() + ("metadata" to JsonObject(records[1].metadata +
                (key to JsonPrimitive(invalid))))).toString()
            val recovered = listOf(records[0].line, corrupted, records[2].line).mapNotNull {
                runCatching { Record.recover(it, custom) }.getOrNull()
            }
            assertEquals(listOf(records[0].id, records[2].id), recovered.map { it.id }, key)
            val reopened = Harness(backgroundScope, store = MemoryStorage().also { it.records = recovered })
            reopened.logger.flush(); runCurrent()
            assertEquals(2, reopened.logger.stats().accepted)
            assertTrue(reopened.fake.bodies.single().contains("neighbor-0") && reopened.fake.bodies.single().contains("neighbor-2"))
            reopened.logger.close(); runCurrent()
        }
        h.logger.close(); runCurrent()
    }
    @Test fun newMetadataIdentifiersMustRemainNonemptyAfterCustomRedaction() = runTest {
        val h = Harness(backgroundScope)
        assertTrue(h.logger.log(Level.INFO, "ids", "valid-before"))
        val erased = Configuration(h.config.baseUrl, h.config.ingestKey, h.config.spoolDirectory, "1", "12",
            debugSessionId = "erase-session", redactor = Redactor { it.replace("erase-session", "") })
        h.logger.reconfigure(erased)
        assertFalse(h.logger.log(Level.INFO, "ids", "invalid-metadata"))
        h.logger.reconfigure(h.config)
        assertTrue(h.logger.log(Level.INFO, "ids", "valid-after"))
        h.logger.flush(); runCurrent()
        assertEquals(2, h.logger.stats().accepted)
        assertFalse(h.fake.bodies.single().contains("invalid-metadata"))
        val installationErased = Configuration(h.config.baseUrl, h.config.ingestKey, h.config.spoolDirectory, "1", "12",
            redactor = Redactor { if (it == h.store.installationId) "" else it })
        h.logger.reconfigure(installationErased)
        assertFalse(h.logger.log(Level.INFO, "ids", "invalid-installation"))
        h.logger.close(); runCurrent()
    }
    @Test fun endpointPolicy() {
        for (bad in listOf("http://example.com", "http://localhost", "https://u:p@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#x", "https://example.com:0")) assertFails { endpoint(bad) }
        assertEquals("http://[::1]:18880/api/logs/ingest", endpoint("http://[::1]:18880"))
        assertEquals("https://example.com/api/logs/ingest", endpoint("https://example.com/"))
    }
}
