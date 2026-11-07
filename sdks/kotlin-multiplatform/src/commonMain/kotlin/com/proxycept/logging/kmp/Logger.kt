package com.proxycept.logging.kmp

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.serialization.json.*
import kotlin.math.min
import kotlin.random.Random

enum class Level { DEBUG, INFO, WARNING, ERROR }

class Configuration(
    val baseUrl: String, val ingestKey: String, val spoolDirectory: String,
    val appVersion: String, val build: String,
    val debugSessionId: String = randomId(),
    val maxQueueBytes: Int = MAX_BYTES, val maxQueueEvents: Int = 2000,
    val redactor: Redactor = Redactor { it }
) {
    init {
        endpoint(baseUrl); checkToken(ingestKey)
        require(spoolDirectory.isNotEmpty() && spoolDirectory.startsWith('/')) { "Use an absolute app-private directory" }
        require(appVersion.length <= 80 && build.length <= 80 && debugSessionId.length in 1..128)
        require(maxQueueBytes in 8192..MAX_BYTES && maxQueueEvents in 1..2000)
    }
    override fun toString() = "Configuration(credentials omitted)"
}

/** Transport implementations must refuse every redirect and preserve platform TLS verification. */
fun interface Transport { suspend fun post(endpoint: String, ingestKey: String, body: ByteArray): Response }
data class Response(val status: Int, val body: String = "", val retryAfter: String? = null)
data class DeliveryStats(
    val queuedEvents: Int, val queuedBytes: Int, val accepted: Long, val duplicates: Long,
    val dropped: Long, val droppedOldest: Long, val expired: Long, val retries: Long,
    val storageFailures: Long, val stoppedForAuthentication: Boolean,
    val disabled: Boolean, val closed: Boolean, val nextAttemptAtMillis: Long,
    val persistencePending: Boolean
)

/** Constructor performs bounded private-file recovery. log/flush/disable never perform storage/network I/O. */
class ProxyceptLogger internal constructor(
    configuration: Configuration, private val transport: Transport, private val storage: Storage,
    private val scope: CoroutineScope, private val now: () -> Long, private val jitter: () -> Double,
    automatic: Boolean
) {
    constructor(configuration: Configuration) : this(configuration, defaultTransport(), PrivateStorage(configuration.spoolDirectory),
        CoroutineScope(SupervisorJob() + Dispatchers.Default), { Clock.System.now().toEpochMilliseconds() }, { Random.nextDouble() }, true)

    private val lock = StateLock()
    private var policy = configuration
    private val destination = endpoint(configuration.baseUrl)
    private val directory = configuration.spoolDirectory
    private val queue = ArrayList<Record>()
    private var total = 0
    private var seq = 0L
    private var revision = 0L
    private var persisted = -1L
    private var generation = 0L
    private var accepted = 0L
    private var duplicate = 0L
    private var dropped = 0L
    private var oldest = 0L
    private var expired = 0L
    private var retries = 0L
    private var storageFailures = 0L
    private var disabled = false
    private var closed = false
    private var authStopped = false
    private var configuring = false
    private var flushWanted = false
    private var activeRequest: Deferred<Response>? = null
    private var failures = 0
    private var limit = 50
    private var nextAttempt = 0L
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val finished = CompletableDeferred<Unit>()
    private data class Persistence(val revision: Long, val success: Boolean)
    private val persistence = MutableStateFlow(Persistence(-1, false))
    private val timer: Job?
    init {
        try {
            val loaded = storage.load(configuration, now())
            dropped = loaded.second
            queue.addAll(loaded.first); total = queue.sumOf { it.size }; bound()
            try { storage.save(queue.toList()); persisted = revision; persistence.value = Persistence(revision, true) }
            catch (_: Exception) { storageFailures++; persistence.value = Persistence(revision, false) }
        } catch (error: Throwable) { storage.close(); scope.cancel(); throw error }
        timer = if (automatic) scope.launch {
            while (isActive) { delay(2000); lock.locked { if (!closed) { flushWanted = true; wake.trySend(Unit) } } }
        } else null
        scope.launch { worker() }
    }
    /** True means admitted to bounded memory. Persistence/delivery happen asynchronously. */
    fun log(level: Level, category: String, message: String, attributes: Map<String, Any?> = emptyMap(), correlationId: String? = null): Boolean {
        val captured = lock.locked {
            if (closed || disabled || authStopped || configuring || seq == Long.MAX_VALUE) null
            else Triple(policy, generation, ++seq)
        } ?: return false
        val record = try {
            val time = now()
            Record(time, metadata(captured.first, storage.installationId), makeEvent(level, category, message,
                attributes, correlationId, randomId(), captured.third, Instant.fromEpochMilliseconds(time).toString(), captured.first))
        } catch (_: Exception) { lock.locked { dropped++ }; return false }
        return lock.locked {
            if (closed || disabled || authStopped || configuring || generation != captured.second) false
            else if (record.size > policy.maxQueueBytes) { dropped++; false }
            else { expire(); queue.add(record); total += record.size; revision++; bound(); wake.trySend(Unit); true }
        }
    }
    /** Swift-friendly scalar JSON input, using exactly the same validation/admission path. */
    fun logJson(level: Level, category: String, message: String, attributesJson: String, correlationId: String?): Boolean {
        val attrs = try { scalarMap(json.parseToJsonElement(attributesJson).jsonObject) }
        catch (_: Exception) { lock.locked { dropped++ }; return false }
        return log(level, category, message, attrs, correlationId)
    }
    fun flush() { lock.locked { if (!closed) { flushWanted = true; wake.trySend(Unit) } } }
    private fun cancelRequest(request: Deferred<Response>?) {
        // Never run transport cancellation hooks on the public/UI caller or under the state lock.
        if (request != null) scope.launch { request.cancel() }
    }
    fun disable() {
        val request = lock.locked {
            if (!closed) {
                generation++; revision++; disabled = true; configuring = false
                dropped += queue.size; queue.clear(); total = 0; wake.trySend(Unit)
                activeRequest
            } else null
        }
        cancelRequest(request)
    }
    fun reconfigure(configuration: Configuration) {
        require(configuration.spoolDirectory == directory && endpoint(configuration.baseUrl) == destination)
        val captured = lock.locked {
            check(!closed); generation++; revision++; configuring = true
            policy = configuration; disabled = false; authStopped = false; failures = 0; nextAttempt = 0; limit = 50
            Triple(generation, queue.toList(), activeRequest)
        }
        cancelRequest(captured.third)
        val cleaned = captured.second.mapNotNull { runCatching { Record.recover(it.line, configuration) }.getOrNull() }
        lock.locked {
            if (!closed && generation == captured.first) {
                dropped += captured.second.size - cleaned.size
                queue.clear(); queue.addAll(cleaned); total = cleaned.sumOf { it.size }
                revision++; configuring = false; bound(); wake.trySend(Unit)
            }
        }
    }
    fun stats(): DeliveryStats = lock.locked {
        DeliveryStats(queue.size, total, accepted, duplicate, dropped, oldest, expired, retries, storageFailures,
            authStopped, disabled, closed, nextAttempt, revision != persisted)
    }
    /** Nonblocking stop; final snapshot/clear and directory release finish on the worker. */
    fun close() {
        val request = lock.locked {
            if (!closed) { closed = true; configuring = false; generation++; timer?.cancel(); wake.trySend(Unit) }
            activeRequest
        }
        cancelRequest(request)
    }
    /** Explicit coroutine lifecycle barrier; never called by log/close. */
    suspend fun awaitClosed() = finished.await()
    internal suspend fun awaitPersistence(): Boolean {
        val target = lock.locked { wake.trySend(Unit); revision }
        return persistence.first { it.revision >= target }.success
    }
    private fun bound() {
        while (queue.size > policy.maxQueueEvents || total > policy.maxQueueBytes) {
            total -= queue.removeAt(0).size; dropped++; oldest++; revision++
        }
    }
    private fun expire() {
        val time = now()
        val i = queue.iterator()
        while (i.hasNext()) {
            val r = i.next()
            if (r.createdAt > time || time - r.createdAt >= EXPIRY) { total -= r.size; i.remove(); expired++; revision++ }
        }
    }
    private fun remove(records: List<Record>) {
        val ids = records.map { it.id }.toSet()
        val i = queue.iterator()
        while (i.hasNext()) { val r = i.next(); if (r.id in ids) { total -= r.size; i.remove(); revision++ } }
    }
    private data class Snapshot(val revision: Long, val records: List<Record>)
    private data class Batch(val generation: Long, val credential: String, val records: List<Record>)
    private suspend fun worker() {
        try {
            for (signal in wake) {
                var failed = false
                val snapshot = lock.locked {
                    expire()
                    if (!configuring && revision != persisted) Snapshot(revision, queue.toList()) else null
                }
                if (snapshot != null) {
                    try {
                        storage.save(snapshot.records)
                        lock.locked { persisted = snapshot.revision }
                        persistence.value = Persistence(snapshot.revision, true)
                    } catch (_: Exception) {
                        failed = true; lock.locked { storageFailures++ }
                        persistence.value = Persistence(snapshot.revision, false)
                    }
                }
                if (lock.locked { closed }) {
                    // close/disable may arrive during a prior write. Final state always writes last.
                    val last = lock.locked { if (revision != persisted) Snapshot(revision, queue.toList()) else null }
                    if (last != null) try {
                        storage.save(last.records); lock.locked { persisted = last.revision }
                        persistence.value = Persistence(last.revision, true)
                    } catch (_: Exception) { lock.locked { storageFailures++ }; persistence.value = Persistence(last.revision, false) }
                    break
                }
                val batch = lock.locked {
                    if (disabled || authStopped) { flushWanted = false; null }
                    else if (configuring || failed || persisted != revision || !flushWanted) null
                    else {
                        flushWanted = false
                        if (queue.isEmpty() || now() < nextAttempt) null
                        else Batch(generation, policy.ingestKey, queue.take(limit).takeWhile { it.metadata == queue.first().metadata })
                    }
                }
                if (batch != null) deliver(batch)
                lock.locked {
                    if (!configuring && revision != persisted && (!failed || revision != snapshot?.revision)) wake.trySend(Unit)
                    else if (!configuring && !failed && flushWanted) wake.trySend(Unit)
                }
            }
        } finally {
            timer?.cancel()
            try { storage.close() } finally { wake.close(); finished.complete(Unit); scope.cancel() }
        }
    }
    private suspend fun deliver(batch: Batch) {
        val selected = ArrayList<Record>()
        var body = ByteArray(0)
        for (record in batch.records) {
            selected.add(record)
            val envelope = JsonObject(record.metadata + ("events" to JsonArray(selected.map { it.event })))
            val candidate = encoded(envelope)
            if (candidate.size > 256 * 1024) { selected.removeAt(selected.lastIndex); break }
            body = candidate
        }
        val request = scope.async(start = CoroutineStart.LAZY) {
            withTimeout(10_000) { transport.post(destination, batch.credential, body) }
        }
        val allowed = lock.locked {
            val valid = !closed && !disabled && !configuring && batch.generation == generation &&
                queue.map { it.id }.toSet().containsAll(selected.map { it.id })
            if (valid) activeRequest = request
            valid
        }
        if (!allowed) { request.cancel(); return }
        request.start()
        val response = try { request.await() }
        catch (cancel: CancellationException) { if (!scope.isActive) throw cancel else null }
        catch (_: Exception) { null }
        finally { lock.locked { if (activeRequest === request) activeRequest = null } }
        val ack = if (response?.status == 200) acknowledgement(response.body, selected.size) else null
        lock.locked {
            if (closed || disabled || generation != batch.generation) return@locked
            when {
                ack != null -> { accepted += ack.accepted; duplicate += ack.duplicate; remove(selected); failures = 0; nextAttempt = 0; limit = 50 }
                response?.status in listOf(401, 403) -> authStopped = true
                response?.status == 413 -> {
                    if (selected.size == 1) { dropped++; remove(selected) } else limit = maxOf(1, selected.size / 2)
                    nextAttempt = 0
                }
                response != null && response.status in 300..499 && response.status !in listOf(408, 429) -> { dropped += selected.size; remove(selected) }
                else -> {
                    retries++; failures = min(failures + 1, 20)
                    val base = min(60_000L, 1000L * (1L shl min(failures - 1, 16)))
                    val delay = (base * (0.5 + jitter().coerceIn(0.0, 1.0) * 0.5)).toLong()
                    val wait = maxOf(delay, if (response?.status == 429) retryAfter(response.retryAfter, now()) else 0)
                    val time = now(); nextAttempt = if (time > Long.MAX_VALUE - wait) Long.MAX_VALUE else time + wait
                }
            }
        }
    }
}
