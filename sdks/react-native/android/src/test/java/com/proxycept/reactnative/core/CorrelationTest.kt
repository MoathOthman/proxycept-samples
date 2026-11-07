package com.proxycept.reactnative.core

import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.test.*

class CorrelationTest {
    private class Peer : Transport {
        val messages = mutableListOf<String>()
        override fun post(endpoint: java.net.URI, token: String, body: ByteArray): Response {
            val events = JsonParser.parseString(String(body, Charsets.UTF_8)).asJsonObject.getAsJsonArray("events")
            for (event in events) {
                val c = event.asJsonObject.get("correlation_id")
                if (!c.isJsonNull && (!c.isJsonPrimitive || !c.asJsonPrimitive.isString || c.asString.isEmpty() || c.asString.codePointCount(0, c.asString.length) > 128)) return Response(422)
            }
            messages.addAll(events.map { it.asJsonObject.get("message").asString })
            return Response(200, """{"accepted":${events.size()},"duplicate":0,"received_at":"2026-10-30T00:00:00Z"}""")
        }
    }
    private fun config(dir: File) = Configuration("http://127.0.0.1:18880", "plog_ingest_fixture", dir, "1", "1")
    @Test fun coreAndRNWireRejectEmptyCorrelationWithValidNeighbors() {
        val root = Files.createTempDirectory("rn-correlation").toFile()
        val peer = Peer(); val logger = ProxyceptLogger(config(File(root, "core")), peer)
        try {
            assertTrue(logger.log(Level.INFO, "correlation", "before"))
            assertFalse(logger.log(Level.INFO, "correlation", "invalid", correlationId = ""))
            assertFalse(logger.log(Level.INFO, "correlation", "long", correlationId = "x".repeat(129)))
            assertTrue(logger.log(Level.INFO, "correlation", "after", correlationId = "x".repeat(128)))
            logger.drain(); assertEquals(listOf("before", "after"), peer.messages)
            assertEquals(2, logger.stats().accepted); assertEquals(2, logger.stats().dropped)
        } finally { logger.close() }
        val bridgePeer = Peer(); val controller = RNLoggerController(File(root, "bridge"), bridgePeer)
        try {
            controller.configure("""{"baseUrl":"http://127.0.0.1:18880","ingestToken":"plog_ingest_fixture","appVersion":"1","build":"1"}""")
            fun log(correlation: String, message: String) = controller.log("""{"level":"info","category":"correlation","message":"$message","attributes":{},"correlationId":$correlation}""")
            assertTrue(log("null", "before")); assertFalse(log("\"\"", "invalid")); assertFalse(log("123", "number"))
            assertTrue(log("\"request-1\"", "after")); controller.flush()
            assertEquals(listOf("before", "after"), bridgePeer.messages)
        } finally { controller.close(); root.deleteRecursively() }
    }
    @Test fun recoveryDropsEmptyCorrelationWithoutLosingValidNeighborIDs() {
        val root = Files.createTempDirectory("rn-correlation-recovery").toFile(); val peer = Peer()
        val metadata = JsonObject().apply {
            addProperty("schema_version", 1); addProperty("app_version", "1"); addProperty("build", "1")
            addProperty("installation_id", "legacy"); addProperty("debug_session_id", "session")
        }
        val correlations = listOf(null, "", "request-1", "x".repeat(129))
        val entries = correlations.mapIndexed { index, correlation ->
            Record(System.currentTimeMillis(), metadata.deepCopy(), JsonObject().apply {
                addProperty("event_id", UUID.randomUUID().toString()); addProperty("sequence", index)
                addProperty("client_time", isoTime(System.currentTimeMillis())); addProperty("severity", "info")
                addProperty("category", "correlation"); addProperty("message", "record-$index"); add("attributes", JsonObject())
                if (correlation == null) add("correlation_id", JsonNull.INSTANCE) else addProperty("correlation_id", correlation)
            })
        }
        val file = File(root, "queue.jsonl")
        file.writeText(entries.joinToString("\n", postfix = "\n") { gson.toJson(it.json()) })
        val logger = ProxyceptLogger(config(root), peer)
        try {
            assertEquals(2, logger.stats().queuedEvents); assertEquals(2, logger.stats().dropped)
            val recovered = file.readLines().map { Record.parse(it).id }
            assertEquals(listOf(entries[0].id, entries[2].id), recovered)
            logger.drain(); assertEquals(listOf("record-0", "record-2"), peer.messages)
            assertEquals(2, logger.stats().accepted); assertEquals(0, logger.stats().queuedEvents)
        } finally { logger.close(); root.deleteRecursively() }
    }
}
