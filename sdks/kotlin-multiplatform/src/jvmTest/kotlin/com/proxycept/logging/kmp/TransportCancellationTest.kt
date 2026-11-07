package com.proxycept.logging.kmp

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.*
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.SocketFactory
import kotlinx.coroutines.*
import kotlinx.datetime.Clock
import kotlinx.serialization.json.*
import okhttp3.*
import kotlin.test.*

class TransportCancellationTest {
    private fun ack(n: Int = 1) = """{"accepted":$n,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}""".encodeToByteArray()
    private fun config(dir: File, port: Int) = Configuration("http://127.0.0.1:$port", "plog_ingest_cancelTest", dir.absolutePath, "1", "1")
    private suspend fun waitFor(block: () -> Boolean) = withTimeout(4000) { while (!block()) delay(10) }

    @Test fun trickleResponseHitsTotalDeadlineAndEventRetriesWithStableId() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val executor = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        server.executor = executor
        val ids = java.util.Collections.synchronizedList(mutableListOf<String>())
        server.createContext("/api/logs/ingest") { ex ->
            val tree = json.parseToJsonElement(ex.requestBody.readBytes().decodeToString()).jsonObject
            ids.add(tree.getValue("events").jsonArray[0].jsonObject.getValue("event_id").jsonPrimitive.content)
            try {
                if (ids.size == 1) {
                    ex.sendResponseHeaders(200, 0)
                    repeat(100) { ex.responseBody.write(' '.code); ex.responseBody.flush(); Thread.sleep(50) }
                } else { val bytes = ack(); ex.sendResponseHeaders(200, bytes.size.toLong()); ex.responseBody.write(bytes) }
            } catch (_: Exception) { } finally { ex.close() }
        }
        server.start()
        val dir = Files.createTempDirectory("kmp-deadline-").toFile()
        val time = AtomicLong(Clock.System.now().toEpochMilliseconds())
        val logger = ProxyceptLogger(config(dir, server.address.port), JavaTransport(250), PrivateStorage(dir.absolutePath),
            CoroutineScope(SupervisorJob() + Dispatchers.Default), { time.get() }, { 0.0 }, false)
        try {
            logger.log(Level.INFO, "deadline", "retryable"); val start = System.nanoTime(); logger.flush()
            waitFor { logger.stats().retries == 1L }
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 2000)
            assertEquals(1, logger.stats().queuedEvents)
            assertTrue(File(dir, "queue.jsonl").readText().contains("retryable"))
            time.addAndGet(60_000); logger.flush(); waitFor { logger.stats().accepted == 1L }
            assertEquals(2, ids.size); assertEquals(ids[0], ids[1])
        } finally {
            logger.close(); withTimeout(1500) { logger.awaitClosed() }
            server.stop(0); executor.shutdownNow(); dir.deleteRecursively()
        }
    }

    @Test fun disableAndCloseCancelDefaultTransportBeforeTrickleEnds() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val executor = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        server.executor = executor
        val entered = CountDownLatch(1)
        val stopped = AtomicBoolean(false)
        server.createContext("/api/logs/ingest") { ex ->
            ex.requestBody.readBytes()
            try {
                ex.sendResponseHeaders(200, 0); entered.countDown()
                repeat(100) { ex.responseBody.write(' '.code); ex.responseBody.flush(); Thread.sleep(500) }
            } catch (_: Exception) { } finally { stopped.set(true); ex.close() }
        }
        server.start()
        val dir = Files.createTempDirectory("kmp-close-trickle-").toFile()
        val logger = ProxyceptLogger(config(dir, server.address.port))
        try {
            logger.log(Level.INFO, "privacy", "clear-now"); logger.flush()
            assertTrue(withContext(Dispatchers.IO) { entered.await(4, TimeUnit.SECONDS) })
            val start = System.nanoTime()
            logger.disable(); logger.close(); withTimeout(1500) { logger.awaitClosed() }
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 1500)
            assertEquals("", File(dir, "queue.jsonl").readText())
            assertEquals(0, logger.stats().accepted)
            assertTrue(logger.stats().disabled)
        } finally { logger.close(); withTimeout(1500) { logger.awaitClosed() }; server.stop(0); executor.shutdownNow(); dir.deleteRecursively() }
    }

    private class SmallBufferSockets : SocketFactory() {
        override fun createSocket() = Socket().apply { sendBufferSize = 1024 }
        override fun createSocket(host: String, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
        override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket = createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
        override fun createSocket(host: InetAddress, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
        override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket = createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
    }
    @Test fun cancellationClosesSocketDuringBlockedRequestWrite() = runBlocking { blockedWrite(true) }
    @Test fun totalDeadlineClosesSocketDuringBlockedRequestWrite() = runBlocking { blockedWrite(false) }
    private suspend fun blockedWrite(explicitCancel: Boolean) = coroutineScope {
        val server = ServerSocket().apply { receiveBufferSize = 1024; bind(InetSocketAddress("127.0.0.1", 0)) }
        val accepted = CompletableDeferred<Socket>()
        val acceptor = launch(Dispatchers.IO) { accepted.complete(server.accept()) }
        val started = CountDownLatch(1); val bodyEnded = AtomicBoolean(false); val cancelled = AtomicBoolean(false)
        val executor = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        val client = OkHttpClient.Builder().socketFactory(SmallBufferSockets()).followRedirects(false).followSslRedirects(false)
            .dispatcher(Dispatcher(executor)).callTimeout(30, TimeUnit.SECONDS).writeTimeout(30, TimeUnit.SECONDS)
            .eventListener(object : EventListener() {
                override fun requestBodyStart(call: Call) { started.countDown() }
                override fun requestBodyEnd(call: Call, byteCount: Long) { bodyEnded.set(true) }
                override fun canceled(call: Call) { cancelled.set(true) }
            }).build()
        val request = async(Dispatchers.Default) {
            JavaTransport(if (explicitCancel) 30_000 else 350, client).post("http://127.0.0.1:${server.localPort}/api/logs/ingest", "plog_ingest_blockedWrite", ByteArray(8 * 1024 * 1024))
        }
        var peer: Socket? = null
        try {
            peer = withTimeout(4000) { accepted.await() }
            assertTrue(withContext(Dispatchers.IO) { started.await(4, TimeUnit.SECONDS) })
            delay(100); assertFalse(bodyEnded.get(), "Fixture must actually block the request write")
            if (explicitCancel) withTimeout(1500) { request.cancelAndJoin() }
            else withTimeout(1500) { assertFailsWith<TimeoutCancellationException> { request.await() } }
            waitFor { client.dispatcher.runningCallsCount() == 0 }
            assertTrue(cancelled.get())
        } finally { request.cancel(); peer?.close(); server.close(); acceptor.cancel(); client.connectionPool.evictAll(); executor.shutdownNow() }
    }
}
