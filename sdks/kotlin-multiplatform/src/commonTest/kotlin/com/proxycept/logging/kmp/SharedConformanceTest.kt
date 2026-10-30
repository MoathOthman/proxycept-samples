@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package com.proxycept.logging.kmp

import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

class SharedConformanceTest {
    @Test fun allTenSharedVectorsWithMixedValidNeighbors() = runTest {
        val cases = json.parseToJsonElement(conformanceFixtureText()).jsonObject.getValue("cases").jsonArray
        assertEquals(10, cases.size)
        for (case in cases) {
            val row = case.jsonObject
            val name = row.getValue("name").jsonPrimitive.content
            val expected = row.getValue("accepted").jsonPrimitive.boolean
            val h = Harness(backgroundScope)
            assertTrue(h.logger.log(Level.INFO, "conformance", "valid-before"), name)
            val values = row.getValue("attributes").jsonObject.mapValues { fixtureValue(it.value) }
            val admitted = h.logger.log(Level.INFO, "conformance", name, values)
            assertEquals(expected, admitted, name)
            assertTrue(h.logger.log(Level.INFO, "conformance", "valid-after"), name)
            h.logger.flush(); runCurrent()
            assertEquals(if (expected) 3 else 2, h.logger.stats().accepted.toInt(), name)
            assertEquals(0, h.logger.stats().queuedEvents, name)
            val wire = h.fake.bodies.joinToString()
            assertTrue(wire.contains("valid-before") && wire.contains("valid-after"), name)
            assertFalse(wire.contains("fixture-secret-do-not-store") || wire.contains("fixture@example.com"), name)
            h.logger.close(); runCurrent()
        }
    }
    @Test fun allTenLegacyVectorsPreserveValidNeighborsAndStableIds() = runTest {
        val cases = json.parseToJsonElement(conformanceFixtureText()).jsonObject.getValue("cases").jsonArray
        for (case in cases) {
            val row = case.jsonObject
            val name = row.getValue("name").jsonPrimitive.content
            val expected = row.getValue("accepted").jsonPrimitive.boolean
            val h = Harness(backgroundScope)
            h.logger.log(Level.INFO, "conformance", "valid-before"); h.logger.log(Level.INFO, "conformance", "valid-after")
            runCurrent()
            val before = h.store.records[0]; val after = h.store.records[1]
            val poisoned = buildJsonObject {
                put("stored_at", h.time); put("metadata", before.metadata)
                put("event", JsonObject(before.event + mapOf("event_id" to JsonPrimitive(randomId()), "attributes" to row.getValue("attributes"))))
            }.toString()
            val lines = listOf(before.line, poisoned, after.line)
            val recovered = lines.mapNotNull { runCatching { Record.recover(it, h.config) }.getOrNull() }
            assertEquals(if (expected) 3 else 2, recovered.size, name)
            assertEquals(before.id, recovered.first().id, name)
            assertEquals(after.id, recovered.last().id, name)
            assertFalse(recovered.joinToString { it.line }.contains("fixture-secret-do-not-store"), name)
            h.logger.close(); runCurrent()
        }
    }
}

private fun fixtureValue(value: JsonElement): Any? = when (value) {
    JsonNull -> null
    is JsonObject -> value.mapValues { fixtureValue(it.value) }
    is JsonArray -> value.map { fixtureValue(it) }
    is JsonPrimitive -> when {
        value.isString -> value.content
        value.booleanOrNull != null -> value.boolean
        value.longOrNull != null -> value.long
        else -> value.double
    }
}
