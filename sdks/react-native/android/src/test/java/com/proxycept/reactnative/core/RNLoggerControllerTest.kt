package com.proxycept.reactnative.core

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Test
import java.io.File
import java.nio.file.Files
import kotlin.test.*

class RNLoggerControllerTest {
    private fun config() = JsonObject().apply {
        addProperty("baseUrl", "http://127.0.0.1:18880"); addProperty("ingestToken", "plog_ingest_fixture")
        addProperty("appVersion", "1"); addProperty("build", "1"); addProperty("spoolName", "test")
        addProperty("debugSessionId", "rn-fixture")
    }
    private fun event(attrs: JsonObject, message: String) = JsonObject().apply {
        addProperty("level", "info"); addProperty("category", "conformance"); addProperty("message", message)
        add("attributes", attrs); add("correlationId", JsonNull.INSTANCE)
    }.toString()
    private fun vectors(): JsonArray = JsonParser.parseString(File(System.getProperty("proxycept.conformance")).readText())
        .asJsonObject.getAsJsonArray("cases")
    @Test fun sharedTenCasesMixedValidNeighborsThroughNativeController() {
        val root = Files.createTempDirectory("proxycept-rn-controller").toFile()
        val bodies = mutableListOf<String>()
        val transport = Transport { _, _, bytes ->
            val body = String(bytes, Charsets.UTF_8); bodies.add(body)
            val events = JsonParser.parseString(body).asJsonObject.getAsJsonArray("events")
            val invalid = events.any { e -> e.asJsonObject.getAsJsonObject("attributes").entrySet().any { (key, v) ->
                key.isEmpty() || (!v.isJsonNull && !v.isJsonPrimitive) ||
                    (v.isJsonPrimitive && v.asJsonPrimitive.isNumber && abs(v.asDouble) > 1e308)
            } }
            if (invalid) Response(422) else Response(200,
                """{"accepted":${events.size()},"duplicate":0,"received_at":"2026-10-30T00:00:00Z"}""")
        }
        val controller = RNLoggerController(root, transport)
        try {
            controller.configure(config().toString())
            assertTrue(controller.log(event(JsonObject(), "before")))
            var valid = 2
            val cases = vectors(); assertEquals(10, cases.size())
            cases.forEach { row ->
                val vector = row.asJsonObject
                val expected = vector.get("accepted").asBoolean
                assertEquals(expected, controller.log(event(vector.getAsJsonObject("attributes"), vector.get("name").asString)))
                if (expected) valid++
            }
            assertTrue(controller.log(event(JsonObject(), "after")))
            controller.flush()
            val stats = JsonParser.parseString(controller.deliveryStats()).asJsonObject
            assertEquals(valid, stats.get("accepted").asInt); assertEquals(0, stats.get("queued").asInt)
            val wire = bodies.joinToString()
            assertFalse(wire.contains("fixture-secret-do-not-store")); assertFalse(wire.contains("plog_ingest_fixture"))
            assertTrue(wire.contains("[REDACTED]")); assertTrue(wire.contains("rn-fixture"))
        } finally { controller.close(); root.deleteRecursively() }
    }
    @Test fun nativeControllerRejectsTraversalAndHostnameHTTP() {
        val root = Files.createTempDirectory("proxycept-rn-validation").toFile()
        val controller = RNLoggerController(root)
        try {
            for (bad in listOf("http://localhost:18880", "http://example.com", "../escape")) {
                val input = config().apply { addProperty(if (bad.startsWith("..")) "spoolName" else "baseUrl", bad) }
                assertFails { controller.configure(input.toString()) }
            }
        } finally { controller.close(); root.deleteRecursively() }
    }
}
private fun abs(number: Double) = kotlin.math.abs(number)
