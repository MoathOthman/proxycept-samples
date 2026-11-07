package com.proxycept.logging.kmp

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.datetime.Clock
import kotlinx.serialization.json.*
import kotlin.test.*

class JvmIntegrationTest {
    private fun dir() = Files.createTempDirectory("proxycept-kmp-test-").toFile()
    private fun config(dir: File, url: String = "http://127.0.0.1:18880") = Configuration(url, "plog_ingest_jvmTest", dir.absolutePath, "1", "1")
    private suspend fun stopped(logger: ProxyceptLogger) { logger.close(); withTimeout(10_000) { logger.awaitClosed() } }
    @Test fun loopbackPostAndAllRedirectsDoNotLeakCredentials() = runBlocking {
        val receiver = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val target = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var targetCalls = 0
        var status = 200
        var seen = ""
        target.createContext("/") { ex -> targetCalls++; ex.sendResponseHeaders(200, -1); ex.close() }
        receiver.createContext("/api/logs/ingest") { ex ->
            seen = ex.requestHeaders.getFirst("Authorization")
            val body = ex.requestBody.readBytes().decodeToString()
            assertFalse(body.contains("must-be-redacted"))
            if (status == 200) {
                val bytes = """{"accepted":1,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""".encodeToByteArray()
                ex.sendResponseHeaders(200, bytes.size.toLong()); ex.responseBody.use { it.write(bytes) }
            } else {
                ex.responseHeaders.add("Location", "http://127.0.0.1:${target.address.port}/stolen")
                ex.sendResponseHeaders(status, -1)
            }
            ex.close()
        }
        receiver.start(); target.start()
        val directory = dir()
        val logger = ProxyceptLogger(config(directory, "http://127.0.0.1:${receiver.address.port}"))
        try {
            logger.log(Level.INFO, "loopback", "first", mapOf("password" to "must-be-redacted")); logger.flush()
            withTimeout(5000) { while (logger.stats().accepted != 1L) delay(10) }
            assertEquals("Bearer plog_ingest_jvmTest", seen)
            for ((index, redirect) in listOf(301, 302, 303, 307, 308).withIndex()) {
                status = redirect; logger.log(Level.INFO, "loopback", "redirect"); logger.flush()
                withTimeout(5000) { while (logger.stats().dropped < index + 1) delay(10) }
            }
            assertEquals(0, targetCalls)
        } finally { stopped(logger); receiver.stop(0); target.stop(0); directory.deleteRecursively() }
    }
    @Test fun realSpoolRecoveryAllSharedVectorsAndCorruption() = runBlocking {
        val rows = json.parseToJsonElement(conformanceFixtureText()).jsonObject.getValue("cases").jsonArray
        for (row in rows.map { it.jsonObject }) {
            val directory = dir()
            val policy = config(directory)
            val first = ProxyceptLogger(policy)
            first.log(Level.INFO, "fixture", "before"); first.log(Level.INFO, "fixture", "after")
            stopped(first)
            val file = File(directory, "queue.jsonl")
            val lines = file.readLines()
            val raw = json.parseToJsonElement(lines.first()).jsonObject
            val event = raw.getValue("event").jsonObject
            val poison = JsonObject(raw + ("event" to JsonObject(event + mapOf("event_id" to JsonPrimitive(randomId()), "attributes" to row.getValue("attributes")))))
            file.writeText(lines.first() + "\n" + poison + "\n{corrupt\n" + lines.last() + "\n")
            val recovered = ProxyceptLogger(policy)
            try {
                assertEquals(if (row.getValue("accepted").jsonPrimitive.boolean) 3 else 2, recovered.stats().queuedEvents)
                assertFalse(file.readText().contains("fixture-secret-do-not-store"))
                assertTrue(file.readText().contains("before") && file.readText().contains("after"))
            } finally { stopped(recovered); directory.deleteRecursively() }
        }
    }
    @Test fun blockedStorageDoesNotBlockLogStatsDisableOrGrowWorkerBacklog() = runBlocking {
        val directory = dir()
        val delegate = PrivateStorage(directory.absolutePath)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        var blocking = false
        val store = object : Storage by delegate {
            override fun save(records: List<Record>) {
                if (blocking) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
                delegate.save(records)
            }
        }
        val logger = ProxyceptLogger(config(directory), Transport { _, _, _ -> error("Not flushed") }, store,
            CoroutineScope(SupervisorJob() + Dispatchers.Default), { Clock.System.now().toEpochMilliseconds() }, { 0.0 }, false)
        val callers = Executors.newFixedThreadPool(4)
        try {
            blocking = true
            logger.log(Level.INFO, "slow", "first")
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val tasks = (1..4).map { callers.submit { repeat(60) { assertTrue(logger.log(Level.INFO, "slow", "another")) } } }
            tasks.forEach { it.get(2, TimeUnit.SECONDS) }
            assertEquals(241, logger.stats().queuedEvents)
            callers.submit { logger.disable() }.get(1, TimeUnit.SECONDS)
            assertFalse(logger.log(Level.INFO, "slow", "blocked"))
            release.countDown(); stopped(logger)
            assertEquals("", File(directory, "queue.jsonl").readText())
        } finally { release.countDown(); callers.shutdownNow(); stopped(logger); directory.deleteRecursively() }
    }
    @Test fun privateModesPrecedePayloadAndPersistedFilesStayOwnerOnly() = runBlocking {
        val directory = dir()
        val probe = File(directory, "permission-probe")
        preparePrivateFile(probe.absolutePath)
        assertEquals(0, probe.length())
        val expected = java.nio.file.attribute.PosixFilePermissions.fromString("rw-------")
        assertEquals(expected, Files.getPosixFilePermissions(probe.toPath()))
        val logger = ProxyceptLogger(config(directory))
        try { logger.log(Level.INFO, "privacy", "content"); stopped(logger)
            for (name in listOf("queue.jsonl", "installation-id", "owner.lock"))
                assertEquals(expected, Files.getPosixFilePermissions(File(directory, name).toPath()), name)
        } finally { stopped(logger); directory.deleteRecursively() }
    }
    @Test fun realLegacySpoolNormalizesCorrelationAndDropsEmptyMetadataWithNeighbors() = runBlocking {
        val directory = dir()
        val policy = config(directory)
        val original = ProxyceptLogger(policy)
        repeat(4) { original.log(Level.INFO, "legacy-ids", "neighbor-$it", correlationId = "valid-$it") }
        stopped(original)
        val file = File(directory, "queue.jsonl")
        val rows = file.readLines().map { json.parseToJsonElement(it).jsonObject }.toMutableList()
        rows[1] = JsonObject(rows[1] + ("event" to JsonObject(rows[1].getValue("event").jsonObject + ("correlation_id" to JsonPrimitive("")))))
        rows[2] = JsonObject(rows[2] + ("metadata" to JsonObject(rows[2].getValue("metadata").jsonObject + ("debug_session_id" to JsonPrimitive("")))))
        file.writeText(rows.joinToString("\n", postfix = "\n"))
        val fake = FakeTransport()
        val reopened = ProxyceptLogger(policy, fake, PrivateStorage(directory.absolutePath),
            CoroutineScope(SupervisorJob() + Dispatchers.Default), { Clock.System.now().toEpochMilliseconds() }, { 0.0 }, false)
        try {
            assertEquals(3, reopened.stats().queuedEvents)
            assertEquals(1, reopened.stats().dropped)
            val rewritten = file.readLines().map { json.parseToJsonElement(it).jsonObject }
            assertEquals(JsonNull, rewritten[1].getValue("event").jsonObject.getValue("correlation_id"))
            val retained = listOf(0, 1, 3).map { rows[it].getValue("event").jsonObject.getValue("event_id") }
            assertEquals(retained, rewritten.map { it.getValue("event").jsonObject.getValue("event_id") })
            reopened.flush()
            withTimeout(5000) { while (reopened.stats().accepted != 3L) delay(10) }
        } finally { stopped(reopened); directory.deleteRecursively() }
    }
    @Test fun directoryLockAndClosePersistPendingAdmission() = runBlocking {
        val directory = dir()
        val logger = ProxyceptLogger(config(directory))
        try {
            assertFails { ProxyceptLogger(config(directory)) }
            logger.log(Level.INFO, "close", "pending")
            stopped(logger)
            val reopened = ProxyceptLogger(config(directory))
            try { assertEquals(1, reopened.stats().queuedEvents) } finally { stopped(reopened) }
        } finally { stopped(logger); directory.deleteRecursively() }
    }
}
