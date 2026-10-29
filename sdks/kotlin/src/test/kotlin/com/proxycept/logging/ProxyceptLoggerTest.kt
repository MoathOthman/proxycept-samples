package com.proxycept.logging

import com.google.gson.JsonParser
import com.sun.net.httpserver.HttpServer
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ProxyceptLoggerTest {
    private val token = "plog_ingest_testSecret123"
    private fun directory() = Files.createTempDirectory("proxycept-test-").toFile().apply { deleteOnExit() }
    private fun config(dir: File, count: Int = 2000, size: Int = 2 * 1024 * 1024) =
        Configuration("http://127.0.0.1:18880", token, dir, "1.0", "12", size, count)
    private class Fake : Transport {
        val bodies = mutableListOf<String>()
        val threads = mutableListOf<String>()
        var reply: ((String) -> Response) = { body ->
            Response(200, """{"accepted":${JsonParser.parseString(body).asJsonObject.getAsJsonArray("events").size()},"duplicate":0,"received_at":"2026-10-29T12:00:00.000Z"}""")
        }
        override fun post(endpoint: java.net.URI, token: String, body: ByteArray): Response {
            assertTrue(endpoint.path == "/api/logs/ingest")
            assertTrue(token.startsWith("plog_ingest_"))
            val value = String(body, Charsets.UTF_8)
            bodies.add(value); threads.add(Thread.currentThread().name)
            return reply(value)
        }
    }
    private class Harness(val dir: File = Files.createTempDirectory("proxycept-test-").toFile(),
                          val fake: Fake = Fake(), count: Int = 2000, size: Int = 2 * 1024 * 1024, storageFactory: (File) -> Storage = { Spool(it) }) : AutoCloseable {
        var time = 1_793_275_200_000L
        val configuration = Configuration("http://127.0.0.1:18880", "plog_ingest_testSecret123", dir, "1.0", "12", size, count)
        val logger = ProxyceptLogger(configuration, fake, { time }, { 0.0 }, Executors.newSingleThreadScheduledExecutor(), false, storageFactory)
        override fun close() { logger.close() }
    }

    private class ControlledStorage(private val delegate: Storage) : Storage by delegate {
        @Volatile var block = false
        @Volatile var fail = false
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val saveThreads = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun save(records: Collection<Record>) {
            saveThreads.add(Thread.currentThread().name)
            if (block) { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
            if (fail) throw java.io.IOException("injected write failure")
            delegate.save(records)
        }
    }

    @Test fun logAndStatsReturnWhileStorageBlockedAndSnapshotsStayBounded() {
        lateinit var storage: ControlledStorage
        val h = Harness(count = 2, storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newSingleThreadExecutor()
        try {
            storage.block = true
            val attributes = mutableMapOf<String, Any?>("password" to "do-not-persist", "copy" to "original")
            assertTrue(h.logger.log(Level.INFO, "a", "first", attributes))
            attributes["copy"] = "mutated-after-log"
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            // These futures must finish BEFORE allowing the disk writer to proceed.
            assertTrue(callers.submit<Boolean> { h.logger.log(Level.INFO, "a", "second") }.get(1, TimeUnit.SECONDS))
            assertTrue(callers.submit<Boolean> { h.logger.log(Level.INFO, "a", "third") }.get(1, TimeUnit.SECONDS))
            assertEquals(2, callers.submit<DeliveryStats> { h.logger.stats() }.get(1, TimeUnit.SECONDS).queuedEvents)
            repeat(200) { h.logger.flush() }
            assertTrue(h.fake.bodies.isEmpty()) // unpersisted events never sent
            storage.release.countDown()
            h.logger.awaitIdle()
            val bodies = h.fake.bodies.joinToString()
            assertFalse(bodies.contains("first"))
            assertFalse(bodies.contains("do-not-persist"))
            assertFalse(bodies.contains("mutated-after-log"))
            assertEquals(2, h.logger.stats().accepted)
            assertEquals(1, h.logger.stats().dropped)
            assertTrue(storage.saveThreads.drop(1).all { it != Thread.currentThread().name })
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun callerMapIsCopiedBeforeReturningEvenWhenPersistenceBlocked() {
        lateinit var storage: ControlledStorage
        val h = Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        try {
            storage.block = true
            val attributes = mutableMapOf<String, Any?>("screen" to "original", "password" to "sensitive")
            h.logger.log(Level.INFO, "a", "copied", attributes)
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            attributes["screen"] = "mutated"
            storage.release.countDown(); h.logger.awaitIdle()
            val disk = File(h.dir, "queue.jsonl").readText()
            assertTrue(disk.contains("original")); assertFalse(disk.contains("mutated")); assertFalse(disk.contains("sensitive"))
        } finally { storage.release.countDown(); h.close() }
    }

    @Test fun persistenceFailureRetainsMemoryAndBlocksDeliveryUntilRetrySucceeds() {
        lateinit var storage: ControlledStorage
        Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } }).use { h ->
            storage.fail = true
            assertTrue(h.logger.log(Level.INFO, "a", "retry-disk"))
            h.logger.drain()
            assertEquals(1, h.logger.stats().queuedEvents)
            assertTrue(h.logger.stats().storageFailures > 0)
            assertTrue(h.fake.bodies.isEmpty())
            storage.fail = false
            h.logger.drain()
            assertEquals(1, h.logger.stats().accepted)
            assertEquals(0, h.logger.stats().queuedEvents)
            assertEquals("", File(h.dir, "queue.jsonl").readText())
        }
    }

    @Test fun disableClearIsOrderedAfterBlockedOldSnapshotAndNewGeneration() {
        lateinit var storage: ControlledStorage
        val h = Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newSingleThreadExecutor()
        try {
            storage.block = true
            h.logger.log(Level.INFO, "a", "must-not-resurrect")
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            callers.submit { h.logger.disable() }.get(1, TimeUnit.SECONDS)
            assertFalse(h.logger.log(Level.INFO, "a", "disabled"))
            storage.release.countDown(); h.logger.awaitIdle()
            assertEquals("", File(h.dir, "queue.jsonl").readText())
            assertTrue(h.fake.bodies.isEmpty())
            h.logger.reconfigure(h.configuration)
            assertTrue(h.logger.log(Level.INFO, "a", "new-generation"))
            h.logger.awaitIdle()
            assertFalse(File(h.dir, "queue.jsonl").readText().contains("must-not-resurrect"))
            h.close()
            Harness(h.dir).use { reopened ->
                assertEquals(1, reopened.logger.stats().queuedEvents)
                reopened.logger.drain()
                assertTrue(reopened.fake.bodies.single().contains("new-generation"))
            }
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun closeWaitsOutsideStateLockAndPreservesPendingMemory() {
        lateinit var storage: ControlledStorage
        val h = Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newFixedThreadPool(2)
        try {
            storage.block = true
            h.logger.log(Level.INFO, "a", "first")
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            h.logger.log(Level.INFO, "a", "pending-at-close")
            val closing = callers.submit { h.close() }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (!h.logger.stats().closed && System.nanoTime() < deadline) Thread.yield()
            assertTrue(h.logger.stats().closed)
            assertFalse(callers.submit<Boolean> { h.logger.log(Level.INFO, "a", "closed") }.get(1, TimeUnit.SECONDS))
            assertFalse(closing.isDone)
            storage.release.countDown(); closing.get(5, TimeUnit.SECONDS)
            Harness(h.dir).use { reopened -> assertEquals(2, reopened.logger.stats().queuedEvents) }
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun concurrentProducersAndDisableDuringBlockedStorageDoNotDeadlock() {
        lateinit var storage: ControlledStorage
        val h = Harness(count = 10, storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newFixedThreadPool(4)
        try {
            storage.block = true
            h.logger.log(Level.INFO, "a", "first")
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            val tasks = (1..4).map { callers.submit { repeat(30) { h.logger.log(Level.DEBUG, "a", "concurrent") } } }
            tasks.forEach { it.get(3, TimeUnit.SECONDS) }
            assertEquals(10, h.logger.stats().queuedEvents)
            callers.submit { h.logger.disable() }.get(1, TimeUnit.SECONDS)
            storage.release.countDown(); h.logger.awaitIdle()
            assertEquals("", File(h.dir, "queue.jsonl").readText())
            assertTrue(h.fake.bodies.isEmpty())
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun acknowledgementSnapshotCannotEraseLogsEnqueuedDuringItsWrite() {
        lateinit var storage: ControlledStorage
        val h = Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newSingleThreadExecutor()
        try {
            h.fake.reply = {
                storage.block = true // block the post-ack removal snapshot, not the initial event write
                Response(200, """{"accepted":1,"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""")
            }
            h.logger.log(Level.INFO, "a", "acknowledged")
            h.logger.flush()
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            assertEquals(1, h.logger.stats().accepted)
            assertTrue(callers.submit<Boolean> { h.logger.log(Level.INFO, "a", "after-ack") }.get(1, TimeUnit.SECONDS))
            storage.release.countDown(); h.logger.awaitIdle(); h.close()
            Harness(h.dir).use { reopened ->
                assertEquals(1, reopened.logger.stats().queuedEvents)
                reopened.logger.drain()
                assertTrue(reopened.fake.bodies.single().contains("after-ack"))
                assertFalse(reopened.fake.bodies.single().contains("acknowledged"))
            }
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun reconfigureDuringBlockedWriteRetainsCurrentPolicyAndGeneration() {
        lateinit var storage: ControlledStorage
        val h = Harness(storageFactory = { ControlledStorage(Spool(it)).also { s -> storage = s } })
        val callers = Executors.newSingleThreadExecutor()
        try {
            storage.block = true
            h.logger.log(Level.INFO, "a", "original-policy")
            assertTrue(storage.entered.await(5, TimeUnit.SECONDS))
            val replacement = Configuration(h.configuration.baseUrl, "plog_ingest_rotated", h.dir, "2.0", "22",
                redactor = Redactor { it.replace("original-policy", "new-policy") })
            callers.submit { h.logger.reconfigure(replacement) }.get(1, TimeUnit.SECONDS)
            assertTrue(h.logger.log(Level.INFO, "a", "next-event"))
            storage.release.countDown(); h.logger.awaitIdle()
            val disk = File(h.dir, "queue.jsonl").readText()
            assertTrue(disk.contains("new-policy")); assertFalse(disk.contains("original-policy"))
            assertTrue(disk.contains("next-event")); assertFalse(disk.contains("plog_ingest_rotated"))
            h.logger.drain(); h.logger.drain()
            assertEquals(2, h.logger.stats().accepted)
        } finally { storage.release.countDown(); callers.shutdownNow(); h.close() }
    }

    @Test fun wireRedactionBeforeDiskAndScalarLimits() = Harness().use { h ->
        assertTrue(h.logger.log(Level.INFO, "checkout", "Bearer abc plog_ingest_testSecret123 user@example.com password=hunter2",
            mapOf("password" to "never-write", "safe" to "user@example.com", "number" to 4, "bool" to true, "nil" to null), "corr-1"))
        h.logger.awaitIdle()
        val disk = File(h.dir, "queue.jsonl").readText()
        listOf("hunter2", "never-write", "abc", token, "user@example.com").forEach { assertFalse(disk.contains(it)) }
        h.logger.drain()
        val body = JsonParser.parseString(h.fake.bodies.single()).asJsonObject
        assertEquals(1, body.get("schema_version").asInt)
        assertEquals("1.0", body.get("app_version").asString)
        assertEquals("12", body.get("build").asString)
        assertEquals(36, body.get("installation_id").asString.length)
        val e = body.getAsJsonArray("events")[0].asJsonObject
        assertEquals("info", e.get("severity").asString)
        assertEquals(1, e.get("sequence").asInt)
        assertEquals("corr-1", e.get("correlation_id").asString)
        assertEquals(4, e.getAsJsonObject("attributes").get("number").asInt)
        assertEquals(1, h.logger.stats().accepted)
        assertEquals(0, h.logger.stats().queuedEvents)
    }
    @Test fun limitsRejectNestedNonFiniteAndOversize() = Harness().use { h ->
        assertFalse(h.logger.log(Level.DEBUG, "a", "b", mapOf("nested" to listOf(1))))
        assertFalse(h.logger.log(Level.DEBUG, "a", "b", mapOf("number" to Double.NaN)))
        assertFalse(h.logger.log(Level.DEBUG, "a", "界".repeat(4096)))
        assertTrue(h.logger.log(Level.WARNING, "c".repeat(100), "x".repeat(5000),
            (1..20).associate { "k$it" to "v".repeat(700) }.mapValues { "v" }, "c".repeat(150)))
        h.logger.drain()
        val event = JsonParser.parseString(h.fake.bodies.single()).asJsonObject.getAsJsonArray("events")[0].asJsonObject
        assertEquals(80, event.get("category").asString.length)
        assertEquals(4096, event.get("message").asString.length)
        assertEquals(128, event.get("correlation_id").asString.length)
        assertEquals(16, event.getAsJsonObject("attributes").size())
        assertEquals(3, h.logger.stats().dropped)
    }
    @Test fun finiteOutOfRangeNumbersCannotPoisonMixedBatch() = Harness().use { h ->
        h.fake.reply = { body ->
            val events = JsonParser.parseString(body).asJsonObject.getAsJsonArray("events")
            val invalid = events.any { event ->
                event.asJsonObject.getAsJsonObject("attributes").entrySet().any { (_, value) ->
                    value.isJsonPrimitive && value.asJsonPrimitive.isNumber &&
                        (!value.asDouble.isFinite() || value.asDouble !in -1e308..1e308)
                }
            }
            if (invalid) Response(422) else Response(200,
                """{"accepted":${events.size()},"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""")
        }
        assertTrue(h.logger.log(Level.INFO, "numbers", "valid-before", mapOf("number" to 42)))
        for (number in listOf(Double.MAX_VALUE, -Double.MAX_VALUE, Math.nextUp(1e308), -Math.nextUp(1e308),
            Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN)) {
            assertFalse(h.logger.log(Level.INFO, "numbers", "invalid-number", mapOf("number" to number)))
        }
        assertTrue(h.logger.log(Level.INFO, "numbers", "valid-after", mapOf("upper" to 1e308, "lower" to -1e308)))
        h.logger.awaitIdle()
        assertFalse(File(h.dir, "queue.jsonl").readText().contains("invalid-number"))
        h.logger.drain()
        assertEquals(1, h.fake.bodies.size)
        assertEquals(2, h.logger.stats().accepted)
        assertEquals(7, h.logger.stats().dropped)
        assertEquals(0, h.logger.stats().queuedEvents)
    }

    @Test fun numericBoundsAlsoProtectRecoveredSpoolAndRedactedSensitiveValues() {
        val dir = directory()
        Harness(dir).use { h ->
            assertTrue(h.logger.log(Level.INFO, "numbers", "valid", mapOf("number" to 1e308)))
            h.logger.awaitIdle()
        }
        val file = File(dir, "queue.jsonl")
        val poison = JsonParser.parseString(file.readLines().single()).asJsonObject
        poison.getAsJsonObject("event").apply {
            addProperty("event_id", java.util.UUID.randomUUID().toString())
            addProperty("message", "legacy-poison")
            getAsJsonObject("attributes").addProperty("number", Double.MAX_VALUE)
        }
        file.appendText(gson.toJson(poison) + "\n")
        Harness(dir).use { h ->
            assertEquals(1, h.logger.stats().queuedEvents)
            assertEquals(1, h.logger.stats().dropped)
            assertFalse(file.readText().contains("legacy-poison"))
            // Sensitive-key masking precedes numeric serialization: only the replacement string survives.
            assertTrue(h.logger.log(Level.INFO, "numbers", "redacted", mapOf("secret" to Double.MAX_VALUE)))
            h.logger.drain(); h.logger.drain()
            assertEquals(2, h.logger.stats().accepted)
            assertTrue(h.fake.bodies.joinToString().contains("[REDACTED]"))
            assertFalse(h.fake.bodies.joinToString().contains(Double.MAX_VALUE.toString()))
        }
    }

    @Test fun countAndByteBoundsDropOldest() {
        Harness(count = 2).use { h ->
            repeat(3) { h.logger.log(Level.INFO, "a", "m$it") }
            assertEquals(2, h.logger.stats().queuedEvents)
            assertEquals(1, h.logger.stats().dropped)
            h.logger.drain()
            assertFalse(h.fake.bodies.single().contains("m0"))
        }
        Harness(size = 8192).use { h ->
            repeat(5) { h.logger.log(Level.INFO, "a", "m$it " + "x".repeat(3500)) }
            assertTrue(h.logger.stats().queuedBytes <= 8192)
            assertTrue(h.logger.stats().dropped > 0)
            h.logger.awaitIdle()
            assertTrue(File(h.dir, "queue.jsonl").length() <= 8192)
        }
    }
    @Test fun batchesNeverExceedFiftyOr256KiB() = Harness().use { h ->
        repeat(61) { assertTrue(h.logger.log(Level.INFO, "a", "x".repeat(4096))) }
        h.logger.drain(); h.logger.drain()
        assertEquals(listOf(50, 11), h.fake.bodies.map { JsonParser.parseString(it).asJsonObject.getAsJsonArray("events").size() })
        assertTrue(h.fake.bodies.all { it.toByteArray().size <= 256 * 1024 })
        assertEquals(61, h.logger.stats().accepted)
    }
    @Test fun offlineBackoffKeepsStableEventIdsAndRequiresCommittedAck() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "b")
        h.fake.reply = { throw java.io.IOException("offline") }
        h.logger.drain(); h.logger.drain()
        assertEquals(1, h.fake.bodies.size)
        assertEquals(h.time + 500, h.logger.stats().nextAttemptAtMillis)
        h.time += 500
        h.fake.reply = { Response(200, "{}") }
        h.logger.drain()
        assertEquals(1, h.logger.stats().queuedEvents)
        h.time += 1000
        h.fake.reply = { Response(200, """{"accepted":0,"duplicate":1,"received_at":"2026-10-29T12:00:00Z"}""") }
        h.logger.drain()
        assertEquals(1, h.logger.stats().duplicates)
        assertEquals(1, h.fake.bodies.distinct().size)
        assertEquals(2, h.logger.stats().retries)
    }
    @Test fun rateLimitSecondsAndHttpDateAreRespected() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "b")
        h.fake.reply = { Response(429, retryAfter = "120") }
        h.logger.drain()
        assertEquals(h.time + 120_000, h.logger.stats().nextAttemptAtMillis)
        h.time += 120_000
        val date = java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", java.util.Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("GMT")
        }.format(java.util.Date(h.time + 30_000))
        h.fake.reply = { Response(429, retryAfter = date) }
        h.logger.drain()
        assertEquals(h.time + 30_000, h.logger.stats().nextAttemptAtMillis)
    }
    @Test fun authenticationStopsUntilReconfigured() {
        for (status in listOf(401, 403)) Harness().use { h ->
            h.logger.log(Level.INFO, "a", "b")
            h.fake.reply = { Response(status) }; h.logger.drain()
            assertTrue(h.logger.stats().stoppedForAuthentication)
            assertFalse(h.logger.log(Level.INFO, "a", "b"))
            h.time += 100_000; h.logger.drain(); assertEquals(1, h.fake.bodies.size)
            h.logger.reconfigure(h.configuration)
            h.fake.reply = { Response(200, """{"accepted":1,"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""") }
            h.logger.drain(); assertEquals(0, h.logger.stats().queuedEvents)
        }
    }
    @Test fun payloadTooLargeShrinksThenDropsSingleAndPermanentErrorsDrop() = Harness().use { h ->
        repeat(4) { h.logger.log(Level.ERROR, "a", "b") }
        h.fake.reply = { Response(413) }
        h.logger.drain(); h.logger.drain(); h.logger.drain()
        assertEquals(listOf(4, 2, 1), h.fake.bodies.map { JsonParser.parseString(it).asJsonObject.getAsJsonArray("events").size() })
        assertEquals(1, h.logger.stats().dropped)
        h.fake.reply = { Response(400) }
        repeat(3) { h.logger.drain() }
        assertEquals(4, h.logger.stats().dropped)
    }
    @Test fun expirationAndDisableStopDelivery() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "expire")
        h.time += TimeUnit.DAYS.toMillis(3)
        h.logger.drain()
        assertEquals(1, h.logger.stats().expired)
        assertEquals(0, h.fake.bodies.size)
        h.logger.log(Level.INFO, "a", "disable")
        h.logger.disable(); h.logger.drain()
        assertEquals(0, h.logger.stats().queuedEvents)
        h.logger.awaitIdle()
        assertFalse(File(h.dir, "queue.jsonl").readText().contains("disable"))
        assertFalse(h.logger.log(Level.INFO, "a", "b"))
        h.logger.reconfigure(h.configuration)
        assertTrue(h.logger.log(Level.INFO, "a", "enabled"))
    }
    @Test fun durableRecoveryPreservesMetadataIdsAndHandlesCorruption() {
        val dir = directory()
        val first = Harness(dir)
        first.logger.log(Level.INFO, "a", "persisted")
        first.logger.awaitIdle()
        val old = File(dir, "queue.jsonl").readText()
        first.close()
        File(dir, "queue.jsonl").appendText("{corrupt\n")
        Harness(dir).use { h ->
            assertEquals(1, h.logger.stats().queuedEvents)
            assertEquals(1, h.logger.stats().dropped)
            h.logger.drain()
            val event = JsonParser.parseString(h.fake.bodies.single()).asJsonObject.getAsJsonArray("events")[0].asJsonObject
            assertTrue(old.contains(event.get("event_id").asString))
            h.logger.log(Level.INFO, "a", "new session")
            h.logger.drain()
            val bodies = h.fake.bodies.map { JsonParser.parseString(it).asJsonObject }
            assertEquals(bodies[0].get("installation_id"), bodies[1].get("installation_id"))
            assertNotEquals(bodies[0].get("debug_session_id"), bodies[1].get("debug_session_id"))
        }
    }
    @Test fun directoryExclusivityAndClose() = Harness().use { h ->
        assertFails { Harness(h.dir) }
        h.logger.close()
        assertFalse(h.logger.log(Level.INFO, "a", "b"))
        assertTrue(h.logger.stats().closed)
        Harness(h.dir).close()
    }
    @Test fun urlAndCredentialValidation() {
        for (url in listOf("http://example.com", "http://localhost", "https://u:p@example.com", "https://example.com?x=1", "https://example.com/#x", "https://example.com/prefix", "ftp://127.0.0.1")) {
            assertFailsWith<IllegalArgumentException>(url) { Configuration(url, token, directory(), "1", "1") }
        }
        assertEquals("https://example.com/api/logs/ingest", ingestEndpoint("https://example.com").toString())
        assertFails { Configuration("https://example.com", "$token\r\nHeader: value", directory(), "1", "1") }
    }
    @Test fun concurrentLoggingAndAsyncFlush() = Harness(count = 2000).use { h ->
        val workers = Executors.newFixedThreadPool(4)
        repeat(4) { workers.submit { repeat(30) { h.logger.log(Level.DEBUG, "a", "b") } } }
        workers.shutdown(); assertTrue(workers.awaitTermination(20, TimeUnit.SECONDS))
        assertEquals(120, h.logger.stats().queuedEvents)
        val latch = CountDownLatch(1)
        val thread = Thread.currentThread().name
        h.fake.reply = { latch.countDown(); Response(503) }
        h.logger.flush()
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertNotEquals(thread, h.fake.threads.single())
        h.logger.awaitIdle()
        val events = File(h.dir, "queue.jsonl").readLines().map { JsonParser.parseString(it).asJsonObject.getAsJsonObject("event") }
        assertEquals(120, events.map { it.get("sequence").asLong }.distinct().size)
    }
    @Test fun authStoppedQueueStillExpires() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "expire while suspended")
        h.fake.reply = { Response(401) }; h.logger.drain()
        h.time += TimeUnit.DAYS.toMillis(3)
        h.logger.drain()
        assertEquals(0, h.logger.stats().queuedEvents)
        assertEquals(1, h.logger.stats().expired)
    }
    @Test fun invalidAcknowledgementsNeverRemoveEvents() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "atomic")
        for (ack in listOf(
            """{"accepted":0,"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""",
            """{"accepted":1,"duplicate":0,"received_at":"2026-99-99T12:00:00Z"}""",
            """{"accepted":"1","duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""",
            """{"accepted":1,"duplicate":-1,"received_at":"2026-10-29T12:00:00Z"}"""
        )) {
            h.fake.reply = { Response(200, ack) }; h.logger.drain()
            assertEquals(1, h.logger.stats().queuedEvents)
            h.time += 60_000
        }
        assertEquals(4, h.logger.stats().retries)
    }
    @Test fun responseAfterDisableCannotAcknowledgeOrRestoreQueue() = Harness().use { h ->
        h.logger.log(Level.INFO, "a", "in-flight")
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val exited = CountDownLatch(1)
        h.fake.reply = { entered.countDown(); finish.await(5, TimeUnit.SECONDS); Response(200,
            """{"accepted":1,"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""") }
        val worker = Thread { try { h.logger.drain() } finally { exited.countDown() } }
        worker.start(); assertTrue(entered.await(5, TimeUnit.SECONDS))
        h.logger.disable(); finish.countDown()
        assertTrue(exited.await(5, TimeUnit.SECONDS))
        assertEquals(0, h.logger.stats().accepted)
        assertEquals(0, h.logger.stats().queuedEvents)
        assertTrue(h.logger.stats().disabled)
    }
    @Test fun loopbackPostAndRedirectNeverLeaksCredentials() {
        val receiver = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val target = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var targetCalls = 0
        var seenAuth = ""
        var seenBody = ""
        var redirect = false
        target.createContext("/") { exchange -> targetCalls++; exchange.sendResponseHeaders(200, -1); exchange.close() }
        receiver.createContext("/api/logs/ingest") { exchange ->
            seenAuth = exchange.requestHeaders.getFirst("Authorization")
            seenBody = exchange.requestBody.bufferedReader().readText()
            if (redirect) {
                exchange.responseHeaders.add("Location", "http://127.0.0.1:${target.address.port}/stolen")
                exchange.sendResponseHeaders(307, -1)
            } else {
                val response = """{"accepted":1,"duplicate":0,"received_at":"2026-10-29T12:00:00Z"}""".toByteArray()
                exchange.sendResponseHeaders(200, response.size.toLong()); exchange.responseBody.use { it.write(response) }
            }
            exchange.close()
        }
        receiver.start(); target.start()
        try {
            val configuration = Configuration("http://127.0.0.1:${receiver.address.port}", token, directory(), "1", "1")
            val logger = ProxyceptLogger(configuration, UrlConnectionTransport(), System::currentTimeMillis,
                { 0.0 }, Executors.newSingleThreadScheduledExecutor(), false)
            logger.use {
                it.log(Level.INFO, "demo", "loopback")
                it.drain()
                assertEquals("Bearer $token", seenAuth)
                assertTrue(seenBody.contains("loopback"))
                assertEquals(1, it.stats().accepted)
                redirect = true
                it.log(Level.INFO, "demo", "redirect")
                it.drain()
                assertEquals(0, targetCalls)
                assertEquals(1, it.stats().dropped)
            }
        } finally { receiver.stop(0); target.stop(0) }
    }
}
