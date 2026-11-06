package com.proxycept.logging

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.random.Random

enum class Level { DEBUG, INFO, WARNING, ERROR }

/** Use a dedicated child of Context.noBackupFilesDir (recommended) or Context.cacheDir. */
class Configuration(
    val baseUrl: String,
    val ingestToken: String,
    val directory: File,
    val appVersion: String,
    val build: String,
    val maxQueueBytes: Int = 2 * 1024 * 1024,
    val maxQueueEvents: Int = 2000,
    val redactor: Redactor = Redactor { it }
) {
    init {
        ingestEndpoint(baseUrl); validateToken(ingestToken)
        require(appVersion.length <= 80 && build.length <= 80)
        require(maxQueueBytes in 8192..2 * 1024 * 1024 && maxQueueEvents in 1..2000)
    }
    override fun toString(): String = "Configuration(credentials omitted)"
}

data class DeliveryStats(
    val queuedEvents: Int, val queuedBytes: Int, val accepted: Long, val duplicates: Long,
    val dropped: Long, val expired: Long, val retries: Long, val storageFailures: Long,
    val stoppedForAuthentication: Boolean, val disabled: Boolean, val closed: Boolean,
    val nextAttemptAtMillis: Long
)

/** A single process/single directory logger. log() only copies/redacts and enqueues bounded memory; worker owns all runtime I/O. */
class ProxyceptLogger internal constructor(
    configuration: Configuration,
    private val transport: Transport,
    private val now: () -> Long,
    private val random: () -> Double,
    private val executor: ScheduledExecutorService,
    automatic: Boolean,
    storageFactory: (File) -> Storage = { Spool(it) }
) : AutoCloseable {
    constructor(configuration: Configuration, transport: Transport = UrlConnectionTransport()) : this(
        configuration, transport, System::currentTimeMillis, { Random.nextDouble() },
        Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "proxycept-logs").apply { isDaemon = true } }, true
    )
    private val monitor = Any()
    private val directory = configuration.directory.canonicalFile
    private val spool = storageFactory(directory)
    private var config = configuration
    private var token: String = configuration.ingestToken
    private var endpoint = ingestEndpoint(configuration.baseUrl)
    private val installationId: String
    private val debugSessionId = UUID.randomUUID().toString()
    private val queue = ArrayList<Record>()
    private var sequence = 0L
    private var accepted = 0L
    private var duplicates = 0L
    private var dropped = 0L
    private var expired = 0L
    private var retries = 0L
    private var storageFailures = 0L
    private var authStopped = false
    private var disabled = false
    private var closed = false
    private var generation = 0L
    private var failures = 0
    private var batchLimit = 50
    private var nextAttempt = 0L
    private var totalBytes = 0
    private var revision = 0L
    private var persistedRevision = -1L
    private var workQueued = false
    private var flushRequested = false
    private var reconfiguring = false
    private var workerThread: Thread? = null
    private val closeFinished = java.util.concurrent.CountDownLatch(1)
    private val expiry = TimeUnit.DAYS.toMillis(3)
    init {
        try {
            installationId = spool.installationId()
            val loaded = spool.load(config.maxQueueBytes, config.maxQueueEvents, now(), expiry)
            dropped += loaded.second
            // Reapply current policy on recovery, before any send or rewrite.
            loaded.first.forEach { old ->
                try {
                    val clean = cleanRecovered(old, config)
                    if (clean.size <= config.maxQueueBytes) queue.add(clean).also { totalBytes += clean.size } else dropped++
                } catch (_: Exception) { dropped++ }
            }
            enforceBounds()
            try { spool.save(queue.toList()); persistedRevision = revision }
            catch (_: Exception) { storageFailures++ }
            if (automatic) executor.scheduleWithFixedDelay({ synchronized(monitor) {
                if (!closed) requestWork(true)
            } }, 2, 2, TimeUnit.SECONDS)
        } catch (e: Exception) { spool.close(); executor.shutdownNow(); throw e }
    }

    private fun redact(value: String, policy: Configuration): String {
        // Run built-in protection both before and after the application's additional redactor.
        val stripped = DefaultRedactor.redact(value.replace(policy.ingestToken, "[REDACTED]"))
        return DefaultRedactor.redact(policy.redactor.redact(stripped).replace(policy.ingestToken, "[REDACTED]"))
    }
    private fun metadata(policy: Configuration): JsonObject = JsonObject().apply {
        addProperty("schema_version", 1)
        addProperty("app_version", clipped(redact(policy.appVersion, policy), 80))
        addProperty("build", clipped(redact(policy.build, policy), 80))
        addProperty("installation_id", installationId)
        addProperty("debug_session_id", debugSessionId)
    }
    private fun event(level: Level, category: String, message: String, attributes: Map<String, Any?>,
                      correlationId: String?, id: String, seq: Long, time: String, policy: Configuration): JsonObject {
        val attrs = JsonObject()
        // Caller-owned objects are copied synchronously; nested/custom objects never invoke toString().
        attributes.entries.take(16).forEach { (key, value) ->
            val name = clipped(redact(key, policy), 64)
            if (name.isNotEmpty()) {
                when {
                    sensitiveKey.matches(key) -> attrs.addProperty(name, "[REDACTED]")
                    value == null -> attrs.add(name, JsonNull.INSTANCE)
                    value is String -> attrs.addProperty(name, clipped(redact(value, policy), 512))
                    value is Boolean -> attrs.addProperty(name, value)
                    value is Byte || value is Short || value is Int || value is Long || value is Float || value is Double -> {
                        val numeric = (value as Number).toDouble()
                        // Match the ingest validator, including finite values outside its allowed range.
                        require(numeric.isFinite() && numeric in -1e308..1e308) { "Numeric attribute exceeds ingest bounds" }
                        attrs.addProperty(name, value)
                    }
                    else -> throw IllegalArgumentException("Attributes must be finite JSON scalars")
                }
            }
        }
        return JsonObject().apply {
            addProperty("event_id", id); addProperty("sequence", seq); addProperty("client_time", time)
            addProperty("severity", level.name.lowercase(Locale.US))
            addProperty("category", clipped(redact(category, policy), 80)); addProperty("message", clipped(redact(message, policy), 4096))
            add("attributes", attrs)
            if (correlationId == null) add("correlation_id", JsonNull.INSTANCE)
            else addProperty("correlation_id", clipped(redact(correlationId, policy), 128))
            require(bytes(this).size <= 8192) { "Event exceeds 8192 bytes" }
        }
    }
    private fun cleanRecovered(record: Record, policy: Configuration): Record {
        val e = record.event
        val attrs = e.getAsJsonObject("attributes").entrySet().associate { (key, v) ->
            key to when {
                v.isJsonNull -> null
                v.isJsonPrimitive && v.asJsonPrimitive.isBoolean -> v.asBoolean
                v.isJsonPrimitive && v.asJsonPrimitive.isNumber -> v.asDouble
                v.isJsonPrimitive && v.asJsonPrimitive.isString -> v.asString
                else -> error("Invalid stored attribute")
            }
        }
        val cleanEvent = event(Level.valueOf(e.get("severity").asString.uppercase(Locale.US)),
            e.get("category").asString, e.get("message").asString, attrs,
            e.get("correlation_id").takeUnless { it.isJsonNull }?.asString,
            e.get("event_id").asString, e.get("sequence").asLong, e.get("client_time").asString, policy)
        val meta = JsonObject().apply {
            addProperty("schema_version", 1)
            listOf("app_version", "build", "installation_id", "debug_session_id").forEach { key ->
                val value = record.metadata.get(key).asString
                require(value.length <= if (key == "app_version" || key == "build") 80 else 128)
                addProperty(key, clipped(redact(value, policy), if (key == "app_version" || key == "build") 80 else 128))
            }
        }
        return Record(record.storedAt, meta, cleanEvent)
    }

    /** True means accepted into bounded memory, not yet durable or delivered. No disk/network I/O. */
    fun log(level: Level, category: String, message: String, attributes: Map<String, Any?> = emptyMap(),
            correlationId: String? = null): Boolean {
        val captured = synchronized(monitor) {
            if (closed || disabled || authStopped || reconfiguring) return false
            if (sequence == Long.MAX_VALUE) { dropped++; return false }
            Triple(config, generation, ++sequence)
        }
        // No application redactor, JSON serialization, or storage operation runs under the state lock.
        val record = try {
            val time = now()
            Record(time, metadata(captured.first), event(level, category, message, attributes, correlationId,
                UUID.randomUUID().toString(), captured.third, isoTime(time), captured.first)).also { it.size }
        } catch (_: Exception) { synchronized(monitor) { dropped++ }; return false }
        return synchronized(monitor) {
            if (closed || disabled || authStopped || reconfiguring || captured.second != generation) return false
            if (record.size > config.maxQueueBytes) { dropped++; return false }
            expire()
            queue.add(record); totalBytes += record.size; revision++
            enforceBounds()
            requestWork(false)
            true
        }
    }

    // The following queue helpers require monitor. Record sizes are computed before publication.
    private fun queueBytes(): Int = totalBytes
    private fun enforceBounds() {
        while (queue.size > config.maxQueueEvents || totalBytes > config.maxQueueBytes) {
            totalBytes -= queue.removeAt(0).size; dropped++; revision++
        }
    }
    private fun expire() {
        val time = now()
        val iterator = queue.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (record.storedAt > time || time - record.storedAt >= expiry) {
                totalBytes -= record.size; iterator.remove(); expired++; revision++
            }
        }
    }
    private fun remove(records: List<Record>) {
        val ids = records.map { it.id }.toSet()
        val iterator = queue.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (record.id in ids) { totalBytes -= record.size; iterator.remove(); revision++ }
        }
    }

    /** Coalesced async flush, including persistence; respects delivery backoff. */
    fun flush() = synchronized(monitor) { if (!closed) requestWork(true) }

    // At most one queued/running work item, regardless of producer rate or blocked storage/network.
    private fun requestWork(send: Boolean) {
        flushRequested = flushRequested || send
        if (!workQueued) { workQueued = true; executor.execute { work() } }
    }
    private data class Snapshot(val records: List<Record>, val revision: Long)
    private data class Batch(val records: List<Record>, val token: String,
                             val endpoint: java.net.URI, val generation: Long)

    private fun work() {
        workerThread = Thread.currentThread()
        var attemptedRevision = -1L
        var writeFailed = false
        try {
            val snapshot = synchronized(monitor) {
                expire()
                if (!reconfiguring && revision != persistedRevision) Snapshot(queue.toList(), revision) else null
            }
            if (snapshot != null) {
                attemptedRevision = snapshot.revision
                try {
                    // Serialized worker is the sole writer. Producers/disable never wait on this I/O.
                    spool.save(snapshot.records)
                    synchronized(monitor) { persistedRevision = snapshot.revision }
                } catch (_: Exception) {
                    writeFailed = true
                    synchronized(monitor) { storageFailures++ }
                }
            }
            val batch = synchronized(monitor) {
                // Retain a flush request while a concurrent producer/reconfigure invalidates the snapshot.
                if (closed || disabled || authStopped) { flushRequested = false; null }
                else if (reconfiguring || revision != persistedRevision || writeFailed) null
                else if (!flushRequested) null
                else {
                    flushRequested = false
                    if (queue.isEmpty() || now() < nextAttempt) null
                    else {
                        val meta = queue.first().metadata
                        Batch(queue.take(batchLimit).takeWhile { it.metadata == meta }, token, endpoint, generation)
                    }
                }
            }
            if (batch != null) deliver(batch)
        } finally {
            val finishClose = synchronized(monitor) {
                workQueued = false
                if (closed) true
                else {
                    // A failed write retries on the next tick/explicit request, never a tight failure loop.
                    if (!reconfiguring && (revision != persistedRevision || flushRequested) &&
                        (!writeFailed || revision != attemptedRevision)) requestWork(false)
                    false
                }
            }
            if (finishClose) {
                // A close/disable may have arrived during the preceding write/network call. Save latest
                // state last, before releasing directory ownership, so stale snapshots cannot resurrect.
                val last = synchronized(monitor) {
                    if (revision != persistedRevision) Snapshot(queue.toList(), revision) else null
                }
                try {
                    if (last != null) {
                        try { spool.save(last.records); synchronized(monitor) { persistedRevision = last.revision } }
                        catch (_: Exception) { synchronized(monitor) { storageFailures++ } }
                    }
                } finally {
                    try { spool.close() } finally { executor.shutdown(); closeFinished.countDown() }
                }
            }
        }
    }

    private fun deliver(batch: Batch) {
        // Batching/serialization is also outside the state lock.
        val selected = ArrayList<Record>()
        var body = ByteArray(0)
        for (record in batch.records) {
            selected.add(record)
            val envelope = record.metadata.deepCopy()
            envelope.add("events", JsonArray().apply { selected.forEach { add(it.event) } })
            val candidate = bytes(envelope)
            if (candidate.size > 256 * 1024) { selected.removeAt(selected.lastIndex); break }
            body = candidate
        }
        synchronized(monitor) {
            if (closed || disabled || reconfiguring || generation != batch.generation ||
                !queue.map { it.id }.toSet().containsAll(selected.map { it.id })) return
        }
        val response = try { transport.post(batch.endpoint, batch.token, body) } catch (_: Exception) { null }
        val ack = if (response?.status == 200 && acknowledged(response.body, selected.size))
            JsonParser.parseString(response.body).asJsonObject else null
        synchronized(monitor) {
            if (closed || disabled || batch.generation != generation) return
            when {
                ack != null -> {
                    accepted += ack.get("accepted").asLong; duplicates += ack.get("duplicate").asLong
                    remove(selected); failures = 0; nextAttempt = 0; batchLimit = 50
                }
                response?.status == 401 || response?.status == 403 -> { authStopped = true; token = "" }
                response?.status == 413 -> {
                    if (selected.size == 1) { dropped++; remove(selected) }
                    else batchLimit = maxOf(1, selected.size / 2)
                    nextAttempt = 0
                }
                response != null && response.status in 300..499 && response.status !in listOf(408, 429) -> {
                    dropped += selected.size; remove(selected)
                }
                else -> {
                    retries++; failures = min(failures + 1, 20)
                    val backoff = min(60_000L, 1000L * (1L shl min(failures - 1, 16)))
                    val delay = (backoff * (0.5 + random().coerceIn(0.0, 1.0) * 0.5)).toLong()
                    val retryAfter = if (response?.status == 429) retryAfterMillis(response.retryAfter) else 0L
                    val time = now(); val wait = maxOf(delay, retryAfter)
                    nextAttempt = if (time > Long.MAX_VALUE - wait) Long.MAX_VALUE else time + wait
                }
            }
        }
    }

    /** Deterministic test barrier; never used by log()/production scheduling. */
    internal fun awaitIdle() {
        check(Thread.currentThread() !== workerThread)
        do {
            executor.submit {}.get(20, TimeUnit.SECONDS)
        } while (synchronized(monitor) { workQueued })
    }
    internal fun drain() { flush(); awaitIdle() }
    private fun acknowledged(body: String, count: Int): Boolean = runCatching {
        val ack = JsonParser.parseString(body).asJsonObject
        require(ack.getAsJsonPrimitive("accepted").isNumber && ack.getAsJsonPrimitive("duplicate").isNumber)
        val a = ack.get("accepted").asString.toLong()
        val d = ack.get("duplicate").asString.toLong()
        require(a in 0..count.toLong() && d in 0..count.toLong() && a + d == count.toLong())
        require(validIsoTime(ack.get("received_at").asString))
        true
    }.getOrDefault(false)
    private fun retryAfterMillis(value: String?): Long {
        if (value == null) return 0
        val seconds = value.trim().toLongOrNull()
        if (seconds != null) return seconds.coerceIn(0, Long.MAX_VALUE / 1000) * 1000
        return runCatching {
            val date = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).parse(value)!!
            (date.time - now()).coerceAtLeast(0)
        }.getOrDefault(0)
    }

    /** Same origin/directory only. Local canonical-path validation may do disk I/O. */
    fun reconfigure(configuration: Configuration) {
        require(configuration.directory.canonicalFile == directory)
        require(ingestEndpoint(configuration.baseUrl) == endpoint) { "Create a separate spool for a different origin" }
        val captured = synchronized(monitor) {
            check(!closed)
            generation++; revision++; reconfiguring = true
            config = configuration; token = configuration.ingestToken
            authStopped = false; disabled = false; failures = 0; nextAttempt = 0; batchLimit = 50
            generation to queue.toList()
        }
        val cleaned = captured.second.mapNotNull { runCatching {
            cleanRecovered(it, configuration).also { record -> record.size }
        }.getOrNull() }
        synchronized(monitor) {
            if (generation != captured.first || closed) return
            dropped += captured.second.size - cleaned.size
            queue.clear(); queue.addAll(cleaned); totalBytes = cleaned.sumOf { it.size }
            revision++; reconfiguring = false; enforceBounds(); requestWork(false)
        }
    }
    /** Immediate memory/dispatch disable; ordered worker clear follows outstanding I/O. */
    fun disable() = synchronized(monitor) {
        if (!closed) {
            generation++; revision++; disabled = true; reconfiguring = false; token = ""
            dropped += queue.size; queue.clear(); totalBytes = 0; requestWork(false)
        }
    }
    fun stats(): DeliveryStats = synchronized(monitor) {
        DeliveryStats(queue.size, queueBytes(), accepted, duplicates, dropped, expired, retries,
            storageFailures, authStopped, disabled, closed, nextAttempt)
    }
    /** Blocking lifecycle barrier: persists pending memory and releases the directory on the worker.
     * Does not request delivery. Do not call on the UI thread; log() never waits for this barrier. */
    override fun close() {
        synchronized(monitor) {
            if (!closed) {
                generation++; closed = true; token = ""; reconfiguring = false; requestWork(false)
            }
        }
        if (Thread.currentThread() !== workerThread) closeFinished.await()
    }
}
